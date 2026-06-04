--!@file SMA.vhd
--!@brief Streaming Median Algorithm implementation in VHDL.
--!@author Luca Russo, luca.russo@cern.ch, luca.russo912@gmail.com
--!@date 22/05/2026
--!@version 1.6.3 - replace_root latency opt -

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

    type state_type is (
        IDLE,
        HOLD_RESET,
        WAIT_INSERT,
        INSERT,
        WAIT_DONE
    );
    signal state : state_type;

    attribute syn_encoding : string;
    attribute syn_encoding of state : signal is "onehot";

    -- MaxHeap
    signal sMax_iINS_en, sMax_iEXT_en, sMax_iREP_en    : std_logic := '0';
    signal sMax_iINS_data, sMax_iREP_data, sMax_oRoot  : std_logic_vector(pDATA_WIDTH-1 downto 0);
    signal sMax_oBusy    : std_logic;
    signal sMax_oCount   : integer range 0 to pHEAP_SIZE;

    -- MinHeap
    signal sMin_iINS_en, sMin_iEXT_en, sMin_iREP_en    : std_logic := '0';
    signal sMin_iINS_data, sMin_iREP_data, sMin_oRoot  : std_logic_vector(pDATA_WIDTH-1 downto 0);
    signal sMin_oBusy    : std_logic;
    signal sMin_oCount   : integer range 0 to pHEAP_SIZE;

    signal sKeep_Inserted : std_logic_vector(pDATA_WIDTH-1 downto 0);

    -- Maschera di attesa:
    --   sWait_Max = '1' se l'operazione corrente coinvolge il MaxHeap
    --   sWait_Min = '1' se l'operazione corrente coinvolge il MinHeap
    signal sWait_Max : std_logic := '0';
    signal sWait_Min : std_logic := '0';

    signal sMedian_Int : std_logic_vector(pDATA_WIDTH-1 downto 0);

    -- Segnali di reset separati per MaxHeap e MinHeap
    signal sRst_MaxHeap, sRst_MinHeap : std_logic := '0';

begin

    MAX: Heap
        generic map(
            pHEAP_SIZE      => pHEAP_SIZE,
            pDATA_WIDTH     => pDATA_WIDTH,
            pIS_MAX_HEAP    => true
        )
        port map(
            iCLK       => iCLK,
            iRST       => sRst_MaxHeap,
            iINS_en    => sMax_iINS_en,
            iINS_data  => sMax_iINS_data,
            iEXT_en    => sMax_iEXT_en,
            iREP_en    => sMax_iREP_en,
            iREP_data  => sMax_iREP_data,
            oBusy      => sMax_oBusy,
            oCount     => sMax_oCount,
            oRoot      => sMax_oRoot
        );

    MIN: Heap
        generic map(
            pHEAP_SIZE      => pHEAP_SIZE,
            pDATA_WIDTH     => pDATA_WIDTH,
            pIS_MAX_HEAP    => false
        )
        port map(
            iCLK       => iCLK,
            iRST       => sRst_MinHeap,
            iINS_en    => sMin_iINS_en,
            iINS_data  => sMin_iINS_data,
            iEXT_en    => sMin_iEXT_en,
            iREP_en    => sMin_iREP_en,
            iREP_data  => sMin_iREP_data,
            oBusy      => sMin_oBusy,
            oCount     => sMin_oCount,
            oRoot      => sMin_oRoot
        );

    oMedian <= sMedian_Int;
    oBusy_SMA <= '1' when (sMax_oBusy = '1' or sMin_oBusy = '1') or state /= IDLE else '0';

    process(iCLK, iRST)
    begin
        if iRST = '1' then
            state <= IDLE;

            sMax_iINS_en <= '0';
            sMin_iINS_en <= '0';
            sMax_iEXT_en <= '0';
            sMin_iEXT_en <= '0';
            sMax_iREP_en <= '0';
            sMin_iREP_en <= '0';

            sMax_iINS_data <= (others => '0');
            sMin_iINS_data <= (others => '0');
            sMax_iREP_data <= (others => '0');
            sMin_iREP_data <= (others => '0');

            sMedian_Int <= (others => '0');
            oValid <= '0';

            sKeep_Inserted <= (others => '0');

            sWait_Max <= '0';
            sWait_Min <= '0';

            sRst_MinHeap <= '1';
            sRst_MaxHeap <= '1';

        elsif rising_edge(iCLK) then
            -- Keep zero default
            sMax_iINS_en <= '0';
            sMin_iINS_en <= '0';
            sMax_iEXT_en <= '0';
            sMin_iEXT_en <= '0';
            sMax_iREP_en <= '0';
            sMin_iREP_en <= '0';
            sRst_MinHeap <= '0';
            sRst_MaxHeap <= '0';
            oValid <= '0';

            case state is
                -- Extract + insert sullo stesso heap in questa versione viene evitata, che è 2 log n e si fa solo log n
                when IDLE =>
                    sWait_Max <= '0';
                    sWait_Min <= '0';

                    -- Se gli heap sono pieni, resetta prima di iniziare una nuova 
                    if (sMax_oCount + sMin_oCount) = pHEAP_SIZE*2 then
                        sRst_MinHeap <= '1';
                        sRst_MaxHeap <= '1';

                        if iINS_en = '1' then
                            sKeep_Inserted <= iINS_data;
                            state <= HOLD_RESET;
                        end if;

                    elsif iINS_en = '1' then
                        sKeep_Inserted <= iINS_data;
                        state <= WAIT_INSERT;
                    end if;

                -- CLOCK WAIT, attende di propagare il segnale di clock agli heap sotto. 
                -- Questo avviene solo ed unicamente se al ritorno in IDLE, alla verifica della grandezza degli heap mi arriva contestualmente un dato.
                when HOLD_RESET =>
                    state <= WAIT_INSERT;

                -- DECISIONE INSERIMENTO
                when WAIT_INSERT =>
                    if (sMax_oBusy = '0') and (sMin_oBusy = '0') then

                        -- CASO
                        -- vuoto: il primo dato va nel MaxHeap.
                        if (sMax_oCount = 0) and (sMin_oCount = 0) then
                            sMax_iINS_data <= sKeep_Inserted;
                            sMax_iINS_en   <= '1';

                            sWait_Max <= '1';
                            sWait_Min <= '0';
                            state <= INSERT;

                        -- CASO "sMax_oCount > sMin_oCount"
                        -- MaxHeap ha già almeno un elemento in più. Dopo questo inserimento bisogna finire con i count uguali.
                        -- Se il dato può stare nella metà alta, insert diretto nel MinHeap altrimenti se il dato appartiene alla metà bassa:
                        --  vecchia root MaxHeap -> MinHeap  
                        --  nuovo dato -> replace_root MaxHeap
                        -- Operazioni partono in parallelo.            
                        elsif sMax_oCount > sMin_oCount then
                            if signed(sKeep_Inserted) >= signed(sMax_oRoot) then
                                sMin_iINS_data <= sKeep_Inserted;
                                sMin_iINS_en   <= '1';

                                sWait_Max <= '0';
                                sWait_Min <= '1';
                                state <= INSERT;
                            else
                                sMin_iINS_data <= sMax_oRoot;
                                sMin_iINS_en   <= '1';

                                sMax_iREP_data <= sKeep_Inserted;
                                sMax_iREP_en   <= '1';

                                sWait_Max <= '1';
                                sWait_Min <= '1';
                                state <= INSERT;
                            end if;

                        -- CASO "sMax_oCount = sMin_oCount"
                        -- Dopo l'inserimento il MaxHeap deve avere un elemento
                        -- in più.
                        -- Se il dato può stare nella metà bassa, insert diretto nel MaxHeap altrimenti:
                        --     vecchia root MinHeap -> MaxHeap
                        --     nuovo dato -> replace_root MinHeap
                        -- In parallelo
                        elsif sMax_oCount = sMin_oCount then
                            if (sMin_oCount = 0) or (signed(sKeep_Inserted) <= signed(sMin_oRoot)) then
                                sMax_iINS_data <= sKeep_Inserted;
                                sMax_iINS_en   <= '1';

                                sWait_Max <= '1';
                                sWait_Min <= '0';
                                state <= INSERT;
                            else
                                sMax_iINS_data <= sMin_oRoot;
                                sMax_iINS_en   <= '1';

                                sMin_iREP_data <= sKeep_Inserted;
                                sMin_iREP_en   <= '1';

                                sWait_Max <= '1';
                                sWait_Min <= '1';
                                state <= INSERT;
                            end if;

                        -- CASO "sMax_oCount < sMin_oCount"
                        -- NON SUCCEDE MAI, ma inserito per mantenere il sistema bilanciato se per qualche ragione accade.
                        -- E' tipo un caso base
                        else
                            if signed(sKeep_Inserted) <= signed(sMin_oRoot) then
                                sMax_iINS_data <= sKeep_Inserted;
                                sMax_iINS_en   <= '1';

                                sWait_Max <= '1';
                                sWait_Min <= '0';
                                state <= INSERT;
                            else
                                sMax_iINS_data <= sMin_oRoot;
                                sMax_iINS_en   <= '1';

                                sMin_iREP_data <= sKeep_Inserted;
                                sMin_iREP_en   <= '1';

                                sWait_Max <= '1';
                                sWait_Min <= '1';
                                state <= INSERT;
                            end if;
                        end if;
                    end if;

                -- INSERIMENTO EFFETTIVO DEGLI ELEMENTI
                when INSERT =>
                    state <= WAIT_DONE;

                -- Si attendono solo gli heap coinvolti nell'operazione
                when WAIT_DONE =>
                    if ((sWait_Max = '0') or (sMax_oBusy = '0')) and
                       ((sWait_Min = '0') or (sMin_oBusy = '0')) then

                        sMedian_Int <= CalcMedian( -- @suppress
                            signed(sMax_oRoot),
                            signed(sMin_oRoot),
                            sMax_oCount,
                            sMin_oCount,
                            pCALC_MODE
                        );

                        oValid <= '1';
                        sWait_Max <= '0';
                        sWait_Min <= '0';
                        state <= IDLE;
                    end if;

                when others => --@suppress
                    state <= IDLE;

            end case;
        end if;
    end process;

end Behavioral;
