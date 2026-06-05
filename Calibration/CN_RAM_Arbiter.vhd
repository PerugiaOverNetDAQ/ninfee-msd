--!@file CN_RAM_Arbiter.vhd
--!@brief Ping-pong CN RAM arbiter for one ADC true dual-port RAM.
--!@details The RAM is 128 words and is split into two logical 64-word banks.
--!         Port A is reserved for the downstream readout whenever a readout is
--!         active. In the same cycles, the writer can still use Port B to fill
--!         the opposite bank. SMA keeps its two-port behaviour, but it is granted
--!         only when neither the reader nor the writer is using the RAM.
--!@author Luca Russo
--!@date 05/06/2026
--!@version 2.0 - ping-pong bank support

library ieee;
use ieee.std_logic_1164.all;

use work.FOOTpackage.all;
use work.basic_package.all;

entity CN_RAM_Arbiter is
    generic (
        pADDR_WIDTH : natural := ceil_log2(cFE_CHANNELS); -- local bank address width: 64 -> 6
        pDATA_WIDTH : natural := cADC_DATA_WIDTH
    );
    port (
        -- Writer side ---------------------------------------------------------
        iWR_req  : in  std_logic;
        oWR_grant: out std_logic;
        iWR_en   : in  std_logic;
        iWR_bank : in  std_logic;
        iWR_addr : in  std_logic_vector(pADDR_WIDTH-1 downto 0);
        iWR_data : in  std_logic_vector(pDATA_WIDTH-1 downto 0);

        -- SMA side ------------------------------------------------------------
        iSMA_req       : in  std_logic;
        oSMA_grant     : out std_logic;
        iSMA_bank      : in  std_logic;
        iSMA_rd_en_a   : in  std_logic;
        iSMA_rd_addr_a : in  std_logic_vector(pADDR_WIDTH-1 downto 0);
        oSMA_rd_data_a : out std_logic_vector(pDATA_WIDTH-1 downto 0);
        iSMA_rd_en_b   : in  std_logic;
        iSMA_rd_addr_b : in  std_logic_vector(pADDR_WIDTH-1 downto 0);
        oSMA_rd_data_b : out std_logic_vector(pDATA_WIDTH-1 downto 0);

        -- Downstream reader side ---------------------------------------------
        iRD_req       : in  std_logic;
        oRD_grant     : out std_logic;
        iRD_en_a      : in  std_logic;
        iRD_bank      : in  std_logic;
        iRD_addr_a    : in  std_logic_vector(pADDR_WIDTH-1 downto 0);
        oRD_data_a    : out std_logic_vector(pDATA_WIDTH-1 downto 0);

        -- Physical RAM side: one extra MSB selects the bank -------------------
        oRAM_addr_a : out std_logic_vector(pADDR_WIDTH downto 0);
        oRAM_data_a : out std_logic_vector(pDATA_WIDTH-1 downto 0);
        oRAM_we_a   : out std_logic;
        oRAM_re_a   : out std_logic;
        iRAM_data_a : in  std_logic_vector(pDATA_WIDTH-1 downto 0);

        oRAM_addr_b : out std_logic_vector(pADDR_WIDTH downto 0);
        oRAM_data_b : out std_logic_vector(pDATA_WIDTH-1 downto 0);
        oRAM_we_b   : out std_logic;
        oRAM_re_b   : out std_logic;
        iRAM_data_b : in  std_logic_vector(pDATA_WIDTH-1 downto 0)
    );
end entity CN_RAM_Arbiter;

architecture Behavioral of CN_RAM_Arbiter is
    signal sSMA_grant : std_logic;
    signal sWR_grant  : std_logic;
    signal sRD_grant  : std_logic;

    function f_phys_addr(
        bank : std_logic;
        addr : std_logic_vector(pADDR_WIDTH-1 downto 0)
    ) return std_logic_vector is
        variable v : std_logic_vector(pADDR_WIDTH downto 0);
    begin
        v := bank & addr;
        return v;
    end function;
begin

    -- Reader and writer can be granted together because they use different RAM
    -- ports and, at system level, different banks. SMA keeps both ports and is
    -- therefore granted only when both of them are free.
    sRD_grant  <= iRD_req;
    sWR_grant  <= iWR_req;
    sSMA_grant <= iSMA_req and not iRD_req and not iWR_req;

    oRD_grant  <= sRD_grant;
    oWR_grant  <= sWR_grant;
    oSMA_grant <= sSMA_grant;

    oSMA_rd_data_a <= iRAM_data_a;
    oSMA_rd_data_b <= iRAM_data_b;
    oRD_data_a     <= iRAM_data_a;

    process(all)
    begin
        oRAM_addr_a <= (others => '0');
        oRAM_data_a <= (others => '0');
        oRAM_we_a   <= '0';
        oRAM_re_a   <= '0';

        oRAM_addr_b <= (others => '0');
        oRAM_data_b <= (others => '0');
        oRAM_we_b   <= '0';
        oRAM_re_b   <= '0';

        if sRD_grant = '1' then
            -- Port A reads the completed bank for CN subtraction.
            oRAM_addr_a <= f_phys_addr(iRD_bank, iRD_addr_a);
            oRAM_re_a   <= iRD_en_a;

            -- While Port A is reading the old bank, Port B can already write
            -- the new bank. SMA waits until the readout is finished.
            if sWR_grant = '1' then
                oRAM_addr_b <= f_phys_addr(iWR_bank, iWR_addr);
                oRAM_data_b <= iWR_data;
                oRAM_we_b   <= iWR_en;
            end if;

        elsif sWR_grant = '1' then
            -- No readout active: writer uses Port A. Keeping the writer atomic
            -- avoids sharing one port with SMA in the same cycle.
            oRAM_addr_a <= f_phys_addr(iWR_bank, iWR_addr);
            oRAM_data_a <= iWR_data;
            oRAM_we_a   <= iWR_en;

        elsif sSMA_grant = '1' then
            -- SMA owns both ports for heap comparisons.
            oRAM_addr_a <= f_phys_addr(iSMA_bank, iSMA_rd_addr_a);
            oRAM_re_a   <= iSMA_rd_en_a;

            oRAM_addr_b <= f_phys_addr(iSMA_bank, iSMA_rd_addr_b);
            oRAM_re_b   <= iSMA_rd_en_b;
        end if;
    end process;

end architecture Behavioral;
