--!@file FOOTpackage.vhd
--!@brief Constants, components declarations and functions
--!@author Mattia Barbanera, mattia.barbanera@infn.it
--!@author Luca Russo, luca.russo@cern.ch, luca.russo912@gmail.com
--!@author Hikmat Nasimi, hikmat.nasimi@pi.infn.it
--!@date 28/01/2020
--!@version 0.1 - 28/01/2020 -

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_unsigned.all;

use work.basic_package.all;

--!@brief Constants, components declarations and functions
package FOOTpackage is
  constant cADC_DATA_WIDTH       : natural := 16;  --!ADC data-width
  constant cADC_FIFO_DEPTH       : natural := 256;  --!ADC FIFO number of words
  constant cCOLL_FIFO_DEPTH      : natural := 2048;  --! numero totale massimo di parole da 16 bit nella fifo finale 1280??
  constant cFE_DAISY_CHAIN_DEPTH : natural := 2;   --!FEs in a daisy chain
  constant cFE_CHANNELS          : natural := 64;  --!Channels per FE
  constant cFE_CLOCK_CYCLES      : natural := cFE_DAISY_CHAIN_DEPTH*cFE_CHANNELS;  --!Number of clock cycles to feed a chain
  constant cFE_SHIFT_2_CLK       : natural := 2; --!Wait between FE shift and clock assertion
  constant cTOTAL_ADCS           : natural := 10; --!Total ADCs

  constant cCLK_FREQ             : natural := 20; --!Clock frequency in ns (used only to compute delay)
  constant cMULT                 : natural := 320; --!Multiplier of the BUSY stretch in ns

  constant cFE_CLK_DIV   : std_logic_vector(15 downto 0) := int2slv(34, 16); --!FE SlowClock divider: was 160 at the GSI test beam
  constant cADC_CLK_DIV  : std_logic_vector(15 downto 0) := int2slv(2, 16);  --!ADC SlowClock divider
  constant cFE_CLK_DUTY  : std_logic_vector(15 downto 0) := int2slv(8, 16);  --!FE SlowClock duty cycle
  constant cADC_CLK_DUTY : std_logic_vector(15 downto 0) := int2slv(1, 16);  --!ADC SlowClock duty cycle
  constant cADC_DELAY    : std_logic_vector(15 downto 0) := int2slv(29, 16);  --!Delay from the FE falling edge and the start of the AD conversion
  constant cBUSY_LEN     : std_logic_vector(15 downto 0) := int2slv((cFE_CLOCK_CYCLES*cTOTAL_ADCS*cCLK_FREQ)/(2*cMULT), 16);  --!320-ns duration of busy extension time
  --!iCFG_PLANE bits: 2:0: FE-Gs;  3: FE-test; 4: Ext-TRG; 15:5: x
  constant cCFG_PLANE    : std_logic_vector(15 downto 0) := x"0107";  --!uStrip configurations
  constant cTRG_PERIOD   : std_logic_vector(31 downto 0) := x"0000FFFF";  --!Clock cycles between two internal triggers
  constant cTRG2HOLD     : std_logic_vector(15 downto 0) := int2slv(325, 16);  --!Clock-cycles between an external trigger and the FE-HOLD signal

  -- - - - - -  ** Calibration ** - - - - -
  constant cADC_CHANNELS          : natural := cFE_CHANNELS*2; 
  constant cHEAP_SIZE             : natural := 4;
  constant cACC_WIDTH             : natural := 32; -- Accumolators for pedestal and sigma bit width
  constant cSQRT_WIDTH            : natural := 32; -- Modified for 32 bit version
  constant cSMA_CALC_MODE         : natural := 2;
  constant cN_EVENT               : natural := 1024; -- Number of events for each calib stare (ped, sigraw, sig)


  -- Costanti moltiplicative
  constant cRHT              : std_logic_vector(cADC_DATA_WIDTH-1 downto 0) := "0000000101000000"; -- 10  in ADC32
  constant cHTH              : std_logic_vector(cADC_DATA_WIDTH-1 downto 0) := "0000000001110000"; -- 3.5 in ADC32
  constant cLTH              : std_logic_vector(cADC_DATA_WIDTH-1 downto 0) := "0000000000110000"; -- 1.5 in ADC32
  constant cMINVAL	         : std_logic_vector(15 downto 0) := x"C000";

  -- Calibration arrays
  type t_FOOT_adc_data is array (0 to cADC_CHANNELS-1) of std_logic_vector(cADC_DATA_WIDTH-1 downto 0);            
  type t_lef_data     is array (0 to cTOTAL_ADCS-1) of t_FOOT_adc_data;
  
  -- Calibration arrays inverted
  type t_FOOT_lef_data   is array (0 to cTOTAL_ADCS-1) of std_logic_vector(cADC_DATA_WIDTH-1 downto 0); 
  type t_FOOT_strip_data is array (0 to cADC_CHANNELS-1) of t_FOOT_lef_data;
  
  type t_FOOT_mult_data is array (0 to cTOTAL_ADCS-1) of std_logic_vector((2*cADC_DATA_WIDTH)-1 downto 0);
  -- Data to SQRT
  type t_FOOT_sqrt_data is array (0 to cTOTAL_ADCS-1) of std_logic_vector(cSQRT_WIDTH-1 downto 0);

  type t_cal_accumul is array (0 to cADC_CHANNELS-1) of std_logic_vector(cACC_WIDTH-1 downto 0);
  type t_lef_accumul is array (0 to cTOTAL_ADCS -1) of  t_cal_accumul;

  type t_lef_accumul_inv is array (0 to cTOTAL_ADCS -1) of std_logic_vector(cACC_WIDTH-1 downto 0);
  type t_ram_accumul_addr is array (0 to cTOTAL_ADCS -1) of std_logic_vector((ceil_log2(cADC_CHANNELS))-1 downto 0);

  function CalcMedian(maxRoot  : signed(cADC_DATA_WIDTH-1 downto 0);
                      minRoot  : signed(cADC_DATA_WIDTH-1 downto 0);
                      maxCount : integer;
                      minCount : integer;
                      mode     : natural) 
                      return std_logic_vector;

  type CalibCompIN is record
    DATA            : t_FOOT_lef_data; -- ADC32
    WADDR           : std_logic_vector(ceil_log2(cADC_CHANNELS)-1 downto 0);
    RADDR           : std_logic_vector(ceil_log2(cADC_CHANNELS)-1 downto 0);
    WE              : std_logic;
  end record CalibCompIN;
  type CalibCompOUT is record
    DATA            : t_FOOT_lef_data; -- ADC32
  end record CalibCompOUT;


  -- - - - - -  ** END Calibration ** - - - - - 

  -- Types for the FE interface ------------------------------------------------
  --!IDE1140_DS front-End input signals (from the FPGA)
  type tFpga2FeIntf is record
    G0      : std_logic;
    G1      : std_logic;
    G2      : std_logic;
    Hold    : std_logic;                -- Active High
    DRst    : std_logic;
    ShiftIn : std_logic;                -- Active Low
    Clk     : std_logic;
    TestOn  : std_logic;
  --Cal       : std_logic; --!@todo Table 2 (page 7) of datasaheet
  end record tFpga2FeIntf;

  --!IDE1140_DS front-End output signals (to the FPGA)
  type tFe2FpgaIntf is record
    initRst  : std_logic;
    ShiftOut : std_logic;               -- Active Low
  end record tFe2FpgaIntf;

  --!Control interface for a generic block: input signals
  type tControlIntfIn is record
    en     : std_logic;                 --!Enable
    start  : std_logic;                 --!Start
    slwClk : std_logic;                 --!Slow clock to forward to the device
    slwEn  : std_logic;                 --!Event for slow clock synchronisation
  end record tControlIntfIn;

  --!Control interface for a generic block: output signals
  type tControlIntfOut is record
    busy  : std_logic;                  --!Busy flag
    error : std_logic;                  --!Error flag
    reset : std_logic;                  --!Resetting flag
    compl : std_logic;                  --!completion of task
  end record tControlIntfOut;

  --!AD7276A ADC input signals (from the FPGA)
  type tFpga2AdcIntf is record
    SClk : std_logic;
    Cs   : std_logic;                   -- Active Low
  end record tFpga2AdcIntf;

  --!AD7276A ADC output signals (to the FPGA)
  type tAdc2FpgaIntf is record
    SData : std_logic;
  end record tAdc2FpgaIntf;

  --!Input signals of a typical FIFO memory
  type tFifoIn_ADC is record
    data : std_logic_vector(cADC_DATA_WIDTH-1 downto 0);  --!Input data port
    rd   : std_logic;                                     --!Read request
    wr   : std_logic;                                     --!Write request
  end record tFifoIn_ADC;

  --!Output signals of a typical FIFO memory
  type tFifoOut_ADC is record
    q      : std_logic_vector(cADC_DATA_WIDTH-1 downto 0);  --!Output data port
    aEmpty : std_logic;                                     --!Almost empty
    empty  : std_logic;                                     --!Empty
    aFull  : std_logic;                                     --!Almost full
    full   : std_logic;                                     --!Full
  end record tFifoOut_ADC;

  --!Output signals of the collector FIFOs
  type tCollFifoOut is record
    q      : std_logic_vector((2*cADC_DATA_WIDTH)-1 downto 0);  --!Output data port
    aEmpty : std_logic;                 --!Almost empty
    empty  : std_logic;                 --!Empty
    aFull  : std_logic;                 --!Almost full
    full   : std_logic;                 --!Full
  end record tCollFifoOut;

  --!Configuration ports to the MSD subpart
  type msd_config is record
    feClkDuty    : std_logic_vector(15 downto 0);  --!FE slowClock duty cycle
    feClkDiv     : std_logic_vector(15 downto 0);  --!FE slowClock divider
    adcClkDuty   : std_logic_vector(15 downto 0);  --!ADC slowClock duty cycle
    adcClkDiv    : std_logic_vector(15 downto 0);  --!ADC slowClock divider
    --!iCFG_PLANE bits: 2:0: FE-Gs;  3: FE-test; 4: Ext-TRG; 15:5: x
    cfgPlane     : std_logic_vector(15 downto 0);  --!uStrip configuration
    intTrgPeriod : std_logic_vector(31 downto 0);  --!Clock-cycles between two internal triggers
    trg2Hold     : std_logic_vector(15 downto 0);  --!Clock-cycles between an external trigger and the FE-HOLD signal
    adcDelay     : std_logic_vector(15 downto 0);  --!Delay from the FE falling edge and the start of the AD conversion
    extendBusy   : std_logic_vector(15 downto 0);  --!320-ns duration of busy extension time
  end record msd_config;

  --!Multiple AD7276A ADCs output signals and FIFOs
  type tMultiAdc2FpgaIntf is array (0 to cTOTAL_ADCS-1) of tAdc2FpgaIntf;
  type tMultiAdcFifoIn is array (0 to cTOTAL_ADCS-1) of tFifoIn_ADC;
  type tMultiAdcFifoOut is array (0 to cTOTAL_ADCS-1) of tFifoOut_ADC;

  --!Initialization constants for the upper types
  constant c_FROM_FIFO_INIT : tFifoOut_ADC := (full   => '0',
                                               empty  => '1',
                                               aFull  => '0',
                                               aEmpty => '0',
                                               q      => (others => '0'));
  constant c_TO_FIFO_INIT : tFifoIn_ADC := (wr   => '0',
                                            data => (others => '0'),
                                            rd   => '0');
  constant c_TO_FIFO_INIT_ARRAY : tMultiAdcFifoIn := (others => c_TO_FIFO_INIT);
  constant c_FROM_FIFO_INIT_ARRAY : tMultiAdcFifoOut := (others => c_FROM_FIFO_INIT);

  -- Components ----------------------------------------------------------------
  --!@brief Low-level front-end interface
  component FE_interface is
    port (
      --# {{clocks|Clock}}
      iCLK      : in  std_logic;
      --# {{control|Control}}
      iRST      : in  std_logic;
      oCNT      : out tControlIntfOut;
      iCNT      : in  tControlIntfIn;
      iCNT_G    : in  std_logic_vector(2 downto 0);
      iCNT_Test : in  std_logic;
      iCNT_TEST_CH    : in std_logic_vector(7 downto 0);
      iCNT_OTHER_EDGE : in std_logic;
      oDATA_VLD : out std_logic;
      --# {{FE interface}}
      oFE       : out tFpga2FeIntf;
      iFE       : in  tFe2FpgaIntf
      );
  end component FE_interface;

  --!@brief Low-level multiple ADCs interface
  component multiADC_interface is
    port (
      --# {{clocks|Clock}}
      iCLK        : in  std_logic;
      --# {{control|Control}}
      iRST        : in  std_logic;
      oCNT        : out tControlIntfOut;
      iCNT        : in  tControlIntfIn;
      iFAST       : in  std_logic;
      --# {{ADC Interface}}
      oADC        : out tFpga2AdcIntf;
      iMULTI_ADC  : in  tMultiAdc2FpgaIntf;
      --# {{data|ADC Data Output}}
      oMULTI_FIFO : out tMultiAdcFifoIn
      );
  end component multiADC_interface;

  --!@brief Low-level multiple ADCs plane interface
  component multiAdcPlaneInterface is
    generic (
      pACTIVE_EDGE : string := "F"      --!"F": falling, "R": rising
      );
    port (
      --# {{clocks|Clock}}
      iCLK          : in  std_logic;
      --# {{control|Control}}
      iRST          : in  std_logic;
      oCNT          : out tControlIntfOut;
      iCNT          : in  tControlIntfIn;
      iFE_CLK_DIV   : in  std_logic_vector(15 downto 0);
      iFE_CLK_DUTY  : in  std_logic_vector(15 downto 0);
      iADC_CLK_DIV  : in  std_logic_vector(15 downto 0);
      iADC_CLK_DUTY : in  std_logic_vector(15 downto 0);
      iADC_DELAY    : in  std_logic_vector(15 downto 0);
      iCFG_FE       : in  std_logic_vector(11 downto 0);
      iADC_FAST     : in  std_logic;
      --# {{FE Interface}}
      oFE0          : out tFpga2FeIntf;
      oFE1          : out tFpga2FeIntf;
      iFE           : in  tFe2FpgaIntf;
      --# {{ADC Interface}}
      oADC0         : out tFpga2AdcIntf;
      oADC1         : out tFpga2AdcIntf;
      iMULTI_ADC    : in  tMultiAdc2FpgaIntf;
      --# {{Output FIFO Interface}}
      oMULTI_FIFO   : out tMultiAdcFifoOut;
      iMULTI_FIFO   : in  tMultiAdcFifoIn
      );
  end component multiAdcPlaneInterface;

  --!@brief Top module that instantiates multiAdcPlaneInterface and Data_Builder
  component Data_Builder_Top
    port (
      --# {{clocks|Clock}}
      iCLK         : in  std_logic;     --!Main clock
      --# {{control|Control}}
      iRST         : in  std_logic;     --!Main reset
      iEN          : in  std_logic;     --!Enable
      iTRIG        : in  std_logic;     --!External trigger
      oCNT         : out tControlIntfOut;  --!Control signals in output-- still to decide where to connect it!!!!!
      oCAL_TRIG    : out std_logic;     --!Internal trigger output
      iMSD_CONFIG  : in  msd_config;  --!Configuration from the control registers
      --# {{First FE-ADC chain Interface}}
      oFE0         : out tFpga2FeIntf;  --!Output signals to the FE1
      oADC0        : out tFpga2AdcIntf;    --!Output signals to the ADC1
      iMULTI_ADC   : in  tMultiAdc2FpgaIntf;  --!Input signals from the ADC1
      --# {{Second FE-ADC chain Interface}}
      oFE1         : out tFpga2FeIntf;  --!Output signals to the FE2
      oADC1        : out tFpga2AdcIntf;    --!Output signals to the ADC2
      --# {{Event Builder Interface}}
      oCOLL_FIFO    : out tCollFifoOut;
      oDATA_VALID   : out std_logic;
      oEND_OF_EVENT : out std_logic
      );
  end component Data_Builder_Top;

  --!@brief Collects data from the MSD and assembles them in a single packet
  component Data_Builder is
    port (
      --# {{clocks|Clock}}
      iCLK          : in  std_logic;
      --# {{control|Control}}
      iRST          : in  std_logic;
      --#{{MSD Interface}}
      iMULTI_FIFO   : in  tMultiAdcFifoOut;
      oMULTI_FIFO   : out tMultiAdcFifoIn;
      --#{{HPS Interface}}
      oCOLL_FIFO    : out tCollFifoOut;
      oDATA_VALID   : out std_logic;
      oEND_OF_EVENT : out std_logic
      );
  end component Data_Builder;

  -- CALIBRATION
  component PedestalSubtraction is
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
      -- out sample stream
      oQ                  : out t_FOOT_lef_data;
      oPUTD               : out std_logic;
      oBUSY               : out std_logic -- Gives to Ladder Wrapper the status of calib
    );
  end component PedestalSubtraction;

  component Heap is
      generic (
          pHEAP_SIZE    : integer := 8;  -- Numero elementi massimi heap
          pDATA_WIDTH   : integer := 8;   -- Larghezza dei dati (8 bit)
          pIS_MAX_HEAP  : boolean := true
      );
      port (
        iCLK      : in  std_logic;
        iRST      : in  std_logic;
        iINS_en   : in  std_logic;
        iINS_data : in  std_logic_vector(pDATA_WIDTH-1 downto 0);
        iEXT_en   : in  std_logic;
        iREP_en   : in  std_logic;
        iREP_data : in  std_logic_vector(pDATA_WIDTH-1 downto 0);
        --oDATA     : out std_logic_vector(pDATA_WIDTH-1 downto 0);
        --oVALID    : out std_logic;
        oBusy     : out std_logic;
        oCount    : out integer range 0 to pHEAP_SIZE;
        oRoot     : out std_logic_vector(pDATA_WIDTH-1 downto 0)
      );
  end component heap;

  component StreamingMedian is
      generic (
          pHEAP_SIZE  : integer := 8; -- VA / 2. 128 strip = 64 heap size
          pCALC_MODE  : natural := 0; 
          pDATA_WIDTH : integer := 16
      );
      port (
          iCLK      : in  std_logic;
          iRST      : in  std_logic;
          iINS_en   : in  std_logic;
          iINS_data : in  std_logic_vector(pDATA_WIDTH-1 downto 0);
          oMedian   : out std_logic_vector(pDATA_WIDTH-1 downto 0);
          oValid    : out std_logic;
          oBusy_SMA : out std_logic
      );
  end component StreamingMedian;

  component StreamingMedianOfMedian is
      generic (
          pHEAP_SIZE  : integer := cHEAP_SIZE;
          pCALC_MODE  : natural := cSMA_CALC_MODE; -- In caso di numero pari di elementi. 0: Media tra le root, 1: MinRoot, >1:MaxRoot
          pDATA_WIDTH : integer := cADC_DATA_WIDTH
      );
      port (
          iCLK      : in  std_logic;
          iRST      : in  std_logic;
          iINS_en   : in  std_logic;
          iINS_data : in  std_logic_vector(pDATA_WIDTH-1 downto 0);
          oMedian   : out std_logic_vector(pDATA_WIDTH-1 downto 0);
          iFlush    : in  std_logic;
          oValid    : out std_logic;
          oBusy_SMA : out std_logic
      );
  end component StreamingMedianOfMedian;

  component StreamingMedianOfMedianWrap is
      generic (
          pHEAP_SIZE  : integer := cHEAP_SIZE;
          pCALC_MODE  : natural := cSMA_CALC_MODE;
          pADC_NUM    : natural := cTOTAL_ADCS;
          pDATA_WIDTH : integer := cADC_DATA_WIDTH
      );
      port (
          iCLK      : in  std_logic;
          iRST      : in  std_logic;
          iINS_en   : in  std_logic_vector(pADC_NUM-1 downto 0);
          iINS_data : in  t_FOOT_lef_data;
          oMedian   : out t_FOOT_lef_data;
          iFlush    : in  std_logic_vector(pADC_NUM-1 downto 0);
          oValid    : out std_logic_vector(pADC_NUM-1 downto 0);
          oBusy_SMA : out std_logic_vector(pADC_NUM-1 downto 0)
      );
  end component StreamingMedianOfMedianWrap;

  component FOOT_FIFO is
    generic (             
      pADC_NUM        : natural := cTOTAL_ADCS;
      pADC_STRIPS     : natural := cADC_CHANNELS;
      pDATA_WIDTH     : natural := cADC_DATA_WIDTH
    );
    port (
      -- global control & clock
      iCLK                : in  std_logic;
      iRST                : in  std_logic;

      iDATA               : in t_FOOT_lef_data;
      iRE                 : in std_logic;
      iWE                 : in std_logic;

      oQ                  : out t_FOOT_lef_data;

      oEMPTY              : out std_logic;
      oAEMPTY             : out std_logic;
      oFULL               : out std_logic;
      oAFULL              : out std_logic
    );
  end component FOOT_FIFO;

  component FOOT_RAM is
    generic (             
      pADC_NUM        : natural := cTOTAL_ADCS;               --!Num of ADCs
      pADC_STRIPS     : natural := cADC_CHANNELS;             --!Num of channels (RAM depth)
      pDATA_WIDTH     : natural := cADC_DATA_WIDTH;           --!Data width (RAM width)
      pUSEDW_WIDTH    : natural := ceil_log2(cADC_CHANNELS);  --!Data ADDR width
      pFORCE_MLAB     : natural := 1                          --!Force MLAB if 1
    );
    port (
      iCLK                : in  std_logic;
      iDATA               : in t_FOOT_lef_data;
      iWADDR              : in std_logic_vector(pUSEDW_WIDTH-1 downto 0);
      iRADDR              : in std_logic_vector(pUSEDW_WIDTH-1 downto 0);
      iWE                 : in std_logic;
      oDATA               : out t_FOOT_lef_data
    );
  end component FOOT_RAM;

  component CALIB_RAM is
    generic (             
      pADC_NUM        : natural := cTOTAL_ADCS;               --! Num of ADCs
      pADC_STRIPS     : natural := cADC_CHANNELS;             --! Num of channels (RAM depth)
      pDATA_WIDTH     : natural := cADC_DATA_WIDTH;           --! Data width (RAM width)
      pUSEDW_WIDTH    : natural := ceil_log2(cADC_CHANNELS);  --! Data ADDR width
      pFORCE_MLAB     : natural := 1;                         --! Force MLAB if 1

      pRHT            : std_logic_vector(cADC_DATA_WIDTH-1 downto 0) := cRHT;
      pHTH            : std_logic_vector(cADC_DATA_WIDTH-1 downto 0) := cHTH;
      pLTH            : std_logic_vector(cADC_DATA_WIDTH-1 downto 0) := cLTH
    );
    port (
      iCLK                    : in  std_logic;
      iRST                    : in  std_logic;

      -- THR CHANGE
      iLTH                    : in std_logic_vector(pDATA_WIDTH-1 downto 0);
      iHTH                    : in std_logic_vector(pDATA_WIDTH-1 downto 0);
      iKC                     : in std_logic;
      iKV                     : in std_logic;

      -- PEDESTAL INTERFACE
      iPED_DATA               : in  t_FOOT_lef_data; -- ADC8
      iPED_WADDR              : in  std_logic_vector(pUSEDW_WIDTH-1 downto 0);
      iPED_RADDR              : in  std_logic_vector(pUSEDW_WIDTH-1 downto 0);
      iPED_WE                 : in  std_logic;
      oPED_DATA               : out t_FOOT_lef_data; -- ADC8

      -- SIGRAW INTERFACE
      iSIGRAW_DATA            : in  t_FOOT_lef_data; -- ADC32
      iSIGRAW_WADDR           : in  std_logic_vector(pUSEDW_WIDTH-1 downto 0);
      iSIGRAW_RADDR           : in  std_logic_vector(pUSEDW_WIDTH-1 downto 0);
      iSIGRAW_WE              : in  std_logic;
      oSIGRAW_DATA            : out t_FOOT_lef_data; -- ADC32

      -- SIGMA INTERFACE
      iSIG_DATA               : in  t_FOOT_lef_data; -- ADC32
      iSIG_WADDR              : in  std_logic_vector(pUSEDW_WIDTH-1 downto 0);
      iSIG_RADDR              : in  std_logic_vector(pUSEDW_WIDTH-1 downto 0);
      iSIG_WE                 : in  std_logic;
      oSIG_DATA               : out t_FOOT_lef_data; -- ADC32

      -- FLG INTERFACE
      iFLG_DATA               : in  t_FOOT_lef_data;
      iFLG_WADDR              : in  std_logic_vector(pUSEDW_WIDTH-1 downto 0);
      iFLG_RADDR              : in  std_logic_vector(pUSEDW_WIDTH-1 downto 0);
      iFLG_WE                 : in  std_logic;
      oFLG_DATA               : out t_FOOT_lef_data;

      -- LOW THR OUTPUT, based on SIG addr
      oLTH_DATA               : out t_FOOT_lef_data; -- ADC8

      -- HIGH THR OUTPUT, based on SIG addr
      oHTH_DATA               : out t_FOOT_lef_data; -- ADC8

      -- R.HIGH THR OUTPUT, based on SIGRAW addr
      oRHT_DATA               : out t_FOOT_lef_data  -- ADC8
    );
  end component CALIB_RAM;

  component CNSubtraction is
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
  end component CNSubtraction;

  component sqrt32_seq is
    port (
      iCLK    : in  std_logic;
      iRST    : in  std_logic;
      iSTART  : in  std_logic;                 
      iDATA   : in  std_logic_vector(31 downto 0);
      oROOT   : out std_logic_vector(15 downto 0);
      oDONE   : out std_logic                  
    );
  end component sqrt32_seq;
  
  component SQRT_wrap is
      generic (             
          pADC_NUM        : natural := cTOTAL_ADCS               --!Num of ADCs
    );
      port (
          iCLK        : in  std_logic;
          iRST        : in  std_logic;
          iSQRT_MSG   : in  t_FOOT_sqrt_data;
          iSQRT_Start : in  std_logic;
          oSQRT_MSG   : out t_FOOT_lef_data;     
          oSQRT_Done  : out std_logic         
      );
  end component SQRT_wrap;

  component DSPSQ is
      generic (
          pDATA_WIDTH : natural := cADC_DATA_WIDTH
      );
      port (
          iDATA   : in  std_logic_vector(pDATA_WIDTH-1 downto 0);
          oSQUARE : out std_logic_vector(2*pDATA_WIDTH-1 downto 0)
      );
  end component DSPSQ;

  component DSPSQ_wrap is
    generic (
        pDATA_WIDTH : natural := cADC_DATA_WIDTH;
        pADC_NUM    : natural := cTOTAL_ADCS
    );
    port (
        iDATA   : in  t_FOOT_lef_data;
        oSQUARE : out t_FOOT_lef_data
    );
  end component DSPSQ_wrap;

  component MultiCalibration is
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
  end component MultiCalibration;

  component CalibrationWrapper is
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
      -- The three MultiCalib results (PED, SIGRAW, SIG) are serialized with
      -- the same linear layout used by the event path: ADC * STRIPS + strip.
      oER_WE                  : out std_logic;
      oER_W_ADDR              : out std_logic_vector(pWADDR_WIDTH-1 downto 0);
      oER_DATA                : out std_logic_vector(pDATA_WIDTH-1 downto 0);
      iER_FULL                : in  std_logic;

      -- THR CHANGE
      iLTH                    : in std_logic_vector(pDATA_WIDTH-1 downto 0);
      iHTH                    : in std_logic_vector(pDATA_WIDTH-1 downto 0);
      iKC                     : in std_logic;
      iKV                     : in std_logic;

      -- RAM INTERFACE
      iPED                    : in  CalibCompIN;
      oPED                    : out CalibCompOUT;                                     -- ADC8
      iSIGRAW                 : in  CalibCompIN;
      oSIGRAW                 : out CalibCompOUT;                                     -- ADC32
      iSIG                    : in  CalibCompIN;
      oSIG                    : out CalibCompOUT;                                     -- ADC32
      iFLG                    : in  CalibCompIN;
      oFLG                    : out CalibCompOUT;
      oLTH                    : out CalibCompOUT;                                     -- LOW THR OUTPUT, based on SIG addr
      oHTH                    : out CalibCompOUT;                                     -- HIGH THR OUTPUT, based on SIG addr
      oRHT                    : out CalibCompOUT;                                     -- R.HIGH THR OUTPUT, based on SIGRAW addr

      -- SMA INTERFACE
      oSMA_priority           : out std_logic;
      oSMA_RST                : out std_logic;
      oSMA_INS_en             : out std_logic_vector(pADC_NUM-1 downto 0);
      oSMA_INS_data           : out t_FOOT_lef_data;
      iSMA_Median             : in  t_FOOT_lef_data;
      oSMA_Flush              : out std_logic_vector(pADC_NUM-1 downto 0);
      iSMA_Valid              : in  std_logic_vector(pADC_NUM-1 downto 0)
    );
  end component CalibrationWrapper;

  component LadderWrapper is
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
        iWORD                   : in  t_FOOT_lef_data;  -- Data from multiADCPlaneInterface, in parallel from all the ADCs.     ** iMULTI_FIFO.tFifoIn_ADC.data **
        iPUTD                   : in  std_logic;        -- Write-enable from ADC-LEF                                            ** iMULTI_FIFO.tFifoIn_ADC.wr   **
        iTRIG                   : in  std_logic;        -- Trigger from ADC-LEF                                                 ** iCNT.start **
        iFULL                   : in  std_logic;        -- Downstream Event RAM/FIFO full

        -- Trigger Lost
        oTRIG_L                 : out std_logic;    -- Trigger LOST or Putd LOST

        -- CLuster ENABLE
        oCLUST_ENABLE           : out std_logic;
        oVALID_EVT_RAM          : out std_logic;

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
  end component LadderWrapper;


end package FOOTpackage;

package body FOOTpackage is

  function CalcMedian(
      maxRoot  : signed(cADC_DATA_WIDTH-1 downto 0);
      minRoot  : signed(cADC_DATA_WIDTH-1 downto 0);
      maxCount : integer;
      minCount : integer;
      mode     : natural
  ) return std_logic_vector is
      variable temp_sum : signed(cADC_DATA_WIDTH downto 0);
  begin
      if maxCount = minCount then
          if mode = 0 then
              temp_sum := resize(maxRoot, cADC_DATA_WIDTH+1)
                      + resize(minRoot, cADC_DATA_WIDTH+1);
              return std_logic_vector(resize(shift_right(temp_sum, 1), cADC_DATA_WIDTH));
          elsif mode = 1 then
              return std_logic_vector(minRoot);
          else 
              return std_logic_vector(maxRoot);
          end if;
      else
          return std_logic_vector(maxRoot);
      end if;
  end function CalcMedian;

end package body FOOTpackage;
