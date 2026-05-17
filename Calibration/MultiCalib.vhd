--!@file MultiCalib.vhd
--!@brief MultiCalib module to compute ped, sigma raw and sigma.
--!@author Luca Russo, luca.russo@cern.ch, luca.russo912@gmail.com
--!@date 17/05/2026
--!@version 1.0.0 
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.basic_package.all;
use work.FOOTpackage.all;

entity MultiCalibration is
  generic (
    pN_EVENT        : natural := cN_EVENT;
    pDATA_WIDTH     : natural := cADC_DATA_WIDTH;
    pADC_STRIPS     : natural := cADC_CHANNELS;   -- number of microstrips per ADC
    pUSEDW_WIDTH    : natural := ceil_log2(cADC_CHANNELS);  --! Data ADDR width
    pACC_WIDTH      : natural := cACC_WIDTH;
    pADC_NUM        : natural := cTOTAL_ADCS
  );
  port (
    -- global control & clock
    iCLK        : in  std_logic;
    iRST        : in  std_logic;

    -- incoming sample stream
    iWORD       : in  t_FOOT_lef_data;   
    iPUTD       : in  std_logic;        
    iENABLE     : in  std_logic;        
    iCMODE      : in  std_logic_vector(1 downto 0);

    -- RAM WRITING
    oDATA       : out t_FOOT_lef_data;
    oWA         : out std_logic_vector(pUSEDW_WIDTH+1 downto 0); -- ADDR WIDTH +2 bits for identifiing ped, sigraw or sig
    oWEN        : out std_logic;

    -- SIGNAL TO NOTIFY BUSY / READY
    oBUSY       : out std_logic;
    oREADY      : out std_logic;

    -- SQRT EXTERIOR CONNECTION
    oSQRT_START : out std_logic;
    oSQRT_MSG   : out t_FOOT_sqrt_data;
    iSQRT_DONE  : in  std_logic;
    iSQRT_MSG   : in  t_FOOT_lef_data
  );
end entity MultiCalibration;


architecture Behavioral of MultiCalibration is

  -- FSM states
  type state_type is (IDLE, WORD, ACC_FETCH, ACC_UPDATE, MEAN, SQRT);
  signal state : state_type;

  -- Attributi per SAFE FSM
  attribute syn_encoding : string;
  attribute syn_encoding of state : signal is "onehot";

  -- STRIP COUNT e EVENT COUNT
  signal sStrp_cnt  : natural range 0 to pADC_STRIPS-1;
  signal sEvent_cnt : natural range 0 to pN_EVENT-1;

  signal sMCMode    : std_logic_vector(1 downto 0);
  signal sLast      : std_logic;

  -- RAM accumulator interface (una RAM per ADC)
  signal sRDATA   : t_lef_accumul_inv;
  signal sWDATA   : t_lef_accumul_inv;
  signal sRADDR   : t_ram_accumul_addr;
  signal sWADDR   : t_ram_accumul_addr;
  signal sWE      : std_logic_vector(pADC_NUM-1 downto 0);

  -- Latch del campione, necessario per read-modify-write con latenza RAM
  signal sWordLat : t_FOOT_lef_data; -- 8 da 16

  -- Valore accumulato aggiornato relativo alla strip corrente
  signal sAccPipe : t_lef_accumul_inv; -- 8 da 32

  -- Funzione per skip address. Serve per evitare warning
  function safe_addr(cur : natural) return std_logic_vector is
    variable nxt : natural; -- @suppress "The type of a variable has to be constrained in size"
  begin
    if pADC_STRIPS <= 1 then
      nxt := cur;
    elsif cur = pADC_STRIPS-1 then
      nxt := 0;
    else
      nxt := cur + 1;
    end if;

    return std_logic_vector(to_unsigned(nxt, 7));
  end function;

begin

  oBusy  <= '1' when (state /= IDLE) else '0';
  oReady <= '0' when (iPutd = '1' or state /= WORD) else '1';

  -- RAM ACC
  gen_ACC : for i in 0 to pADC_NUM-1 generate
    ACCU : parametric_ram_tp
        generic map(
            pWIDTH       => pACC_WIDTH,
            pDEPTH       => (pACC_WIDTH*pADC_NUM),
            pUSEDW_WIDTH => pUSEDW_WIDTH,
            pFORCE_MLAB  => 0
        )
        port map(
            iCLK     => iCLK,
            iData    => sWDATA(i), -- @suppress
            iRd_Addr => sRADDR(i), -- @suppress
            iWr_Addr => sWADDR(i), -- @suppress
            iWr_En   => sWE(i),
            oData    => sRDATA(i)  -- @suppress
        );
  end generate;


  

  -- Main FSM: accumulate in RAM, compute mean / start SQRT, write output RAM
  process(iCLK, iRST)
    variable vSum : unsigned(pACC_WIDTH-1 downto 0);
  begin
    if iRST = '1' then
      state      <= IDLE;
      sStrp_cnt  <= 0;
      sEvent_cnt <= 0;
      sMCMode    <= "00";
      sLast      <= '0';
      oDATA      <= (others => (others => '0'));
      oWA        <= (others => '0');
      oWEN       <= '0';

      oSQRT_Start <= '0';
      for adc in 0 to pADC_NUM-1 loop
        oSQRT_MSG(adc) <= (others => '0');
      end loop;

      sWE <= (others => '0');

      for adc in 0 to pADC_NUM-1 loop
        sRADDR(adc)   <= (others => '0');
        sWADDR(adc)   <= (others => '0');
        sWDATA(adc)   <= (others => '0');
        sAccPipe(adc) <= (others => '0');
        sWordLat(adc) <= (others => '0');
      end loop;

    elsif rising_edge(iCLK) then

      oWEN        <= '0';
      oSQRT_Start <= '0';
      sWE         <= (others => '0');

      case state is

        when IDLE =>
          sStrp_cnt  <= 0;
          sEvent_cnt <= 0;
          sMCMode    <= "00";
          sLast      <= '0';

          if iEnable = '1' then
            sMCMode <= iCMode;
            state   <= WORD;
          end if;


        when WORD =>
          if iPutd = '1' then
            sWordLat <= iWord;

            if sEvent_cnt = 0 then
              -- primo evento: sovrascrivo direttamente
              for adc in 0 to pADC_NUM-1 loop
                vSum := resize(unsigned(iWord(adc)), pACC_WIDTH);

                sAccPipe(adc) <= std_logic_vector(vSum); -- @suppress

                sWDATA(adc) <= std_logic_vector(vSum); -- @suppress
                sWADDR(adc) <= std_logic_vector(to_unsigned(sStrp_cnt, 7));
                sWE(adc)    <= '1';

                sRADDR(adc) <= safe_addr(sStrp_cnt);
              end loop;

              state <= MEAN;

            else
              -- eventi successivi: read-modify-write su RAM
              for adc in 0 to pADC_NUM-1 loop
                sRADDR(adc) <= std_logic_vector(to_unsigned(sStrp_cnt, 7));
              end loop;

              state <= ACC_FETCH;
            end if;
          end if;

        -- Potrebbe essere superfluo dato che con safe_addr ho già fatto il fetch corretto, però si lascia per risurezza.
        when ACC_FETCH =>
          state <= ACC_UPDATE;


        when ACC_UPDATE =>
          -- calcolo nuovo accumulo e preparo scrittura
          for adc in 0 to pADC_NUM-1 loop
            vSum := unsigned(sRDATA(adc)) + resize(unsigned(sWordLat(adc)), pACC_WIDTH);

            sAccPipe(adc) <= std_logic_vector(vSum); -- @suppress

            sWDATA(adc) <= std_logic_vector(vSum); -- @suppress
            sWADDR(adc) <= std_logic_vector(to_unsigned(sStrp_cnt, 7));
            sWE(adc)    <= '1';

            sRADDR(adc) <= safe_addr(sStrp_cnt);
          end loop;

          state <= MEAN;


        when MEAN =>
          if sStrp_cnt = pADC_STRIPS-1 then
            if sEvent_cnt /= pN_EVENT-1 then
              sEvent_cnt <= sEvent_cnt + 1;
              sStrp_cnt  <= 0;
            end if;
          else
            sStrp_cnt <= sStrp_cnt + 1;
          end if;

          oWA <= sMCMode & std_logic_vector(to_unsigned(sStrp_cnt, 7)); -- @suppress

          if sMCMode = "00" then
            for i in 0 to pADC_NUM - 1 loop
                oDATA(i)  <= sAccPipe(i)(pDATA_WIDTH+9 downto 10); -- @suppress
            end loop;
          end if;

          if (sMCMode = "01") or (sMCMode = "10") then
            for adc in 0 to pADC_NUM-1 loop
              oSQRT_MSG(adc) <= "00" & sAccPipe(adc)(pACC_WIDTH-1 downto 2); -- @suppress
            end loop;
          end if;

          state <= WORD;

          if sEvent_cnt = pN_EVENT-1 then
            if sStrp_cnt < pADC_STRIPS-1 then
              if sMCMode = "00" then
                oWEN <= '1';
              end if;

              if (sMCMode = "01") or (sMCMode = "10") then
                state       <= SQRT;
                oSQRT_Start <= '1';
              end if;

            else
              if sMCMode = "00" then
                oWEN  <= '1';
                state <= IDLE;
              end if;

              if (sMCMode = "01") or (sMCMode = "10") then
                sLast       <= '1';
                state       <= SQRT;
                oSQRT_Start <= '1';
              end if;
            end if;
          end if;


        when SQRT =>
          if iSQRT_Done = '1' then
            oDATA  <= iSQRT_MSG;

            oWEN <= '1';

            if sLast = '1' then
              state <= IDLE;
            else
              state <= WORD;
            end if;
          end if;


        when others => -- @suppress
          state <= IDLE;

      end case;
    end if;
  end process;

end architecture Behavioral;
