--!@file SMAx2_wrapper.vhd
--!@brief Streaming Median Algorith x2 wrapper.
--!@author Luca Russo, luca.russo@cern.ch, luca.russo912@gmail.com
--!@date 29/04/2025
--!@version 1.0.0 

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;


use work.FOOTpackage.all;

entity StreamingMedianOfMedianWrap is
    generic (
        pHEAP_SIZE  : integer := cHEAP_SIZE;
        pCALC_MODE  : natural := cSMA_CALC_MODE; -- In caso di numero pari di elementi. 0: Media tra le root, 1: MinRoot, >1:MaxRoot
        pADC_NUM    : natural := cTOTAL_ADCS;
        pDATA_WIDTH : integer := cADC_DATA_WIDTH
    );
    port (
        iCLK      : in  std_logic;
        iRST     : in  std_logic;
        iINS_en   : in  std_logic_vector(pADC_NUM-1 downto 0);
        iINS_data : in  t_FOOT_lef_data;
        oMedian   : out t_FOOT_lef_data; -- 1 bit extra per eventuali divisioni. Infatti l'assegnazione poi è concatenata.
                                                                -- Il bit in più serve ad evitare overflow. Vanno presi poi solo i 16 LSB
        iFlush    : in  std_logic_vector(pADC_NUM-1 downto 0);
        oValid    : out std_logic_vector(pADC_NUM-1 downto 0);
        oBusy_SMA : out std_logic_vector(pADC_NUM-1 downto 0)
    );
end StreamingMedianOfMedianWrap;

architecture Behavioral of StreamingMedianOfMedianWrap is

begin

    gen_SMA : for i in 0 to cTOTAL_ADCS-1 generate
        SMA : StreamingMedianOfMedian
        generic map(
            pHEAP_SIZE  => pHEAP_SIZE, -- Set to 32, automatic RESET after 64 insertions.
            pCALC_MODE  => pCALC_MODE,
            pDATA_WIDTH => pDATA_WIDTH 
        )
        port map(
            iCLK      => iCLK,
            iRST     => iRST,
            iINS_en   => iINS_en(i),
            iINS_data => iINS_data(i), -- @suppress "Incorrect array size in assignment: expected (<pDATA_WIDTH>) but was (<16>)"
            oMedian   => oMedian(i), -- @suppress "Incorrect array size in assignment: expected (<pDATA_WIDTH>) but was (<16>)"
            iFlush    => iFlush(i), 
            oValid    => oValid(i),
            oBusy_SMA => oBusy_SMA(i)
        );
        end generate;


end Behavioral;
