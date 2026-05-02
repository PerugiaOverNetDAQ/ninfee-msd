--!@file multiLTC2313_interface.vhd
--!@brief Low-level interface for multiple ADCs (possibly, AD7276)
--!@author Mattia Barbanera, mattia.barbanera@infn.it
--!@date 16/06/2020
--!@version 0.1 - 03/07/2020 - SV Testbench

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_unsigned.all;
use ieee.math_real.all;

use work.basic_package.all;
use work.FOOTpackage.all;

--!@brief Low-level interface for multiple ADCs (possibly, AD7276)
--!@details Serial interface with the 12-bit ADC.
--!See the ADC datasheet for additional details
entity multiLTC2313_interface is
  port (
    iCLK  : in  std_logic;                --!Main clock
    iRST  : in  std_logic;                --!Main reset
    -- control interface
    oCNT  : out tControlIntfOut;          --!Control signals in output
    iCNT  : in  tControlIntfIn;           --!Control signals in input
    iFAST : in  std_logic;                --!Switch to the fast-data mode
    -- ADC interface
    oADC        : out tFpga2AdcIntf;      --!Signals from the FPGA to the ADCs
    iMULTI_ADC  : in  tMultiAdc2FpgaIntf; --!Signals from the ADCs to the FPGA
    -- Word in output
    oMULTI_FIFO : out tMultiAdcFifoIn     --!Output data and write request
    );
end multiLTC2313_interface;

architecture std of multiLTC2313_interface is
  constant cCOUNT_INTERFACE : natural := 8;
  constant cLTC2313_WIDTH : natural := 14;

  signal sCntIn    : tControlIntfIn;
  signal sCntOut   : tControlIntfOut;
  signal sFpga2Adc : tFpga2AdcIntf;
  signal sAdc2Fpga : tMultiAdc2FpgaIntf;
  signal sOutWord  : tMultiAdcFifoIn;

  type tFsmAdc is (RESET, IDLE, SAMPLE, READOUT, WRITE_WORD);
  signal sAdcState, sNextAdcState : tFsmAdc;

  --!@brief Wait for the enable assertion to change state
  --!@param[in] en  If '1', go to destination state
  --!@param[in] src Source state; remain here until enable is asserted
  --!@param[in] dst Destination state; go here when enable is asserted
  --!@return FSM next state depending on the enable assertion
  function wait4en (en : std_logic; src : tFsmAdc; dst : tFsmAdc)
    return tFsmAdc is
    variable goto : tFsmAdc;
  begin
    if (en = '1') then
      goto := dst;
    else
      goto := src;
    end if;
    return goto;
  end function wait4en;

  type tCountInterface is record
    preset : std_logic_vector(cCOUNT_INTERFACE-1 downto 0);
    count  : std_logic_vector(cCOUNT_INTERFACE-1 downto 0);
    en     : std_logic;
    load   : std_logic;
    carry  : std_logic;
  end record tCountInterface;
  signal sCountRst  : std_logic := '0';
  signal sCountIntf : tCountInterface;

  type tShiftRegInterface is record
    en     : std_logic;
    load   : std_logic;
    serIn  : std_logic;
    parIn  : std_logic_vector(cADC_DATA_WIDTH-1 downto 0);
    serOut : std_logic;
    parOut : std_logic_vector(cADC_DATA_WIDTH-1 downto 0);
  end record tShiftRegInterface;
  type tMultiShiftRegIntf is array (0 to cTOTAL_ADCS-1) of tShiftRegInterface;
  signal sSrRst : std_logic;
  signal sSrEn  : std_logic;
  --signal sSr    : tShiftRegInterface;
  signal sMultiSr : tMultiShiftRegIntf;

  signal sSampleDuration : std_logic_vector(4 downto 0);

begin
  -- Combinatorial assignments -------------------------------------------------
  oCNT   <= sCntOut;
  sCntIn <= iCNT;

  oADC.SClk <= sFpga2Adc.SClk;
  oADC.Cs   <= sFpga2Adc.Cs;

  sAdc2Fpga <= iMULTI_ADC;

  oMULTI_FIFO   <= sOutWord;
  ------------------------------------------------------------------------------

  --! @brief Output signals in a synchronous fashion, without reset
  --! @param[in] iCLK Clock, used on rising edge
  ADC_synch_signals_proc : process (iCLK)
  begin
    if (rising_edge(iCLK)) then
      if (sNextAdcState = READOUT) then
        sFpga2Adc.SClk <= sCntIn.slwClk;
      else
        sFpga2Adc.SClk <= '0';
      end if;

      if (sNextAdcState = SAMPLE) then
        sFpga2Adc.Cs <= '1';
      else
        sFpga2Adc.Cs <= '0';
      end if;

      if (sNextAdcState /= IDLE) then
        sCntOut.busy <= '1';
      else
        sCntOut.busy <= '0';
      end if;

      if (sNextAdcState = RESET) then
        sCntOut.reset <= '1';
      else
        sCntOut.reset <= '0';
      end if;

      --!@todo How do I check the "when others" statement?
      sCntOut.error <= '0';

      if (sNextAdcState = WRITE_WORD) then
        sCntOut.compl <= '1';
      else
        sCntOut.compl <= '0';
      end if;

      if (sNextAdcState = READOUT) then
        sSrEn <= sCntIn.slwEn;
      else
        sSrEn <= '0';
      end if;

      if (sNextAdcState = SAMPLE) then
        sSampleDuration <= sSampleDuration + 1;
      else
        sSampleDuration <= (others => '0');
      end if;

    end if;
  end process ADC_synch_signals_proc;

  sCountRst <= '1' when (sAdcState /= READOUT) else
               '0';
  sCountIntf.en <= sCntIn.slwEn when (sAdcState = READOUT) else
                   '0';
  sCountIntf.load   <= '0';
  sCountIntf.preset <= (others => '0');
  --!@brief Multi-purpose counter to implement delays in the FSM
  delay_timer : counter
    generic map(
      pOVERLAP  => "Y",
      pBUSWIDTH => cCOUNT_INTERFACE
      )
    port map(
      iCLK   => iCLK,
      iRST   => sCountRst,
      iEN    => sCountIntf.en,
      iLOAD  => sCountIntf.load,
      iDATA  => sCountIntf.preset,
      oCOUNT => sCountIntf.count,
      oCARRY => sCountIntf.carry
      );

  sSrRst <= '1' when (sAdcState = RESET or sAdcState = IDLE) else
            '0';
  --!@brief Generate multiple Shift-registers to sample the ADCs
  SR_GENERATE : for i in 0 to cTOTAL_ADCS-1 generate
    sMultiSr(i).load  <= '0';
    sMultiSr(i).parIn <= (others => '0');
    sMultiSr(i).en    <= sSrEn;
    sMultiSr(i).serIn <= sAdc2Fpga(i).SData;

    --!@brief Shift register to sample and deserialize the single ADC output
    sampler : shift_register
      generic map(
        pWIDTH => cADC_DATA_WIDTH,
        pDIR   => "LEFT"                  --"RIGHT"
        )
      port map(
        iCLK      => iCLK,
        iRST      => sSrRst,
        iEN       => sMultiSr(i).en,
        iLOAD     => sMultiSr(i).load,
        iSHIFT    => sMultiSr(i).serIn,
        iDATA     => sMultiSr(i).parIn,
        oSER_DATA => sMultiSr(i).serOut,
        oPAR_DATA => sMultiSr(i).parOut
        );

    --sOutWord(i).data <= sMultiSr(i).parOut(cADC_DATA_WIDTH-3 downto 0) & "00"
    --                      when (iFAST = '1') else
    --                    sMultiSr(i).parOut;
    sOutWord(i).data <= "00" & sMultiSr(i).parOut(cADC_DATA_WIDTH-3 downto 0)
                        when (iFAST = '1') else
                        sMultiSr(i).parOut;
    sOutWord(i).wr   <= '1' when (sAdcState = WRITE_WORD) else
                        '0';
    sOutWord(i).rd   <= '0';
  end generate SR_GENERATE;

  --!@brief Add FFDs to the combinatorial signals
  --!@param[in] iCLK  Clock, used on rising edge
  ffds : process (iCLK)
  begin
    if (rising_edge(iCLK)) then
      if (iRST = '1') then
        sAdcState <= RESET;
      else
        sAdcState <= sNextAdcState;
      end if;  --iRST
    end if;  --rising_edge
  end process ffds;

  --! @brief Combinatorial FSM to operate the ADC
  --! @param[in] sAdcState Current state of the FSM
  --! @param[in] sCntIn Input signals of the control interface
  --! @param[in] sCountIntf.count Output of the delay counter
  --! @param[in] sSampleDuration Minimum conversion time
  --! @return sNextAdcState  Next state of the FSM
  FSM_ADC_proc : process (sAdcState, sCntIn, sCountIntf.count, sSampleDuration)
  begin
    case (sAdcState) is
      --Reset the FSM
      when RESET =>
        sNextAdcState <= wait4en(sCntIn.slwEn, RESET, IDLE);

      --Wait for the start signal to be asserted
      when IDLE =>
        if (sCntIn.en = '1' and sCntIn.start = '1') then
          sNextAdcState <= SAMPLE;
        else
          sNextAdcState <= IDLE;
        end if;
      
      --Wait for the start signal to be asserted
      when SAMPLE =>
        if (sSampleDuration <
            int2slv((cLTC3213_CONV_CLK), sSampleDuration'length)) then
          sNextAdcState <= SAMPLE;
        else
        sNextAdcState <= READOUT;
        end if;

      --Readout the incoming 14 bits
      when READOUT =>
        if (sCountIntf.count <
            int2slv((cADC_DATA_WIDTH-2), sCountIntf.count'length)) then
          sNextAdcState <= READOUT;
        else
          sNextAdcState <= wait4en(sCntIn.slwEn, READOUT, WRITE_WORD);
        end if;

      --Write the deserialized word in output
      when WRITE_WORD =>
        sNextAdcState <= IDLE;

      --State not foreseen
      when others =>
        sNextAdcState <= RESET;

    end case;
  end process FSM_ADC_proc;


end architecture std;
