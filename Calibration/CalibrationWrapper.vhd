--!@file CalibrationWrapper.vhd
--!@brief Core of calibration, MAIN FSM that pilots the calibration.
--!@author Luca Russo, luca.russo@cern.ch, luca.russo912@gmail.com
--!@date 05/05/2026
--!@version 1.0.0 
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
    pRHT            : std_logic_vector(pDATA_WIDTH-1 downto 0) := cRHT;
    pHTH            : std_logic_vector(pDATA_WIDTH-1 downto 0) := cHTH;
    pLTH            : std_logic_vector(pDATA_WIDTH-1 downto 0) := cLTH
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

    -- HOST CONTROL
    iHC_REQ                 : in  std_logic_vector(7 downto 0);                     -- Host Control Request
    oHC_RES                 : out std_logic_vector(6 downto 0);                     -- Host Control Response

    -- RAM INTERFACE
    iPED_RADDR              : in  std_logic_vector(pUSEDW_WIDTH-1 downto 0);
    oPED_DATA               : out t_FOOT_lef_data;  -- ADC8
    iSIGRAW_RADDR           : in  std_logic_vector(pUSEDW_WIDTH-1 downto 0);
    oSIGRAW_DATA            : out t_FOOT_lef_data;  -- ADC32
    iSIG_RADDR              : in  std_logic_vector(pUSEDW_WIDTH-1 downto 0);
    oSIG_DATA               : out t_FOOT_lef_data;  -- ADC32
    iFLG_RADDR              : in  std_logic_vector(pUSEDW_WIDTH-1 downto 0);
    oFLG_DATA               : out t_FOOT_lef_data;
    oLTH_DATA               : out t_FOOT_lef_data;  -- LOW THR OUTPUT, based on SIG addr  -- ADC8
    oHTH_DATA               : out t_FOOT_lef_data;  -- HIGH THR OUTPUT, based on SIG addr -- ADC8
    oRHT_DATA               : out t_FOOT_lef_data;  -- R.HIGH THR OUTPUT, based on SIGRAW addr -- ADC8

    -- SMA INTERFACE
    oSMA_priority           : out std_logic;
    oSMA_RST                : out std_logic;
    oSMA_INS_en             : out std_logic_vector(pADC_NUM-1 downto 0);
    oSMA_INS_data           : out t_FOOT_lef_data;
    iSMA_Median             : in  t_FOOT_lef_data; 
    oSMA_Flush              : out std_logic_vector(pADC_NUM-1 downto 0);
    iSMA_Valid              : in  std_logic_vector(pADC_NUM-1 downto 0)

  );
end entity CalibrationWrapper;


architecture Behavioral of CalibrationWrapper is

    -- RAM INTERFACE SIGNALS
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

begin

    -- RAM ASYNC SIGNALS MAPPING
    sPedIn.RADDR    <= iPED_RADDR;
    sSigRawIn.RADDR <= iSIGRAW_RADDR;
    sSigIn.RADDR    <= iSIG_RADDR;
    sFlgIn.RADDR    <= iFLG_RADDR;
    oPED_DATA       <= sPedOut.DATA;            
    oSIGRAW_DATA    <= sSigRawOut.DATA;                 
    oSIG_DATA       <= sSigOut.DATA;                    
    oFLG_DATA       <= sFlgOut.DATA;         
    oLTH_DATA       <= sLthOut.DATA;         
    oHTH_DATA       <= sHthOut.DATA;         
    oRHT_DATA       <= sRhtOut.DATA;



    -- RAM ISTANCE
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

end architecture Behavioral;