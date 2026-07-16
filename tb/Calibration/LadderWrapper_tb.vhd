--!@file LadderWrapper_tb.vhd
--!@brief TestBench to test ladder wrapper. Uses AMS RAW_DATA as input file.
--!@author Luca Russo, luca.russo@cern.ch, luca.russo912@gmail.com
--!@date 19/05/2025
--!@version 1.0.1 - 19/05/2025 -

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.basic_package.all;
use work.FOOTpackage.all;

use std.textio.all;
use ieee.std_logic_textio.all;

entity LadderWrapper_tb is
end entity LadderWrapper_tb;

architecture tb of LadderWrapper_tb is
    -- Clock period definition
    constant CLK_PERIOD : time := 10 ns;

    -- Timing specs
    constant TRIG_GAP : time := 100 us; -- distance between TRIG rising edges
    constant PUTD_GAP : time := 1 us;   -- distance between PUTD rising edges

    -- DUT generics
    constant TB_DATA_WIDTH  : natural := cADC_DATA_WIDTH; -- (tipicamente 16 bit)
    constant TB_ADC_STRIPS  : natural := cADC_CHANNELS;   -- 128
    constant TB_HEAP_SIZE   : natural := cHEAP_SIZE;
    constant TB_ADC_NUM     : natural := cTOTAL_ADCS;
    constant TB_WADDR_WIDTH : natural := ceil_log2(TB_ADC_NUM * TB_ADC_STRIPS);

    -- DUT event.
    -- FOOT receives TB_ADC_NUM ADCs in parallel, each with TB_ADC_STRIPS samples.
    constant C_SAMPLES_EVENT : natural := TB_ADC_NUM * TB_ADC_STRIPS;

    -- Geometry of the legacy RAW_ADC.txt file imported from *AMS*:
    -- 8 ADCs, 128 strips per ADC
    constant C_RAW_ADC_NUM       : natural := 8;
    constant C_RAW_ADC_STRIPS    : natural := 128;
    constant C_RAW_SAMPLES_EVENT : natural := C_RAW_ADC_NUM * C_RAW_ADC_STRIPS;
    constant C_RAW_FRAC_ZEROS    : natural := 2; -- Number of frac zeros to add to RAW_ADC, for FOOT the input for iWORD is 00 xxxx xxxx xxxx 00 ADC4

    -- Each of the first three calibration phases sends 1024 events.
    constant C_CAL_EVENTS_PER_PHASE : natural := 1024;

    constant C_TRIG_GAP_CYCLES : natural := TRIG_GAP / CLK_PERIOD;
    constant C_PUTD_GAP_CYCLES : natural := PUTD_GAP / CLK_PERIOD;

    

    -- DUT inputs
    signal iCLK               : std_logic := '0';
    signal iRST               : std_logic := '1';
    signal iWord              : t_FOOT_lef_data := (others => (others => '0'));
    signal iPutd              : std_logic := '0';
    signal iTrig              : std_logic := '0';
    signal iFull              : std_logic := '0';
    signal iCalibrationEnable : std_logic := '0';
    signal iHostControl       : std_logic_vector(7 downto 0) := (others => '0');
    signal iEventEnable       : std_logic := '1'; -- enable EVENT path--@suppress

    -- DUT outputs (main)
    signal oTrigLost   : std_logic;--@suppress
    signal oCEnable    : std_logic;--@suppress
    signal oVERAM      : std_logic;--@suppress
    signal oLadderBusy : std_logic;

    -- Event RAM outputs
    signal oER_WE     : std_logic;
    signal oER_W_ADDR : std_logic_vector(TB_WADDR_WIDTH-1 downto 0);
    signal oER_DATA   : std_logic_vector(TB_DATA_WIDTH-1 downto 0);

    -- Direct calibration RAM interface
    signal sPedIn_Cal    : CalibCompIN := (
        DATA  => (others => (others => '0')),
        WADDR => (others => '0'),
        RADDR => (others => '0'),
        WE    => '0'
    );
    signal sSigRawIn_Cal : CalibCompIN := (
        DATA  => (others => (others => '0')),
        WADDR => (others => '0'),
        RADDR => (others => '0'),
        WE    => '0'
    );
    signal sSigIn_Cal    : CalibCompIN := (
        DATA  => (others => (others => '0')),
        WADDR => (others => '0'),
        RADDR => (others => '0'),
        WE    => '0'
    );
    signal sFlgIn_Cal    : CalibCompIN := (
        DATA  => (others => (others => '0')),
        WADDR => (others => '0'),
        RADDR => (others => '0'),
        WE    => '0'
    );
    signal sPedOut_Cal    : CalibCompOUT;--@suppress
    signal sSigRawOut_Cal : CalibCompOUT;--@suppress
    signal sSigOut_Cal    : CalibCompOUT;--@suppress
    signal sFlgOut_Cal    : CalibCompOUT;--@suppress
    signal sLthOut_Cal    : CalibCompOUT;--@suppress
    signal sHthOut_Cal    : CalibCompOUT;--@suppress
    signal sRhtOut_Cal    : CalibCompOUT;--@suppress

    -- Phase marker for logs: 'C' (calib) / 'E' (event)
    signal sPhaseCE  : std_logic := '0'; -- '0' = C, '1' = E
    signal sEventCnt : integer := 0;     -- incremental id for log

    signal sK1 : std_logic_vector(TB_DATA_WIDTH-1 downto 0) := cLTH;
    signal sK2 : std_logic_vector(TB_DATA_WIDTH-1 downto 0) := cHTH;
    
    -- Full FOOT-side event buffer.
    type t_event_buf is array (0 to C_SAMPLES_EVENT-1) of integer;

    -- FILES (WRITE MODE)
    file f_event_ram : text open write_mode is "FOOT_V1_event_ram_log.txt";

    -- INPUT: convert a non-negative ADC sample to the current LEF word width.
    -- RAW_ADC.txt stores integer ADC values; zero-extensioning it.
    function int_to_lef_word(
        constant x                  : integer
    ) return std_logic_vector is
        variable xi      : integer := x;
        variable shifted : integer;
        variable maxv    : integer := (2**TB_DATA_WIDTH) - 1;--@suppress
    begin
        if xi < 0 then
            xi := 0;
        end if;

        shifted := xi * (2**C_RAW_FRAC_ZEROS);

        if shifted > maxv then
            shifted := maxv;
        end if;

        return std_logic_vector(to_unsigned(shifted, TB_DATA_WIDTH));
    end function;

    -- OUTPUT: signed Q12.3-like data used by the current datapath:
    function q12_3_to_real(d : std_logic_vector(TB_DATA_WIDTH-1 downto 0)) return real is
        variable si : integer;
    begin
        si := to_integer(signed(d));
        return real(si) / 8.0; -- Shift to obtain 3 frac bits
    end function;

    -- Print real with THREE decimal digits
    procedure write_real_3dp(variable L : inout line; constant x : in real) is
    begin
        write(L, x, right, 0, 3);
    end procedure;

    procedure wait_clk_cycles(signal clk : in std_logic; constant n : in natural) is
    begin
        for i in 1 to n loop
            wait until rising_edge(clk);
        end loop;
    end procedure;

    procedure pulse_putd(signal clk : in std_logic; signal putd : out std_logic) is
    begin
        wait until rising_edge(clk);
        putd <= '1';
        wait until rising_edge(clk);
        putd <= '0';
        if C_PUTD_GAP_CYCLES > 2 then
            wait_clk_cycles(clk, C_PUTD_GAP_CYCLES - 2);
        end if;
    end procedure;

    procedure pulse_trig(signal clk : in std_logic; signal trig : out std_logic) is
    begin
        wait_clk_cycles(clk, C_TRIG_GAP_CYCLES);
        trig <= '1';
        wait until rising_edge(clk);
        trig <= '0';
        if C_PUTD_GAP_CYCLES > 2 then
            wait_clk_cycles(clk, C_PUTD_GAP_CYCLES - 2);
        end if;
    end procedure;

    procedure pulse_host(signal clk : in std_logic; signal host : out std_logic_vector(7 downto 0); constant cmd : in std_logic_vector(7 downto 0)) is
    begin
        wait until rising_edge(clk);
        host <= cmd;
        wait until rising_edge(clk);
        host <= (others => '0');
    end procedure;

    procedure pulse_calib_request(
        signal clk  : in std_logic;
        signal cal  : out std_logic;
        signal host : out std_logic_vector(7 downto 0);
        constant cmd : in std_logic_vector(7 downto 0)
    ) is
    begin
        wait until rising_edge(clk);
        cal  <= '1';
        host <= cmd;
        wait until rising_edge(clk);
        cal  <= '0';
        host <= (others => '0');
    end procedure;

begin
    -- Instantiate the LadderWrapper
    dut: entity work.LadderWrapper
        generic map(
            pDATA_WIDTH  => TB_DATA_WIDTH,
            pADC_STRIPS  => TB_ADC_STRIPS,
            pHEAP_SIZE   => TB_HEAP_SIZE,
            pADC_NUM     => TB_ADC_NUM,
            pWADDR_WIDTH => TB_WADDR_WIDTH
        )
        port map(
            iCLK        => iCLK,
            iRST        => iRST,

            iWORD       => iWord,
            iPUTD       => iPutd,
            iTRIG       => iTrig,
            iFULL       => iFull,

            oTRIG_L     => oTrigLost,
            oCLUST_ENABLE  => oCEnable,
            oVALID_EVT_RAM => oVERAM,
            oEVENT_ACCEPTED => open,

            iCAL_ENABLE  => iCalibrationEnable,
            iEVT_ENABLE  => iEventEnable,
            iHOST_CONTROL => iHostControl,
            iK1         => sK1,
            iK2         => sK2,   
            oBUSY       => oLadderBusy,

            oER_WE      => oER_WE,
            oER_W_ADDR  => oER_W_ADDR,
            oER_DATA    => oER_DATA,

            iPED        => sPedIn_Cal,
            oPED        => sPedOut_Cal,
            iSIGRAW     => sSigRawIn_Cal,
            oSIGRAW     => sSigRawOut_Cal,
            iSIG        => sSigIn_Cal,
            oSIG        => sSigOut_Cal,
            iFLG        => sFlgIn_Cal,
            oFLG        => sFlgOut_Cal,
            oLTH        => sLthOut_Cal,
            oHTH        => sHthOut_Cal,
            oRHT        => sRhtOut_Cal
        );

    -- Clock generation
    clk_proc: process
    begin
        while true loop
            iCLK <= '1';
            wait for CLK_PERIOD/2;
            iCLK <= '0';
            wait for CLK_PERIOD/2;
        end loop;
    end process clk_proc;

    -- LOGGER: write when WE is asserted
    -- format: "C/E  event_id  addr  value"
    logger_proc: process(iCLK)
        variable L        : line;
        variable phase_ch : character;
        variable addr_i   : integer;
        variable val_r    : real;
    begin
        if rising_edge(iCLK) then
            if sPhaseCE = '0' then phase_ch := 'C'; else phase_ch := 'E'; end if;

            if oER_WE = '1' then
                addr_i := to_integer(unsigned(oER_W_ADDR));
                val_r  := q12_3_to_real(oER_DATA);

                write(L, phase_ch); write(L, string'(" "));
                write(L, sEventCnt); write(L, string'(" "));
                write(L, addr_i);    write(L, string'(" "));
                write_real_3dp(L, val_r);
                writeline(f_event_ram, L);
            end if;

        end if;
    end process logger_proc;

    -- Stimulus process
    stim_proc: process
        -- RAW input file: (id_evento  id_strip  dato)
        file f_raw : text open read_mode is "RAW_ADC.txt";
        variable buf       : t_event_buf;
        variable got_event : boolean;

        variable global_evt_cnt : integer := 0;

        -- Read one RAW_ADC event.
        -- ADCs that do not exist in RAW_ADC.txt remain zero.
        procedure read_next_event(
            file f : text;
            variable b  : out t_event_buf;
            variable ok : out boolean
        ) is
            variable l         : line;
            variable ev        : integer;--@suppress
            variable sid       : integer;
            variable val       : integer;
            variable k         : integer;
            variable raw_adc   : integer;
            variable raw_strip : integer;
            variable foot_idx  : integer;
        begin
            -- Zero the full FOOT event buffer first:
            -- this explicitly forces the additional FOOT ADCs to zero. 
            for i in 0 to C_SAMPLES_EVENT-1 loop
                b(i) := 0;
            end loop;

            ok := true;
            k := 0;

            -- RAW_ADC.txt contains exactly one legacy event every 1024 rows:
            -- 8 ADCs * 128 strips.
            while k < C_RAW_SAMPLES_EVENT loop
                if endfile(f) then
                    ok := false;
                    exit;
                end if;

                readline(f, l);
                read(l, ev);
                read(l, sid);
                read(l, val);

                -- Decode the old flattened RAW index.
                if (sid >= 0) and (sid < C_RAW_SAMPLES_EVENT) then
                    raw_adc   := sid / C_RAW_ADC_STRIPS;
                    raw_strip := sid mod C_RAW_ADC_STRIPS;

                    -- Map legacy ADCs/strips into the current FOOT buffer.
                    -- For FOOT10 from RAW8, adc=8 and adc=9 are never assigned
                    -- and therefore remain at the zero initialized above.
                    if (raw_adc >= 0) and (raw_adc < TB_ADC_NUM) and
                       (raw_strip >= 0) and (raw_strip < TB_ADC_STRIPS) then
                        foot_idx := raw_adc*TB_ADC_STRIPS + raw_strip;
                        b(foot_idx) := val;
                    end if;
                end if;

                k := k + 1;
            end loop;
        end procedure;

        -- Stream one full FOOT event with mapping:
        --   FOOT buffer index = adc*TB_ADC_STRIPS + strip
        -- Additional ADCs not present in the RAW file are streamed as zero.
        procedure stream_event(constant b : in t_event_buf) is
        begin
            for strip in 0 to TB_ADC_STRIPS-1 loop
                for adc in 0 to TB_ADC_NUM-1 loop
                    iWord(adc) <= int_to_lef_word(b(adc*TB_ADC_STRIPS + strip));
                end loop;
                pulse_putd(iCLK, iPutd);
            end loop;
        end procedure;

    begin
        -- guard (evita ForLoop fatal se qualche costante è 0, accaduto per errore)
        assert TB_ADC_NUM > 0 report "TB_ADC_NUM is 0" severity failure;
        assert TB_ADC_STRIPS > 0 report "TB_ADC_STRIPS is 0" severity failure;

        -- This TB reuses RAW_ADC.txt from the AMS 8-ADC design.
        -- FOOT has more ADCs; those extra ADC words are kept at zero.
        assert TB_ADC_NUM >= C_RAW_ADC_NUM
            report "TB_ADC_NUM is smaller than the 8 ADCs present in RAW_ADC.txt; the legacy RAW file would be truncated."
            severity warning;
        assert TB_ADC_STRIPS >= C_RAW_ADC_STRIPS
            report "TB_ADC_STRIPS is smaller than the 128 strips encoded in RAW_ADC.txt; the legacy RAW file would be truncated."
            severity warning;

        -- Apply asynchronous reset
        wait for 50 ns;
        wait until rising_edge(iCLK);
        iRST <= '0';

        -- Start calibration sequence (request)
        wait for 1000 ns;
        pulse_calib_request(iCLK, iCalibrationEnable, iHostControl, "10001010");

        wait until rising_edge(iCLK);
        ----------------------------------------------------------------------------
        -- PEDESTAL (CALIB) 1024 events
        ----------------------------------------------------------------------------
        report "=== Phase: PEDESTAL === at " & time'image(now) severity NOTE;
        sPhaseCE <= '0'; -- C

        for evt in 0 to C_CAL_EVENTS_PER_PHASE-1 loop
            read_next_event(f_raw, buf, got_event);
            assert got_event report "EOF while reading PEDESTAL events" severity failure;

            sEventCnt <= global_evt_cnt;
            wait for 0 ns;

            pulse_trig(iCLK, iTrig);
            stream_event(buf);

            global_evt_cnt := global_evt_cnt + 1;
        end loop;

        wait for 50 us;

        ----------------------------------------------------------------------------
        -- SIGMARAW (CALIB) 1024 events
        ----------------------------------------------------------------------------
        report "=== Phase: SIGMARAW === at " & time'image(now) severity NOTE;
        sPhaseCE <= '0'; -- C

        for evt in 0 to C_CAL_EVENTS_PER_PHASE-1 loop
            read_next_event(f_raw, buf, got_event);
            assert got_event report "EOF while reading SIGMARAW events" severity failure;

            sEventCnt <= global_evt_cnt;
            wait for 0 ns;

            pulse_trig(iCLK, iTrig);
            stream_event(buf);

            global_evt_cnt := global_evt_cnt + 1;
        end loop;

        wait for 50 us;

        ----------------------------------------------------------------------------
        -- SIGMA (CALIB) 1024 events
        ----------------------------------------------------------------------------
        report "=== Phase: SIGMA === at " & time'image(now) severity NOTE;
        sPhaseCE <= '0'; -- C

        for evt in 0 to C_CAL_EVENTS_PER_PHASE-1 loop
            read_next_event(f_raw, buf, got_event);
            assert got_event report "EOF while reading SIGMA events" severity failure;

            sEventCnt <= global_evt_cnt;
            wait for 0 ns;

            pulse_trig(iCLK, iTrig);
            stream_event(buf);

            global_evt_cnt := global_evt_cnt + 1;
        end loop;

        wait for 50 us;

        ----------------------------------------------------------------------------
        -- EVENT (E) 512 events
        ----------------------------------------------------------------------------
        report "=== Phase: EVENT === at " & time'image(now) severity NOTE;
        sPhaseCE <= '1'; -- E

        for evt in 0 to (C_CAL_EVENTS_PER_PHASE-1)/2 loop
            read_next_event(f_raw, buf, got_event);
            --exit when not got_event;

            sEventCnt <= global_evt_cnt;
            wait for 0 ns;

            pulse_trig(iCLK, iTrig);
            stream_event(buf);

            wait until oLadderBusy = '0';
            global_evt_cnt := global_evt_cnt + 1;
        end loop;

        -- TEST SCRITTURA THR con RICALCOLO, le TH nuove sono 2.5 e 5.5
        wait for 200 us;
        pulse_host(iCLK, iHostControl, "10000001");
        wait until rising_edge(iCLK);
        sK1  <= "0000000001010000"; -- Provo a caricare K1 come 2.5
        wait until rising_edge(iCLK);
        sK2  <= "0000000010110000"; -- Provo a caricare K2 come 5.5
        wait until rising_edge(iCLK);

        wait for 200 us;

        ----------------------------------------------------------------------------
        -- EVENT (E) 512 events
        ----------------------------------------------------------------------------
        report "=== Phase: EVENT === at " & time'image(now) severity NOTE;
        sPhaseCE <= '1'; -- E

        for evt in 0 to (C_CAL_EVENTS_PER_PHASE-1)/2 loop
            read_next_event(f_raw, buf, got_event);
            --exit when not got_event;

            sEventCnt <= global_evt_cnt;
            wait for 0 ns;

            pulse_trig(iCLK, iTrig);
            stream_event(buf);

            wait until oLadderBusy = '0';
            global_evt_cnt := global_evt_cnt + 1;
        end loop;
        
        -- Start calibration sequence (request)
        pulse_calib_request(iCLK, iCalibrationEnable, iHostControl, "10001010");
        wait until rising_edge(iCLK);
        sK1  <= "0000000001110000"; -- Provo a caricare K1 come 3.5
        wait until rising_edge(iCLK);
        sK2  <= "0000000011010000"; -- Provo a caricare K2 come 6.5
        wait until rising_edge(iCLK);

        ----------------------------------------------------------------------------
        -- PEDESTAL (CALIB) 1024 events
        ----------------------------------------------------------------------------
        report "=== Phase: PEDESTAL === at " & time'image(now) severity NOTE;
        sPhaseCE <= '0'; -- C

        for evt in 0 to C_CAL_EVENTS_PER_PHASE-1 loop
            read_next_event(f_raw, buf, got_event);
            assert got_event report "EOF while reading PEDESTAL events" severity failure;

            sEventCnt <= global_evt_cnt;
            wait for 0 ns;

            pulse_trig(iCLK, iTrig);
            stream_event(buf);

            global_evt_cnt := global_evt_cnt + 1;
        end loop;

        wait for 50 us;

        ----------------------------------------------------------------------------
        -- SIGMARAW (CALIB) 1024 events
        ----------------------------------------------------------------------------
        report "=== Phase: SIGMARAW === at " & time'image(now) severity NOTE;
        sPhaseCE <= '0'; -- C

        for evt in 0 to C_CAL_EVENTS_PER_PHASE-1 loop
            read_next_event(f_raw, buf, got_event);
            assert got_event report "EOF while reading SIGMARAW events" severity failure;

            sEventCnt <= global_evt_cnt;
            wait for 0 ns;

            pulse_trig(iCLK, iTrig);
            stream_event(buf);

            global_evt_cnt := global_evt_cnt + 1;
        end loop;

        wait for 50 us;

        ----------------------------------------------------------------------------
        -- SIGMA (CALIB) 1024 events
        ----------------------------------------------------------------------------
        report "=== Phase: SIGMA === at " & time'image(now) severity NOTE;
        sPhaseCE <= '0'; -- C

        for evt in 0 to C_CAL_EVENTS_PER_PHASE-1 loop
            read_next_event(f_raw, buf, got_event);
            assert got_event report "EOF while reading SIGMA events" severity failure;

            sEventCnt <= global_evt_cnt;
            wait for 0 ns;

            pulse_trig(iCLK, iTrig);
            stream_event(buf);

            global_evt_cnt := global_evt_cnt + 1;
        end loop;

        wait for 50 us;

        ----------------------------------------------------------------------------
        -- EVENT (E) until EOF
        ----------------------------------------------------------------------------
        report "=== Phase: EVENT === at " & time'image(now) severity NOTE;
        sPhaseCE <= '1'; -- E

        loop
            read_next_event(f_raw, buf, got_event);
            exit when not got_event;

            sEventCnt <= global_evt_cnt;
            wait for 0 ns;

            pulse_trig(iCLK, iTrig);
            stream_event(buf);

            wait until oLadderBusy = '0';
            global_evt_cnt := global_evt_cnt + 1;
        end loop;

        ----------------------------------------------------------------------------
        -- Wait end busy, then finish
        ----------------------------------------------------------------------------
        wait until oLadderBusy = '0';
        wait until rising_edge(iCLK);

        wait for 200 ns;
        report "LadderWrapper_tb: Simulation finished" severity note;
        assert false report "TB finished" severity failure;
        wait;
    end process stim_proc;

end architecture tb;
