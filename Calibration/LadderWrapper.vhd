--!@file LadderWrapper.vhd
--!@brief Top level of calibration module.
--!@author Luca Russo, luca.russo@cern.ch, luca.russo912@gmail.com
--!@date 24/04/2026
--!@version 1.0.0 
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.FOOTpackage.all;

entity LadderWrapper is
    generic(
        pDATA_WIDTH : natural := cADC_DATA_WIDTH;
        pADC_STRIPS : natural := cADC_CHANNELS; -- number of microstrips per ADC
        pHEAP_SIZE  : natural := cHEAP_SIZE;
        pADC_NUM    : natural := cTOTAL_ADCS;
        pLTH        : std_logic_vector(cADC_DATA_WIDTH-1 downto 0) := cLTH;
        pHTH        : std_logic_vector(cADC_DATA_WIDTH-1 downto 0) := cHTH
    );
    port(
        -- global control & clock
        iCLK                    : in  std_logic;
        iRST                    : in  std_logic;
        -- in sample stream
        iWORD                   : in  t_FOOT_lef_data;  -- Data from multiADCPlaneInterface, in parallel from all the ADCs. ** iMULTI_FIFO.tFifoIn_ADC.data **
        iPUTD                   : in  std_logic;    -- Write-enable from ADC-LEF                                            ** iMULTI_FIFO.tFifoIn_ADC.wr   **
        iTRIG                   : in  std_logic;    -- Trigger from ADC-LEF                                                 ** iCNT.start **

        -- Trigger Lost
        oTRIG_L                 : out std_logic;    -- Trigger LOST or Putd LOST

        -- CLuster ENABLE
        oCLUST_ENABLE           : out std_logic;
        oVALID_EVT_RAM          : out std_logic;

        -- Enable and trigger from front-end
        iCAL_ENABLE             : in  std_logic;    -- '1': calibration; '0': no calibration
        iEVT_ENABLE             : in  std_logic;    -- '1': event run, if not cal; '0': no run

        iHOST_CONTROL           : in std_logic_vector(7 downto 0);
        oHOST_CONTROL           : out std_logic_vector(6 downto 0);
        iK1                     : in std_logic_vector(pDATA_WIDTH-1 downto 0);
        iK2                     : in std_logic_vector(pDATA_WIDTH-1 downto 0);

        oBUSY                   : out std_logic;

        -- Event ram outputs
        oER_WE                  : out std_logic;
        oER_W_ADDR              : out std_logic_vector(9 downto 0);
        oER_DATA                : out std_logic_vector(pDATA_WIDTH-1 downto 0);

        -- ** CALIB RAM UNLOAD ONCE CALIBRATION IS OVER**
        oWADDR                  : out std_logic_vector(9 downto 0);

        oWELTH                  : out std_logic;
        oLTH_DATA               : out std_logic_vector(pDATA_WIDTH-1 downto 0);

        oWEHTH                  : out std_logic;
        oHTH_DATA               : out std_logic_vector(pDATA_WIDTH-1 downto 0);

        oWERHT                  : out std_logic;
        oRHT_DATA               : out std_logic_vector(pDATA_WIDTH-1 downto 0);

        oWEPED                  : out std_logic;
        oREPED                  : out std_logic;
        oPED_DATA               : out std_logic_vector(pDATA_WIDTH-1 downto 0);

        oWEFLG                  : out std_logic;
        oREFLG                  : out std_logic;
        oFLG_DATA               : out std_logic_vector(pDATA_WIDTH-1 downto 0);

        oRESIG                  : out std_logic;
        oSIG_DATA               : out std_logic_vector(pDATA_WIDTH-1 downto 0)     
    );
end entity LadderWrapper;

architecture Behavioral of LadderWrapper is

    signal sCalRst, sRst : std_logic;

    -- FSM states
    type   sLWState_type is (IDLE, CALIB, C1, EVENT, WE, E1);
    signal sLW_State     : sLWState_type;

    attribute syn_encoding : string;
    attribute syn_encoding of sLW_State : signal is "onehot";

    signal sLW_StripCnt  : natural range 0 to (pADC_STRIPS * 8) - 1; -- Haven't set to -1 to avoid overflow
    signal sLW_Adc       : natural range 0 to pADC_NUM - 1;

    --! Calibration Ram Interface (Read-only) ** WILL BE DEPRECATED **
    signal sCalibRam_Addr_B   : std_logic_vector(8 downto 0);
    signal sCalibRam_Addr_A   : std_logic_vector(8 downto 0);
    signal sCalibRam_Data03_B : std_logic_vector((pDATA_WIDTH * 4) - 1 downto 0);
    signal sCalibRam_Data47_B : std_logic_vector((pDATA_WIDTH * 4) - 1 downto 0);
    signal sCalibRam_Data03_A : std_logic_vector((pDATA_WIDTH * 4) - 1 downto 0);
    signal sCalibRam_Data47_A : std_logic_vector((pDATA_WIDTH * 4) - 1 downto 0);
    signal sCalibRam_Busy_A   : std_logic; -- '1' when port A is writing

    --** WIP: NUOVI SEGNALI DI INTERFACCIA CON LA RAM
    -- Pedestal RAM
    signal sPedestal_Ram_Addr   : std_logic_vector(6 downto 0);
    signal sPedestal_Ram_Data   : t_FOOT_lef_data;
    signal sRHT_Ram_Addr        : std_logic_vector(6 downto 0);
    signal sRHT_Ram_Data        : t_FOOT_lef_data;

    -- Pedestal subtraction module interface
    signal sPedSub_Data  : t_FOOT_lef_data;
    signal sPedSub_WeIn  : std_logic;
    signal sPedSub_En    : std_logic;
    signal sPedSub_Busy  : std_logic;   -- Unused
    signal sPedSub_Q     : t_FOOT_lef_data;
    signal sPedSub_WeOut : std_logic;
    signal sPedSub_Re    : std_logic;

    -- Common-Noise module interface
    signal sCN_Data  : t_FOOT_lef_data;
    signal sCN_WeIn  : std_logic;
    signal sCN_En    : std_logic;
    signal sCN_Busy  : std_logic;       -- Unused
    signal sCN_Q     : t_FOOT_lef_data;
    signal sCN_WeOut : std_logic;

    -- CN Subtraction FIFO
    signal sCNSubFifo_Q     : t_FOOT_lef_data;
    signal sCNSubFifo_Empty : std_logic;
    signal sCNSubFifo_RE    : std_logic;
    signal sCNSubFifo_Data  : t_FOOT_lef_data;
    signal sCNSubFifo_Full  : std_logic; -- Unused
    signal sCNSubFifo_WE    : std_logic;

    -- CN FIFO
    signal sCNFifo_Q     : t_FOOT_lef_data;
    signal sCNFifo_Empty : std_logic;
    signal sCNFifo_RE    : std_logic;
    signal sCNFifo_Data  : t_FOOT_lef_data;
    signal sCNFifo_Full  : std_logic;
    signal sCNFifo_WE    : std_logic;

    -- Calibration Wrapper Interface
    signal sCWState             : std_logic_vector(1 downto 0); -- 00: Pedestal computation; 001: Sigma Raw; 010: Sigma
    signal sCWReady             : std_logic;
    signal sCWData              : t_FOOT_lef_data;
    signal sCWPutd              : std_logic;
    signal sCWCalBusy           : std_logic;
    signal sCWCalBusy_D         : std_logic := '0';
    signal sCWCalBusy_Falling   : std_logic := '0';
    signal sCWCalBusy_FallLatch : std_logic;

    -- EVENT BUSY
    signal sEvent_StripCnt : natural range 0 to pADC_STRIPS - 1;
    signal sEvent_Running  : std_logic;
    signal sEvent_End      : std_logic;
    signal sTrig           : std_logic;
    signal sPutDGated      : std_logic; -- To send data to lower levels only if in event


    -- * FLAG SIMULATION * TO REMOVE
    -- signal sFlag : std_logic_vector(1 downto 0) := "00";

    -- ** FOR TESTING PURPOSES ** calibRamEventData
    signal sER_CalibMSG     : std_logic_vector(pDATA_WIDTH-1 downto 0);
    signal sER_CalibWA      : std_logic_vector(9 downto 0);
    signal sER_CalibWEN     : std_logic;
    signal sER_Full         : std_logic;
    signal sValidEventRam   : std_logic;

    -- SIGNAL TO START CALIBRATING JUST ONCE FOR TESTING
    signal sCAL_sync    : std_logic := '0';
    signal sCAL_prev    : std_logic := '0';
    signal sCAL_edge    : std_logic := '0';
    signal sCalPending  : std_logic := '0';
    signal sCalInternal : std_logic := '0'; -- rimane impulso di 1 clk
    signal sIsCalibrating : std_logic;

    signal sCAL_HOST_control : std_logic_vector(6 downto 0);
    signal sCAL_HOST_control_int : std_logic_vector(7 downto 0);
    signal sHostCmdForCalPending : std_logic := '0';

    -- K save
    type   sKState_type is (IDLE, SYNC, K1, K2);
    signal sK_state : sKState_type;

    signal sKV : std_logic;
    signal sKC : std_logic;
    signal sK1 : std_logic_vector(pDATA_WIDTH-1 downto 0);
    signal sK2 : std_logic_vector(pDATA_WIDTH-1 downto 0);
    -- PUTD edge detect
    signal sPUTD_sync  : std_logic := '0';
    signal sPUTD_prev  : std_logic := '0';
    signal sPUTD_edge  : std_logic := '0';  -- '1' per 1 clk quando iPUTD passa 0->1

    -- signal sCalRestart         : std_logic;
    -- attribute syn_preserve : boolean;
    -- attribute syn_preserve of sCalRestart : signal is true;

    -- SMA INTERFACE INPUT
    signal sSMA_rst           : std_logic;
    signal sSMA_putd          : std_logic_vector(pADC_NUM-1 downto 0);
    signal sSMA_i_data        : t_FOOT_lef_data;
    signal sSMA_o_data        : t_FOOT_lef_data;
    signal sSMA_valid         : std_logic_vector(pADC_NUM-1 downto 0);
    signal sSMA_flush         : std_logic_vector(pADC_NUM-1 downto 0);

    -- SMA FROM CN
    signal sSMA_CN_rst           : std_logic;
    signal sSMA_CN_putd          : std_logic_vector(pADC_NUM-1 downto 0);
    signal sSMA_CN_i_data        : t_FOOT_lef_data;
    signal sSMA_CN_o_data        : t_FOOT_lef_data;
    signal sSMA_CN_valid         : std_logic_vector(pADC_NUM-1 downto 0);
    signal sSMA_CN_flush         : std_logic_vector(pADC_NUM-1 downto 0);

    -- SMA FROM CAL
    signal sSMA_CAL_priority      : std_logic;
    signal sSMA_CAL_rst           : std_logic;
    signal sSMA_CAL_putd          : std_logic_vector(pADC_NUM-1 downto 0);
    signal sSMA_CAL_i_data        : t_FOOT_lef_data;
    signal sSMA_CAL_o_data        : t_FOOT_lef_data;
    signal sSMA_CAL_valid         : std_logic_vector(pADC_NUM-1 downto 0);
    signal sSMA_CAL_flush         : std_logic_vector(pADC_NUM-1 downto 0);

begin
    sRst    <= sCalRst or iRST;

    -- If i get a putD while in IDLE it means that data has been lost
    oTRIG_L <= '1' when (sLW_State = IDLE and sPUTD_edge = '1') or sTrig = '1' else
               '0';
    -- Internal Reset is part of the busy, does not release the system
    oBUSY   <= '1' when (sLW_State /= IDLE) or (sCalRst = '1') else
               '0';
    -- Valid Event ram for both calibration and events
    oVALID_EVT_RAM  <= sValidEventRam or sER_Full; -- Full will arrive for just 1clk

    oRHT_DATA  <= sRHT_Ram_Data(0); --!!! JUST TO SUPPRESS ERROR, WILL NEED ADJUSTMENT

    sIsCalibrating <= '1' when (sLW_State = CALIB) or (sLW_State = C1) else '0';
-- SMA DEC
    SMA_WRAP : StreamingMedianOfMedianWrap
        generic map(
            pHEAP_SIZE  => pHEAP_SIZE,
            pCALC_MODE  => cSMA_CALC_MODE,
            pADC_NUM    => pADC_NUM,
            pDATA_WIDTH => pDATA_WIDTH
        )
        port map(
            iCLK      => iCLK,
            iRST      => sSMA_rst,          
            iINS_en   => sSMA_putd,         
            iINS_data => sSMA_i_data,          
            oMedian   => sSMA_o_data,           
            iFlush    => sSMA_flush,            
            oValid    => sSMA_valid,            
            oBusy_SMA => open
        );
    
    PED_SUB : PedestalSubtraction
        generic map(
            pDATA_WIDTH => pDATA_WIDTH,
            pADC_NUM    => pADC_NUM, 
            pADC_STRIPS => pADC_STRIPS
        )
        port map(
            iCLK         => iCLK,
            iRST         => sRst,
            iEN          => sPedSub_En,
            iDATA        => sPedSub_Data,
            iPUTD        => sPedSub_WeIn,
            oREAD_ADDR   => sPedestal_Ram_Addr, -- Address of pedestal
            iPED         => sPedestal_Ram_Data, -- Pedestal from ram
            oQ           => sPedSub_Q,
            oPUTD        => sPedSub_WeOut,
            oBUSY        => sPedSub_Busy
        );

    -- FIFO to hold data while computing CN
    CN_SUB_FIFO : FOOT_FIFO
        generic map(
            pADC_NUM     => pADC_NUM,
            pADC_STRIPS  => pADC_STRIPS,
            pDATA_WIDTH  => pDATA_WIDTH
        )
        port map(
            iCLK    => iCLK,
            iRST    => sRst,
            iDATA   => sCNSubFifo_Data,
            iRE     => sCNSubFifo_RE,
            iWE     => sCNSubFifo_WE,
            oQ      => sCNSubFifo_Q,
            oEMPTY  => sCNSubFifo_Empty,
            oAEMPTY => open,
            oFULL   => sCNSubFifo_Full,
            oAFULL  => open
        );

    CN_SUB : CNSubtraction
        generic map(
            pADC_STRIPS => pADC_STRIPS,
            pADC_NUM    => pADC_NUM
        )
        port map(
            iCLK          => iCLK,
            iRST          => sRst,
            iEN           => sCN_En,
            iWORD         => sCN_Data,
            iPUTD         => sCN_WeIn,
            oRE           => sCNSubFifo_RE,    -- From FIFO_0
            iDATA         => sCNSubFifo_Q,
            iEMPTY        => sCNSubFifo_Empty,
            oRHT_ADDR     => sRHT_Ram_Addr,
            iRHT_DATA     => sRHT_Ram_Data,
            oQ            => sCN_Q,
            oPUTD         => sCN_WeOut,
            iFULL         => sCNFifo_Full,     -- From FIFO_1
            oSMA_NRST     => sSMA_CN_rst,
            oSMA_INS_en   => sSMA_CN_putd, 
            oSMA_INS_data => sSMA_CN_i_data,
            iSMA_Median   => sSMA_CN_o_data,
            oSMA_Flush    => sSMA_CN_flush,
            iSMA_Valid    => sSMA_CN_valid,
            oBUSY         => sCN_Busy
        );

    -- FIFO to hold data after CN subtraction
    CN_FIFO : FOOT_FIFO
        generic map(
            pADC_NUM     => pADC_NUM,
            pADC_STRIPS  => pADC_STRIPS,
            pDATA_WIDTH  => pDATA_WIDTH
        )
        port map(
            iCLK   => iCLK,
            iRST   => sRst,
            iDATA  => sCNFifo_Data,
            iRE    => sCNFifo_RE,
            iWE    => sCNFifo_WE,
            oQ     => sCNFifo_Q,
            oEMPTY => sCNFifo_Empty,
            oAEMPTY => open,
            oFULL  => sCNFifo_Full,
            oAFULL  => open
        );

    CALIB_WRAP : CalibrationWrapper
        generic map(
            pDATA_WIDTH => pDATA_WIDTH,
            pADC_NUM    => pADC_NUM,
            pRHT        => cRHT,
            pHTH        => cHTH,
            pLTH        => cLTH
        )
        port map(
            iCLK               => iCLK,
            iNRST              => sRst,
            iWord              => sCWData,
            iPutd              => sCWPutd,
            oCM                => sCWState,
            oMCReady           => sCWReady,
            iCalibrationEnable => sCalInternal,
            oCalibrationBusy   => sCWCalBusy,
            iTrig              => iTRIG,
            iHOST_CONTROL       => sCAL_HOST_control_int, --Passo i 9 bit di comando.
            oHOST_CONTROL       => oHOST_CONTROL,
            iKV                => sKV,
            iKC                => sKC,
            iK1                => sK1,
            iK2                => sK2,
            iRA_B              => sCalibRam_Addr_B,
            iRA_A              => sCalibRam_Addr_A, -- SAME ADDRESS AS WRITING
            oREAD_03_B         => sCalibRam_Data03_B,
            oREAD_47_B         => sCalibRam_Data47_B,
            oREAD_03_A         => sCalibRam_Data03_A, -- FIXME: ADD OF SECOND READ ADDRESS TO FETCH HIGH AND LOW THR ON THE SAME CLK
            oREAD_47_A         => sCalibRam_Data47_A,
            iRHT_RADDR         => sRHT_Ram_Addr,
            oWADDR             => oWADDR,
            oWELTH             => oWELTH,
            oLTH_DATA          => oLTH_DATA,
            oWEHTH             => oWEHTH,
            oHTH_DATA          => oHTH_DATA, 
            oWERHT             => oWERHT,
            oRHT_DATA          => sRHT_Ram_Data,
            oWEPED             => oWEPED,
            oREPED             => oREPED,
            oPED_DATA          => oPED_DATA,
            oWEFLG             => oWEFLG,
            oREFLG             => oREFLG,
            oFLG_DATA          => oFLG_DATA,
            oRESIG             => oRESIG,
            oSIG_DATA          => oSIG_DATA,
            oSMA_priority      => sSMA_CAL_priority,
            oSMA_NRST          => sSMA_CAL_rst,
            oSMA_INS_en        => sSMA_CAL_putd, 
            oSMA_INS_data      => sSMA_CAL_i_data,
            iSMA_Median        => sSMA_CAL_o_data,
            oSMA_Flush         => sSMA_CAL_flush,
            iSMA_Valid         => sSMA_CAL_valid,
            oER_CalibMSG       => sER_CalibMSG,
            oER_CalibWA        => sER_CalibWA,
            oER_CalibWEN       => sER_CalibWEN,
            oER_Full           => sER_Full
        );

  -- SMA MUX
  process(all)
  begin
    if sSMA_CAL_priority = '1' then
        -- FROM CAL TO SMA
        sSMA_rst        <= sSMA_CAL_rst;   
        sSMA_putd       <= sSMA_CAL_putd;
        sSMA_i_data     <= sSMA_CAL_i_data;
        sSMA_flush      <= sSMA_CAL_flush;
        -- FROM SMA TO CAL
        sSMA_CAL_o_data <= sSMA_o_data;
        sSMA_CAL_valid  <= sSMA_valid;
    else
        -- FROM CN TO SMA
        sSMA_rst        <= sSMA_CN_rst;   
        sSMA_putd       <= sSMA_CN_putd;
        sSMA_i_data     <= sSMA_CN_i_data;
        sSMA_flush      <= sSMA_CN_flush;
        -- FROM SMA TO CN
        sSMA_CN_o_data  <= sSMA_o_data;
        sSMA_CN_valid   <= sSMA_valid;
    end if;
  end process;

    -- Signals Mapping
    -- Internal PutD gated: replicate iPUTD only when processing events
    sPutDGated      <= '1' when (sPUTD_edge = '1' and sEvent_Running = '1') else
                       '0';
    sPedSub_Data    <= iWORD when sLW_State /= IDLE else (others => (others => '0'));
    sPedSub_WeIn    <= sPutDGated when sLW_State /= IDLE else '0';
    sCN_Data        <= sPedSub_Q when sLW_State /= IDLE else (others => (others => '0'));
    sCN_WeIn        <= sPedSub_WeOut when sLW_State /= IDLE else '0';
    sCNSubFifo_Data <= sPedSub_Q when sLW_State /= IDLE else (others => (others => '0'));
    sCNSubFifo_WE   <= sPedSub_WeOut when sLW_State /= IDLE else '0';
    sCNFifo_Data    <= sCN_Q when sLW_State /= IDLE else (others => (others => '0'));
    sCNFifo_WE      <= sCN_WeOut when sLW_State /= IDLE else '0';
    sCWData         <= sCNFifo_Q when sLW_State /= IDLE else (others => (others => '0'));

   sCalibRam_Addr_A <= sCalibRam_Addr_B; -- FIXME: JUST TO TEST IF READING FROM SECOND PORT IS WORKING

    PUTD_EDGE_PROC : process(iCLK, iRST)
    begin
        if iRST = '1' then
            sPUTD_sync <= '0';
            sPUTD_prev <= '0';
            sPUTD_edge <= '0';
        elsif rising_edge(iCLK) then
            -- registro precedente
            sPUTD_prev <= sPUTD_sync;
            -- sincronizzo l'ingresso esterno
            sPUTD_sync <= iPUTD;

            -- impulso di 1 clk sulla fronte di salita di iPUTD
            if (sPUTD_sync = '1' and sPUTD_prev = '0') then
                sPUTD_edge <= '1';
            else
                sPUTD_edge <= '0';
            end if;
        end if;
    end process PUTD_EDGE_PROC;

    CAL_EDGE_PROC : process(iCLK, iRST)
    begin
        if iRST = '0' then
            sCAL_sync <= '0';
            sCAL_prev <= '0';
            sCAL_edge <= '0';
        elsif rising_edge(iCLK) then
            sCAL_prev <= sCAL_sync;
            sCAL_sync <= iCAL_ENABLE;

            if (sCAL_sync = '1' and sCAL_prev = '0') then
                sCAL_edge <= '1';
            else
                sCAL_edge <= '0';
            end if;

        end if;
    end process CAL_EDGE_PROC;

    -- PROCESS TO CALIB ONCE TILL RESET
    CAL_REQ_PROC : process(iCLK, iRST)
    begin
    if iRST = '0' then
        sCalPending              <= '0';
        sCalInternal             <= '0';
        sCAL_HOST_control_int     <= (others => '0');
        sCAL_HOST_control         <= (others => '0');
        sHostCmdForCalPending     <= '0';

        sKV  <= '0';
        sKC  <= '0';
        sK1  <= pLTH;
        sK2  <= pHTH;
        sK_state  <= IDLE;

    elsif rising_edge(iCLK) then
        sCalInternal          <= '0';
        sCAL_HOST_control_int <= (others => '0');

        -- Latch richiesta calibrazione
        if (sCAL_edge = '1') and (sIsCalibrating = '0') then
            sCalPending <= '1';
        end if;

        -- Latch comandi host
        if (iHOST_CONTROL(7) = '1') and (sIsCalibrating = '0') then
            -- Comando legato alla calibrazione, prendo sul segnale originale di cal enable che è sincronizzato ad host control
            if iCAL_ENABLE = '1' then
                sCAL_HOST_control     <= iHOST_CONTROL(6 downto 0);
                sHostCmdForCalPending <= '1';
            -- comando indipendente da cal: invia subito
            else
                sCAL_HOST_control_int <= iHOST_CONTROL;
            end if;
        end if;

        -- Start calibrazione "all'evento successivo": IDLE + iTRIG + pending
        if (sLW_State = IDLE) and (iTRIG = '1') and (sCalPending = '1') then
            sCalPending  <= '0';
            sCalInternal <= '1';

            if sHostCmdForCalPending = '1' then
                sCAL_HOST_control_int <= "1" & sCAL_HOST_control;  -- pulse 1 clk al start calib, imposto manualmente il valid
                sHostCmdForCalPending <= '0';
            end if;
        end if;

        -- FETCH COSTANTI
        case sK_state is
            when IDLE =>
                sKV  <= '0';
                sKC  <= '0';
                -- Se il comando è valido provo a vedere se devo ricompilare con le nuove soglie.
                if (iHOST_CONTROL(7) = '1') then
                    sK_state  <= SYNC;
                end if;
            -- Host invia le THR con un ciclo di delay
            when SYNC =>
                sK_state  <= K1;
            
            when K1 =>
                if iK1 /= sK1 then
                    sK1  <= iK1;
                    sKC  <= '1'; 
                end if;
                sK_state  <= K2;
            when K2 =>
                if iK2 /= sK2 then
                    sK2  <= iK2;
                    sKC  <= '1';
                end if;

                sK_state  <= IDLE;
                sKV  <= '1';
        end case;
    end if;
    end process CAL_REQ_PROC;

    -- Find falling-edge of calibration busy 
    BUSY_DELAY_PROC : process(iCLK, iRST)
    begin
        if iRST = '1' then
            sCWCalBusy_D       <= '0';
            sCWCalBusy_Falling <= '0';
        elsif rising_edge(iCLK) then
            sCWCalBusy_D       <= sCWCalBusy;
            sCWCalBusy_Falling <= sCWCalBusy_D and not sCWCalBusy;
        end if;
    end process BUSY_DELAY_PROC;

    -- Event running signal and data lost
    RUNNING_BUSY_LOGIC_PROC : process(iCLK, iRST)
    begin
        if iRST = '1' then
            sEvent_StripCnt <= 0;
            sEvent_Running  <= '0';
            sEvent_End      <= '0';
            sTrig           <= '0';
        elsif rising_edge(iCLK) then
            sTrig      <= '0';
            sEvent_End <= '0';

            -- Se mi arriva un trigger e non sono in nessun evento allora inizio un evento.
            if iTRIG = '1' and sEvent_Running = '0' then
                sEvent_Running  <= '1';
                sEvent_StripCnt <= 0;
            -- Se mi arriva un trigger mentre sono in un evento (NON dovrebbe succedere) ho perso dati.
            elsif iTRIG = '1' and sEvent_Running = '1' then
                sTrig <= '1';
            end if;

            -- Se mi arriva un dato, è l'ultimo ed ero in un evento. Resetto il contatore
            if (sPUTD_edge = '1' and sEvent_StripCnt = pADC_STRIPS - 1 and sEvent_Running = '1') then
                sEvent_End      <= '1';
                sEvent_StripCnt <= 0;
            -- Se mi arriva un dato ed ero in un evento, incremento il numero di strip
            elsif sPUTD_edge = '1' and sEvent_Running = '1' then
                sEvent_StripCnt <= sEvent_StripCnt + 1;
            end if;

            -- Se mi arriva un dato e non ero in running, allora ho perso dati.
            if (sPUTD_edge = '1' and sEvent_Running = '0') then
                sTrig <= '1';
            end if;

            -- Gives time to the last putd to pass to the lower level.
            if sEvent_End = '1' then
                sEvent_Running <= '0';
                sEvent_End     <= '0';
            end if;
        end if;
    end process RUNNING_BUSY_LOGIC_PROC;

    LW_FSM : process(iCLK, iRST)
    begin
        if iRST = '1' then
            sLW_Adc              <= 0;
            sCWPutd              <= '0';
            sCWCalBusy_FallLatch <= '0';
            oER_DATA             <= (others => '0');
            sCN_En               <= '0';
            sPedSub_En           <= '0';
            oER_W_ADDR           <= (others => '0');
            oER_WE               <= '0';
            sLW_State            <= IDLE;
            sLW_StripCnt         <= 0;
            sCNFifo_RE           <= '0';
            sCalRst              <= '0';
            oCLUST_ENABLE        <= '0';
            sValidEventRam       <= '0';

        elsif rising_edge(iCLK) then
            case sLW_State is
                when IDLE =>
                    -- ** FOR TESTING PURPOSES ** calibRamEventData 
                    oER_WE      <= sER_CalibWEN;
                    oER_W_ADDR  <= sER_CalibWA;
                    --oER_DATA    <= "00" & sER_CalibMSG; -- where 00 are the fake flags --@suppress
                    oER_DATA    <= sER_CalibMSG; -- where 00 are the fake flags --@suppress
                    
                    sCWCalBusy_FallLatch <= '0';
                    sCalRst              <= '0'; -- Deassert del reset
                    oCLUST_ENABLE        <= '0';

                    sPedSub_En <= '0';
                    sCN_En     <= '0';

                    -- FIXME: iCalibration for the second time does not allow MC MODULE
                    if iTRIG = '1' then
                        if sCalPending = '1' then
                            sLW_State <= CALIB;
                        elsif iEVT_ENABLE = '1' then
                            sLW_State    <= EVENT;
                            sPedSub_En   <= '1';
                            sCN_En       <= '1';
                            sLW_StripCnt <= 0;
                        end if;
                    end if;

                when CALIB =>
                    -- ** FOR TESTING PURPOSES ** calibRamEventData 
                    oER_WE      <= sER_CalibWEN;
                    oER_W_ADDR  <= sER_CalibWA;
                    --oER_DATA    <= "00" & sER_CalibMSG; -- where 00 are the fake flags --@suppress
                    oER_DATA    <= sER_CalibMSG; -- where 00 are the fake flags --@suppress

                    sCNFifo_RE <= '0';
                    sCWPutd    <= '0';

                    if sCWState = "00" then
                        sPedSub_En <= '0';
                        sCN_En     <= '0';
                    elsif sCWState = "01" then
                        sPedSub_En <= '1';
                        sCN_En     <= '0';
                    elsif sCWState = "10" then
                        sPedSub_En <= '1';
                        sCN_En     <= '1';
                    end if;

                    if sCWCalBusy_Falling = '1' then -- If calibration is over keep the notification to exit when fifo is empty
                        sCWCalBusy_FallLatch <= '1';
                    end if;


                    if sCNFifo_Empty = '0' and sCWReady = '1' then -- If there is data in CNFifo and CW is ready, read data from fifo and, in C1, send it to CALIB W by PutData.
                        sCNFifo_RE <= '1';
                        sLW_State  <= C1;
                    elsif sCWCalBusy_FallLatch = '1' and sCNFifo_Empty = '1' then
                        sLW_State <= IDLE;
                        sCalRst   <= '1';
                    end if;


                when C1 =>
                    -- ** FOR TESTING PURPOSES ** calibRamEventData 
                    oER_WE      <= sER_CalibWEN;
                    oER_W_ADDR  <= sER_CalibWA;
                    --oER_DATA    <= "00" & sER_CalibMSG; -- where 00 are the fake flags --@suppress
                    oER_DATA    <= sER_CalibMSG; -- where 00 are the fake flags --@suppress

                    sCNFifo_RE <= '0';
                    sCWPutd    <= '1';
                    sLW_State  <= CALIB;

                when EVENT =>
                    oER_WE     <= '0';
                    sPedSub_En <= '1';
                    sCN_En     <= '1';
                    sCNFifo_RE <= '0';
                    oCLUST_ENABLE <= '0'; -- TEST TO ENABLE CLUSTERING.

                    if sCNFifo_Empty = '0' then
                        sCNFifo_RE <= '1';
                        sLW_State  <= WE;
                        sLW_Adc    <= 0;
                        sValidEventRam   <= '0';
                    end if;

                when WE =>
                    sCNFifo_RE <= '0';
                    sLW_State  <= E1;

                when E1 =>
                    sCNFifo_RE <= '0';
                    sValidEventRam   <= '0';

                    oER_W_ADDR <= std_logic_vector(to_unsigned(sLW_Adc, 3)) & std_logic_vector(to_unsigned(sLW_StripCnt, 7));
                    oER_WE     <= '1';
                    -- * FLAG SIMULATION * TO REMOVE
                    -- oER_DATA   <= sFlag & sCNFifo_Q(sLW_Adc); -- Flagsim.
                    -- * oER_DATA with THR on 2 MSB
                    -- oER_DATA   <= "00" & sCNFifo_Q(sLW_Adc);
                    -- * oER_DATA without THR
                    oER_DATA   <= sCNFifo_Q(sLW_Adc); --@suppress

                    if sLW_Adc = pADC_NUM - 1 then
                        if sLW_StripCnt = pADC_STRIPS - 1 then
                            sLW_StripCnt <= 0;
                            -- EVENT RESET, if another trigger has arrived during RAM SAVING IT WILL CONTINUE TO ACQUIRE DATA.
                            if sEvent_Running = '0' then
                                sCalRst   <= '1';        -- JUST A SAFETY RESET
                                sLW_State <= IDLE;
                                oCLUST_ENABLE <= '1';    -- TEST TO ENABLE CLUSTERING.
                                sValidEventRam   <= '1';
                            else
                                sLW_State <= EVENT;
                                oCLUST_ENABLE <= '1';    -- TEST TO ENABLE CLUSTERING.
                                sValidEventRam   <= '1';
                            end if;
                        else
                            sLW_Adc      <= 0;
                            sLW_State    <= EVENT;
                            sLW_StripCnt <= sLW_StripCnt + 1;
                        end if;
                    else
                        sLW_Adc <= sLW_Adc + 1;
                    end if;
                when others => sLW_State <= IDLE;
            end case;
        end if;
    end process LW_FSM;

end architecture Behavioral;