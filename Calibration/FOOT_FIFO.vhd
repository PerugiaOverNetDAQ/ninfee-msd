--!@file FOOT_FIFO.vhd
--!@brief CN_FIFO wrapper, pre-CN e post-CN use case.
--!@author Luca Russo, luca.russo@cern.ch, luca.russo912@gmail.com
--!@date 30/04/2026
--!@version 1.0.0 
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.basic_package.all;
use work.FOOTpackage.all;

entity FOOT_FIFO is
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
end entity FOOT_FIFO;

architecture Behavioral of FOOT_FIFO is

    signal sEmpty  : std_logic_vector(pADC_NUM-1 downto 0);
    signal sAEmpty : std_logic_vector(pADC_NUM-1 downto 0);
    signal sFull   : std_logic_vector(pADC_NUM-1 downto 0);
    signal sAFull  : std_logic_vector(pADC_NUM-1 downto 0);

begin

    -- All identical by definition
    oEMPTY  <= sEmpty(0);
    oAEMPTY <= sAEmpty(0);
    oFULL   <= sFull(0);
    oAFULL  <= sAFull(0);

    gen_FIFO : for i in 0 to pADC_NUM-1 generate
        FIFO : parametric_fifo_synch_MLAB
            generic map(
                pWIDTH       => pDATA_WIDTH,
                pDEPTH       => pADC_STRIPS,
                pUSEDW_WIDTH => ceil_log2(pADC_STRIPS),
                pAEMPTY_VAL  => 3,
                pAFULL_VAL   => pADC_STRIPS-3,
                pSHOW_AHEAD  => "OFF"
            )
            port map(
                iCLK    => iCLK,
                iRST    => iRST,

                oAEMPTY => sAEmpty(i),
                oEMPTY  => sEmpty(i),
                oAFULL  => sAFull(i),
                oFULL   => sFull(i),
                oUSEDW  => open,

                iRD_REQ => iRE,
                iWR_REQ => iWE,
                iDATA   => iDATA(i), --@suppress
                oQ      => oQ(i)     --@suppress
            );
    end generate;

end architecture Behavioral;