--!@file SMA.vhd
--!@brief Streaming Median Algorith implementation in VHDL.
--!@author Luca Russo, luca.russo@cern.ch, luca.russo912@gmail.com
--!@date 27/06/2025
--!@version 1.6.1 - 27/06/2025 -

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.FOOTpackage.all;

entity StreamingMedian is
    generic (
        pHEAP_SIZE  : integer := 8; -- VA / 2. 128 strip = 64 heap size
        pCALC_MODE  : natural := 0; 
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

    type state_type is (IDLE, WAIT_INSERT, INSERT, WAIT_SWAP, SWAP, WAIT_REBALANCE, REBALANCE);
    signal state : state_type;

    attribute syn_encoding : string;
    attribute syn_encoding of state : signal is "onehot";

    -- Interfaccia MaxHeap
    signal max_iINS_en, max_iEXT_en : std_logic := '0';
    signal max_iINS_data, max_oRoot : std_logic_vector(pDATA_WIDTH-1 downto 0);
    signal max_oBusy : std_logic;
    signal max_oCount : integer range 0 to pHEAP_SIZE;

    -- Interfaccia MinHeap
    signal min_iINS_en, min_iEXT_en : std_logic := '0';
    signal min_iINS_data, min_oRoot : std_logic_vector(pDATA_WIDTH-1 downto 0);
    signal min_oBusy : std_logic;
    signal min_oCount : integer range 0 to pHEAP_SIZE;

    signal keep_data : std_logic_vector(pDATA_WIDTH-1 downto 0);
    signal keep_inserted : std_logic_vector(pDATA_WIDTH-1 downto 0);

    signal oMedian_int : std_logic_vector(pDATA_WIDTH-1 downto 0);

    -- Segnali di reset separati per MaxHeap e MinHeap
    signal rst_maxheap, rst_minheap : std_logic := '0';

begin

    -- Istanze MaxHeap e MinHeap con reset locali
    MAX: maxheap
        generic map(pHEAP_SIZE => pHEAP_SIZE, pDATA_WIDTH => pDATA_WIDTH)
        port map(
            iCLK,             -- clock
            rst_maxheap,      -- reset locale per MaxHeap
            max_iINS_en,
            max_iINS_data,
            max_iEXT_en,
            -- max_oDATA,
            -- max_oVALID,
            max_oBusy,
            max_oCount,
            max_oRoot
        );

    MIN: minheap
        generic map(pHEAP_SIZE => pHEAP_SIZE, pDATA_WIDTH => pDATA_WIDTH)
        port map(
            iCLK,             -- clock
            rst_minheap,      -- reset locale per MinHeap
            min_iINS_en,
            min_iINS_data,
            min_iEXT_en,
            -- min_oDATA,
            -- min_oVALID,
            min_oBusy,
            min_oCount,
            min_oRoot
        );

    oMedian <= oMedian_int;
    oBusy_SMA  <= '1' when (max_oBusy = '1' or min_oBusy = '1') or state /= IDLE else '0';

    -- Macchina a stati
    process(iCLK, iRST)
    begin
        -- Imposto tutto il reset
        if iRST = '1' then
            state <= IDLE;
            --oBusy_SMA <= '0';
            max_iINS_en <= '0'; min_iINS_en <= '0';
            max_iEXT_en <= '0'; min_iEXT_en <= '0';
            max_iINS_data <= (others => '0'); min_iINS_data <= (others => '0');
            oMedian_int <= (others => '0');
            oValid <= '0';
            keep_data <= (others => '0');
            keep_inserted <= (others => '0');
            rst_minheap <= '1';
            rst_maxheap <= '1';

        elsif rising_edge(iCLK) then
            -- Caso in cui lo stato è IDLE
            case state is
                when IDLE =>
                    rst_minheap <= '0';
                    rst_maxheap <= '0';
                    oValid <= '0';
                    --oBusy_SMA <= '0'; -- Il sistema non è impegnato
                    max_iINS_en <= '0'; min_iINS_en <= '0'; -- No inserimento in HEAPS
                    max_iEXT_en <= '0'; min_iEXT_en <= '0'; -- No estrazione in HEAPS
                    if (max_oCount + min_oCount) = pHEAP_SIZE*2 then
                        rst_minheap <= '1';
                        rst_maxheap <= '1';
                    end if;
                    if iINS_en = '1' then
                        state <= WAIT_INSERT; -- Se l'inserimento va su, passo allo stato di attesa inserimento
                        keep_inserted  <= iINS_data;
                        --oBusy_SMA <= '1'; -- Il sistema è impegnato, non accetta inserimenti
                    end if;

                when WAIT_INSERT =>
                    -- Entrambi gli heap non devono essere impegnati, se è così allora entro:
                    if (max_oBusy = '0') and (min_oBusy = '0') then
                        -- Se il maxHeap è vuoto oppure il dato è <= della radice del maxHeap
                        if (max_oCount = 0) or (signed(keep_inserted ) <= signed(max_oRoot)) then
                            if max_oCount < pHEAP_SIZE then 
                                max_iINS_data <= keep_inserted ; -- Metto il dato nel flusso di maxHeap
                                max_iINS_en <= '1'; -- Attivo l'inserimento del maxHeap
                                state <= INSERT; 
                            else
                                keep_data   <= keep_inserted ;
                                max_iEXT_en <= '1';
                                min_iINS_data <= max_oRoot; -- Metto il dato nel flusso di minHeap
                                min_iINS_en <= '1'; -- Attivo l'inserimento del minHeap
                                state <= WAIT_SWAP;
                            end if;
                        -- Altrimenti
                        else
                            min_iINS_data <= keep_inserted ; -- Metto il dato nel flusso di minHeap
                            min_iINS_en <= '1'; -- Attivo l'inserimento del minHeap
                            state <= INSERT; 
                        end if;

                    end if;

                when WAIT_SWAP =>
                    max_iINS_en <= '0'; min_iINS_en <= '0';
                    max_iEXT_en <= '0'; min_iEXT_en <= '0';
                    state <= SWAP;

                when SWAP =>
                    max_iINS_en <= '0'; min_iINS_en <= '0';
                    max_iEXT_en <= '0'; min_iEXT_en <= '0';
                    if (max_oBusy = '0') then
                        max_iINS_data <= keep_data; -- Metto il dato nel flusso di maxHeap
                        max_iINS_en <= '1'; -- Attivo l'inserimento del maxHeap
                        state <= INSERT;
                    end if;

                when INSERT =>
                    -- I trigger di inserimento di maxheap e minheap vengono chiusi. In un ciclo di clock dedicato
                    max_iINS_en <= '0'; min_iINS_en <= '0';
                    state <= WAIT_REBALANCE;

                when WAIT_REBALANCE =>
                    -- Attendo che entrambi gli heap terminino le loro operazioni dopo l'inserimento. Heapify-up.
                    if (max_oBusy = '0') and (min_oBusy = '0') then
                        -- Se il max heap ha più di un elemento in più. In pratica mantiene il max_heap più grande.
                        if max_oCount > min_oCount + 1 then
                            max_iEXT_en <= '1'; -- Estraggo dal maxHeap
                            min_iINS_data <= max_oRoot; -- Prendo il dato dalla radice e lo carico nel flusso dati inserimento minHeap
                            min_iINS_en <= '1'; -- Attivo l'inserimento nel min heap
                            state <= REBALANCE;
                        -- Se il min heap è più grande del max heap
                        elsif min_oCount > max_oCount then
                            min_iEXT_en <= '1'; -- Estraggo da minHeap
                            max_iINS_data <= min_oRoot; -- Prendo il dato dalla radice e lo carico nel flusso dati inserimento maxHeap
                            max_iINS_en <= '1'; -- Attivo l'inserimento del max heap
                            state <= REBALANCE;
                        else
                            -- Altrimenti passo direttamente alla computazione della mediana
                            oMedian_int        <= CalcMedian( -- @suppress 
                                signed(max_oRoot),
                                signed(min_oRoot),
                                max_oCount,
                                min_oCount,
                                pCALC_MODE
                              );
                            oValid <= '1';
                            state <= IDLE;
                        end if;
                    end if;

                when REBALANCE =>
                    max_iINS_en <= '0'; min_iINS_en <= '0';
                    max_iEXT_en <= '0'; min_iEXT_en <= '0';
                    -- Calcola la mediana solo quando gli heap sono scarichi da lavoro
                    if (max_oBusy = '0') and (min_oBusy = '0') and (max_iINS_en = '0') and (min_iINS_en = '0') then
                        oMedian_int        <= CalcMedian( -- @suppress 
                            signed(max_oRoot),
                            signed(min_oRoot),
                            max_oCount,
                            min_oCount,
                            pCALC_MODE
                        );
                        oValid <= '1';
                        state <= IDLE;
                    end if;
                when others => state <= IDLE; --@suppress
            end case;
        end if;
    end process;

end Behavioral;
