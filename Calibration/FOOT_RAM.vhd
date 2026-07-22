--!@file FOOT_RAM.vhd
--!@brief RAM Block for calib memory. Can store 1 calib component for all ADCs.
--!@author Luca Russo, luca.russo@cern.ch, luca.russo912@gmail.com
--!@date 05/05/2026
--!@version 1.0.0 

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.basic_package.all;
use work.FOOTpackage.all;

entity FOOT_RAM is
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
end entity FOOT_RAM;

architecture Behavioral of FOOT_RAM is

begin

    gen_RAM : for i in 0 to pADC_NUM-1 generate
        RAM : parametric_ram_tp
            generic map(
                pWIDTH       => pDATA_WIDTH,
                pDEPTH       => pADC_STRIPS,
                pUSEDW_WIDTH => pUSEDW_WIDTH,
                pFORCE_MLAB  => pFORCE_MLAB
            )
            port map(
                iCLK     => iCLK,
                iData    => iData(i), --@suppress
                iRd_Addr => iRADDR,
                iWr_Addr => iWADDR,
                iWr_En   => iWE,
                oData    => oData(i)  --@suppress
            );
    end generate;

end architecture Behavioral;