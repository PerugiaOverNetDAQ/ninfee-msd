--!@file SQRT_wrap.vhd
--!@brief SQRT_wrap to hold all SQRT32 modules, one per ADC.
--!@author Luca Russo, luca.russo@cern.ch, luca.russo912@gmail.com
--!@date 14/05/2026
--!@version 1.0.0 

library ieee;
use ieee.std_logic_1164.all;

use work.basic_package.all;
use work.FOOTpackage.all;

entity SQRT_wrap is
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
end entity SQRT_wrap;

architecture RTL of SQRT_wrap is

    signal sSQRT_Done : std_logic_vector(pADC_NUM-1 downto 0);

begin

    gen_SQRT : for i in 0 to pADC_NUM-1 generate
        SQRT : sqrt32_seq
            port map(
                iCLK   => iCLK,
                iRST   => iRST,
                iSTART => iSQRT_Start,
                iDATA  => iSQRT_MSG(i),
                oROOT  => oSQRT_MSG(i),
                oDONE  => sSQRT_Done(i)        
            );  
    end generate;

    -- Tutte le radici devono aver terminato
    oSQRT_Done <= '1' when sSQRT_Done = (sSQRT_Done'range => '1') else '0';

end architecture RTL;
