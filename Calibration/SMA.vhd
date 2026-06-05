--!@file SMA.vhd
--!@brief Streaming Median Algorithm controller using pointer heaps and external RAM.
--!@details SMA receives the value and the RAM address of each newly written sample.
--!         It does not store the sample in heap arrays. It stores only RAM addresses
--!         inside two heaps and reads the shared RAM only when heap comparisons are
--!         required. The output is the median value, not the median address.
--!@author Luca Russo
--!@date 05/06/2026
--!@version 1.1

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.FOOTpackage.all;
use work.basic_package.all;

entity StreamingMedian is
    generic (
        pHEAP_SIZE  : natural := cHEAP_SIZE; -- Each heap size. Total SMA window = 2*pHEAP_SIZE.
        pADDR_WIDTH : natural := ceil_log2(cFE_CHANNELS);
        pDATA_WIDTH : natural := cADC_DATA_WIDTH;
        pCALC_MODE  : natural := 0  -- 0 average roots, 1 MinRoot, >1 MaxRoot
    );
    port (
        iCLK : in std_logic;
        iRST : in std_logic;

        -- New sample already written in the shared RAM ------------------------
        iINS_en   : in std_logic;
        iINS_data : in std_logic_vector(pDATA_WIDTH-1 downto 0);
        iINS_addr : in std_logic_vector(pADDR_WIDTH-1 downto 0);
        iFlush    : in std_logic;
        oReady    : out std_logic;

        -- Shared RAM control request -----------------------------------------
        oRAM_req   : out std_logic;
        iRAM_grant : in  std_logic;

        -- Shared RAM read ports, available only when iRAM_grant = '1' ---------
        oRAM_rd_en_a   : out std_logic;
        oRAM_rd_addr_a : out std_logic_vector(pADDR_WIDTH-1 downto 0);
        iRAM_rd_data_a : in  std_logic_vector(pDATA_WIDTH-1 downto 0);

        oRAM_rd_en_b   : out std_logic;
        oRAM_rd_addr_b : out std_logic_vector(pADDR_WIDTH-1 downto 0);
        iRAM_rd_data_b : in  std_logic_vector(pDATA_WIDTH-1 downto 0);

        -- Median
        oMedian   : out std_logic_vector(pDATA_WIDTH-1 downto 0);
        oValid    : out std_logic;
        oBusy_SMA : out std_logic
    );
end entity StreamingMedian;

architecture Behavioral of StreamingMedian is

    constant cCMD_INSERT       : std_logic_vector(1 downto 0) := "00";
    constant cCMD_REPLACE_ROOT : std_logic_vector(1 downto 0) := "01";

    type tState is (
        IDLE,
        CLEAR_HEAPS,
        WAIT_RAM_GRANT,
        DECIDE_OPS,
        START_OP1,
        WAIT_OP1,
        START_OP2,
        WAIT_OP2,
        CALC_MEDIAN,
        RELEASE_RAM
    );

    type tHeapSel is (SEL_MAX, SEL_MIN);

    signal sState : tState := IDLE;

    signal sKeepData : std_logic_vector(pDATA_WIDTH-1 downto 0) := (others => '0');
    signal sKeepAddr : std_logic_vector(pADDR_WIDTH-1 downto 0) := (others => '0');

    -- Operation queue: at most two sequential heap operations are needed.
    signal sOp1Heap : tHeapSel := SEL_MAX;
    signal sOp1Cmd  : std_logic_vector(1 downto 0) := cCMD_INSERT;
    signal sOp1Addr : std_logic_vector(pADDR_WIDTH-1 downto 0) := (others => '0');
    signal sOp1Data : std_logic_vector(pDATA_WIDTH-1 downto 0) := (others => '0');

    signal sOp2Valid : std_logic := '0';
    signal sOp2Heap  : tHeapSel := SEL_MAX;
    signal sOp2Cmd   : std_logic_vector(1 downto 0) := cCMD_INSERT;
    signal sOp2Addr  : std_logic_vector(pADDR_WIDTH-1 downto 0) := (others => '0');
    signal sOp2Data  : std_logic_vector(pDATA_WIDTH-1 downto 0) := (others => '0');

    signal sActiveHeap : tHeapSel := SEL_MAX;

    -- MaxHeap command/status --------------------------------------------------
    signal sMaxRst      : std_logic := '0';
    signal sMaxRstInt   : std_logic := '0';
    signal sMaxCmdEn    : std_logic := '0';
    signal sMaxCmdOp    : std_logic_vector(1 downto 0) := (others => '0');
    signal sMaxCmdAddr  : std_logic_vector(pADDR_WIDTH-1 downto 0) := (others => '0');
    signal sMaxCmdData  : std_logic_vector(pDATA_WIDTH-1 downto 0) := (others => '0');
    signal sMaxBusy     : std_logic; --@suppress
    signal sMaxDone     : std_logic;
    signal sMaxCount    : integer range 0 to pHEAP_SIZE;
    signal sMaxRootAddr : std_logic_vector(pADDR_WIDTH-1 downto 0);
    signal sMaxRootData : std_logic_vector(pDATA_WIDTH-1 downto 0);

    signal sMaxRamEnA   : std_logic;
    signal sMaxRamAddrA : std_logic_vector(pADDR_WIDTH-1 downto 0);
    signal sMaxRamEnB   : std_logic;
    signal sMaxRamAddrB : std_logic_vector(pADDR_WIDTH-1 downto 0);

    -- MinHeap command/status --------------------------------------------------
    signal sMinRst      : std_logic := '0';
    signal sMinRstInt   : std_logic := '0';
    signal sMinCmdEn    : std_logic := '0';
    signal sMinCmdOp    : std_logic_vector(1 downto 0) := (others => '0');
    signal sMinCmdAddr  : std_logic_vector(pADDR_WIDTH-1 downto 0) := (others => '0');
    signal sMinCmdData  : std_logic_vector(pDATA_WIDTH-1 downto 0) := (others => '0');
    signal sMinBusy     : std_logic; --@suppress
    signal sMinDone     : std_logic;
    signal sMinCount    : integer range 0 to pHEAP_SIZE;
    signal sMinRootAddr : std_logic_vector(pADDR_WIDTH-1 downto 0);
    signal sMinRootData : std_logic_vector(pDATA_WIDTH-1 downto 0);

    signal sMinRamEnA   : std_logic;
    signal sMinRamAddrA : std_logic_vector(pADDR_WIDTH-1 downto 0);
    signal sMinRamEnB   : std_logic;
    signal sMinRamAddrB : std_logic_vector(pADDR_WIDTH-1 downto 0);

    signal sMedian : std_logic_vector(pDATA_WIDTH-1 downto 0) := (others => '0');

    constant cTOTAL_SIZE : integer := 2 * pHEAP_SIZE;

    function f_calc_median(
        max_root  : std_logic_vector(pDATA_WIDTH-1 downto 0);
        min_root  : std_logic_vector(pDATA_WIDTH-1 downto 0);
        max_count : integer;
        min_count : integer;
        mode      : natural
    ) return std_logic_vector is
        variable vSum : signed(pDATA_WIDTH downto 0);
        variable vAvg : signed(pDATA_WIDTH downto 0);
    begin
        if (max_count = 0) and (min_count = 0) then
            return (max_root'range => '0');

        elsif max_count = min_count then
            if mode = 0 then
                vSum := resize(signed(max_root), pDATA_WIDTH+1) +
                        resize(signed(min_root), pDATA_WIDTH+1);
                vAvg := shift_right(vSum, 1);
                return std_logic_vector(vAvg(pDATA_WIDTH-1 downto 0));
            elsif mode = 1 then
                return min_root;
            else
                return max_root;
            end if;

        else
            -- Keep the same convention used by FOOTpackage.CalcMedian.
            return max_root;
        end if;
    end function;

begin

    sMaxRstInt <= iRST or sMaxRst;
    sMinRstInt <= iRST or sMinRst;

    MAX_HEAP : Heap
        generic map (
            pHEAP_SIZE   => pHEAP_SIZE,
            pADDR_WIDTH  => pADDR_WIDTH,
            pDATA_WIDTH  => pDATA_WIDTH,
            pIS_MAX_HEAP => true
        )
        port map (
            iCLK => iCLK,
            iRST => sMaxRstInt,

            iCMD_en   => sMaxCmdEn,
            iCMD_op   => sMaxCmdOp,
            iCMD_addr => sMaxCmdAddr,
            iCMD_data => sMaxCmdData,

            oRAM_rd_en_a   => sMaxRamEnA,
            oRAM_rd_addr_a => sMaxRamAddrA,
            iRAM_rd_data_a => iRAM_rd_data_a,
            oRAM_rd_en_b   => sMaxRamEnB,
            oRAM_rd_addr_b => sMaxRamAddrB,
            iRAM_rd_data_b => iRAM_rd_data_b,

            oBusy      => sMaxBusy,
            oDone      => sMaxDone,
            oCount     => sMaxCount,
            oRoot_addr => sMaxRootAddr,
            oRoot_data => sMaxRootData,
            oEmpty     => open,
            oFull      => open
        );

    MIN_HEAP : Heap
        generic map (
            pHEAP_SIZE   => pHEAP_SIZE,
            pADDR_WIDTH  => pADDR_WIDTH,
            pDATA_WIDTH  => pDATA_WIDTH,
            pIS_MAX_HEAP => false
        )
        port map (
            iCLK => iCLK,
            iRST => sMinRstInt,

            iCMD_en   => sMinCmdEn,
            iCMD_op   => sMinCmdOp,
            iCMD_addr => sMinCmdAddr,
            iCMD_data => sMinCmdData,

            oRAM_rd_en_a   => sMinRamEnA,
            oRAM_rd_addr_a => sMinRamAddrA,
            iRAM_rd_data_a => iRAM_rd_data_a,
            oRAM_rd_en_b   => sMinRamEnB,
            oRAM_rd_addr_b => sMinRamAddrB,
            iRAM_rd_data_b => iRAM_rd_data_b,

            oBusy      => sMinBusy,
            oDone      => sMinDone,
            oCount     => sMinCount,
            oRoot_addr => sMinRootAddr,
            oRoot_data => sMinRootData,
            oEmpty     => open,
            oFull      => open
        );

    -- Only one heap is allowed to access the RAM at a time.
    -- On both ports to read two samples
    oRAM_rd_en_a   <= sMaxRamEnA   when sActiveHeap = SEL_MAX else sMinRamEnA;
    oRAM_rd_addr_a <= sMaxRamAddrA when sActiveHeap = SEL_MAX else sMinRamAddrA;
    oRAM_rd_en_b   <= sMaxRamEnB   when sActiveHeap = SEL_MAX else sMinRamEnB;
    oRAM_rd_addr_b <= sMaxRamAddrB when sActiveHeap = SEL_MAX else sMinRamAddrB;

    oRAM_req <= '1' when (sState = WAIT_RAM_GRANT or
                          sState = DECIDE_OPS or
                          sState = START_OP1 or
                          sState = WAIT_OP1 or
                          sState = START_OP2 or
                          sState = WAIT_OP2) else '0';

    oReady    <= '1' when sState = IDLE else '0';
    oBusy_SMA <= '0' when sState = IDLE else '1';
    oMedian   <= sMedian;

    process(iCLK, iRST)
    begin
        if iRST = '1' then
            sState      <= IDLE;
            sKeepData   <= (others => '0');
            sKeepAddr   <= (others => '0');
            sOp1Heap    <= SEL_MAX;
            sOp1Cmd     <= cCMD_INSERT;
            sOp1Addr    <= (others => '0');
            sOp1Data    <= (others => '0');
            sOp2Valid   <= '0';
            sOp2Heap    <= SEL_MAX;
            sOp2Cmd     <= cCMD_INSERT;
            sOp2Addr    <= (others => '0');
            sOp2Data    <= (others => '0');
            sActiveHeap <= SEL_MAX;
            sMaxRst     <= '1';
            sMinRst     <= '1';
            sMaxCmdEn   <= '0';
            sMinCmdEn   <= '0';
            sMaxCmdOp   <= cCMD_INSERT;
            sMinCmdOp   <= cCMD_INSERT;
            sMaxCmdAddr <= (others => '0');
            sMinCmdAddr <= (others => '0');
            sMaxCmdData <= (others => '0');
            sMinCmdData <= (others => '0');
            sMedian     <= (others => '0');
            oValid      <= '0';

        elsif rising_edge(iCLK) then
            sMaxRst   <= '0';
            sMinRst   <= '0';
            sMaxCmdEn <= '0';
            sMinCmdEn <= '0';
            oValid    <= '0';

            case sState is
                when IDLE =>
                    sOp2Valid <= '0';

                    if iFlush = '1' then
                        sMedian <= f_calc_median(
                            sMaxRootData,
                            sMinRootData,
                            sMaxCount,
                            sMinCount,
                            pCALC_MODE
                        );
                        oValid <= '1';

                    elsif (sMaxCount + sMinCount) = cTOTAL_SIZE then
                        -- The RAM contents are not cleared. Only SMA pointers are reset.
                        sMaxRst <= '1';
                        sMinRst <= '1';

                        if iINS_en = '1' then
                            sKeepData <= iINS_data;
                            sKeepAddr <= iINS_addr;
                            sState    <= CLEAR_HEAPS;
                        end if;

                    elsif iINS_en = '1' then
                        sKeepData <= iINS_data;
                        sKeepAddr <= iINS_addr;
                        sState    <= WAIT_RAM_GRANT;
                    end if;

                when CLEAR_HEAPS =>
                    -- One cycle is enough to propagate the clear to both heaps.
                    sState <= WAIT_RAM_GRANT;

                when WAIT_RAM_GRANT =>
                    if iRAM_grant = '1' then
                        sState <= DECIDE_OPS;
                    end if;

                when DECIDE_OPS =>
                    sOp2Valid <= '0';

                    if (sMaxCount = 0) and (sMinCount = 0) then
                        sOp1Heap <= SEL_MAX;
                        sOp1Cmd  <= cCMD_INSERT;
                        sOp1Addr <= sKeepAddr;
                        sOp1Data <= sKeepData;

                    elsif sMaxCount > sMinCount then
                        if signed(sKeepData) >= signed(sMaxRootData) then
                            sOp1Heap <= SEL_MIN;
                            sOp1Cmd  <= cCMD_INSERT;
                            sOp1Addr <= sKeepAddr;
                            sOp1Data <= sKeepData;
                        else
                            -- old Max root moves to MinHeap, new pointer replaces Max root
                            sOp1Heap <= SEL_MIN;
                            sOp1Cmd  <= cCMD_INSERT;
                            sOp1Addr <= sMaxRootAddr;
                            sOp1Data <= sMaxRootData;

                            sOp2Valid <= '1';
                            sOp2Heap  <= SEL_MAX;
                            sOp2Cmd   <= cCMD_REPLACE_ROOT;
                            sOp2Addr  <= sKeepAddr;
                            sOp2Data  <= sKeepData;
                        end if;

                    elsif sMaxCount = sMinCount then
                        if (sMinCount = 0) or (signed(sKeepData) <= signed(sMinRootData)) then
                            sOp1Heap <= SEL_MAX;
                            sOp1Cmd  <= cCMD_INSERT;
                            sOp1Addr <= sKeepAddr;
                            sOp1Data <= sKeepData;
                        else
                            -- old Min root moves to MaxHeap, new pointer replaces Min root
                            sOp1Heap <= SEL_MAX;
                            sOp1Cmd  <= cCMD_INSERT;
                            sOp1Addr <= sMinRootAddr;
                            sOp1Data <= sMinRootData;

                            sOp2Valid <= '1';
                            sOp2Heap  <= SEL_MIN;
                            sOp2Cmd   <= cCMD_REPLACE_ROOT;
                            sOp2Addr  <= sKeepAddr;
                            sOp2Data  <= sKeepData;
                        end if;

                    else
                        -- Safety branch. Normally MinHeap should not become larger.
                        if signed(sKeepData) <= signed(sMinRootData) then
                            sOp1Heap <= SEL_MAX;
                            sOp1Cmd  <= cCMD_INSERT;
                            sOp1Addr <= sKeepAddr;
                            sOp1Data <= sKeepData;
                        else
                            sOp1Heap <= SEL_MAX;
                            sOp1Cmd  <= cCMD_INSERT;
                            sOp1Addr <= sMinRootAddr;
                            sOp1Data <= sMinRootData;

                            sOp2Valid <= '1';
                            sOp2Heap  <= SEL_MIN;
                            sOp2Cmd   <= cCMD_REPLACE_ROOT;
                            sOp2Addr  <= sKeepAddr;
                            sOp2Data  <= sKeepData;
                        end if;
                    end if;

                    sState <= START_OP1;

                when START_OP1 =>
                    sActiveHeap <= sOp1Heap;
                    if sOp1Heap = SEL_MAX then
                        sMaxCmdOp   <= sOp1Cmd;
                        sMaxCmdAddr <= sOp1Addr;
                        sMaxCmdData <= sOp1Data;
                        sMaxCmdEn   <= '1';
                    else
                        sMinCmdOp   <= sOp1Cmd;
                        sMinCmdAddr <= sOp1Addr;
                        sMinCmdData <= sOp1Data;
                        sMinCmdEn   <= '1';
                    end if;
                    sState <= WAIT_OP1;

                when WAIT_OP1 =>
                    if ((sActiveHeap = SEL_MAX) and (sMaxDone = '1')) or
                       ((sActiveHeap = SEL_MIN) and (sMinDone = '1')) then
                        if sOp2Valid = '1' then
                            sState <= START_OP2;
                        else
                            sState <= CALC_MEDIAN;
                        end if;
                    end if;

                when START_OP2 =>
                    sActiveHeap <= sOp2Heap;
                    if sOp2Heap = SEL_MAX then
                        sMaxCmdOp   <= sOp2Cmd;
                        sMaxCmdAddr <= sOp2Addr;
                        sMaxCmdData <= sOp2Data;
                        sMaxCmdEn   <= '1';
                    else
                        sMinCmdOp   <= sOp2Cmd;
                        sMinCmdAddr <= sOp2Addr;
                        sMinCmdData <= sOp2Data;
                        sMinCmdEn   <= '1';
                    end if;
                    sState <= WAIT_OP2;

                when WAIT_OP2 =>
                    if ((sActiveHeap = SEL_MAX) and (sMaxDone = '1')) or
                       ((sActiveHeap = SEL_MIN) and (sMinDone = '1')) then
                        sState <= CALC_MEDIAN;
                    end if;

                when CALC_MEDIAN =>
                    sMedian <= f_calc_median(
                        sMaxRootData,
                        sMinRootData,
                        sMaxCount,
                        sMinCount,
                        pCALC_MODE
                    );
                    oValid <= '1';
                    sState <= RELEASE_RAM;

                when RELEASE_RAM =>
                    sState <= IDLE;
            end case;
        end if;
    end process;

end architecture Behavioral;
