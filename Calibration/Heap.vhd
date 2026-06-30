--!@file Heap.vhd
--!@brief Parametric binary heap implementation. The same entity can work as MaxHeap or MinHeap.
--!@author Luca Russo, luca.russo@cern.ch, luca.russo912@gmail.com
--!@date 04/06/2026
--!@version 1.7.0 - unified MaxHeap/MinHeap through pIS_MAX_HEAP -

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.FOOTpackage.all;

entity Heap is
    generic (
        pHEAP_SIZE   : integer := 8;
        pDATA_WIDTH  : integer := 8;
        pIS_MAX_HEAP : boolean := true
    );
    port (
        iCLK      : in  std_logic;
        iRST      : in  std_logic;
        iINS_en   : in  std_logic;
        iINS_data : in  std_logic_vector(pDATA_WIDTH-1 downto 0);
        iEXT_en   : in  std_logic;
        iREP_en   : in  std_logic;
        iREP_data : in  std_logic_vector(pDATA_WIDTH-1 downto 0);
        oBusy     : out std_logic;
        oCount    : out integer range 0 to pHEAP_SIZE;
        oRoot     : out std_logic_vector(pDATA_WIDTH-1 downto 0)
    );
end Heap;

architecture Behavioral of Heap is

    -- Sottotipi per rendere sicuri gli indici usati per accedere all'array.
    subtype idx_t is integer range 0 to pHEAP_SIZE-1;  -- indici validi dell'array
    subtype cnt_t is integer range 0 to pHEAP_SIZE;    -- il contatore può arrivare alla capienza

    type heap_array is array (0 to pHEAP_SIZE-1) of signed(pDATA_WIDTH-1 downto 0);
    signal heap       : heap_array := (others => (others => '0'));
    signal heap_count : cnt_t := 0;

    type state_type is (IDLE, HEAPIFY_UP, HEAPIFY_DOWN);
    signal state : state_type;

    attribute syn_encoding : string;
    attribute syn_encoding of state : signal is "onehot";

    signal current_index : idx_t := 0;
    signal root_element  : std_logic_vector(pDATA_WIDTH-1 downto 0) := (others => '0');

    function HasPriority(
        a      : signed;
        b      : signed;
        is_max : boolean
    ) return boolean is
    begin
        if is_max then
            return a > b;
        else
            return a < b;
        end if;
    end function;

begin
    oCount <= heap_count;
    oRoot  <= root_element;

    oBusy  <= '1' when state /= IDLE else '0';

    process(iCLK, iRST)
        -- Variabili grezze per calcolare i figli. Restano integer perché possono uscire temporaneamente dal range dell'array.
        variable left_i, right_i : integer; --@suppress

        -- Variabili di indice ristretto, usate solo dopo aver verificato che l'indice sia valido.
        variable parent_idx : idx_t;
        variable left_idx   : idx_t;
        variable right_idx  : idx_t;
        variable selected   : idx_t;

        -- Indici temporanei sicuri per insert/extract.
        variable ins_idx  : idx_t;
        variable last_idx : idx_t;

        variable temp : signed(pDATA_WIDTH-1 downto 0);
    begin
        if iRST = '1' then
            heap          <= (others => (others => '0'));
            heap_count    <= 0;
            state         <= IDLE;
            current_index <= 0;
            root_element  <= (others => '0');

        elsif rising_edge(iCLK) then
            case state is
                when IDLE =>
                    -- Priorità dei comandi mantenuta identica ai vecchi MinHeap/MaxHeap:
                    -- insert, poi extract, poi replace_root.
                    if (iINS_en = '1') and (heap_count < pHEAP_SIZE) then
                        ins_idx := heap_count;                 -- 0..pHEAP_SIZE-1, quindi sicuro
                        heap(ins_idx) <= signed(iINS_data);     -- Il nuovo valore entra in fondo all'heap
                        current_index <= ins_idx;              -- Da qui parte la risalita verso la root
                        heap_count <= heap_count + 1;
                        state <= HEAPIFY_UP;

                    elsif iEXT_en = '1' then
                        if heap_count > 0 then
                            -- La root viene rimossa logicamente: l'ultimo elemento prende il suo posto
                            -- e poi scende fino a ripristinare la proprietà dell'heap.
                            last_idx := heap_count - 1;
                            heap(0) <= heap(last_idx);
                            heap_count <= heap_count - 1;
                            current_index <= 0;
                            state <= HEAPIFY_DOWN;
                        else
                            state <= IDLE;
                        end if;

                    elsif iREP_en = '1' then
                        if heap_count > 0 then
                            -- replace_root evita extract + insert sullo stesso heap.
                            -- Si cambia solo la root e poi si esegue heapify_down.
                            heap(0) <= signed(iREP_data);
                            current_index <= 0;
                            state <= HEAPIFY_DOWN;
                        else
                            state <= IDLE;
                        end if;

                    else
                        state <= IDLE;
                    end if;

                when HEAPIFY_UP =>
                    if current_index = 0 then
                        state <= IDLE;
                        root_element <= std_logic_vector(heap(0));
                    else
                        parent_idx := (current_index - 1) / 2;

                        -- Nel MaxHeap sale il figlio maggiore del padre.
                        -- Nel MinHeap sale il figlio minore del padre.
                        if HasPriority(heap(current_index), heap(parent_idx), pIS_MAX_HEAP) then
                            temp := heap(parent_idx);
                            heap(parent_idx) <= heap(current_index);
                            heap(current_index) <= temp;
                            current_index <= parent_idx;
                            state <= HEAPIFY_UP;
                        else
                            state <= IDLE;
                            root_element <= std_logic_vector(heap(0));
                        end if;
                    end if;

                when HEAPIFY_DOWN =>
                    left_i  := 2 * current_index + 1;
                    right_i := 2 * current_index + 2;
                    selected := current_index;

                    -- Se esiste il figlio sinistro, lo confronto con il nodo corrente.
                    if left_i < heap_count then
                        left_idx := left_i;
                        if HasPriority(heap(left_idx), heap(selected), pIS_MAX_HEAP) then
                            selected := left_idx;
                        end if;
                    end if;

                    -- Se esiste anche il figlio destro, lo confronto con il migliore trovato finora.
                    if right_i < heap_count then
                        right_idx := right_i;
                        if HasPriority(heap(right_idx), heap(selected), pIS_MAX_HEAP) then
                            selected := right_idx;
                        end if;
                    end if;

                    -- Se uno dei figli ha priorità maggiore della posizione corrente, faccio swap e continuo a scendere.
                    if selected /= current_index then
                        temp := heap(current_index);
                        heap(current_index) <= heap(selected);
                        heap(selected) <= temp;
                        current_index <= selected;
                        state <= HEAPIFY_DOWN;
                    else
                        state <= IDLE;
                        if heap_count > 0 then
                            root_element <= std_logic_vector(heap(0));
                        else
                            root_element <= (others => '0');
                        end if;
                    end if;

                when others => --@suppress
                    state <= IDLE;
            end case;
        end if;
    end process;

end Behavioral;
