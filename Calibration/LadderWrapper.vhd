--!@file LadderWrapper.vhd
--!@brief Top level of calibration module.
--!@author Luca Russo, luca.russo@cern.ch, luca.russo912@gmail.com
--!@date 18/05/2026
--!@version 1.0.3 
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.basic_package.all;
use work.FOOTpackage.all;

entity LadderWrapper is
    generic(
        pDATA_WIDTH  : natural := cADC_DATA_WIDTH;
        pADC_STRIPS  : natural := cADC_CHANNELS; -- number of microstrips per ADC
        pHEAP_SIZE   : natural := cHEAP_SIZE;
        pADC_NUM     : natural := cTOTAL_ADCS;
        pLTH         : std_logic_vector(cADC_DATA_WIDTH-1 downto 0) := cLTH;
        pHTH         : std_logic_vector(cADC_DATA_WIDTH-1 downto 0) := cHTH;
        pWADDR_WIDTH : natural := ceil_log2(cTOTAL_ADCS * cADC_CHANNELS) -- linear address width for ADC x STRIP memories
    );
    port(
        -- global control & clock
        iCLK                    : in  std_logic;
        iRST                    : in  std_logic;
        -- in sample stream
        iWORD                   : in  t_FOOT_lef_data;  -- Data from multiADCPlaneInterface, in parallel from all the ADCs. ** iMULTI_FIFO.tFifoIn_ADC.data **
        iPUTD                   : in  std_logic;    -- Write-enable from ADC-LEF                                            ** iMULTI_FIFO.tFifoIn_ADC.wr   **
        iTRIG                   : in  std_logic;    -- Trigger from ADC-LEF                                                 ** iCNT.start **
        iFULL                   : in  std_logic;    -- Downstream Event RAM/FIFO full

        -- Trigger Lost
        oTRIG_L                 : out std_logic;    -- Trigger LOST or Putd LOST

        -- CLuster ENABLE
        oCLUST_ENABLE           : out std_logic;
        oVALID_EVT_RAM          : out std_logic;
        oEVENT_ACCEPTED         : out std_logic;    -- Current trigger starts a normal (non-calibration) event
        oCALIB_TYPE             : out std_logic_vector(1 downto 0); -- 00 PED, 01 SIGRAW, 10 SIGMA, 11 FLG

        -- Enable and trigger from front-end
        iCAL_ENABLE             : in  std_logic;    -- '1': calibration; '0': no calibration
        iEVT_ENABLE             : in  std_logic;    -- '1': event run, if not cal; '0': no run

        iTHR_VALID              : in std_logic;
        iK1                     : in std_logic_vector(pDATA_WIDTH-1 downto 0);
        iK2                     : in std_logic_vector(pDATA_WIDTH-1 downto 0);

        oBUSY                   : out std_logic;

        -- Event ram outputs
        oER_WE                  : out std_logic;
        oER_W_ADDR              : out std_logic_vector(pWADDR_WIDTH-1 downto 0);
        oER_DATA                : out std_logic_vector(pDATA_WIDTH-1 downto 0);

        -- Direct calibration RAM access, available only when oBUSY = '0'.
        iPED                    : in  CalibCompIN;
        oPED                    : out CalibCompOUT;
        iSIGRAW                 : in  CalibCompIN;
        oSIGRAW                 : out CalibCompOUT;
        iSIG                    : in  CalibCompIN;
        oSIG                    : out CalibCompOUT;
        iFLG                    : in  CalibCompIN;
        oFLG                    : out CalibCompOUT;
        oLTH                    : out CalibCompOUT;
        oHTH                    : out CalibCompOUT;
        oRHT                    : out CalibCompOUT
    );
end entity LadderWrapper;

architecture Behavioral of LadderWrapper is

    signal sCalRst, sRst : std_logic;

    -- FSM states
    type   sLWState_type is (IDLE, CALIB, C1, EVENT, WE, E1);
    signal sLW_State     : sLWState_type;

    attribute syn_encoding : string;
    attribute syn_encoding of sLW_State : signal is "onehot";

    signal sLW_StripCnt  : natural range 0 to pADC_STRIPS - 1;
    signal sLW_Adc       : natural range 0 to pADC_NUM - 1;

    -- Direct interface to the calibration RAM exposed by CalibrationWrapper.
    -- PED is used by pedestal subtraction; SIGRAW drives the derived RHT path used by CN subtraction.
    signal sPedIn_CW           : CalibCompIN;
    signal sSigRawIn_CW        : CalibCompIN;
    signal sSigIn_CW           : CalibCompIN;
    signal sFlgIn_CW           : CalibCompIN;
    signal sPedOut_CW          : CalibCompOUT;
    signal sSigRawOut_CW       : CalibCompOUT;
    signal sSigOut_CW          : CalibCompOUT;
    signal sFlgOut_CW          : CalibCompOUT;
    signal sLthOut_CW          : CalibCompOUT;
    signal sHthOut_CW          : CalibCompOUT;
    signal sRhtOut_CW          : CalibCompOUT;

    signal sPedestal_Ram_Addr  : std_logic_vector(6 downto 0);
    signal sPedestal_Ram_Data  : t_FOOT_lef_data;

    signal sRHT_Ram_Addr       : std_logic_vector(6 downto 0);
    signal sRHT_Ram_Data       : t_FOOT_lef_data;

    signal sSIGRAW_Ram_Data    : t_FOOT_lef_data; --@suppress
    signal sSIG_Ram_Data       : t_FOOT_lef_data;
    signal sFLG_Ram_Data       : t_FOOT_lef_data;
    signal sLTH_Ram_Data       : t_FOOT_lef_data;
    signal sHTH_Ram_Data       : t_FOOT_lef_data;

    -- Pedestal subtraction module interface
    signal sPedSub_Data  : t_FOOT_lef_data;
    signal sPedSub_WeIn  : std_logic;
    signal sPedSub_En    : std_logic;
    signal sPedSub_Busy  : std_logic;   -- Unused   --@suppress
    signal sPedSub_Q     : t_FOOT_lef_data;
    signal sPedSub_WeOut : std_logic;
    signal sPedSub_Re    : std_logic;               --@suppress

    -- Common-Noise module interface
    signal sCN_Data  : t_FOOT_lef_data;
    signal sCN_WeIn  : std_logic;
    signal sCN_En    : std_logic;
    signal sCN_Busy  : std_logic;       -- Unused   --@suppress
    signal sCN_Q     : t_FOOT_lef_data;
    signal sCN_WeOut : std_logic;

    -- CN Subtraction FIFO
    signal sCNSubFifo_Q     : t_FOOT_lef_data;
    signal sCNSubFifo_Empty : std_logic;
    signal sCNSubFifo_RE    : std_logic;
    signal sCNSubFifo_Data  : t_FOOT_lef_data;
    signal sCNSubFifo_Full  : std_logic; -- Unused  --@suppress
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

    -- Calibration result mirror toward Event RAM
    signal sCW_ER_WE             : std_logic;
    signal sCW_ER_W_ADDR         : std_logic_vector(pWADDR_WIDTH-1 downto 0);
    signal sCW_ER_DATA           : std_logic_vector(pDATA_WIDTH-1 downto 0);

    -- EVENT BUSY
    signal sEvent_StripCnt : natural range 0 to pADC_STRIPS - 1;
    signal sEvent_Running  : std_logic;
    signal sEvent_End      : std_logic;
    signal sTrig_Lost           : std_logic;
    signal sPutDGated      : std_logic; -- To send data to lower levels only if in event

    signal sValidEventRam   : std_logic;
    signal sSystemBusy      : std_logic;
    signal sCalRamExtAccess : std_logic;
    signal sTrigAccepted    : std_logic;

    -- SIGNAL TO START CALIBRATING JUST ONCE FOR TESTING
    signal sCAL_sync    : std_logic := '0';
    signal sCAL_prev    : std_logic := '0';
    signal sCAL_edge    : std_logic := '0';
    signal sCalPending  : std_logic := '0';
    signal sCalInternal : std_logic := '0'; -- combinational start pulse on the first useful trigger
    signal sIsCalibrating : std_logic;

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
    oTRIG_L <= '1' when (sLW_State = IDLE and sPUTD_edge = '1') or sTrig_Lost = '1' else
               '0';
    sSystemBusy <= '1' when (sLW_State /= IDLE) or (sCalRst = '1') or
                            (sEvent_Running = '1') or (iTRIG = '1') or
                            (iFULL = '1') else
                   '0';

    -- External calibration RAM access depends only on memory ownership.
    -- iFULL still contributes to oBUSY, but it must not revoke the read ports
    -- while ClusterModule is scanning a completed event under backpressure.
    sCalRamExtAccess <= '1' when sLW_State = IDLE and sCalRst = '0' and sEvent_Running = '0' and iTRIG = '0' else '0';
    oBUSY <= sSystemBusy;

    sTrigAccepted <= '1' when (iTRIG = '1') and (iFULL = '0') else
                     '0';

    -- Valid Event ram for processed events.
    oVALID_EVT_RAM <= sValidEventRam;
    oCALIB_TYPE    <= sCWState;

    -- Per-trigger packet classification.
    -- Calibration triggers keep the normal RAW packet length.
    oEVENT_ACCEPTED <= '1' when (sLW_State = IDLE) and
                               (sTrigAccepted = '1') and
                               (sCalPending = '0') and
                               (iEVT_ENABLE = '1') else
                       '0';

    sIsCalibrating <= '1' when (sLW_State = CALIB) or (sLW_State = C1) else '0';

    -- CalibrationWrapper is started on the first trigger that arrives after
    -- a calibration request has been latched.  This is combinational on purpose:
    -- both LadderWrapper and CalibrationWrapper sample the same useful trigger,
    -- so the trigger is not consumed only to arm the submodule and then wasted.
    sCalInternal <= '1' when (sLW_State = IDLE) and
                             (sCalPending = '1') and
                             (sTrigAccepted = '1') else
                    '0';
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
            pADC_STRIPS => pADC_STRIPS,
            pRHT        => cRHT,
            pHTH        => pHTH,
            pLTH        => pLTH,
            pWADDR_WIDTH => pWADDR_WIDTH
        )
        port map(
            iCLK              => iCLK,
            iRST              => sRst,
            iWORD             => sCWData,
            iPUTD             => sCWPutd,
            oMC_MODE          => sCWState,
            oMC_READY         => sCWReady,
            iCALIB_ENABLE     => sCalInternal,
            oCALIB_BUSY       => sCWCalBusy,
            iTRIG             => sTrigAccepted,

            oER_WE            => sCW_ER_WE,
            oER_W_ADDR        => sCW_ER_W_ADDR,
            oER_DATA          => sCW_ER_DATA,
            iER_FULL          => iFULL,

            iLTH              => sK1,
            iHTH              => sK2,
            iKC               => sKC,
            iKV               => sKV,

            iPED              => sPedIn_CW,
            oPED              => sPedOut_CW,
            iSIGRAW           => sSigRawIn_CW,
            oSIGRAW           => sSigRawOut_CW,
            iSIG              => sSigIn_CW,
            oSIG              => sSigOut_CW,
            iFLG              => sFlgIn_CW,
            oFLG              => sFlgOut_CW,
            oLTH              => sLthOut_CW,
            oHTH              => sHthOut_CW,
            oRHT              => sRhtOut_CW,

            oSMA_priority     => sSMA_CAL_priority,
            oSMA_RST          => sSMA_CAL_rst,
            oSMA_INS_en       => sSMA_CAL_putd,
            oSMA_INS_data     => sSMA_CAL_i_data,
            iSMA_Median       => sSMA_CAL_o_data,
            oSMA_Flush        => sSMA_CAL_flush,
            iSMA_Valid        => sSMA_CAL_valid
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

    -- CalibrationWrapper record mapping.
    sPedIn_CW.DATA     <= iPED.DATA    when sCalRamExtAccess = '1' else (others => (others => '0'));
    sPedIn_CW.WADDR    <= iPED.WADDR   when sCalRamExtAccess = '1' else (others => '0');
    sPedIn_CW.WE       <= iPED.WE      when sCalRamExtAccess = '1' else '0';
    sSigRawIn_CW.DATA  <= iSIGRAW.DATA when sCalRamExtAccess = '1' else (others => (others => '0'));
    sSigRawIn_CW.WADDR <= iSIGRAW.WADDR when sCalRamExtAccess = '1' else (others => '0');
    sSigRawIn_CW.WE    <= iSIGRAW.WE   when sCalRamExtAccess = '1' else '0';
    sSigIn_CW.DATA     <= iSIG.DATA    when sCalRamExtAccess = '1' else (others => (others => '0'));
    sSigIn_CW.WADDR    <= iSIG.WADDR   when sCalRamExtAccess = '1' else (others => '0');
    sSigIn_CW.WE       <= iSIG.WE      when sCalRamExtAccess = '1' else '0';
    sFlgIn_CW.DATA     <= iFLG.DATA    when sCalRamExtAccess = '1' else (others => (others => '0'));
    sFlgIn_CW.WADDR    <= iFLG.WADDR   when sCalRamExtAccess = '1' else (others => '0');
    sFlgIn_CW.WE       <= iFLG.WE      when sCalRamExtAccess = '1' else '0';

    sPedestal_Ram_Data <= sPedOut_CW.DATA;
    sSIGRAW_Ram_Data   <= sSigRawOut_CW.DATA;
    sSIG_Ram_Data      <= sSigOut_CW.DATA;
    sFLG_Ram_Data      <= sFlgOut_CW.DATA;
    sLTH_Ram_Data      <= sLthOut_CW.DATA;
    sHTH_Ram_Data      <= sHthOut_CW.DATA;
    sRHT_Ram_Data      <= sRhtOut_CW.DATA;

    -- RAM read-address arbitration.
    -- In normal processing, PED and SIGRAW/RHT are consumed by the event path.
    -- External addresses are forwarded only while the whole wrapper is idle.
    sPedIn_CW.RADDR <= iPED.RADDR when sCalRamExtAccess = '1' else sPedestal_Ram_Addr;

    sSigRawIn_CW.RADDR <= iSIGRAW.RADDR when sCalRamExtAccess = '1' else sRHT_Ram_Addr;

    sSigIn_CW.RADDR <= iSIG.RADDR when sCalRamExtAccess = '1' else (others => '0');

    sFlgIn_CW.RADDR <= iFLG.RADDR when sCalRamExtAccess = '1' else (others => '0');

    oPED.DATA    <= sPedOut_CW.DATA    when sCalRamExtAccess = '1' else (others => (others => '0'));
    oSIGRAW.DATA <= sSigRawOut_CW.DATA when sCalRamExtAccess = '1' else (others => (others => '0'));
    oSIG.DATA    <= sSigOut_CW.DATA    when sCalRamExtAccess = '1' else (others => (others => '0'));
    oFLG.DATA    <= sFlgOut_CW.DATA    when sCalRamExtAccess = '1' else (others => (others => '0'));
    oLTH.DATA    <= sLthOut_CW.DATA    when sCalRamExtAccess = '1' else (others => (others => '0'));
    oHTH.DATA    <= sHthOut_CW.DATA    when sCalRamExtAccess = '1' else (others => (others => '0'));
    oRHT.DATA    <= sRhtOut_CW.DATA    when sCalRamExtAccess = '1' else (others => (others => '0'));

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
        if iRST = '1' then
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

    CAL_REQ_PROC : process(iCLK, iRST)
    begin
    if iRST = '1' then
        sCalPending              <= '0';

        sKV  <= '0';
        sKC  <= '0';
        sK1  <= pLTH;--@suppress
        sK2  <= pHTH;--@suppress
        sK_state  <= IDLE;

    elsif rising_edge(iCLK) then
        -- Calib request
        if (sCAL_edge = '1') and (sIsCalibrating = '0') then
            sCalPending <= '1';
        end if;

        -- Consume the pending request on the same first useful trigger that
        -- is forwarded combinationally (see above) to CalibrationWrapper.
        if (sLW_State = IDLE) and (sTrigAccepted = '1') and (sCalPending = '1') then
            sCalPending  <= '0';
        end if;

        -- Fetch of mult constants 
        case sK_state is
            when IDLE =>
                sKV  <= '0';
                sKC  <= '0';
                -- If valid, check constants
                if (iTHR_VALID = '1') then
                    sK_state  <= SYNC;
                end if;
            -- Host invia le THR con un ciclo di delay
            when SYNC =>
                sK_state  <= K1;
            
            when K1 =>
                -- K1 is always after a valid HostControl word.
                sK1       <= iK1;
                sK_state  <= K2;

            when K2 =>
                -- Reload the thresholds in CALIB_RAM for every host command,
                -- even when K1/K2 are numerically equal to the previous values
                -- in LadderWrapper (no if, no waste). CALIB_RAM may have been
                -- reset independently by sCalRst.
                sK2       <= iK2;
                sKC       <= '1';
                sKV       <= '1';
                sK_state  <= IDLE;
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
            sTrig_Lost           <= '0';
        elsif rising_edge(iCLK) then
            sTrig_Lost      <= '0';
            sEvent_End <= '0';

            -- If trigger comel and not in eventm then start event
            if sTrigAccepted = '1' and sEvent_Running = '0' then
                sEvent_Running  <= '1';
                sEvent_StripCnt <= 0;
            -- If trigger comes while in event (should not happen) then data lost. Signal it.
            elsif iTRIG = '1' and (sEvent_Running = '1' or iFULL = '1') then
                sTrig_Lost <= '1';
            end if;

            -- If i get data, it's the last one, and in event. Reset counter
            if (sPUTD_edge = '1' and sEvent_StripCnt = pADC_STRIPS - 1 and sEvent_Running = '1') then
                sEvent_End      <= '1';
                sEvent_StripCnt <= 0;
            -- If data comes and event is running, increment counter
            elsif sPUTD_edge = '1' and sEvent_Running = '1' then
                sEvent_StripCnt <= sEvent_StripCnt + 1;
            end if;

            -- If putd arrives while not running an event, then data lost
            if (sPUTD_edge = '1' and sEvent_Running = '0') then
                sTrig_Lost <= '1';
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
            oER_WE <= '0';

            case sLW_State is
                when IDLE =>
                    -- TODO: Maybe Calibration-RAM-to-event-RAM debug forwarding?
                    sCWCalBusy_FallLatch <= '0';
                    sCalRst              <= '0'; -- Deassert del reset
                    oCLUST_ENABLE        <= '0';

                    sPedSub_En <= '0';
                    sCN_En     <= '0';

                    -- FIXME: iCalibration for the second time does not allow MC MODULE
                    if sTrigAccepted = '1' then
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
                    -- During calibration, CalibrationWrapper mirrors the completed
                    -- PED/SIGRAW/SIG stage into Event RAM with event-like addressing.
                    oER_WE     <= sCW_ER_WE;
                    oER_W_ADDR <= sCW_ER_W_ADDR;
                    oER_DATA   <= sCW_ER_DATA;

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
                    else
                        -- Flag computation/dump does not consume event data.
                        sPedSub_En <= '0';
                        sCN_En     <= '0';
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
                    -- Keep forwarding the CalibrationWrapper Event-RAM stream
                    -- also in the one-cycle FIFO handoff state.
                    oER_WE     <= sCW_ER_WE;
                    oER_W_ADDR <= sCW_ER_W_ADDR;
                    oER_DATA   <= sCW_ER_DATA;

                    sCNFifo_RE <= '0';
                    sCWPutd    <= '1';
                    sLW_State  <= CALIB;

                when EVENT =>
                    oER_WE     <= '0';
                    sPedSub_En <= '1';
                    sCN_En     <= '1';
                    sCNFifo_RE <= '0';
                    oCLUST_ENABLE <= '0'; -- TEST TO ENABLE CLUSTERING.

                    if sCNFifo_Empty = '0' and iFULL = '0' then
                        sCNFifo_RE <= '1';
                        sLW_State  <= WE;
                        sLW_Adc    <= 0;
                        sValidEventRam   <= '0';
                    end if;

                when WE =>
                    sCNFifo_RE <= '0';
                    if iFULL = '0' then
                        sLW_State <= E1;
                    end if;

                when E1 =>
                    sCNFifo_RE <= '0';
                    sValidEventRam   <= '0';

                    oER_W_ADDR <= std_logic_vector(
                        to_unsigned((sLW_Adc * pADC_STRIPS) + sLW_StripCnt, oER_W_ADDR'length)
                    );
                    -- * oER_DATA without THR
                    oER_DATA   <= sCNFifo_Q(sLW_Adc); --@suppress

                    if iFULL = '0' then
                        oER_WE <= '1';

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
                                sLW_State <= EVENT;
                                sLW_StripCnt <= sLW_StripCnt + 1;
                            end if;
                        else
                            sLW_Adc <= sLW_Adc + 1;
                        end if;
                    end if;
                when others => sLW_State <= IDLE; --@suppress
            end case;
        end if;
    end process LW_FSM;

end architecture Behavioral;
