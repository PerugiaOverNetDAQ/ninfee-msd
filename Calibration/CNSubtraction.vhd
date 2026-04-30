--!@file CNSubtraction.vhd
--!@brief Common Noise compute and subtraction for calibration module.
--!@author Luca Russo, luca.russo@cern.ch, luca.russo912@gmail.com
--!@date 01/05/2026
--!@version 1.0.0 
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.FOOTpackage.all;

entity CNSubtraction is
  generic (             
    pADC_STRIPS     : natural := cADC_CHANNELS;   -- number of microstrips per ADC
    pADC_NUM        : natural := cTOTAL_ADCS
  );
  port (
    -- global control & clock
    iCLK                : in  std_logic;
    iRST                : in  std_logic;
    iEN                 : in  std_logic; -- New event

    -- PREVIUS MODULE INTERFACE
    iWORD               : in t_FOOT_lef_data; -- Word that goes into SMA
    iPUTD               : in std_logic; -- The word is valid.
    
    -- FIFO INTERFACE ** FROM NOT YET IMPLEMENTED FIFO WRAPPER **
    oRE                 : out std_logic; -- Extract from FIFO for sub on the next cycle oData is valid.
    iDATA               : in t_FOOT_lef_data;
    iEMPTY              : in std_logic;

    -- CALIB RAM INTERFACE
    oRHT_ADDR           : out std_logic_vector(6 downto 0);
    iRHT_DATA           : in t_FOOT_lef_data;

    -- NEXT MODULE INTERFACE ** 2ND FIFO **
    oQ                  : out t_FOOT_lef_data; -- Word that goes to the next step.
    oPUTD               : out std_logic; -- Word ready mark.
    iFULL               : in std_logic; -- Full of the following FIFO

    -- SMA INTERFACE --
    oSMA_NRST           : out std_logic;
    oSMA_INS_en         : out std_logic_vector(pADC_NUM-1 downto 0);
    oSMA_INS_data       : out t_FOOT_lef_data;
    iSMA_Median         : in  t_FOOT_lef_data; 
    oSMA_Flush          : out std_logic_vector(pADC_NUM-1 downto 0);
    iSMA_Valid          : in  std_logic_vector(pADC_NUM-1 downto 0);

    oBUSY               : out std_logic -- Gives to Ladder Wrapper the status of calib
  );
end entity CNSubtraction;

architecture Behavioral of CNSubtraction is    
  -- FSM states
  attribute syn_encoding : string;
  
  type Compute_type is (IDLE, F_FETCH, FETCH, TWAIT, STORE_MED, CHECK, FLUSHING);
  signal C_state        : Compute_type;
  attribute syn_encoding of C_state : signal is "onehot";
  
  type Sub_type is (IDLE, COMP, C2);
  signal S_state        : Sub_type;
  attribute syn_encoding of S_state : signal is "onehot";

  type Sigma_type is (IDLE, FETCH, STORE, COMP);
  signal SR_state       : Sigma_type;
  attribute syn_encoding of SR_state : signal is "onehot";

  signal oMedian        : t_FOOT_lef_data; -- Directly linked to SMA


  signal intMedian      : t_FOOT_lef_data; -- Saves median values every 64 strips
  signal intValid       : std_logic;      -- Gives the signal to start subtracting and send data outside
  signal sRead          : std_logic;      -- Delay 1 clk after read from FIFO

  signal strp_cnt_128   : natural range 0 to (pADC_STRIPS)-1;   -- 128 strips, 2 VA
  signal strp_cnt_64    : natural range 0 to (pADC_STRIPS/2)-1;  -- 64 strips, 1 VA

  signal sRST           : std_logic; -- internal signal to reset SMAs
  signal smRST          : std_logic; -- internal signal to reset SMAs

  signal sValid_vec     : std_logic_vector(pADC_NUM-1 downto 0);
  signal sValid_latched : std_logic_vector(pADC_NUM-1 downto 0);
  signal sValid_rst     : std_logic;

  -- CALIB RAM INTERFACE SIGNALS
  signal sRHT_ADDR             : std_logic_vector(6 downto 0);
  signal sRHT_strp_cnt         : natural range 0 to pADC_STRIPS-1; -- Haven't set to -1 to avoid overflow
  signal sRHT_data           : t_FOOT_lef_data;

  --SMA INPUTS
  type sSMA_cnt   is array (0 to pADC_NUM-1)  of natural range 0 to (pADC_STRIPS/2); --Niente -1 perché devo poter arrivare a 64
  signal sSMA_putd          : std_logic_vector(pADC_NUM-1 downto 0);
  signal sSMA_pexp          : std_logic_vector(pADC_NUM-1 downto 0);
  signal sSMA_i_data        : t_FOOT_lef_data;
  signal sSMA_flush         : std_logic_vector(pADC_NUM-1 downto 0);
  signal sSMA_insertCnt     : sSMA_cnt;

  
  -- Normal Event.
  signal oRE_en : std_logic;

begin
    oBUSY <= '1' when (C_state /= IDLE or S_state /= IDLE) else '0';

    smRST <= iRST or sRST; -- Metto and invece che or con gli nrest, altrimenti non funziona

    oRHT_ADDR  <= sRHT_ADDR;


    -- SMA CONNECTION
    oSMA_NRST       <= smRST; 
    oSMA_INS_en     <= sSMA_putd;
    oSMA_INS_data   <= sSMA_i_data;
    oMedian         <= iSMA_Median;  
    oSMA_Flush      <= sSMA_flush;  
    sValid_vec      <= iSMA_Valid;   
        

    process(iCLK, iRST)
        begin
            if iRST = '1' then
            sValid_latched <= (others => '0');
            elsif rising_edge(iCLK) then
            if sValid_rst = '1' then
                sValid_latched <= (others => '0');
            else
                for i in 0 to pADC_NUM-1 loop
                    sValid_latched(i) <= sValid_latched(i) or sValid_vec(i);
                end loop;
            end if;
            end if;
    end process;

    -- RHT COMPARISON
    process(iCLK, iRST)
    begin
        if iRST = '1' then
            sRHT_strp_cnt <= 0;
            sRHT_ADDR  <= (others => '0');
            SR_state  <= IDLE;

            sSMA_i_data  <= (others => (others => '0'));
            sSMA_putd    <= (others => '0');

        elsif rising_edge(iCLK) then
            case SR_state is
                when IDLE =>
                    sSMA_putd  <= (others => '0');
                    sRHT_strp_cnt <= 0;

                    if iEN = '1' then
                        SR_state <= FETCH;
                    end if;

                when FETCH =>
                    sSMA_putd  <= (others => '0');

                    sRHT_ADDR  <= std_logic_vector(to_unsigned(sRHT_strp_cnt, 7));
                    SR_state  <= STORE;
                when STORE =>
                    sSMA_putd  <= (others => '0');
                    sRHT_data <= iRHT_DATA; --@suppress
                    SR_state  <= COMP;
                    SR_state  <= FETCH;

                    
                when COMP  =>
                    sSMA_putd <= (others => '0');

                    if iPUTD = '1' then
                        sSMA_i_data  <= iWORD;

                        for j in 0 to pADC_NUM-1 loop
                            if signed(iWORD(j)) > signed(sRHT_data(j)) then
                                sSMA_putd(j) <= '0'; -- Don't consider input data in median calc
                            else
                                sSMA_putd(j) <= '1'; -- Consider input data in median calc
                            end if;
                        end loop;

                        if sRHT_strp_cnt = pADC_STRIPS - 1 then
                            SR_state  <= IDLE;
                            sRHT_strp_cnt <= 0;
                        else
                            SR_state  <= FETCH;
                            sRHT_strp_cnt  <= sRHT_strp_cnt + 1;
                        end if;
                    end if;

                when others => SR_state <= IDLE; --@suppress
            end case;
        end if;
    end process;


  -- Process to compute common noise
  process(iCLK, iRST)
  begin
    if iRST = '1' then
        C_state         <= IDLE;
        intValid        <= '0';
        sRST            <= '0';
        strp_cnt_128    <= 0;
        oRE_en          <= '0';
        sSMA_flush      <= (others => '0');
        sSMA_pexp       <= (others => '0');
        sSMA_insertCnt  <= (others => 0); 
        intMedian       <= (others => (others => '0'));

        sValid_rst  <= '0';

    elsif rising_edge(iCLK) then
       case C_state is
            when IDLE =>
                intValid <= '0';
                sRST <= '0';
                strp_cnt_128 <= 0;
                oRE_en<= '0';
                sSMA_flush      <= (others => '0');
                sSMA_pexp       <= (others => '0');
                sSMA_insertCnt  <= (others => 0); 

                sValid_rst  <= '1';

                if iEN = '1' then
                    C_state <= F_FETCH;
                    sValid_rst  <= '0';
                    strp_cnt_128 <= 0;
                elsif iPUTD = '1' then
                        oRE_en <= '1';
                end if;
            -- Nel primo fetch dopo idle, ricevuto il primo putd, intMedian viene resettato.
            -- Sarà già stato scaricato dal processo di scarico.
            when F_FETCH =>
                sValid_rst   <= '0';
                intValid    <= '0';

                if iPUTD = '1' then
                    C_state     <= TWAIT;
                    intMedian   <= (others => (others => '0'));
                end if;

            when FETCH =>
                sValid_rst   <= '0';
                intValid    <= '0';

                if iPUTD = '1' then
                    C_state     <= TWAIT;
                end if;

            when TWAIT  => 
            -- Serve per dar tempo a sSMA_putd di ottenere il valore corretto.
                sValid_rst  <= '0';
                sSMA_pexp  <= sSMA_putd;
                C_state    <= STORE_MED;

            when STORE_MED =>
                sValid_rst  <= '0';
                for i in 0 to pADC_NUM-1 loop
                    if sValid_vec(i) = '1' then
                        intMedian(i) <= oMedian(i);
                        sSMA_insertCnt(i) <= sSMA_insertCnt(i) + 1;
                    end if;
                end loop;

                if (sValid_latched = sSMA_pexp) or (sValid_vec = sSMA_pexp) then
                    C_state  <= CHECK;  -- Il passaggio di stato serve ad aggiornare le variabili sopra
                    sValid_rst  <= '1';
                    sSMA_pexp  <= (others => '0');
                end if;

            when CHECK  => 
                sValid_rst  <= '1';

                if strp_cnt_128 = pADC_STRIPS-1 then
                    C_state <= FLUSHING;
                    for i in 0 to pADC_NUM-1 loop
                        if sSMA_insertCnt(i) /= (pADC_STRIPS/2) then
                            sSMA_flush(i)  <= '1';
                            sSMA_pexp(i)  <= '1';
                        end if;
                    end loop;

                elsif strp_cnt_128 = (pADC_STRIPS/2)-1 then
                    C_state <= FLUSHING;
                    for i in 0 to pADC_NUM-1 loop
                        -- Controllo anche che non sia 0. Se non è stato inserito nulla il flush non ritorna un valid.
                        if sSMA_insertCnt(i) /= (pADC_STRIPS/2) then
                            sSMA_flush(i)  <= '1';
                            sSMA_pexp(i)  <= '1';
                        end if;
                    end loop;

                else    
                    strp_cnt_128 <= strp_cnt_128 + 1;
                    C_state <= FETCH;
                    sSMA_pexp  <= (others => '0');
                end if; 

            when FLUSHING  =>
                sValid_rst  <= '0';
                sSMA_flush <= (others => '0');
                
                for i in 0 to pADC_NUM-1 loop
                    if sValid_vec(i) = '1' then
                        intMedian(i) <= oMedian(i);
                    end if;
                end loop;

                if (sValid_latched = sSMA_pexp) or (sValid_vec = sSMA_pexp) then
                    intValid  <= '1';

                    sValid_rst  <= '1';
                    sSMA_pexp  <= (others => '0');
                    sSMA_insertCnt  <= (others => 0);

                    if strp_cnt_128 = pADC_STRIPS-1 then
                        C_state  <= IDLE;
                        sRST <= '1';
                    else
                        C_state  <= FETCH;
                        strp_cnt_128 <= strp_cnt_128 + 1;
                    end if;
                end if;
                

            when others => C_state <= IDLE; --@suppress
       end case; 
    end if;
  end process;

  oRE <= '1' when (S_state = COMP and iEMPTY = '0' and iFULL = '0') or (C_state = IDLE and oRE_en = '1') else  -- This is the reading from FIFO_0. In EVENT 
         '0';

  process(iCLK, iRST)
  begin
    if iRST = '1' then
        S_state <= IDLE;
        oPUTD <= '0';
        strp_cnt_64 <= 0;
        sRead <= '0';

    elsif rising_edge(iCLK) then
        if (S_state = COMP and iEMPTY = '0' and iFULL = '0') then
            sRead <= '1';
        else 
            sRead <= '0';
        end if;
        case S_state is
            when IDLE =>
                oPUTD <= '0';
                if intValid = '1' then
                    strp_cnt_64 <= 0;
                    S_state <= COMP;
                elsif iPUTD = '1' and iEN /= '1' then
                    oQ <= iWORD;
                    oPUTD <= '1';
                end if;
            
            when COMP =>
                
            if (sRead = '1') then
                for i in 0 to pADC_NUM -1 loop
                    oQ(i) <= std_logic_vector(signed(iDATA(i)) - signed(intMedian(i)));
                end loop;
                oPUTD <= '1';

                if strp_cnt_64 = (pADC_STRIPS/2)-2 then
                    S_state <= C2;
                else
                    S_state <= COMP;
                end if;
                strp_cnt_64 <= strp_cnt_64 + 1;
            end if;

            -- So that oRE gets desserted 1clk early and doesn't extract the 65th element.
            when C2 =>
            if (sRead = '1') then
                for i in 0 to pADC_NUM -1 loop
                    oQ(i) <= std_logic_vector(signed(iDATA(i)) - signed(intMedian(i)));
                end loop;
                oPUTD <= '1';
                
                S_state <= IDLE;
                strp_cnt_64 <= 0;
            end if;
            when others => S_state <= IDLE;  --@suppress     
        end case;
    end if;
  end process;

end architecture Behavioral;