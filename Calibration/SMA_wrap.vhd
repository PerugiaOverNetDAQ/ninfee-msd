--!@file SMA_wrap.vhd
--!@brief 2VAs CN RAM + arbiter + pointer SMA wrapper, one instance per ADC.
--!@details For each ADC it instantiates one 128-word true dual-port RAM split in
--!         two 64-word banks, one RAM arbiter and one StreamingMedian using heap
--!         pointers. The RAM stores all samples; SMA stores only the local
--!         addresses of the samples accepted for the median. CN can read one bank
--!         while the writer fills the opposite bank.
--!@author Luca Russo
--!@date 05/06/2026
--!@version 2.0 

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.basic_package.all;
use work.FOOTpackage.all;

entity SMA_wrap is
    generic (
        pHEAP_SIZE   : natural := cHEAP_SIZE;
        pCALC_MODE   : natural := cSMA_CALC_MODE;
        pADC_NUM     : natural := cTOTAL_ADCS;
        pDATA_WIDTH  : natural := cADC_DATA_WIDTH;
        pRAM_DEPTH   : natural := 2*cFE_CHANNELS; -- two 64-word banks
        pADDR_WIDTH  : natural := ceil_log2(cFE_CHANNELS); -- local address inside a bank
        pFORCE_MLAB  : natural := 0
    );
    port (
        iCLK : in std_logic;
        iRST : in std_logic;

        iCN_RST      : in  std_logic;
        iCN_WR_en    : in  std_logic;
        iCN_WR_bank  : in  std_logic;
        iCN_WR_addr  : in  std_logic_vector(pADDR_WIDTH-1 downto 0);
        iCN_WR_data  : in  t_FOOT_lef_data;
        iCN_INS_en   : in  std_logic_vector(pADC_NUM-1 downto 0);
        iCN_Flush    : in  std_logic_vector(pADC_NUM-1 downto 0);
        oCN_Median   : out t_FOOT_lef_data;
        oCN_Valid    : out std_logic_vector(pADC_NUM-1 downto 0);
        oCN_Ready    : out std_logic;

        iCN_RD_req   : in  std_logic;
        iCN_RD_en    : in  std_logic;
        iCN_RD_bank  : in  std_logic;
        iCN_RD_addr  : in  std_logic_vector(pADDR_WIDTH-1 downto 0);
        oCN_RD_grant : out std_logic;
        oCN_RD_data  : out t_FOOT_lef_data;
        oCN_RD_valid : out std_logic;

        iCAL_priority : in  std_logic;
        iCAL_RST      : in  std_logic;
        iCAL_WR_en    : in  std_logic;
        iCAL_WR_addr  : in  std_logic_vector(pADDR_WIDTH-1 downto 0);
        iCAL_WR_data  : in  t_FOOT_lef_data;
        iCAL_INS_en   : in  std_logic_vector(pADC_NUM-1 downto 0);
        iCAL_Flush    : in  std_logic_vector(pADC_NUM-1 downto 0);
        oCAL_Median   : out t_FOOT_lef_data;
        oCAL_Valid    : out std_logic_vector(pADC_NUM-1 downto 0);
        oCAL_Ready    : out std_logic;

        oBusy_SMA     : out std_logic_vector(pADC_NUM-1 downto 0)
    );
end entity SMA_wrap;

architecture Behavioral of SMA_wrap is

    type tInputState is (IN_IDLE, IN_WRITE, IN_INSERT);
    signal sInputState : tInputState := IN_IDLE;

    type tAddrArray     is array (0 to pADC_NUM-1) of std_logic_vector(pADDR_WIDTH-1 downto 0);
    type tPhysAddrArray is array (0 to pADC_NUM-1) of std_logic_vector(pADDR_WIDTH downto 0);

    signal sLatData  : t_FOOT_lef_data := (others => (others => '0'));
    signal sLatAddr  : std_logic_vector(pADDR_WIDTH-1 downto 0) := (others => '0');
    signal sLatBank  : std_logic := '0';
    signal sLatInsEn : std_logic_vector(pADC_NUM-1 downto 0) := (others => '0');

    signal sSelWrEn   : std_logic;
    signal sSelWrAddr : std_logic_vector(pADDR_WIDTH-1 downto 0);
    signal sSelWrBank : std_logic;
    signal sSelWrData : t_FOOT_lef_data;
    signal sSelInsEn  : std_logic_vector(pADC_NUM-1 downto 0);
    signal sSelFlush  : std_logic_vector(pADC_NUM-1 downto 0);
    signal sSelRst    : std_logic;

    signal sAllReady   : std_logic;
    signal sAllWrGrant : std_logic;
    signal sAllRdGrant : std_logic;
    signal sWrReqAll   : std_logic;
    signal sWrEnAll    : std_logic;
    signal sRdEnAll    : std_logic;
    signal sSMAReset   : std_logic;

    signal sInsPulse   : std_logic_vector(pADC_NUM-1 downto 0) := (others => '0');
    signal sFlushPulse : std_logic_vector(pADC_NUM-1 downto 0);

    signal sSMAReady : std_logic_vector(pADC_NUM-1 downto 0);
    signal sSMAReq   : std_logic_vector(pADC_NUM-1 downto 0);
    signal sSMAGrant : std_logic_vector(pADC_NUM-1 downto 0);
    signal sSMAValid : std_logic_vector(pADC_NUM-1 downto 0);
    signal sSMABusy  : std_logic_vector(pADC_NUM-1 downto 0);
    signal sMedian   : t_FOOT_lef_data;

    signal sSMARdEnA   : std_logic_vector(pADC_NUM-1 downto 0);
    signal sSMARdAddrA : tAddrArray;
    signal sSMARdDataA : t_FOOT_lef_data;
    signal sSMARdEnB   : std_logic_vector(pADC_NUM-1 downto 0);
    signal sSMARdAddrB : tAddrArray;
    signal sSMARdDataB : t_FOOT_lef_data;

    signal sWrGrant : std_logic_vector(pADC_NUM-1 downto 0);
    signal sRdGrant : std_logic_vector(pADC_NUM-1 downto 0);
    signal sRdDataA : t_FOOT_lef_data;
    signal sRdValid : std_logic := '0';

    signal sRamAddrA : tPhysAddrArray;
    signal sRamDataA : t_FOOT_lef_data;
    signal sRamWeA   : std_logic_vector(pADC_NUM-1 downto 0);
    signal sRamReA   : std_logic_vector(pADC_NUM-1 downto 0);
    signal sRamQ_A   : t_FOOT_lef_data;

    signal sRamAddrB : tPhysAddrArray;
    signal sRamDataB : t_FOOT_lef_data;
    signal sRamWeB   : std_logic_vector(pADC_NUM-1 downto 0);
    signal sRamReB   : std_logic_vector(pADC_NUM-1 downto 0);
    signal sRamQ_B   : t_FOOT_lef_data;

    function all_ready(v : std_logic_vector) return std_logic is
        variable r : std_logic := '1';
    begin
        for i in v'range loop
            r := r and v(i);
        end loop;
        return r;
    end function;

begin

    sSelWrEn   <= iCAL_WR_en   when iCAL_priority = '1' else iCN_WR_en;
    sSelWrAddr <= iCAL_WR_addr when iCAL_priority = '1' else iCN_WR_addr;
    sSelWrBank <= '0'          when iCAL_priority = '1' else iCN_WR_bank;
    sSelWrData <= iCAL_WR_data when iCAL_priority = '1' else iCN_WR_data;
    sSelInsEn  <= iCAL_INS_en  when iCAL_priority = '1' else iCN_INS_en;
    sSelFlush  <= iCAL_Flush   when iCAL_priority = '1' else iCN_Flush;
    sSelRst    <= iCAL_RST     when iCAL_priority = '1' else iCN_RST;

    sAllReady   <= all_ready(sSMAReady);
    sAllWrGrant <= all_ready(sWrGrant);
    sAllRdGrant <= all_ready(sRdGrant);
    sWrReqAll   <= '1' when sInputState = IN_WRITE else '0';
    sWrEnAll    <= '1' when sInputState = IN_WRITE else '0';
    sRdEnAll    <= iCN_RD_en and sAllRdGrant;
    sSMAReset   <= iRST or sSelRst;

    oCN_Ready    <= '1' when (iCAL_priority = '0' and sInputState = IN_IDLE and sAllReady = '1') else '0';
    oCAL_Ready   <= '1' when (iCAL_priority = '1' and sInputState = IN_IDLE and sAllReady = '1') else '0';
    oCN_RD_grant <= sAllRdGrant;
    oCN_RD_valid <= sRdValid;
    oCN_RD_data  <= sRdDataA;

    oCN_Median  <= sMedian;
    oCAL_Median <= sMedian;
    oCN_Valid   <= sSMAValid;
    oCAL_Valid  <= sSMAValid;
    oBusy_SMA   <= sSMABusy;

    -- Flush is a direct command, allowed only when all SMAs are idle.
    GEN_FLUSH : for i in 0 to pADC_NUM-1 generate
        sFlushPulse(i) <= sSelFlush(i) when (sInputState = IN_IDLE and sAllReady = '1') else '0';
    end generate;

    process(iCLK, iRST)
    begin
        if iRST = '1' then
            sInputState <= IN_IDLE;
            sLatData    <= (others => (others => '0'));
            sLatAddr    <= (others => '0');
            sLatBank    <= '0';
            sLatInsEn   <= (others => '0');
            sInsPulse   <= (others => '0');
        elsif rising_edge(iCLK) then
            sInsPulse <= (others => '0');

            case sInputState is
                when IN_IDLE =>
                    if (sSelWrEn = '1') and (sAllReady = '1') then
                        sLatData    <= sSelWrData;
                        sLatAddr    <= sSelWrAddr;
                        sLatBank    <= sSelWrBank;
                        sLatInsEn   <= sSelInsEn;
                        sInputState <= IN_WRITE;
                    end if;

                when IN_WRITE =>
                    if sAllWrGrant = '1' then
                        sInputState <= IN_INSERT;
                    end if;

                when IN_INSERT =>
                    sInsPulse   <= sLatInsEn;
                    sInputState <= IN_IDLE;
            end case;
        end if;
    end process;

    process(iCLK, iRST)
    begin
        if iRST = '1' then
            sRdValid <= '0';
        elsif rising_edge(iCLK) then
            sRdValid <= sRdEnAll;
        end if;
    end process;

    GEN_ADC : for i in 0 to pADC_NUM-1 generate

        RAM_I : parametric_ram_dp
            generic map(
                pWIDTH       => pDATA_WIDTH,
                pDEPTH       => pRAM_DEPTH,
                pUSEDW_WIDTH => pADDR_WIDTH+1,
                pFORCE_MLAB  => pFORCE_MLAB
            )
            port map(
                iCLK => iCLK,

                iData_A => sRamDataA(i),                --@suppress
                iAddr_A => sRamAddrA(i),
                iWE_A   => sRamWeA(i),
                iRE_A   => sRamReA(i),
                oData_A => sRamQ_A(i),                  --@suppress

                iData_B => sRamDataB(i),                --@suppress
                iAddr_B => sRamAddrB(i),
                iWE_B   => sRamWeB(i),
                iRE_B   => sRamReB(i),
                oData_B => sRamQ_B(i)                   --@suppress
            );

        ARB_I : CN_RAM_Arbiter
            generic map(
                pADDR_WIDTH => pADDR_WIDTH,
                pDATA_WIDTH => pDATA_WIDTH
            )
            port map(
                iWR_req   => sWrReqAll,
                oWR_grant => sWrGrant(i),
                iWR_en    => sWrEnAll,
                iWR_bank  => sLatBank,
                iWR_addr  => sLatAddr,
                iWR_data  => sLatData(i),               --@suppress

                iSMA_req       => sSMAReq(i),
                oSMA_grant     => sSMAGrant(i),
                iSMA_bank      => sLatBank,
                iSMA_rd_en_a   => sSMARdEnA(i),
                iSMA_rd_addr_a => sSMARdAddrA(i),
                oSMA_rd_data_a => sSMARdDataA(i),       --@suppress
                iSMA_rd_en_b   => sSMARdEnB(i),
                iSMA_rd_addr_b => sSMARdAddrB(i),
                oSMA_rd_data_b => sSMARdDataB(i),       --@suppress

                iRD_req    => iCN_RD_req,
                oRD_grant  => sRdGrant(i),
                iRD_en_a   => sRdEnAll,
                iRD_bank   => iCN_RD_bank,
                iRD_addr_a => iCN_RD_addr,
                oRD_data_a => sRdDataA(i),              --@suppress

                oRAM_addr_a => sRamAddrA(i),
                oRAM_data_a => sRamDataA(i),            --@suppress
                oRAM_we_a   => sRamWeA(i),
                oRAM_re_a   => sRamReA(i),
                iRAM_data_a => sRamQ_A(i),              --@suppress

                oRAM_addr_b => sRamAddrB(i),
                oRAM_data_b => sRamDataB(i),            --@suppress
                oRAM_we_b   => sRamWeB(i),
                oRAM_re_b   => sRamReB(i),
                iRAM_data_b => sRamQ_B(i)               --@suppress
            );

        SMA_I : StreamingMedian
            generic map(
                pHEAP_SIZE  => pHEAP_SIZE,
                pADDR_WIDTH => pADDR_WIDTH,
                pDATA_WIDTH => pDATA_WIDTH,
                pCALC_MODE  => pCALC_MODE
            )
            port map(
                iCLK      => iCLK,
                iRST      => sSMAReset,
                iINS_en   => sInsPulse(i),
                iINS_data => sLatData(i),               --@suppress
                iINS_addr => sLatAddr,
                iFlush    => sFlushPulse(i),
                oReady    => sSMAReady(i),

                oRAM_req   => sSMAReq(i),
                iRAM_grant => sSMAGrant(i),

                oRAM_rd_en_a   => sSMARdEnA(i),
                oRAM_rd_addr_a => sSMARdAddrA(i),
            iRAM_rd_data_a => sSMARdDataA(i),           --@suppress
                oRAM_rd_en_b   => sSMARdEnB(i),
                oRAM_rd_addr_b => sSMARdAddrB(i),
                iRAM_rd_data_b => sSMARdDataB(i),       --@suppress

                oMedian   => sMedian(i),                --@suppress
                oValid    => sSMAValid(i),
                oBusy_SMA => sSMABusy(i)
            );

    end generate;

end architecture Behavioral;
