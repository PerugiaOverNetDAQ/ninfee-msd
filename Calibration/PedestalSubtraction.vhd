--!@file PedestalSubtraction.vhd
--!@brief Pedestal Subtraction implementation in VHDL for calibration.
--!@author Luca Russo, luca.russo@cern.ch, luca.russo912@gmail.com
--!@date 29/04/2026
--!@version 1.0.0 
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.FOOTpackage.all;

entity PedestalSubtraction is
  generic (             
    pDATA_WIDTH     : natural := cADC_DATA_WIDTH;
    pADC_NUM        : natural := cTOTAL_ADCS;
    pADC_STRIPS     : natural := cADC_CHANNELS   -- 64 x 2 standard. Number of microstrips per ADC
  );
  port (
    iCLK                : in  std_logic;
    iRST                : in  std_logic;
    iEN                 : in  std_logic;

    -- in sample stream
    iDATA               : in  t_FOOT_lef_data;
    iPUTD               : in  std_logic;     
    
    -- RAM interface
    oREAD_ADDR          : out std_logic_vector(6 downto 0);
    iPED                : in  t_FOOT_lef_data;

    oQ                  : out t_FOOT_lef_data;
    oPUTD               : out std_logic;

    oBUSY               : out std_logic -- Gives to Ladder Wrapper the status of calib
  );
end entity PedestalSubtraction;


architecture Behavioral of PedestalSubtraction is

    -- FSM states
    type state_type is (IDLE, FETCH, COMP);
    signal state     : state_type;

    -- ??
    attribute syn_encoding : string;
    attribute syn_encoding of state : signal is "onehot";
    
    signal sStrp_cnt  : natural range 0 to pADC_STRIPS-1; -- Haven't set to -1 to avoid overflow
    signal sW         : natural range 0 to 2;
    signal sPed       : t_FOOT_lef_data;

begin

  oBUSY <= '1' when state /= IDLE else '0';

  process(iCLK, iRST)

  begin
    if iRST = '1' then
        oQ              <= (others =>(others => '0'));
        sPed            <= (others =>(others => '0'));
        oPUTD           <= '0';
        oREAD_ADDR      <= (others => '0');
        sStrp_cnt       <= 0;
        sW              <= 0;
        state           <= IDLE;

    elsif rising_edge(iCLK) then
        case state is
            when IDLE =>
                oPUTD           <= '0';
                oREAD_ADDR      <= (others => '0');
                sStrp_cnt       <= 0;
                sPed            <= (others =>(others => '0'));
                sW              <= 0;

                -- Se prima dell'arrivo del primo dato mi arriva l'enable i successivi 128 dati vengono presi come ped sub
                if iEN = '1' then
                    state       <= FETCH;
                    oPUTD       <= '0';
                    oREAD_ADDR  <= (others => '0');
                    sStrp_cnt   <= 0;
                    sW          <= 0;

                -- Altrimenti PASS
                -- FOR AD7276 iWORD is : 00 xxxx xxxx xxxx 00. Data is ADC4, already.
                elsif iPUTD = '1' then
                  -- Passthrough based on ADC num
                  for i in 0 to pADC_NUM - 1 loop
                    oQ(i) <= iDATA(i)(pDATA_WIDTH-2 downto 0) & '0'; --@suppress ADC8
                  end loop;

                  oPUTD <= '1';
                end if;

            when FETCH =>
                sW          <= 0;
                oPUTD       <= '0';

                oREAD_ADDR  <= std_logic_vector(to_unsigned(sStrp_cnt, 7));
                state       <= COMP;
                
            when COMP =>
                oPUTD       <= '0';

                -- Wait for one cycle and then store data. Then do nothing (w=2) till reset.
                if sW = 1 then
                    sPed    <= iPED;
                    sW      <= 2; 
                elsif sW = 0 then
                    sW      <= 1;
                end if;

                -- Se è arrivato un dato e ho immagazzinato il piedistallo corretto allora:
                if iPUTD = '1' and sW = 2 then
                    -- FOR AD7276 iWORD is : 00 xxxx xxxx xxxx 00. Data is ADC4, already.
                    -- Subtraction based on ADC num
                    for i in 0 to pADC_NUM - 1 loop
                        oQ(i) <= std_logic_vector(signed(iDATA(i)(pDATA_WIDTH-2 downto 0) & '0') - signed(sPed(i))); -- ADC8
                    end loop;

                    oPUTD   <= '1';

                    if sStrp_cnt = pADC_STRIPS-1 then
                        state       <= IDLE;
                        sStrp_cnt   <= 0;
                    else
                        state       <= FETCH;
                        sStrp_cnt   <= sStrp_cnt + 1;
                    end if;
                end if;

            when others => state <= IDLE; --@suppress
        end case;
    end if;
  end process;

end architecture Behavioral;