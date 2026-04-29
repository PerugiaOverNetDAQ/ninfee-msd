--!@file SMAx2.vhd
--!@brief Streaming Median Algorith x2 implementation in VHDL.
--!@author Luca Russo, luca.russo@cern.ch, luca.russo912@gmail.com
--!@date 29/04/2026
--!@version 1.0.0 
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.FOOTpackage.all;

entity StreamingMedianOfMedian is
    generic (
        pHEAP_SIZE  : integer := cHEAP_SIZE;
        pCALC_MODE  : natural := cSMA_CALC_MODE; -- In caso di numero pari di elementi. 0: Media tra le root, 1: MinRoot, >1:MaxRoot
        pDATA_WIDTH : integer := cADC_DATA_WIDTH
    );
    port (
        iCLK      : in  std_logic;
        iRST     : in  std_logic;
        iINS_en   : in  std_logic;
        iINS_data : in  std_logic_vector(pDATA_WIDTH-1 downto 0);
        oMedian   : out std_logic_vector(pDATA_WIDTH-1 downto 0);
        iFlush    : in  std_logic;
        oValid    : out std_logic;
        oBusy_SMA : out std_logic
    );
end StreamingMedianOfMedian;

architecture Behavioral of StreamingMedianOfMedian is

    signal sBTT_INS_data : std_logic_vector(pDATA_WIDTH-1 downto 0); --BTT : Bottom To Top
    signal sBOT_Median   : std_logic_vector(pDATA_WIDTH-1 downto 0); --BTT : Bottom To Top
    signal sTOP_INS_en   : std_logic;
    signal sBOT_Valid    : std_logic;
    signal sTOP_Valid    : std_logic;
    signal sBOT_Busy     : std_logic;
    signal sTOP_Busy     : std_logic;

    signal sBOT_Internal_RST : std_logic;
    signal sTOP_Internal_RST : std_logic;
    signal sTOP_Sync_RST     : std_logic;

    signal sBOT_InsertCount : natural range 0 to (pHEAP_SIZE*2); -- 0 to 7
    signal sTOP_InsertCount : natural range 0 to (pHEAP_SIZE*2); -- 0 to 7
    signal sGOT_Mean        : std_logic;
    
    type t_wrap_state is (IDLE, ENDING);
    signal state : t_wrap_state;

    attribute syn_encoding : string;
    attribute syn_encoding of state : signal is "onehot";

    signal sFlush_pending : std_logic;
    signal sFlush_seen    : std_logic; -- edge detect helper

    signal sValid_mux     : std_logic;
    signal sRaise_valid   : std_logic;
begin
    oBusy_SMA  <= '1' when (sTOP_Busy = '1' or sBOT_Busy = '1') else '0';
    sBOT_Internal_RST  <= '1' when (iRST = '1' or sTOP_INS_en = '1') else '0'; -- Utilizzo sTOP_INS_en dato che tanto devo resettare quando inserisco nel TOP.
    sTOP_Internal_RST  <= '1' when (iRST = '1' or sTOP_Sync_RST = '1') else '0'; 

    oValid      <= sValid_mux or sRaise_valid; 
    sValid_mux  <= sBOT_Valid when (sBOT_InsertCount /= (pHEAP_SIZE*2) and sBOT_InsertCount /= 0) else sTOP_Valid; -- Per l'ultimo elemento prendo il valid del TOP.
    -- Istanze SMA
    -- HEAP 4x16 + 4x16 = 8 spaces of 8 means = 8 x 8 = 64  
    SMATOP : StreamingMedian
        generic map(
            pHEAP_SIZE  => pHEAP_SIZE,
            pCALC_MODE  => pCALC_MODE,
            pDATA_WIDTH => pDATA_WIDTH
        )
        port map(
            iCLK      => iCLK,
            iRST      => sTOP_Internal_RST,
            iINS_en   => sTOP_INS_en,   --in
            iINS_data => sBTT_INS_data, --in, autolink
            oMedian   => oMedian,
            oValid    => sTOP_Valid,
            oBusy_SMA => sTOP_Busy      --out
        );

    -- HEAP 4x16 + 4x16 = 8 spaces
    SMABOT : StreamingMedian
        generic map(
            pHEAP_SIZE  => pHEAP_SIZE,
            pCALC_MODE  => pCALC_MODE,
            pDATA_WIDTH => pDATA_WIDTH
        )
        port map(
            iCLK      => iCLK,
            iRST      => sBOT_Internal_RST,      --in
            iINS_en   => iINS_en,
            iINS_data => iINS_data,
            oMedian   => sBOT_Median, --out
            oValid    => sBOT_Valid,    --out
            oBusy_SMA => sBOT_Busy      --out
        );
    
  
    process(iCLK, iRST)
    begin
        
        if iRST = '1' then
            sBTT_INS_data  <= (others => '0');
            sBOT_InsertCount  <= 0;
            sTOP_InsertCount  <= 0;
            sTOP_INS_en  <= '0';

            sFlush_pending  <= '0';
            sFlush_seen  <= '0';
            sGOT_Mean  <= '0';
            sTOP_Sync_RST  <= '0';

            sRaise_valid  <= '0';

            state  <= IDLE;
            
        elsif rising_edge(iCLK) then
            sTOP_INS_en  <= '0';
            sRaise_valid <= '0';

            if sBOT_Valid = '1' then
                sBTT_INS_data  <= sBOT_Median; -- Lo carico per non perdere dato dal reset del BOT.
                sGOT_Mean  <= '1';
            end if;


            if iINS_en = '1' and sBOT_InsertCount /= (pHEAP_SIZE*2) then
                sBOT_InsertCount  <=  sBOT_InsertCount + 1;
                sGOT_Mean  <= '0';
            end if;

            if sBOT_InsertCount = (pHEAP_SIZE*2) and sBOT_Valid = '1' then 
                sBOT_InsertCount  <= 0;
                sTOP_INS_en  <= '1';
                sTOP_InsertCount  <= sTOP_InsertCount + 1;
                sGOT_Mean  <= '0';
            end if;

            if (iFlush = '1') and (sFlush_seen = '0') then
                sFlush_pending <= '1';
                sFlush_seen    <= '1';
            elsif (iFlush = '0') then
                sFlush_seen    <= '0';
            end if;

            -- Ho inserito tutti i dati nel top, sono a saturazione, quando vedo il valid resetto
            case state is
                when IDLE  => 
                    sTOP_Sync_RST  <= '0';
                    
                    if sTOP_InsertCount = (pHEAP_SIZE*2) then
                        state  <= ENDING;
                    elsif sFlush_pending = '1' and sGOT_Mean = '1' and sBOT_Busy = '0' and sTOP_Busy = '0' then
                        sBOT_InsertCount  <= 0;
                        sTOP_INS_en  <= '1';
                        sGOT_Mean  <= '0';
                        sTOP_InsertCount  <= sTOP_InsertCount + 1;

                        sFlush_pending  <= '0';
                        state  <= ENDING;
                    elsif sFlush_pending = '1' and sGOT_Mean = '0' and sBOT_Busy = '0' and sTOP_Busy = '0' then
                        sRaise_valid <= '1';
                        state  <= ENDING;
                    end if;

                when ENDING  =>
                    sFlush_pending  <= '0';
                    if sTOP_Valid = '1' or sRaise_valid = '1' then
                        sTOP_InsertCount  <= 0;
                        sTOP_Sync_RST    <= '1';
                        state  <= IDLE;
                    end if;
                    
                when others => state <= IDLE; --@suppress
            end case;

        end if;
    end process;

end Behavioral;
