--!@file CalibrationWrapper.vhd
--!@brief Core of calibration, MAIN FSM that pilots the calibration.
--!@author Luca Russo, luca.russo@cern.ch, luca.russo912@gmail.com
--!@date 17/05/2026
--!@version 1.2.0
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.basic_package.all;
use work.FOOTpackage.all;

entity CalibrationWrapper is
  generic (
    pDATA_WIDTH     : natural := cADC_DATA_WIDTH;
    pADC_NUM        : natural := cTOTAL_ADCS;
    pUSEDW_WIDTH    : natural := ceil_log2(cADC_CHANNELS);
    pADC_STRIPS     : natural := cADC_CHANNELS;
    pRHT            : std_logic_vector(cADC_DATA_WIDTH-1 downto 0) := cRHT; --@suppress
    pHTH            : std_logic_vector(cADC_DATA_WIDTH-1 downto 0) := cHTH; --@suppress
    pLTH            : std_logic_vector(cADC_DATA_WIDTH-1 downto 0) := cLTH; --@suppress
    pN_EVENT        : natural := cN_EVENT;
    pACC_WIDTH      : natural := cACC_WIDTH;
    pWADDR_WIDTH    : natural := ceil_log2(cTOTAL_ADCS * cADC_CHANNELS)
  );
  port (
    iCLK                    : in  std_logic;
    iRST                    : in  std_logic;

    iWORD                   : in  t_FOOT_lef_data;                                  -- Input words - ADC8
    iPUTD                   : in  std_logic;                                        -- Input word  - valid
    oMC_MODE                : out std_logic_vector(1 downto 0);                     -- Multicalib Running mode.
    oMC_READY               : out std_logic;                                        -- MultiCalib ready to receive.

    -- Enable and trigger from front-end
    iCALIB_ENABLE           : in  std_logic;                                        -- Comes from LadderProcessingWrapper
    oCALIB_BUSY             : out std_logic;                                        -- Gives to Ladder Wrapper the status of calib
    iTRIG                   : in  std_logic;                                        -- Comes From front END

    -- Calibration result mirror toward Event RAM.
    -- The three MultiCalib results (PED, SIGRAW, SIG) and the final FLG map
    oER_WE                  : out std_logic;
    oER_W_ADDR              : out std_logic_vector(pWADDR_WIDTH-1 downto 0);
    oER_DATA                : out std_logic_vector(pDATA_WIDTH-1 downto 0);

    -- THR CHANGE
    iLTH                    : in std_logic_vector(pDATA_WIDTH-1 downto 0);
    iHTH                    : in std_logic_vector(pDATA_WIDTH-1 downto 0);
    iKC                     : in std_logic;
    iKV                     : in std_logic;

    -- RAM INTERFACE
    iPED_RADDR              : in  std_logic_vector(pUSEDW_WIDTH-1 downto 0);
    oPED_DATA               : out t_FOOT_lef_data;                                  -- ADC8
    iSIGRAW_RADDR           : in  std_logic_vector(pUSEDW_WIDTH-1 downto 0);
    oSIGRAW_DATA            : out t_FOOT_lef_data;                                  -- ADC8
    iSIG_RADDR              : in  std_logic_vector(pUSEDW_WIDTH-1 downto 0);
    oSIG_DATA               : out t_FOOT_lef_data;                                  -- ADC8
    iFLG_RADDR              : in  std_logic_vector(pUSEDW_WIDTH-1 downto 0);
    oFLG_DATA               : out t_FOOT_lef_data;
    oLTH_DATA               : out t_FOOT_lef_data;                                  -- LOW THR OUTPUT, based on SIG addr
    oHTH_DATA               : out t_FOOT_lef_data;                                  -- HIGH THR OUTPUT, based on SIG addr
    oRHT_DATA               : out t_FOOT_lef_data;                                  -- R.HIGH THR OUTPUT, based on SIGRAW addr

    -- SMA INTERFACE
    oSMA_priority           : out std_logic;
    oSMA_RST                : out std_logic;
    oSMA_INS_en             : out std_logic_vector(pADC_NUM-1 downto 0);
    oSMA_INS_data           : out t_FOOT_lef_data;
    oSMA_WR_en              : out std_logic;
    oSMA_WR_addr            : out std_logic_vector(ceil_log2(cFE_CHANNELS)-1 downto 0);
    iSMA_Ready              : in  std_logic;
    iSMA_Median             : in  t_FOOT_lef_data;
    oSMA_Flush              : out std_logic_vector(pADC_NUM-1 downto 0);
    iSMA_Valid              : in  std_logic_vector(pADC_NUM-1 downto 0)
  );
end entity CalibrationWrapper;


architecture Behavioral of CalibrationWrapper is
  attribute syn_encoding : string;

  ----------------------------------------------------------------------------
  -- MAIN FSM states
  ----------------------------------------------------------------------------
  type state_type is (
    IDLE,
    WAIT_PEDESTAL, PEDESTAL,
    ER_PED_INIT, ER_PED_WAIT, ER_PED_SEND,
    WAIT_SIGRAW,   SIGRAW,
    ER_SIGRAW_INIT, ER_SIGRAW_WAIT, ER_SIGRAW_SEND,
    WAIT_SIGMA,    SIGMA,
    ER_SIG_INIT, ER_SIG_WAIT, ER_SIG_SEND,
    RSF_FETCH, RSF_COMP, RSF_PRE_FLAG, RSF_FLAG,
    SF_FETCH,  SF_COMP,  SF_PRE_FLAG,  SF_WAIT,  SF_FLAG,
    ER_FLG_INIT, ER_FLG_WAIT, ER_FLG_SEND
  );

  signal sCalibState : state_type;
  attribute syn_encoding of sCalibState : signal is "onehot";

  ----------------------------------------------------------------------------
  -- RAM INTERFACE SIGNALS
  ----------------------------------------------------------------------------
  -- INPUT
  signal sPedIn       : CalibCompIN;
  signal sSigRawIn    : CalibCompIN;
  signal sSigIn       : CalibCompIN;
  signal sFlgIn       : CalibCompIN;

  -- OUTPUT
  signal sPedOut      : CalibCompOUT;
  signal sSigRawOut   : CalibCompOUT;
  signal sSigOut      : CalibCompOUT;
  signal sFlgOut      : CalibCompOUT;
  signal sRhtOut      : CalibCompOUT;
  signal sHthOut      : CalibCompOUT;
  signal sLthOut      : CalibCompOUT;

  ----------------------------------------------------------------------------
  -- SQRT SIGNALS
  ----------------------------------------------------------------------------
  signal sToSQRT_Start  : std_logic;
  signal sToSQRT_MSG    : t_FOOT_sqrt_data;
  signal sFromSQRT_Done : std_logic;
  signal sFromSQRT_MSG  : t_FOOT_lef_data;

  ----------------------------------------------------------------------------
  -- SMA
  ----------------------------------------------------------------------------
  signal sSMA_Valid_latched : std_logic_vector(pADC_NUM-1 downto 0);
  signal sSMA_Valid_rst     : std_logic;
  signal sSMA_InsertOnce    : std_logic;

  ----------------------------------------------------------------------------
  -- DSP and MULTICALIB
  ----------------------------------------------------------------------------
  signal sDSPout        : t_FOOT_lef_data;
  signal sWord          : t_FOOT_lef_data;

  signal sMCEnable      : std_logic;
  signal sMCMode        : std_logic_vector(1 downto 0);

  signal sMC_Data       : t_FOOT_lef_data;
  signal sMC_WA         : std_logic_vector(pUSEDW_WIDTH+1 downto 0);
  signal sMC_WEN        : std_logic;
  signal sMCBusy        : std_logic;
  signal sMCReady       : std_logic;

  ----------------------------------------------------------------------------
  -- Calibration-result mirror toward Event RAM
  ----------------------------------------------------------------------------
  signal sER_Adc        : natural range 0 to pADC_NUM - 1;
  signal sER_Strip      : natural range 0 to pADC_STRIPS - 1;
  signal sER_ReadAddr   : std_logic_vector(pUSEDW_WIDTH-1 downto 0);

  ----------------------------------------------------------------------------
  -- Busy edge (MultiCalib)
  ----------------------------------------------------------------------------
  signal sMCBusy_d       : std_logic;
  signal sMCBusy_falling : std_logic;

  ----------------------------------------------------------------------------
  -- Flag computation
  ----------------------------------------------------------------------------
  type t_flag_acc_data is array (0 to pADC_NUM - 1) of
    std_logic_vector((pDATA_WIDTH + 6) - 1 downto 0);

  signal sFlag_Compare   : t_flag_acc_data; 
  signal sFlag_VA_done   : std_logic;
  signal sFlag_cnt       : natural range 0 to cFE_CHANNELS-1;

  signal sFlag_ReadAddr  : std_logic_vector(pUSEDW_WIDTH-1 downto 0);
  signal sFlag_WriteAddr : std_logic_vector(pUSEDW_WIDTH-1 downto 0);

  signal sFlgWriteData   : t_FOOT_lef_data;
  signal sFlgWriteWE     : std_logic;

  -- RETRIEVE ADDR from VA 0 or 1 and iCNT
  function fFlagAddr(
    iVA  : std_logic;
    iCnt : natural
  ) return std_logic_vector is
  begin
    if iVA = '0' then
      return std_logic_vector(to_unsigned(iCnt, pUSEDW_WIDTH));
    else
      return std_logic_vector(to_unsigned(cFE_CHANNELS + iCnt, pUSEDW_WIDTH));
    end if;
  end function;

begin

  oMC_READY   <= sMCReady;
  oMC_MODE    <= sMCMode;
  oCALIB_BUSY <= '1' when sCalibState /= IDLE else '0';

  ----------------------------------------------------------------------------
  -- RAM read-address multiplexing
  --
  -- During flag computation, the calibration FSM temporarily owns the read
  -- ports of SIGRAW, SIG and FLG. Outside this phase, the external read
  -- addresses are forwarded unchanged.
  ----------------------------------------------------------------------------
  sPedIn.RADDR <= sER_ReadAddr
    when (
      sCalibState = ER_PED_INIT or
      sCalibState = ER_PED_WAIT or
      sCalibState = ER_PED_SEND
    )
    else iPED_RADDR;

  sSigRawIn.RADDR <= sER_ReadAddr
    when (
      sCalibState = ER_SIGRAW_INIT or
      sCalibState = ER_SIGRAW_WAIT or
      sCalibState = ER_SIGRAW_SEND
    )
    else sFlag_ReadAddr
    when (
      sCalibState = RSF_FETCH or
      sCalibState = RSF_COMP or
      sCalibState = RSF_PRE_FLAG or
      sCalibState = RSF_FLAG
    )
    else iSIGRAW_RADDR;

  sSigIn.RADDR <= sER_ReadAddr
    when (
      sCalibState = ER_SIG_INIT or
      sCalibState = ER_SIG_WAIT or
      sCalibState = ER_SIG_SEND
    )
    else sFlag_ReadAddr
    when (
      sCalibState = SF_FETCH or
      sCalibState = SF_COMP or
      sCalibState = SF_PRE_FLAG or
      sCalibState = SF_WAIT or
      sCalibState = SF_FLAG
    )
    else iSIG_RADDR;

  sFlgIn.RADDR <= sER_ReadAddr
    when (
      sCalibState = ER_FLG_INIT or
      sCalibState = ER_FLG_WAIT or
      sCalibState = ER_FLG_SEND
    )
    else sFlag_WriteAddr
    when (
      sCalibState = SF_PRE_FLAG or
      sCalibState = SF_WAIT or
      sCalibState = SF_FLAG
    )
    else iFLG_RADDR;

  ----------------------------------------------------------------------------
  -- RAM outputs to wrapper ports
  ----------------------------------------------------------------------------
  oPED_DATA    <= sPedOut.DATA;
  oSIGRAW_DATA <= sSigRawOut.DATA;
  oSIG_DATA    <= sSigOut.DATA;
  oFLG_DATA    <= sFlgOut.DATA;
  oLTH_DATA    <= sLthOut.DATA;
  oHTH_DATA    <= sHthOut.DATA;
  oRHT_DATA    <= sRhtOut.DATA;

  ----------------------------------------------------------------------------
  -- SQRT INSTANCE
  ----------------------------------------------------------------------------
  SQRT_INST : SQRT_wrap
    generic map(
      pADC_NUM => pADC_NUM
    )
    port map(
      iCLK        => iCLK,
      iRST        => iRST,
      iSQRT_MSG   => sToSQRT_MSG,
      iSQRT_Start => sToSQRT_Start,
      oSQRT_MSG   => sFromSQRT_MSG,
      oSQRT_Done  => sFromSQRT_Done
    );

  ----------------------------------------------------------------------------
  -- CALIB RAM INSTANCE
  ----------------------------------------------------------------------------
  CAL_RAM : CALIB_RAM
    generic map(
      pADC_NUM     => pADC_NUM,
      pADC_STRIPS  => pADC_STRIPS,
      pDATA_WIDTH  => pDATA_WIDTH,
      pUSEDW_WIDTH => pUSEDW_WIDTH,
      pFORCE_MLAB  => 1,
      pRHT         => pRHT,
      pHTH         => pHTH,
      pLTH         => pLTH
    )
    port map(
      iCLK          => iCLK,

      iRST          => iRST,
      iLTH          => iLTH,
      iHTH          => iHTH,
      iKC           => iKC,
      iKV           => iKV,

      iPED_DATA     => sPedIn.DATA,
      iPED_WADDR    => sPedIn.WADDR,
      iPED_RADDR    => sPedIn.RADDR,
      iPED_WE       => sPedIn.WE,
      oPED_DATA     => sPedOut.DATA,

      iSIGRAW_DATA  => sSigRawIn.DATA,
      iSIGRAW_WADDR => sSigRawIn.WADDR,
      iSIGRAW_RADDR => sSigRawIn.RADDR,
      iSIGRAW_WE    => sSigRawIn.WE,
      oSIGRAW_DATA  => sSigRawOut.DATA,

      iSIG_DATA     => sSigIn.DATA,
      iSIG_WADDR    => sSigIn.WADDR,
      iSIG_RADDR    => sSigIn.RADDR,
      iSIG_WE       => sSigIn.WE,
      oSIG_DATA     => sSigOut.DATA,

      iFLG_DATA     => sFlgIn.DATA,
      iFLG_WADDR    => sFlgIn.WADDR,
      iFLG_RADDR    => sFlgIn.RADDR,
      iFLG_WE       => sFlgIn.WE,
      oFLG_DATA     => sFlgOut.DATA,

      oLTH_DATA     => sLthOut.DATA,
      oHTH_DATA     => sHthOut.DATA,
      oRHT_DATA     => sRhtOut.DATA
    );

  ----------------------------------------------------------------------------
  -- DSPSQ INSTANCE
  ----------------------------------------------------------------------------
  DSPSQWrap_0 : DSPSQ_wrap
    generic map(
      pDATA_WIDTH  => pDATA_WIDTH,
      pADC_NUM     => pADC_NUM
    )
    port map(
      iDATA   => iWORD,   --ADC8
      oSQUARE => sDSPout  --ADC64
    );

  ----------------------------------------------------------------------------
  -- MULTICALIB INSTANCE
  ----------------------------------------------------------------------------
  MultiCalib : MultiCalibration
    generic map(
      pN_EVENT     => pN_EVENT,
      pDATA_WIDTH  => pDATA_WIDTH,
      pADC_STRIPS  => pADC_STRIPS,
      pUSEDW_WIDTH => pUSEDW_WIDTH,
      pACC_WIDTH   => pACC_WIDTH,
      pADC_NUM     => pADC_NUM
    )
    port map(
      iCLK        => iCLK,
      iRST        => iRST,
      iWORD       => sWord,
      iPUTD       => iPUTD,
      iENABLE     => sMCEnable,
      iCMODE      => sMCMode,
      oDATA       => sMC_Data,
      oWA         => sMC_WA,
      oWEN        => sMC_WEN,
      oBUSY       => sMCBusy,
      oREADY      => sMCReady,
      oSQRT_START => sToSQRT_Start,
      oSQRT_MSG   => sToSQRT_MSG,
      iSQRT_DONE  => sFromSQRT_Done,
      iSQRT_MSG   => sFromSQRT_MSG
    );

  -- If the current MultiCalib mode is SIGRAW or SIGMA, the squared input is used.
  sWord <= sDSPout when (sMCMode = "01" or sMCMode = "10") else iWORD;

  ----------------------------------------------------------------------------
  -- MultiCalib
  --
  -- The two MSBs of sMC_WA select the RAM bank:
  --   00 -> PED
  --   01 -> SIGRAW
  --   10 -> SIG
  --   11 -> unused here, ready for occupancy if needed
  --
  -- FLG is written only by the flag FSM below.
  ----------------------------------------------------------------------------
  process(all)
  begin
    sPedIn.DATA       <= (others => (others => '0'));
    sPedIn.WADDR      <= (others => '0');
    sPedIn.WE         <= '0';

    sSigRawIn.DATA    <= (others => (others => '0'));
    sSigRawIn.WADDR   <= (others => '0');
    sSigRawIn.WE      <= '0';

    sSigIn.DATA       <= (others => (others => '0'));
    sSigIn.WADDR      <= (others => '0');
    sSigIn.WE         <= '0';

    sFlgIn.DATA       <= (others => (others => '0'));
    sFlgIn.WADDR      <= (others => '0');
    sFlgIn.WE         <= '0';

    if sMC_WEN = '1' then
      case sMC_WA(pUSEDW_WIDTH+1 downto pUSEDW_WIDTH) is
        when "00" =>
          sPedIn.DATA  <= sMC_Data;
          sPedIn.WADDR <= sMC_WA(pUSEDW_WIDTH-1 downto 0);
          sPedIn.WE    <= '1';

        when "01" =>
          sSigRawIn.DATA  <= sMC_Data;
          sSigRawIn.WADDR <= sMC_WA(pUSEDW_WIDTH-1 downto 0);
          sSigRawIn.WE    <= '1';

        when "10" =>
          sSigIn.DATA  <= sMC_Data;
          sSigIn.WADDR <= sMC_WA(pUSEDW_WIDTH-1 downto 0);
          sSigIn.WE    <= '1';

        when others =>
          null;
      end case;
    end if;

    if sFlgWriteWE = '1' then
      sFlgIn.DATA  <= sFlgWriteData;
      sFlgIn.WADDR <= sFlag_WriteAddr;
      sFlgIn.WE    <= '1';
    end if;
  end process;

  ----------------------------------------------------------------------------
  -- PROCESS FOR SMA VALID
  ----------------------------------------------------------------------------
  process(iCLK, iRST)
  begin
    if iRST = '1' then
      sSMA_Valid_latched <= (others => '0');
    elsif rising_edge(iCLK) then
      if sSMA_Valid_rst = '1' then
        sSMA_Valid_latched <= (others => '0');
      else
        for i in 0 to pADC_NUM - 1 loop
          sSMA_Valid_latched(i) <= sSMA_Valid_latched(i) or iSMA_Valid(i);
        end loop;
      end if;
    end if;
  end process;

  ----------------------------------------------------------------------------
  -- Busy edge for MultiCalib
  ----------------------------------------------------------------------------
  process(iCLK, iRST)
  begin
    if iRST = '1' then
      sMCBusy_d       <= '0';
      sMCBusy_falling <= '0';
    elsif rising_edge(iCLK) then
      sMCBusy_d       <= sMCBusy;
      sMCBusy_falling <= sMCBusy_d and not sMCBusy;
    end if;
  end process;

  ----------------------------------------------------------------------------
  -- MAIN FSM
  ----------------------------------------------------------------------------
  process(iCLK, iRST)
    variable vFlagData : t_FOOT_lef_data;
  begin
    if iRST = '1' then
      sCalibState      <= IDLE;

      sMCEnable        <= '0';
      sMCMode          <= (others => '0');

      oSMA_priority    <= '0';
      oSMA_RST         <= '0';
      oSMA_INS_en      <= (others => '0');
      oSMA_INS_data    <= (others => (others => '0'));
      oSMA_WR_en       <= '0';
      oSMA_WR_addr     <= (others => '0');
      oSMA_Flush       <= (others => '0');

      sSMA_Valid_rst   <= '1';
      sSMA_InsertOnce  <= '0';

      sFlag_Compare    <= (others => (others => '0'));
      sFlag_VA_done    <= '0';
      sFlag_cnt        <= 0;
      sFlag_ReadAddr   <= (others => '0');
      sFlag_WriteAddr  <= (others => '0');

      sFlgWriteData    <= (others => (others => '0'));
      sFlgWriteWE      <= '0';

      oER_WE            <= '0';
      oER_W_ADDR        <= (others => '0');
      oER_DATA          <= (others => '0');
      sER_Adc           <= 0;
      sER_Strip         <= 0;
      sER_ReadAddr      <= (others => '0');

    elsif rising_edge(iCLK) then
      sMCEnable       <= '0';
      sFlgWriteWE     <= '0';
      oER_WE          <= '0';
      oSMA_INS_en     <= (others => '0');
      oSMA_WR_en      <= '0';
      oSMA_RST        <= '0';
      oSMA_Flush      <= (others => '0');
      sSMA_Valid_rst  <= '0';

      case sCalibState is

        -- Calibration
        when IDLE =>
          sMCMode         <= "00";
          oSMA_priority   <= '0';

          sFlag_Compare   <= (others => (others => '0'));
          sFlag_VA_done   <= '0';
          sFlag_cnt       <= 0;
          sSMA_InsertOnce <= '0';

          if iCALIB_ENABLE = '1' then
            -- When LadderWrapper forwards the first useful trigger together
            -- with iCALIB_ENABLE, start the pedestal acquisition immediately.
            -- The WAIT_PEDESTAL path is kept for compatibility with any caller
            -- that raises iCALIB_ENABLE before the trigger arrives.
            -- **TODO - Maybe rename iCALIB_ENABLE as iCALIB_START ??
            if iTRIG = '1' then
              sMCEnable   <= '1';
              sCalibState <= PEDESTAL;
            else
              sCalibState <= WAIT_PEDESTAL;
            end if;
          end if;

        when WAIT_PEDESTAL =>
          if iTRIG = '1' then
            sMCEnable   <= '1';
            sCalibState <= PEDESTAL;
          end if;

        when PEDESTAL =>
          if sMCBusy_falling = '1' then
            -- The PED RAM is complete: expose it through Event RAM
            -- before arming the next calibration stage.
            sCalibState <= ER_PED_INIT;
          end if;

        when ER_PED_INIT =>
          sER_Adc      <= 0;
          sER_Strip    <= 0;
          sER_ReadAddr <= (others => '0');
          sCalibState  <= ER_PED_WAIT;

        when ER_PED_WAIT =>
          -- CALIB_RAM read latency alignment.
          sCalibState <= ER_PED_SEND;

        when ER_PED_SEND =>
          oER_W_ADDR <= std_logic_vector(
            to_unsigned((sER_Adc * pADC_STRIPS) + sER_Strip, oER_W_ADDR'length)
          );
          oER_DATA <= sPedOut.DATA(sER_Adc); --@suppress
          oER_WE   <= '1';

          if sER_Adc /= pADC_NUM - 1 then
            sER_Adc <= sER_Adc + 1;
          else
            sER_Adc <= 0;
            if sER_Strip /= pADC_STRIPS - 1 then
              sER_Strip    <= sER_Strip + 1;
              sER_ReadAddr <= std_logic_vector(to_unsigned(sER_Strip + 1, pUSEDW_WIDTH));
              sCalibState  <= ER_PED_WAIT;
            else
              sMCMode      <= "01";   -- SIGRAW step
              sCalibState  <= WAIT_SIGRAW;
            end if;
          end if;

        when WAIT_SIGRAW =>
          if iTRIG = '1' then
            sMCEnable   <= '1';
            sCalibState <= SIGRAW;
          end if;

        when SIGRAW =>
          if sMCBusy_falling = '1' then
            -- The SIGRAW RAM is complete: expose it through Event RAM
            -- before arming the SIGMA acquisition.
            sCalibState <= ER_SIGRAW_INIT;
          end if;

        when ER_SIGRAW_INIT =>
          sER_Adc      <= 0;
          sER_Strip    <= 0;
          sER_ReadAddr <= (others => '0');
          sCalibState  <= ER_SIGRAW_WAIT;

        when ER_SIGRAW_WAIT =>
          -- CALIB_RAM read latency alignment.
          sCalibState <= ER_SIGRAW_SEND;

        when ER_SIGRAW_SEND =>
          oER_W_ADDR <= std_logic_vector(
            to_unsigned((sER_Adc * pADC_STRIPS) + sER_Strip, oER_W_ADDR'length)
          );
          oER_DATA <= sSigRawOut.DATA(sER_Adc); --@suppress
          oER_WE   <= '1';

          if sER_Adc /= pADC_NUM - 1 then
            sER_Adc <= sER_Adc + 1;
          else
            sER_Adc <= 0;
            if sER_Strip /= pADC_STRIPS - 1 then
              sER_Strip    <= sER_Strip + 1;
              sER_ReadAddr <= std_logic_vector(to_unsigned(sER_Strip + 1, pUSEDW_WIDTH));
              sCalibState  <= ER_SIGRAW_WAIT;
            else
              sMCMode      <= "10";   -- SIGMA step
              sCalibState  <= WAIT_SIGMA;
            end if;
          end if;

        when WAIT_SIGMA =>
          if iTRIG = '1' then
            sMCEnable   <= '1';
            sCalibState <= SIGMA;
          end if;

        when SIGMA =>
          if sMCBusy_falling = '1' then
            -- The SIG RAM is complete: expose it through Event RAM
            -- before starting the post-calibration flag computation.
            sCalibState <= ER_SIG_INIT;
          end if;

        when ER_SIG_INIT =>
          sER_Adc      <= 0;
          sER_Strip    <= 0;
          sER_ReadAddr <= (others => '0');
          sCalibState  <= ER_SIG_WAIT;

        when ER_SIG_WAIT =>
          -- CALIB_RAM read latency alignment.
          sCalibState <= ER_SIG_SEND;

        when ER_SIG_SEND =>
          oER_W_ADDR <= std_logic_vector(
            to_unsigned((sER_Adc * pADC_STRIPS) + sER_Strip, oER_W_ADDR'length)
          );
          oER_DATA <= sSigOut.DATA(sER_Adc); --@suppress
          oER_WE   <= '1';

          if sER_Adc /= pADC_NUM - 1 then
            sER_Adc <= sER_Adc + 1;
          else
            sER_Adc <= 0;
            if sER_Strip /= pADC_STRIPS - 1 then
              sER_Strip    <= sER_Strip + 1;
              sER_ReadAddr <= std_logic_vector(to_unsigned(sER_Strip + 1, pUSEDW_WIDTH));
              sCalibState  <= ER_SIG_WAIT;
            else
              -- Threshold data are exposed directly by CALIB_RAM with DSP, no computation needed
              -- Start the flag computation.
              oSMA_priority   <= '1';

              sFlag_Compare   <= (others => (others => '0'));
              sFlag_VA_done   <= '0';
              sFlag_cnt       <= 0;
              sSMA_InsertOnce <= '0';
              sSMA_Valid_rst  <= '1';

              sFlag_ReadAddr  <= fFlagAddr('0', 0);
              sFlag_WriteAddr <= fFlagAddr('0', 0);

              sCalibState <= RSF_FETCH;
            end if;
          end if;

        ----------------------------------------------------------------------
        -- RSF: Raw Sigma Flag
        --
        -- For each VA block, the raw sigma values are streamed into the SMA.
        -- Once the medians are available, each strip is classified as:
        --   bit 0 = dead raw-sigma channel
        --   bit 1 = noisy raw-sigma channel
        ----------------------------------------------------------------------
        when RSF_FETCH =>
          -- RAM-prefetch:
          -- RAM is currently addressed with the strip to be consumed in
          -- RSF_COMP; here the next address is already presented to get the next one in the following clk.
          sFlag_ReadAddr   <= std_logic_vector(unsigned(sFlag_ReadAddr) + 1);
          sSMA_InsertOnce  <= '0';
          sCalibState      <= RSF_COMP;

        when RSF_COMP =>
          if (sSMA_InsertOnce = '0') and (iSMA_Ready = '1') then
            oSMA_INS_data   <= sSigRawOut.DATA;
            oSMA_INS_en     <= (others => '1');
            oSMA_WR_en      <= '1';
            oSMA_WR_addr    <= std_logic_vector(to_unsigned(sFlag_cnt, oSMA_WR_addr'length));
            sSMA_InsertOnce <= '1';
          end if;

          for i in 0 to pADC_NUM - 1 loop
            if iSMA_Valid(i) = '1' then
              sFlag_Compare(i)(pDATA_WIDTH-1 downto 0) <= iSMA_Median(i); --@suppress
            end if;
          end loop;

          if (sSMA_Valid_latched = (sSMA_Valid_latched'range => '1')) or
             (iSMA_Valid = (iSMA_Valid'range => '1')) then

            sSMA_Valid_rst <= '1';

            if sFlag_cnt /= cFE_CHANNELS - 1 then
              sFlag_cnt   <= sFlag_cnt + 1;
              sCalibState <= RSF_FETCH;
            else
              sFlag_cnt       <= 0;
              oSMA_RST        <= '1';
              sFlag_ReadAddr  <= fFlagAddr(sFlag_VA_done, 0);
              sFlag_WriteAddr <= fFlagAddr(sFlag_VA_done, 0);
              sCalibState     <= RSF_PRE_FLAG;
            end if;
          end if;

        when RSF_PRE_FLAG =>
          -- Prefetch the next SIGRAW address while RSF_FLAG consumes the data
          -- already requested on the previous cycle.
          sFlag_ReadAddr  <= std_logic_vector(unsigned(sFlag_ReadAddr) + 1);
          sFlag_WriteAddr <= fFlagAddr(sFlag_VA_done, sFlag_cnt);
          sCalibState     <= RSF_FLAG;

        when RSF_FLAG =>
          vFlagData := (others => (others => '0'));

          for i in 0 to pADC_NUM - 1 loop
            -- Dead raw-sigma flag: raw sigma <= median / 2.
            if unsigned(sSigRawOut.DATA(i)) <=
               (unsigned(sFlag_Compare(i)(pDATA_WIDTH-1 downto 0)) / 2) then
              vFlagData(i)(0) := '1';
            end if;

            -- Noisy raw-sigma flag: raw sigma >= 1.5 * median.
            if unsigned(sSigRawOut.DATA(i)) >=
               ((unsigned(sFlag_Compare(i)(pDATA_WIDTH-1 downto 0)) * 3) / 2) then
              vFlagData(i)(1) := '1';
            end if;
          end loop;

          sFlgWriteData <= vFlagData;
          sFlgWriteWE   <= '1';

          if sFlag_cnt /= cFE_CHANNELS - 1 then
            sFlag_cnt   <= sFlag_cnt + 1;
            sCalibState <= RSF_PRE_FLAG;
          else
            sFlag_cnt <= 0;

            if sFlag_VA_done = '0' then
              sFlag_VA_done   <= '1';
              sSMA_InsertOnce <= '0';
              sSMA_Valid_rst  <= '1';
              sFlag_ReadAddr  <= fFlagAddr('1', 0);
              sCalibState     <= RSF_FETCH;
            else
              sFlag_VA_done  <= '0';
              sFlag_Compare  <= (others => (others => '0'));
              sFlag_ReadAddr <= fFlagAddr('0', 0);
              sCalibState    <= SF_FETCH;
            end if;
          end if;

        ----------------------------------------------------------------------
        -- SF: Sigma Flag
        --
        -- For each VA block, compute the average sigma for each ADC channel.
        -- Then each strip is classified as:
        --   bit 2 = dead sigma channel
        --   bit 3 = noisy sigma channel
        ----------------------------------------------------------------------
        when SF_FETCH =>
          -- Same read-ahead policy used by the original CalibrationWrapper.
          sFlag_ReadAddr <= std_logic_vector(unsigned(sFlag_ReadAddr) + 1);
          sCalibState    <= SF_COMP;

        when SF_COMP =>
          for i in 0 to pADC_NUM - 1 loop
            sFlag_Compare(i) <= std_logic_vector(
              unsigned(sFlag_Compare(i)) +
              resize(unsigned(sSigOut.DATA(i)), pDATA_WIDTH + 6)
            );
          end loop;

          if sFlag_cnt /= cFE_CHANNELS - 1 then
            sFlag_cnt   <= sFlag_cnt + 1;
            sCalibState <= SF_FETCH;
          else
            sFlag_cnt       <= 0;
            sFlag_ReadAddr  <= fFlagAddr(sFlag_VA_done, 0);
            sFlag_WriteAddr <= fFlagAddr(sFlag_VA_done, 0);
            -- comparison must wait one cycle for the just-requested SIG/FLG
            -- RAM words, without pre-incrementing the addresses first.
            sCalibState     <= SF_WAIT;
          end if;

        when SF_PRE_FLAG =>
          -- Prefetch both SIG and FLG read addresses.
          sFlag_ReadAddr  <= std_logic_vector(unsigned(sFlag_ReadAddr) + 1);
          sFlag_WriteAddr <= std_logic_vector(unsigned(sFlag_WriteAddr) + 1);
          sCalibState     <= SF_WAIT;

        when SF_WAIT =>
          sCalibState <= SF_FLAG;

        when SF_FLAG =>
          -- Preserve the two RSF flag bits already written in FLG RAM.
          vFlagData := sFlgOut.DATA;

          for i in 0 to pADC_NUM - 1 loop
            -- Dead sigma flag: sigma <= average_sigma / 4.
            if unsigned(sSigOut.DATA(i)) <=
               (unsigned(sFlag_Compare(i)((pDATA_WIDTH + 6) - 1 downto 6)) / 4) then
              vFlagData(i)(2) := '1';
            end if;

            -- Noisy sigma flag: sigma >= 1.5 * average_sigma.
            if unsigned(sSigOut.DATA(i)) >=
               ((unsigned(sFlag_Compare(i)((pDATA_WIDTH + 6) - 1 downto 6)) * 3) / 2) then
              vFlagData(i)(3) := '1';
            end if;
          end loop;

          -- SF_PRE_FLAG uses this register to prefetch the next FLG word.
          -- Before raising the write strobe, restore the current strip address,
          -- as the original wrapper did with sFsm_B_addr inside SF_FLAG.
          sFlag_WriteAddr <= fFlagAddr(sFlag_VA_done, sFlag_cnt);
          sFlgWriteData   <= vFlagData;
          sFlgWriteWE     <= '1';

          if sFlag_cnt /= cFE_CHANNELS - 1 then
            sFlag_cnt   <= sFlag_cnt + 1;
            sCalibState <= SF_PRE_FLAG;
          else
            sFlag_cnt <= 0;

            if sFlag_VA_done = '0' then
              sFlag_VA_done  <= '1';
              sFlag_Compare  <= (others => (others => '0'));
              sFlag_ReadAddr <= fFlagAddr('1', 0);
              sCalibState    <= SF_FETCH;
            else
              sFlag_VA_done <= '0';
              oSMA_priority <= '0';
              -- The FLG RAM now contains both RSF and SF flag bits.
              -- Mirror the final flag map to Event RAM as well.
              sCalibState   <= ER_FLG_INIT;
            end if;
          end if;

        -- Final FLG dump toward Event RAM
        when ER_FLG_INIT =>
          sER_Adc      <= 0;
          sER_Strip    <= 0;
          sER_ReadAddr <= (others => '0');
          sCalibState  <= ER_FLG_WAIT;

        when ER_FLG_WAIT =>
          -- CALIB_RAM read latency alignment.
          sCalibState <= ER_FLG_SEND;

        when ER_FLG_SEND =>
          oER_W_ADDR <= std_logic_vector(
            to_unsigned((sER_Adc * pADC_STRIPS) + sER_Strip, oER_W_ADDR'length)
          );
          oER_DATA <= sFlgOut.DATA(sER_Adc); --@suppress
          oER_WE   <= '1';

          if sER_Adc /= pADC_NUM - 1 then
            sER_Adc <= sER_Adc + 1;
          else
            sER_Adc <= 0;
            if sER_Strip /= pADC_STRIPS - 1 then
              sER_Strip    <= sER_Strip + 1;
              sER_ReadAddr <= std_logic_vector(to_unsigned(sER_Strip + 1, pUSEDW_WIDTH));
              sCalibState  <= ER_FLG_WAIT;
            else
              sCalibState <= IDLE;
            end if;
          end if;

        when others => --@suppress
          sCalibState <= IDLE;

      end case;
    end if;
  end process;

end architecture Behavioral;
