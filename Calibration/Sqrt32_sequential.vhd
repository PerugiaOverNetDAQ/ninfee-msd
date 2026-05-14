--!@file Sqrt32_sequential.vhd
--!@brief SQRT32, computes sqrt for 32 bit input in fixed sequential delay.
--!@author Luca Russo, luca.russo@cern.ch, luca.russo912@gmail.com
--!@date 14/05/2026
--!@version 1.0.0 

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Radice quadrata intera per n unsigned(31 downto 0)
-- Handshake: alza iStart per 1 ciclo quando IDLE;
entity sqrt32_seq is
  port (
    iCLK    : in  std_logic;
    iRST    : in  std_logic;                 -- reset sincrono attivo basso
    iSTART  : in  std_logic;                 -- campiona n e avvia il calcolo
    iDATA   : in  std_logic_vector(31 downto 0);
    oROOT   : out std_logic_vector(15 downto 0);
    oDONE   : out std_logic                  -- '1' per 1 ciclo quando root è valido
  );
end entity;

architecture rtl of sqrt32_seq is
  type state_t is (IDLE, RUN, DONE);
  signal state : state_t;

  attribute syn_encoding : string;
  attribute syn_encoding of state : signal is "onehot";

  constant IN_W   : integer := 32;
  constant ROOT_W : integer := 16;           -- sqrt(32 bit) -> 16 bit
  constant PAIRS  : integer := ROOT_W;       -- 16 coppie di bit
  constant REM_W  : integer := ROOT_W + 1;   -- resto max = 2*root -> 17 bit

  signal sNreg    : unsigned(IN_W-1 downto 0)   := (others => '0');
  signal sRreg    : unsigned(ROOT_W-1 downto 0) := (others => '0'); -- radice parziale
  signal sRemReg  : unsigned(REM_W-1 downto 0)  := (others => '0'); -- resto
  signal sIter    : integer range 0 to PAIRS-1  := 0;

  signal sRootQ   : unsigned(ROOT_W-1 downto 0) := (others => '0');
  signal sDoneQ   : std_logic                   := '0';
begin
  oRoot <= std_logic_vector(sRootQ);
  oDone <= sDoneQ;

  process(iClk, iRst)
    variable vPair  : unsigned(1 downto 0);
    variable vRem   : unsigned(REM_W+1 downto 0);  
    variable vTrial : unsigned(REM_W+1 downto 0);  -- allineato a vRem per confronto/sottrazione
    variable vR     : unsigned(ROOT_W-1 downto 0);
  begin
    if iRst = '1' then
      state    <= IDLE;
      sNreg    <= (others => '0');
      sRreg    <= (others => '0');
      sRemReg  <= (others => '0');
      sIter    <= 0;
      sRootQ   <= (others => '0');
      sDoneQ <= '0';

    elsif rising_edge(iClk) then
      -- default
      sDoneQ <= '0';

        case state is
          when IDLE =>
            if iStart = '1' then
              sNreg    <= unsigned(iData);
              sRreg    <= (others => '0');
              sRemReg  <= (others => '0');
              sIter    <= PAIRS-1;            -- 15..0
              state    <= RUN;
            end if;

          when RUN =>
            -- coppia di bit corrente
            vPair := sNreg(sIter*2+1 downto sIter*2);

            -- rem = (sRemReg<<2) + vPair
            vRem   := unsigned(sRemReg & vPair);

            -- trial = (sRreg<<2) + 1  
            vTrial := resize(unsigned(sRreg & "01"), vTrial'length);

            if vRem >= vTrial then
              vRem := vRem - vTrial;
              vR   := shift_left(sRreg, 1) or to_unsigned(1, ROOT_W);
            else
              vR   := shift_left(sRreg, 1);
            end if;

            -- registra risultati
            sRemReg <= vRem(REM_W-1 downto 0);
            sRreg   <= vR;

            if sIter = 0 then
              sRootQ <= vR;
              sDoneQ <= '1';
              state  <= DONE;
            else
              sIter <= sIter - 1;
            end if;
          when DONE  => 
              state  <= IDLE;

          when others => -- @suppress "Unexpected 'others' choice, case statement covers all choices explicitly"
            state <= IDLE;
        end case;
    end if;
  end process;

end architecture;
