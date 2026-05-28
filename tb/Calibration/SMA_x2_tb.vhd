--!@file SMAx2_tb.vhd
--!@brief Streaming Median Algorithm x2 test bench in VHDL.
--!@author Luca Russo, luca.russo@cern.ch, luca.russo912@gmail.com
--!@date 22/05/2026
--!@version 1.6.3 - testing SMA ver 1.6.3
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.TEXTIO.ALL;

entity SMAx2_tb is
end SMAx2_tb;

architecture sim of SMAx2_tb is
  constant pHEAP_SIZE  : integer := 4;
  constant pDATA_WIDTH : integer := 16;
  constant N_INSERT    : integer := 75;

  signal iCLK      : std_logic := '0';
  signal iRST      : std_logic := '0';

  signal iINS_en   : std_logic := '0';
  signal iINS_data : std_logic_vector(pDATA_WIDTH-1 downto 0) := (others => '0');

  signal iFlush    : std_logic := '0';

  signal oMedian   : std_logic_vector(pDATA_WIDTH-1 downto 0);
  signal oValid    : std_logic;
  signal oBusy_SMA : std_logic; --@suppress

  signal clk_count : integer := 0;
begin

  -- DUT
  DUT: entity work.StreamingMedianOfMedian
    generic map(
      pHEAP_SIZE  => pHEAP_SIZE,
      pCALC_MODE  => 2,
      pDATA_WIDTH => pDATA_WIDTH
    )
    port map(
      iCLK      => iCLK,
      iRST     => iRST,
      iINS_en   => iINS_en,
      iINS_data => iINS_data,
      iFlush    => iFlush,
      oMedian   => oMedian,
      oValid    => oValid,
      oBusy_SMA => oBusy_SMA
    );

  -- clock 100 MHz
  clock_p: process
  begin
    while true loop
      iCLK <= '0'; wait for 5 ns;
      iCLK <= '1'; wait for 5 ns;
    end loop;
  end process;

  -- contatore cicli
  count_p: process(iCLK)
  begin
    if rising_edge(iCLK) then
      clk_count <= clk_count + 1;
    end if;
  end process;

  -- monitor: stampa quando oValid
  mon_p: process
    variable L : line;
  begin
    wait until rising_edge(iCLK);
    if oValid = '1' then
      write(L, string'("[VALID] t="));
      write(L, clk_count);
      write(L, string'(" median="));
      write(L, to_integer(signed(oMedian)));
      writeline(output, L);
    end if;
  end process;

  -- stimolo: 75 insert poi flush
  stim_p: process
    variable L : line;
  begin
    -- reset
    iRST <= '1';
    iINS_en <= '0';
    iFlush  <= '0';
    wait for 30 ns;
    wait until rising_edge(iCLK);
    iRST <= '0';
    wait until rising_edge(iCLK);

    write(L, string'("=== INSERT 75 then FLUSH ==="));
    writeline(output, L);

    -- inserisci 75 elementi: 0..74
    for i in 0 to N_INSERT-1 loop
      -- aspetta DUT pronto (così non perdi l'impulso one-shot)

      wait until rising_edge(iCLK);
      iINS_data <= std_logic_vector(to_signed(i, pDATA_WIDTH));
      iINS_en   <= '1';
      wait until rising_edge(iCLK);
      iINS_en   <= '0';
      wait until rising_edge(iCLK);

      write(L, string'("[SEND]  t="));
      write(L, clk_count);
      write(L, string'(" x="));
      write(L, i);
      writeline(output, L);

      while oValid = '0' loop
        wait until rising_edge(iCLK);
      end loop;
    end loop;

    -- un paio di cicli di respiro
    wait until rising_edge(iCLK);
    wait until rising_edge(iCLK);

    -- flush (1 ciclo)
    iFlush <= '1';
    wait until rising_edge(iCLK);
    iFlush <= '0';

    write(L, string'("[FLUSH] t="));
    write(L, clk_count);
    writeline(output, L);

    -- lascia tempo al DUT di completare
    for k in 1 to 200 loop
      wait until rising_edge(iCLK);
    end loop;

    write(L, string'("=== END ==="));
    writeline(output, L);

    wait;
  end process;

end sim;
