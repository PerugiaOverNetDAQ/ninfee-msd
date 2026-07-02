--!@file FE_interface.vhd
--!@brief Low-level interface of the uStrip FrontEnd IDE1140_DS
--!@details See the FE datasheet for additional details on the interface
--!@todo The deassertion of enable input shall stop the FSM
--!@author Mattia Barbanera, mattia.barbanera@infn.it
--!@date 28/01/2020

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_unsigned.all;
use ieee.math_real.all;

use work.basic_package.all;
use work.FOOTpackage.all;

--!@copydoc FE_interface.vhd
entity FE_interface is
  port (
    iCLK      : in  std_logic;          --!Main clock
    iRST      : in  std_logic;          --!Main reset
    -- control interface
    oCNT      : out tControlIntfOut;    --!Control signals in output
    iCNT      : in  tControlIntfIn;     --!Control signals in input
    iCNT_G    : in  std_logic_vector(2 downto 0);  --!Values for FE G* parameters
    iCNT_Test : in  std_logic;          --!Flag to activate the FE test-mode
    iCNT_TEST_CH    : in std_logic_vector(7 downto 0); --!Channel where to inject calibration in test mode
    iCNT_OTHER_EDGE : in std_logic;     --!Opposite edge when compared to the slwEn
    oDATA_VLD : out std_logic;          --!Flags data available at ADC input
    -- FE interface
    oFE       : out tFpga2FeIntf;       --!Signals from the FPGA to the FE
    iFE       : in  tFe2FpgaIntf        --!Signals from the FE to the FPGA
    );
end FE_interface;

--!@copydoc FE_interface.vhd
architecture std of FE_interface is
  constant cCH_COUNT_WIDTH  : natural := ceil_log2(cFE_CHANNELS);
  --cDC_COUNT_WIDTH has 1 extra bit to handle the case of only 1 VA
  constant cDC_COUNT_WIDTH  : natural := ceil_log2(cFE_DAISY_CHAIN_DEPTH)+1;
  constant cS2C_COUNT_WIDTH : natural := 4;

  signal sCntIn   : tControlIntfIn;
  signal sCntOut  : tControlIntfOut;
  signal sFpga2Fe : tFpga2FeIntf;

  type tFsmFe is (RESET, IDLE, SYNCH_START, HOLD, SHIFT,
                  FIRST_CLOCK, CLOCK_FORWARD, SYNCH_END, COMPLETE);
  signal sFeState, sNextFeState : tFsmFe;

  --!@brief Wait for the enable assertion to change state
  --!@param[in] en  If '1', go to destination state
  --!@param[in] src Source state; remain here until enable is asserted
  --!@param[in] dst Destination state; go here when enable is asserted
  --!@return FSM next state depending on the enable assertion
  function wait4en (en : std_logic; src : tFsmFe; dst : tFsmFe) return tFsmFe is
    variable goto : tFsmFe;
  begin
    if (en = '1') then
      goto := dst;
    else
      goto := src;
    end if;
    return goto;
  end function wait4en;

  type tChCountInterface is record
    preset : std_logic_vector(cCH_COUNT_WIDTH-1 downto 0);
    count  : std_logic_vector(cCH_COUNT_WIDTH-1 downto 0);
    en     : std_logic;
    load   : std_logic;
    carry  : std_logic;
  end record tChCountInterface;
  signal sChCountRst  : std_logic;
  signal sChCount     : tChCountInterface;

  type tDcCountInterface is record
    preset : std_logic_vector(cDC_COUNT_WIDTH-1 downto 0);
    count  : std_logic_vector(cDC_COUNT_WIDTH-1 downto 0);
    en     : std_logic;
    load   : std_logic;
    carry  : std_logic;
  end record tDcCountInterface;
  signal sDcCountRst  : std_logic;
  signal sDcCount     : tDcCountInterface;

  type tS2cCountInterface is record
    preset : std_logic_vector(cS2C_COUNT_WIDTH-1 downto 0);
    count  : std_logic_vector(cS2C_COUNT_WIDTH-1 downto 0);
    en     : std_logic;
    load   : std_logic;
    carry  : std_logic;
  end record tS2cCountInterface;
  signal sS2cCountRst : std_logic;
  signal sS2cCount    : tS2cCountInterface;

  signal sAtLeastOneFe : std_logic;

  --Count channels for test mode
  --sTestCh has 1 extra bit to handle the case of only 1 VA
  signal sTestCh    : std_logic_vector(ceil_log2(cFE_CLOCK_CYCLES) downto 0);
  signal sTestSend  : std_logic;
begin
  -- Combinatorial assignments -------------------------------------------------
  oCNT   <= sCntOut;
  sCntIn <= iCNT;

  oFE.G0      <= sFpga2Fe.G0;
  oFE.G1      <= sFpga2Fe.G1;
  oFE.G2      <= sFpga2Fe.G2;
  oFE.Hold    <= not sFpga2Fe.Hold;
  oFE.DRst    <= sFpga2Fe.DRst;
  oFE.ShiftIn <= not sFpga2Fe.ShiftIn;
  oFE.Clk     <= sFpga2Fe.Clk;
  oFE.TestOn  <= sFpga2Fe.TestOn;

  sFpga2Fe.G0 <= iCNT_G(0);
  sFpga2Fe.G1 <= iCNT_G(1);
  sFpga2Fe.G2 <= iCNT_G(2);

  sTestCh <= sDcCount.count & sChCount.count;
  ------------------------------------------------------------------------------

  --! @brief Output signals in a synchronous fashion, without reset
  --! @param[in] iCLK Clock, used on rising edge
  FE_synch_signals_proc : process (iCLK)
  begin
    if (rising_edge(iCLK)) then
    sFpga2Fe.TestOn <= iCNT_Test;

      if (sFeState = HOLD or sFeState = SHIFT or sFeState = FIRST_CLOCK
          or sFeState = CLOCK_FORWARD or sFeState = SYNCH_END) then
        sFpga2Fe.Hold <= not iCNT_Test; --Disable HOLD when test mode is enabled
      else
        sFpga2Fe.Hold <= '0';
      end if;

      if (sFeState = RESET) then
        sFpga2Fe.DRst <= '1';
      else
        sFpga2Fe.DRst <= '0';
      end if;

      if (sFeState = RESET or sFeState = IDLE or
         (sFeState = FIRST_CLOCK and iCNT_OTHER_EDGE='1')) then
        sFpga2Fe.ShiftIn <= '0';
      elsif (sFeState = SHIFT) then
        sFpga2Fe.ShiftIn <= not sAtLeastOneFe;
      end if;

      if (sFeState = FIRST_CLOCK or sFeState = CLOCK_FORWARD
          or sFeState = SYNCH_END) then
        sFpga2Fe.Clk <= sCntIn.slwClk;
      else
        sFpga2Fe.Clk <= '1';
      end if;

      if (sNextFeState /= IDLE) then
        sCntOut.busy <= '1';
      else
        sCntOut.busy <= '0';
      end if;

      if (sNextFeState = RESET) then
        sCntOut.reset <= '1';
      else
        sCntOut.reset <= '0';
      end if;

      --!@todo How do I check the "when others" statement?
      sCntOut.error <= '0';

      if (sNextFeState = COMPLETE) then
        sCntOut.compl <= '1';
      else
        sCntOut.compl <= '0';
      end if;

      if (sFeState = SYNCH_END) then
        sAtLeastOneFe <= '1';
      elsif (sFeState = HOLD) then
        sAtLeastOneFe <= '0';
      end if;

      if (sNextFeState = FIRST_CLOCK or sNextFeState = CLOCK_FORWARD
          or sNextFeState = SYNCH_END) then
        oDATA_VLD <= not iCNT_Test;
      else
        oDATA_VLD <= '0';
      end if;

      if (sTestCh < iCNT_TEST_CH) then
        sTestSend <= '1';
      else
        sTestSend <= not iCNT_Test;
      end if;

    end if;
  end process FE_synch_signals_proc;

  --!Counters default
  sChCount.load   <= '0';
  sDcCount.load   <= '0';
  sS2cCount.load  <= '0';
  sChCount.preset <= (others => '0');
  sDcCount.preset <= (others => '0');
  sS2cCount.preset<= (others => '0');

  sChCountRst <= '1' when (sFeState = RESET or sFeState = IDLE
                           or sFeState = SHIFT) else
                 '0';
  sChCount.en <= sCntIn.slwEn when (sFeState = FIRST_CLOCK
                                    or sFeState = CLOCK_FORWARD) else
                 '0';
  --! @brief Multi-purpose counter to implement delays in the FSM
  CH_COUNTER : counter
    generic map(
      pOVERLAP  => "Y",
      pBUSWIDTH => cCH_COUNT_WIDTH
      )
    port map(
      iCLK   => iCLK,
      iRST   => sChCountRst,
      iEN    => sChCount.en,
      iLOAD  => sChCount.load,
      iDATA  => sChCount.preset,
      oCOUNT => sChCount.count,
      oCARRY => sChCount.carry
      );

  sDcCountRst <= '1' when (sFeState = RESET or sFeState = IDLE) else
                 '0';
  sDcCount.en <= sCntIn.slwEn when (sFeState = SYNCH_END) else
                 '0';
  --!@brief Count the number of FEs in the daisy chain
  DC_COUNTER : counter
    generic map(
      pOVERLAP  => "Y",
      pBUSWIDTH => cDC_COUNT_WIDTH
      )
    port map(
      iCLK   => iCLK,
      iRST   => sDcCountRst,
      iEN    => sDcCount.en,
      iLOAD  => sDcCount.load,
      iDATA  => sDcCount.preset,
      oCOUNT => sDcCount.count,
      oCARRY => sDcCount.carry
      );

  sS2cCountRst <= '1' when (sFeState /= SHIFT) else
                  '0';
  sS2cCount.en <= sCntIn.slwEn when (sFeState = SHIFT) else
                  '0';
  --!@brief Count the slwClk cycles between the shift and clk assertion
  S2C_COUNTER : counter
    generic map(
      pOVERLAP  => "Y",
      pBUSWIDTH => cS2C_COUNT_WIDTH
      )
    port map(
      iCLK   => iCLK,
      iRST   => sS2cCountRst,
      iEN    => sS2cCount.en,
      iLOAD  => sS2cCount.load,
      iDATA  => sS2cCount.preset,
      oCOUNT => sS2cCount.count,
      oCARRY => sS2cCount.carry
      );

  --! @brief Add FFDs to the combinatorial signals \n
  --! @param[in] iCLK  Clock, used on rising edge
  ffds : process (iCLK)
  begin
    if (rising_edge(iCLK)) then
      if (iRST = '1') then
        sFeState <= RESET;
      else
        sFeState <= sNextFeState;
      end if;  --iRST
    end if;  --rising_edge
  end process ffds;

  --! @brief Combinatorial FSM to operate the FEs
  --! @param[in] sFeState  Current state of the FSM
  --! @param[in] sCntIn Input signals of the control interface
  --! @param[in] sChCount.count Output of the delay counter
  --! @return sNextFeState  Next state of the FSM
  FSM_FE_proc : process (sFeState, sCntIn, sChCount.count,
                        sDcCount.count, sS2cCount.count)
  begin
    case (sFeState) is
      --Reset the FSM
      when RESET =>
        sNextFeState <= wait4en(sCntIn.slwEn, RESET, IDLE);

      --Wait for the START signal to be asserted
      when IDLE =>
        if (sCntIn.en = '1' and sCntIn.start = '1') then
          sNextFeState <= SYNCH_START;
        else
          sNextFeState <= IDLE;
        end if;

      --Wait for the slow-clock enable before starting
      when SYNCH_START =>
        sNextFeState <= wait4en(sCntIn.slwEn, SYNCH_START, HOLD);

      --Assert the HOLD signal
      when HOLD =>
        sNextFeState <= wait4en(sCntIn.slwEn, HOLD, SHIFT);

      --Assert the SHIFT signal without forwarding clock
      when SHIFT =>
        if (sS2cCount.count <
                  int2slv(cFE_SHIFT_2_CLK-1, sS2cCount.count'length)) then
          --Wait until the  delay is over
          sNextFeState <= SHIFT;
        else
          --Delay concluded
          sNextFeState <= wait4en(sCntIn.slwEn, SHIFT, FIRST_CLOCK);
        end if;

      --First clock forwarded to the FE
      when FIRST_CLOCK =>
        if (sTestSend = '1') then
          sNextFeState <= wait4en(sCntIn.slwEn, FIRST_CLOCK, CLOCK_FORWARD);
        else
          sNextFeState <= SYNCH_END;
        end if;


      --Send the remaining clocks to the FE(s)
      when CLOCK_FORWARD =>
        if (sChCount.count <
            int2slv(cFE_CHANNELS-1, sChCount.count'length)) then
          if (sTestSend = '1') then
            sNextFeState <= CLOCK_FORWARD;
          else
            sNextFeState <= SYNCH_END;
          end if;
        else
          sNextFeState <= SYNCH_END;
        end if;

      --Wait for the slow clock enable before ending the readout
      when SYNCH_END =>
        if (sDcCount.count <
                  int2slv(cFE_DAISY_CHAIN_DEPTH-1, sDcCount.count'length)) then
          --Still other FEs in the chain
          if (sTestSend = '1') then
            sNextFeState <= wait4en(sCntIn.slwEn, SYNCH_END, SHIFT);
          else
            sNextFeState <= wait4en(sCntIn.slwEn, SYNCH_END, COMPLETE);
          end if;
        else
          --No more FEs to readout
          sNextFeState <= wait4en(sCntIn.slwEn, SYNCH_END, COMPLETE);
        end if;
      
      --Done; Reset if in test mode, or go back to IDLE otherwise
      when COMPLETE =>
        if (iCNT_Test = '1') then
          if (sCntIn.en = '1') then
            sNextFeState <= COMPLETE;
          else
            sNextFeState <= RESET;
          end if;
        else --iCNT_TEST = '0' or others
          sNextFeState <= IDLE;
        end if;

      --State not foreseen
      when others =>
        sNextFeState <= RESET;

    end case;
  end process FSM_FE_proc;


end architecture std;
