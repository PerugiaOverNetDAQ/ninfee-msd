--!@file DSPSQ_wrap.vhd
--!@brief Square of a parametric input data wrapper. Combinatorial. Produces ADC_NUM of DSPSQ
--!@author Luca Russo, luca.russo@cern.ch, luca.russo912@gmail.com
--!@date 17/05/2026
--!@version 1.0.0 
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.FOOTpackage.all;

entity DSPSQ_wrap is
    generic (
        pDATA_WIDTH : natural := cADC_DATA_WIDTH;
        pADC_NUM    : natural := cTOTAL_ADCS
    );
    port (
        iDATA   : in  t_FOOT_lef_data; --ADC2   x
        oSQUARE : out t_FOOT_lef_data  --ADC4   xx
    );
end entity DSPSQ_wrap;

architecture Behavioral of DSPSQ_wrap is

    signal sSquare : t_FOOT_mult_data;

begin

    gen_DSPSQ : for i in 0 to pADC_NUM-1 generate
        DSPSQ_COMP : DSPSQ
            generic map(
                pDATA_WIDTH => pDATA_WIDTH
            )
            port map(
                iDATA   => iDATA(i),  -- @suppress
                oSQUARE => sSquare(i) -- @suppress
            );
        
        oSQUARE(i)  <= sSquare(i)(pDATA_WIDTH-1 downto 0);  -- @suppress
    end generate;

end architecture Behavioral;