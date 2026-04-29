--!@file Minheap.vhd
--!@brief Minheap implementation in VHDL.
--!@author Luca Russo, luca.russo@cern.ch, luca.russo912@gmail.com
--!@date 29/04/2026
--!@version 1.6.1 - 27/06/2025 -
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.FOOTpackage.all;

entity minheap is
    generic (
        pHEAP_SIZE  : integer := 8;
        pDATA_WIDTH : integer := 8
    );
    port (
        iCLK      : in  std_logic;
        iRST      : in  std_logic;
        iINS_en   : in  std_logic;
        iINS_data : in  std_logic_vector(pDATA_WIDTH-1 downto 0);
        iEXT_en   : in  std_logic;
        --oDATA     : out std_logic_vector(pDATA_WIDTH-1 downto 0);
        --oVALID    : out std_logic;
        oBusy     : out std_logic;
        oCount    : out integer range 0 to pHEAP_SIZE;
        oRoot     : out std_logic_vector(pDATA_WIDTH-1 downto 0)
    );
end minheap;

architecture Behavioral of minheap is

    -- Sottotipi per rendere "sicuri" gli indici usati per accedere all'array
    subtype idx_t is integer range 0 to pHEAP_SIZE-1;  -- indici validi dell'array
    subtype cnt_t is integer range 0 to pHEAP_SIZE;    -- contatore può arrivare alla capienza

    type heap_array is array (0 to pHEAP_SIZE-1) of signed(pDATA_WIDTH-1 downto 0);
    signal heap       : heap_array := (others => (others => '0'));
    signal heap_count : cnt_t := 0;

    type state_type is (IDLE, HEAPIFY_UP, HEAPIFY_DOWN);
    signal state : state_type;

    attribute syn_encoding : string;
    attribute syn_encoding of state : signal is "onehot";

    signal current_index : idx_t := 0;
    signal root_element  : std_logic_vector(pDATA_WIDTH-1 downto 0) := (others => '0');

begin
    oCount <= heap_count;
    oRoot  <= root_element;

    oBusy  <= '1' when state /= IDLE else '0';

    process(iCLK, iRST)
        -- Variabili "grezze" per calcoli aritmetici di indici
        variable left_i, right_i : integer; --@suppress

        -- Variabili di indice ristretto (0..pHEAP_SIZE-1) usate per indicizzare l'array
        variable parent_idx : idx_t;
        variable left_idx   : idx_t;
        variable right_idx  : idx_t;
        variable smallest   : idx_t;

        -- Indici temporanei sicuri per INS/EXT
        variable ins_idx  : idx_t;
        variable last_idx : idx_t;

        variable temp : signed(pDATA_WIDTH-1 downto 0);
    begin
        if iRST = '1' then
            -- Azzera tutto
            heap <= (others => (others => '0'));
            heap_count <= 0;
            state <= IDLE;
            current_index <= 0;
            root_element <= (others => '0');
            --oVALID <= '0';
            --oBusy  <= '0';
            --oDATA  <= (others => '0');

        elsif rising_edge(iCLK) then
            case state is
                when IDLE =>
                    --oVALID <= '0';
                    if (iINS_en = '1') and (heap_count < pHEAP_SIZE) then
                        ins_idx := heap_count;                 -- 0..pHEAP_SIZE-1 (sicuro)
                        heap(ins_idx) <= signed(iINS_data);
                        current_index <= ins_idx;              -- Serve per tenere traccia dell'indice su cui sto lavorando
                        heap_count <= heap_count + 1;
                        --oBusy  <= '1';
                        state  <= HEAPIFY_UP;

                    elsif iEXT_en = '1' then
                        if heap_count > 0 then
                            --oDATA  <= std_logic_vector(heap(0)); -- Metto in output la radice
                            --oVALID <= '1';
                            last_idx := heap_count - 1;         -- 0..pHEAP_SIZE-1 (sicuro)
                            heap(0) <= heap(last_idx);          -- Carico nella radice ultimo elemento (hc non parte da 0 ma da 1, quindi - 1)
                            heap_count <= heap_count - 1;       -- Decremento la grandezza dell'heap
                            current_index <= 0;                 -- Carico 0, quindi la radice nell'indice su cui sto lavorando
                            --oBusy  <= '1';
                            state  <= HEAPIFY_DOWN;
                        else
                            --oVALID <= '0';
                            --oBusy  <= '0';
                            state  <= IDLE;
                        end if;
                    else
                        --oBusy <= '0';
                        state <= IDLE;
                    end if;

                when HEAPIFY_UP =>
                    --oBusy <= '1';
                    if current_index = 0 then
                        state <= IDLE;
                        root_element <= std_logic_vector(heap(0));
                    else
                        parent_idx := (current_index - 1) / 2; -- Formula per calcolare indice del parent di un nodo dato un indice figlio.
                        if heap(current_index) < heap(parent_idx) then -- Se il figlio è minore del padre allora swap
                            temp := heap(parent_idx);
                            heap(parent_idx) <= heap(current_index);
                            heap(current_index) <= temp;
                            current_index <= parent_idx;
                            state <= HEAPIFY_UP;
                        else
                            state <= IDLE;
                            root_element <= std_logic_vector(heap(0));
                            --oBusy <= '0';
                        end if;
                    end if;

                when HEAPIFY_DOWN =>
                    --oBusy <= '1';
                    --oVALID <= '0';
                    left_i  := 2 * current_index + 1; -- Formula per il figlio sx, parto dalla radice alla prima iter
                    right_i := 2 * current_index + 2; -- Formula per il figlio dx, parto dalla radice alla prima iter
                    smallest := current_index;        -- Imposto come "smallest" la radice alla prima iter, si parla di indice

                    if left_i < heap_count then
                        left_idx := left_i;                       -- cast sicuro: ora 0..pHEAP_SIZE-1
                        if heap(left_idx) < heap(smallest) then
                            smallest := left_idx;
                        end if;
                    end if;
                    if right_i < heap_count then
                        right_idx := right_i;                     -- cast sicuro
                        if heap(right_idx) < heap(smallest) then
                            smallest := right_idx;                -- Con := l'assegnazione è immediata
                        end if;
                    end if;

                    -- In questo caso do priorità al figlio destro.
                    if smallest /= current_index then
                        temp := heap(current_index);
                        heap(current_index) <= heap(smallest);
                        heap(smallest) <= temp;    -- Temp era stata assegnata immediatamente
                        current_index <= smallest;
                        state <= HEAPIFY_DOWN;
                    else
                        state <= IDLE;
                        root_element <= std_logic_vector(heap(0));
                        --oBusy <= '0';
                    end if;

                when others => --@suppress
                    state <= IDLE;
            end case;
        end if;
    end process;

end Behavioral;
