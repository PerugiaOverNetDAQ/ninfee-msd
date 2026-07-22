--!@file CalibrationRAM.vhd
--!@brief Full CALIB Ram block with all it's components: ped, sigraw, sigma, ...
--!@author Luca Russo, luca.russo@cern.ch, luca.russo912@gmail.com
--!@date 05/05/2026
--!@version 1.0.0 
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.basic_package.all;
use work.FOOTpackage.all;

entity CALIB_RAM is
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
end entity CALIB_RAM;


architecture Behavioral of CALIB_RAM is

    -- Fixed-point format
    constant cDATA_FRAC_BITS : natural := 5;
    constant cTHR_FRAC_BITS  : natural := 5;
    constant cOUT_FRAC_BITS  : natural := 3;

    constant cMULT_FRAC_BITS : natural := cDATA_FRAC_BITS + cTHR_FRAC_BITS;
    constant cSHIFT_BITS     : natural := cMULT_FRAC_BITS - cOUT_FRAC_BITS;

    -- RAM output internal signals
    signal sSIGRAW_DATA_RAM : t_FOOT_lef_data;
    signal sSIG_DATA_RAM    : t_FOOT_lef_data;

    -- Multiplication result signals
    --
    -- Assumption:
    -- t_FOOT_mult_data is an array of std_logic_vector(2*pDATA_WIDTH-1 downto 0)
    -- or equivalent, defined in FOOTpackage/basic_package.
    signal sLTH_MULT : t_FOOT_mult_data;
    signal sHTH_MULT : t_FOOT_mult_data;
    signal sRHT_MULT : t_FOOT_mult_data;

    -- Force DSP implementation in Quartus
    attribute multstyle : string;
    attribute multstyle of Behavioral : architecture is "dsp";
    -- attribute multstyle of sLTH_MULT : signal is "dsp";
    -- attribute multstyle of sHTH_MULT : signal is "dsp";
    -- attribute multstyle of sRHT_MULT : signal is "dsp";

        -- THR CHANGE
    signal sLTH                    : std_logic_vector(pDATA_WIDTH-1 downto 0);
    signal sHTH                    : std_logic_vector(pDATA_WIDTH-1 downto 0);
begin

    TRH_CHANGE :   process(iCLK, iRST)
    begin
        if iRST = '1' then
            sLTH  <= pLTH; --@suppress
            sHTH  <= pHTH; --@suppress
        elsif rising_edge(iCLK) then
            if iKV = '1' and iKC = '1' then
                sLTH  <= iLTH;
                sHTH  <= iHTH;
            end if;
        end if;
    end process TRH_CHANGE;
    

    -- PEDESTAL RAM
    PED: FOOT_RAM
        generic map(
            pADC_NUM     => pADC_NUM,
            pADC_STRIPS  => pADC_STRIPS,
            pDATA_WIDTH  => pDATA_WIDTH,
            pUSEDW_WIDTH => pUSEDW_WIDTH,
            pFORCE_MLAB  => pFORCE_MLAB
        )
        port map(
            iCLK   => iCLK,
            iDATA  => iPED_DATA,
            iWADDR => iPED_WADDR,
            iRADDR => iPED_RADDR,
            iWE    => iPED_WE,
            oDATA  => oPED_DATA
        );

    -- SIGRAW RAM
    SIGRAW: FOOT_RAM
        generic map(
            pADC_NUM     => pADC_NUM,
            pADC_STRIPS  => pADC_STRIPS,
            pDATA_WIDTH  => pDATA_WIDTH,
            pUSEDW_WIDTH => pUSEDW_WIDTH,
            pFORCE_MLAB  => pFORCE_MLAB
        )
        port map(
            iCLK   => iCLK,
            iDATA  => iSIGRAW_DATA,
            iWADDR => iSIGRAW_WADDR,
            iRADDR => iSIGRAW_RADDR,
            iWE    => iSIGRAW_WE,
            oDATA  => sSIGRAW_DATA_RAM
        );

    oSIGRAW_DATA <= sSIGRAW_DATA_RAM;

    -- SIGMA RAM
    SIG: FOOT_RAM
        generic map(
            pADC_NUM     => pADC_NUM,
            pADC_STRIPS  => pADC_STRIPS,
            pDATA_WIDTH  => pDATA_WIDTH,
            pUSEDW_WIDTH => pUSEDW_WIDTH,
            pFORCE_MLAB  => pFORCE_MLAB
        )
        port map(
            iCLK   => iCLK,
            iDATA  => iSIG_DATA,
            iWADDR => iSIG_WADDR,
            iRADDR => iSIG_RADDR,
            iWE    => iSIG_WE,
            oDATA  => sSIG_DATA_RAM
        );

    oSIG_DATA <= sSIG_DATA_RAM;

    -- FLG RAM
    FLG: FOOT_RAM
        generic map(
            pADC_NUM     => pADC_NUM,
            pADC_STRIPS  => pADC_STRIPS,
            pDATA_WIDTH  => pDATA_WIDTH,
            pUSEDW_WIDTH => pUSEDW_WIDTH,
            pFORCE_MLAB  => pFORCE_MLAB
        )
        port map(
            iCLK   => iCLK,
            iDATA  => iFLG_DATA,
            iWADDR => iFLG_WADDR,
            iRADDR => iFLG_RADDR,
            iWE    => iFLG_WE,
            oDATA  => oFLG_DATA
        );

    -- THRESHOLD MULTIPLICATIONS
    -- SIG    Q.5 * LTH Q.5 = product Q.10
    -- SIG    Q.5 * HTH Q.5 = product Q.10
    -- SIGRAW Q.5 * RHT Q.5 = product Q.10
    -- Output required: Q.3
    -- Shift right 7 bits.

    GEN_THR_MULT : for i in 0 to pADC_NUM-1 generate

        -- DSP products
        sLTH_MULT(i) <= std_logic_vector(--@suppress
            unsigned(sSIG_DATA_RAM(i)) * unsigned(sLTH) 
        );

        sHTH_MULT(i) <= std_logic_vector( --@suppress
            unsigned(sSIG_DATA_RAM(i)) * unsigned(sHTH) 
        );

        sRHT_MULT(i) <= std_logic_vector(
            unsigned(sSIGRAW_DATA_RAM(i)) * unsigned(pRHT)
        );

        -- Rescale: ADC32 * ADC32 = ADC1024 -> ADC8
        -- product Q.10 -> output Q.3
        -- shift_right by 7.

        oLTH_DATA(i) <= std_logic_vector( -- @suppress
            resize(
                shift_right(
                    unsigned(sLTH_MULT(i)),
                    cSHIFT_BITS
                ),
                pDATA_WIDTH
            )
        ); -- @suppress

        oHTH_DATA(i) <= std_logic_vector( -- @suppress
            resize(
                shift_right(
                    unsigned(sHTH_MULT(i)),
                    cSHIFT_BITS
                ),
                pDATA_WIDTH
            )
        ); -- @suppress

        oRHT_DATA(i) <= std_logic_vector( -- @suppress
            resize(
                shift_right(
                    unsigned(sRHT_MULT(i)),
                    cSHIFT_BITS
                ),
                pDATA_WIDTH
            )
        ); -- @suppress

    end generate GEN_THR_MULT;

end architecture Behavioral;