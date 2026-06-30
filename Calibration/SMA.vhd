--!@file SMA.vhd
--!@brief Streaming Median Algorithm con ordinamento parziale.
--!@author Luca Russo, luca.russo@cern.ch, luca.russo912@gmail.com
--!@date 22/05/2026
--!@version 1.7.0 - selezione parziale della mediana bassa -

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.FOOTpackage.all;

entity StreamingMedian is
    generic (
        pHEAP_SIZE  : integer := 4; -- Metà elementi
        pCALC_MODE  : natural := 0; -- 0: media dei due centrali; 1: centrale alto; >1: centrale basso.
        pDATA_WIDTH : integer := 16 
    );
    port (
        iCLK      : in  std_logic;
        iRST      : in  std_logic;
        iINS_en   : in  std_logic;
        iINS_data : in  std_logic_vector(pDATA_WIDTH-1 downto 0);
        oMedian   : out std_logic_vector(pDATA_WIDTH-1 downto 0);
        oValid    : out std_logic;
        oBusy_SMA : out std_logic
    );
end StreamingMedian;

architecture Behavioral of StreamingMedian is

    -- serve conoscere solo i 4 valori più piccoli e la mediana è il quarto.
    -- Per media e mediana alta serve anche il primo valore della meta' alta.
    function fKeep_size(
        heap_size : integer;
        mode      : natural
    ) return integer is
    begin
        if (mode = 0) or (mode = 1) then
            return heap_size + 1;
        else
            return heap_size;
        end if;
    end function;

    
    constant cWINDOW_SIZE : integer := pHEAP_SIZE * 2;                      -- Numero massimo dati prima di RST automatico
    constant cKEEP_SIZE   : integer := fKeep_size(pHEAP_SIZE, pCALC_MODE);  -- Numero di registri realmente conservati ordinati

    subtype t_SMA_total is integer range 0 to cWINDOW_SIZE;                 -- Conta dati totali
    subtype t_SMA_keep  is integer range 0 to cKEEP_SIZE;                   -- Conta dati effettivamente salvati in Keep

    type t_SMA_keep_data is array (0 to cKEEP_SIZE-1) of signed(pDATA_WIDTH-1 downto 0); --Array con solo valori utili alla mediana

    signal sKeep        : t_SMA_keep_data := (others => (others => '0'));   
    signal sTotalCount  : t_SMA_total := 0;                               
    signal sStoredCount : t_SMA_keep := 0;                                 
    signal sMedian_Int  : std_logic_vector(pDATA_WIDTH-1 downto 0) := (others => '0'); -- Mediana
    signal sBusy_Int    : std_logic := '0';                                

begin

    oMedian <= sMedian_Int;

    -- Tutto si completa in un solo ciclo
    -- Busy resta alto durante il ciclo di richiesta e nel ciclo di aggiornamento.
    oBusy_SMA <= iINS_en or sBusy_Int;

    process(iCLK, iRST)
        -- Variabili locali usate per calcolare il nuovo stato e la nuova mediana nello stesso clk del dato
        variable vKeep        : t_SMA_keep_data;
        variable vTotalCount  : t_SMA_total;
        variable vStoredCount : t_SMA_keep;
        variable vInsertPos   : integer range 0 to cKEEP_SIZE-1; -- Posizione in cui inserire il nuovo dato, tipo puntatore

        -- Per gestire i flush anticipati
        variable vIdxLow     : integer range 0 to cKEEP_SIZE-1; -- Indice centrale basso
        variable vIdxHigh    : integer range 0 to cKEEP_SIZE-1; -- Indice centrale alto
        variable vSum         : signed(pDATA_WIDTH downto 0); 
    begin
        if iRST = '1' then
            sKeep        <= (others => (others => '0'));
            sTotalCount  <= 0;
            sStoredCount <= 0;
            sMedian_Int  <= (others => '0');
            sBusy_Int    <= '0';
            oValid       <= '0';

        elsif rising_edge(iCLK) then
            -- Default zero
            oValid    <= '0';
            sBusy_Int <= '0';

            if iINS_en = '1' then
                -- Se pieno, il nuovo dato parte da reset
                if sTotalCount = cWINDOW_SIZE then
                    vKeep        := (others => (others => '0'));
                    vTotalCount  := 0;
                    vStoredCount := 0;
                else
                    vKeep        := sKeep;
                    vTotalCount  := sTotalCount;
                    vStoredCount := sStoredCount;
                end if;

                vTotalCount := vTotalCount + 1;

                -- Caso 1: array keep non è pieno, inserisco il nuovo dato nella posizione ordinata corretta
                -- INSERTION SORT
                if vStoredCount < cKEEP_SIZE then
                    vInsertPos := vStoredCount;

                    for i in 0 to cKEEP_SIZE-1 loop
                        if (i < vStoredCount) and
                           (signed(iINS_data) < vKeep(i)) and
                           (vInsertPos = vStoredCount) then
                            vInsertPos := i;
                        end if;
                    end loop;

                    -- Shifta a destra solo la porzione valida che deve fare spazio
                    for i in cKEEP_SIZE-1 downto 1 loop
                        if (i <= vStoredCount) and (i > vInsertPos) then
                            vKeep(i) := vKeep(i-1);
                        end if;
                    end loop;

                    vKeep(vInsertPos) := signed(iINS_data);
                    vStoredCount := vStoredCount + 1;

                -- Caso 2: array keep pieno ma il nuovo dato entra comunque tra quelli di mediana
                -- Il valore maggiore tra i conservati viene perso tanto non influisce più sulla mediana
                elsif signed(iINS_data) < vKeep(cKEEP_SIZE-1) then
                    vInsertPos := cKEEP_SIZE-1;

                    -- INSERTION SORT
                    for i in 0 to cKEEP_SIZE-1 loop
                        if (signed(iINS_data) < vKeep(i)) and
                           (vInsertPos = cKEEP_SIZE-1) then
                            vInsertPos := i;
                        end if;
                    end loop;

                    for i in cKEEP_SIZE-1 downto 1 loop
                        if i > vInsertPos then
                            vKeep(i) := vKeep(i-1);
                        end if;
                    end loop;

                    vKeep(vInsertPos) := signed(iINS_data);
                end if;

                -- Aggiornamento stato
                sKeep        <= vKeep;
                sTotalCount  <= vTotalCount;
                sStoredCount <= vStoredCount;

                -- Calcolo della mediana sul numero reale di campioni presenti
                -- Questo per restituire la mediana ad ogni iterazione
                if (vTotalCount mod 2) = 0 then
                    vIdxLow := (vTotalCount / 2) - 1;

                    if pCALC_MODE = 0 then
                        -- Media dei due centrali in mode 0
                        vIdxHigh := vTotalCount / 2;
                        vSum := resize(vKeep(vIdxLow), pDATA_WIDTH+1)
                              + resize(vKeep(vIdxHigh), pDATA_WIDTH+1);
                        sMedian_Int <= std_logic_vector(resize(shift_right(vSum, 1), pDATA_WIDTH));
                    elsif pCALC_MODE = 1 then
                        -- Mediana alta in mode 1
                        vIdxHigh := vTotalCount / 2;
                        sMedian_Int <= std_logic_vector(vKeep(vIdxHigh));
                    else
                        -- Mediana bassa, si usa questa di base, quindi la logica sopra viene deprecata
                        sMedian_Int <= std_logic_vector(vKeep(vIdxLow));
                    end if;
                else
                    -- Se i campioni sono dispari c'è un solo centro
                    vIdxLow := vTotalCount / 2;
                    sMedian_Int <= std_logic_vector(vKeep(vIdxLow));
                end if;

                -- Mediana valid al clk successivo
                oValid    <= '1';
                sBusy_Int <= '1';
            end if;
        end if;
    end process;

end Behavioral;
