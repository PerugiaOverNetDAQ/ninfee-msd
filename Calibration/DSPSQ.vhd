--!@file DSPSQ.vhd
--!@brief Square of a parametric input data. Combinatorial.
--!@author Luca Russo, luca.russo@cern.ch, luca.russo912@gmail.com
--!@date 17/05/2026
--!@version 1.0.0 

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.FOOTpackage.all;

entity DSPSQ is
    generic (
        pDATA_WIDTH : natural := cADC_DATA_WIDTH
    );
    port (
        iDATA   : in  std_logic_vector(pDATA_WIDTH-1 downto 0);
        oSQUARE : out std_logic_vector(2*pDATA_WIDTH-1 downto 0)
    );
end entity DSPSQ;

architecture Behavioral of DSPSQ is

    attribute multstyle : string;
    attribute multstyle of Behavioral : architecture is "dsp";

begin

    oSQUARE <= std_logic_vector(signed(iDATA) * signed(iDATA));

end architecture Behavioral;