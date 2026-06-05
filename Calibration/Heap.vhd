--!@file Heap.vhd
--!@brief Heap of RAM pointers. The heap array stores addresses, not data.
--!@details The data values remain in the external shared RAM. During heapify the
--!         module reads the RAM addresses stored in the heap and compares the
--!         returned values as signed numbers. The root address and root data are
--!         cached and exposed to SMA.
--!@author Luca Russo
--!@date 05/06/2026
--!@version 1.1

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.FOOTpackage.all;
use work.basic_package.all;

entity Heap is
    generic (
        pHEAP_SIZE   : natural := cHEAP_SIZE;
        pADDR_WIDTH  : natural := ceil_log2(cFE_CHANNELS);
        pDATA_WIDTH  : natural := cADC_DATA_WIDTH;
        pIS_MAX_HEAP : boolean := true
    );
    port (
        iCLK : in std_logic;
        iRST : in std_logic;

        -- Command interface ---------------------------------------------------
        -- iCMD_op = "00" insert pointer
        -- iCMD_op = "01" replace root pointer
        -- iCMD_op = "10" clear heap pointers
        iCMD_en   : in std_logic;
        iCMD_op   : in std_logic_vector(1 downto 0);
        iCMD_addr : in std_logic_vector(pADDR_WIDTH-1 downto 0);
        iCMD_data : in std_logic_vector(pDATA_WIDTH-1 downto 0);

        -- External RAM read ports --------------------------------------------
        oRAM_rd_en_a   : out std_logic;
        oRAM_rd_addr_a : out std_logic_vector(pADDR_WIDTH-1 downto 0);
        iRAM_rd_data_a : in  std_logic_vector(pDATA_WIDTH-1 downto 0);

        oRAM_rd_en_b   : out std_logic;
        oRAM_rd_addr_b : out std_logic_vector(pADDR_WIDTH-1 downto 0);
        iRAM_rd_data_b : in  std_logic_vector(pDATA_WIDTH-1 downto 0);

        -- Status --------------------------------------------------------------
        oBusy      : out std_logic;
        oDone      : out std_logic;
        oCount     : out integer range 0 to pHEAP_SIZE;
        oRoot_addr : out std_logic_vector(pADDR_WIDTH-1 downto 0);
        oRoot_data : out std_logic_vector(pDATA_WIDTH-1 downto 0);
        oEmpty     : out std_logic;
        oFull      : out std_logic
    );
end entity Heap;

architecture Behavioral of Heap is

    constant cCMD_INSERT       : std_logic_vector(1 downto 0) := "00";
    constant cCMD_REPLACE_ROOT : std_logic_vector(1 downto 0) := "01";
    constant cCMD_CLEAR        : std_logic_vector(1 downto 0) := "10";

    type tState is (
        IDLE,
        UP_READ_PARENT,
        UP_COMPARE_PARENT,
        DOWN_READ_CHILDREN,
        DOWN_COMPARE_CHILDREN
    );

    type tHeapArray is array (0 to pHEAP_SIZE-1) of std_logic_vector(pADDR_WIDTH-1 downto 0);

    signal sState : tState := IDLE;
    signal sHeap  : tHeapArray := (others => (others => '0'));

    signal sCount : integer range 0 to pHEAP_SIZE := 0;

    signal sMoveAddr : std_logic_vector(pADDR_WIDTH-1 downto 0) := (others => '0');
    signal sMoveData : std_logic_vector(pDATA_WIDTH-1 downto 0) := (others => '0');

    signal sIdx       : integer range 0 to pHEAP_SIZE := 0;
    signal sParentIdx : integer range 0 to pHEAP_SIZE := 0;
    signal sLeftIdx   : integer range 0 to pHEAP_SIZE := 0;
    signal sRightIdx  : integer range 0 to pHEAP_SIZE := 0;

    signal sHaveLeft  : std_logic := '0';
    signal sHaveRight : std_logic := '0';

    signal sRootAddr : std_logic_vector(pADDR_WIDTH-1 downto 0) := (others => '0');
    signal sRootData : std_logic_vector(pDATA_WIDTH-1 downto 0) := (others => '0');

    signal sDone : std_logic := '0';

    function f_has_priority(a : signed; b : signed) return boolean is
    begin
        if pIS_MAX_HEAP then
            return a > b;
        else
            return a < b;
        end if;
    end function;

begin

    oCount     <= sCount;
    oRoot_addr <= sRootAddr;
    oRoot_data <= sRootData;
    oDone      <= sDone;
    oBusy      <= '1' when sState /= IDLE else '0';
    oEmpty     <= '1' when sCount = 0 else '0';
    oFull      <= '1' when sCount = pHEAP_SIZE else '0';

    -- Read addresses are driven only in the states that issue RAM reads.
    process(sState, sParentIdx, sLeftIdx, sRightIdx, sHaveLeft, sHaveRight, sHeap)
    begin
        oRAM_rd_en_a   <= '0';
        oRAM_rd_addr_a <= (others => '0');
        oRAM_rd_en_b   <= '0';
        oRAM_rd_addr_b <= (others => '0');

        if sState = UP_READ_PARENT then
            oRAM_rd_en_a   <= '1';
            oRAM_rd_addr_a <= sHeap(sParentIdx);

        elsif sState = DOWN_READ_CHILDREN then
            if sHaveLeft = '1' then
                oRAM_rd_en_a   <= '1';
                oRAM_rd_addr_a <= sHeap(sLeftIdx);
            end if;

            if sHaveRight = '1' then
                oRAM_rd_en_b   <= '1';
                oRAM_rd_addr_b <= sHeap(sRightIdx);
            end if;
        end if;
    end process;

    process(iCLK, iRST)
        variable vBestIdx  : integer range 0 to pHEAP_SIZE;
        variable vBestAddr : std_logic_vector(pADDR_WIDTH-1 downto 0);
        variable vBestData : std_logic_vector(pDATA_WIDTH-1 downto 0);
        variable vLeft     : integer; --@suppress
        variable vRight    : integer; --@suppress
    begin
        if iRST = '1' then
            sState     <= IDLE;
            sHeap      <= (others => (others => '0'));
            sCount     <= 0;
            sMoveAddr  <= (others => '0');
            sMoveData  <= (others => '0');
            sIdx       <= 0;
            sParentIdx <= 0;
            sLeftIdx   <= 0;
            sRightIdx  <= 0;
            sHaveLeft  <= '0';
            sHaveRight <= '0';
            sRootAddr  <= (others => '0');
            sRootData  <= (others => '0');
            sDone      <= '0';

        elsif rising_edge(iCLK) then
            sDone <= '0';

            case sState is
                when IDLE =>
                    if iCMD_en = '1' then
                        if iCMD_op = cCMD_CLEAR then
                            sHeap      <= (others => (others => '0'));
                            sCount     <= 0;
                            sRootAddr  <= (others => '0');
                            sRootData  <= (others => '0');
                            sDone      <= '1';

                        elsif iCMD_op = cCMD_INSERT then
                            if sCount = pHEAP_SIZE then
                                -- SMA should avoid this case. The command is ignored safely.
                                sDone <= '1';

                            elsif sCount = 0 then
                                sHeap(0)   <= iCMD_addr;
                                sCount     <= 1;
                                sRootAddr  <= iCMD_addr;
                                sRootData  <= iCMD_data;
                                sDone      <= '1';

                            else
                                sMoveAddr  <= iCMD_addr;
                                sMoveData  <= iCMD_data;
                                sIdx       <= sCount;
                                sParentIdx <= (sCount - 1) / 2;
                                sState     <= UP_READ_PARENT;
                            end if;

                        elsif iCMD_op = cCMD_REPLACE_ROOT then
                            if sCount = 0 then
                                -- Empty replace behaves like insert.
                                sHeap(0)   <= iCMD_addr;
                                sCount     <= 1;
                                sRootAddr  <= iCMD_addr;
                                sRootData  <= iCMD_data;
                                sDone      <= '1';

                            elsif sCount = 1 then
                                sHeap(0)   <= iCMD_addr;
                                sRootAddr  <= iCMD_addr;
                                sRootData  <= iCMD_data;
                                sDone      <= '1';

                            else
                                sMoveAddr  <= iCMD_addr;
                                sMoveData  <= iCMD_data;
                                sIdx       <= 0;
                                sLeftIdx   <= 1;
                                sRightIdx  <= 2;
                                sHaveLeft  <= '1';
                                if 2 < sCount then
                                    sHaveRight <= '1';
                                else
                                    sHaveRight <= '0';
                                end if;
                                sState <= DOWN_READ_CHILDREN;
                            end if;
                        end if;
                    end if;

                when UP_READ_PARENT =>
                    -- Address has been driven for one cycle. Data will be checked
                    -- at the next rising edge.
                    sState <= UP_COMPARE_PARENT;

                when UP_COMPARE_PARENT =>
                    if f_has_priority(signed(sMoveData), signed(iRAM_rd_data_a)) then
                        -- Parent goes down. Moving item continues upward.
                        sHeap(sIdx) <= sHeap(sParentIdx);

                        if sParentIdx = 0 then
                            sHeap(0)   <= sMoveAddr;
                            sRootAddr  <= sMoveAddr;
                            sRootData  <= sMoveData;
                            sCount     <= sCount + 1;
                            sDone      <= '1';
                            sState     <= IDLE;
                        else
                            sIdx       <= sParentIdx;
                            sParentIdx <= (sParentIdx - 1) / 2;
                            sState     <= UP_READ_PARENT;
                        end if;
                    else
                        -- Correct position found.
                        sHeap(sIdx) <= sMoveAddr;
                        sCount      <= sCount + 1;
                        sDone       <= '1';
                        sState      <= IDLE;
                    end if;

                when DOWN_READ_CHILDREN =>
                    sState <= DOWN_COMPARE_CHILDREN;

                when DOWN_COMPARE_CHILDREN =>
                    -- Select child with higher priority.
                    vBestIdx  := sLeftIdx;
                    vBestAddr := sHeap(sLeftIdx);
                    vBestData := iRAM_rd_data_a;

                    if sHaveRight = '1' then
                        if f_has_priority(signed(iRAM_rd_data_b), signed(iRAM_rd_data_a)) then
                            vBestIdx  := sRightIdx;
                            vBestAddr := sHeap(sRightIdx);
                            vBestData := iRAM_rd_data_b;
                        end if;
                    end if;

                    if f_has_priority(signed(vBestData), signed(sMoveData)) then
                        -- Best child goes up.
                        sHeap(sIdx) <= vBestAddr;

                        if sIdx = 0 then
                            sRootAddr <= vBestAddr;
                            sRootData <= vBestData;
                        end if;

                        vLeft  := (2 * vBestIdx) + 1;
                        vRight := (2 * vBestIdx) + 2;

                        if vLeft >= sCount then
                            -- No more children: place moving pointer here.
                            sHeap(vBestIdx) <= sMoveAddr;
                            sDone           <= '1';
                            sState          <= IDLE;
                        else
                            sIdx      <= vBestIdx;
                            sLeftIdx  <= vLeft;
                            sRightIdx <= vRight;
                            sHaveLeft <= '1';
                            if vRight < sCount then
                                sHaveRight <= '1';
                            else
                                sHaveRight <= '0';
                            end if;
                            sState <= DOWN_READ_CHILDREN;
                        end if;
                    else
                        -- Moving pointer belongs here.
                        sHeap(sIdx) <= sMoveAddr;
                        if sIdx = 0 then
                            sRootAddr <= sMoveAddr;
                            sRootData <= sMoveData;
                        end if;
                        sDone  <= '1';
                        sState <= IDLE;
                    end if;
            end case;
        end if;
    end process;

end architecture Behavioral;
