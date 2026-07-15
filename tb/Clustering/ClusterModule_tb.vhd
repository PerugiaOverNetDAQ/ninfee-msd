--!@file ClusterModule_tb.vhd
--!@brief Testbench auto-verificante per il ClusterModule continuo

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.basic_package.all;
use work.FOOTpackage.all;

entity ClusterModule_tb is
end entity ClusterModule_tb;

architecture Behavioral of ClusterModule_tb is

  constant CLK_PERIOD : time := 10 ns;
  constant TRIG_GAP    : time := 200 us;

  constant cTB_ADC_NUM       : positive := cTOTAL_ADCS;
  constant cTB_ADC_STRIPS    : positive := cADC_CHANNELS;
  constant cTB_DATA_WIDTH    : positive := cADC_DATA_WIDTH;
  constant cTB_TOTAL_STRIPS  : positive := cTB_ADC_NUM*cTB_ADC_STRIPS;
  constant cTB_ADDR_WIDTH    : positive := ceil_log2(cTB_TOTAL_STRIPS);
  constant cMAX_EXPECTED     : positive := 4096;
  constant cHOLD_CLUSTERS    : positive := 70;

  subtype tAdcWord is std_logic_vector(cTB_DATA_WIDTH-1 downto 0);
  subtype tOutputWord is std_logic_vector(cTB_DATA_WIDTH downto 0);
  subtype tFlagWord is std_logic_vector(cTB_DATA_WIDTH-1 downto 0);

  type tAdcRam is array (0 to cTB_TOTAL_STRIPS-1) of tAdcWord;
  type tFlagRam is array (0 to cTB_TOTAL_STRIPS-1) of tFlagWord;
  type tExpectedRam is array (0 to cMAX_EXPECTED-1) of tOutputWord;

  function fADC8(iValue : real) return tAdcWord is
    variable vScaled : integer;
  begin
    vScaled := integer(iValue*8.0);
    assert vScaled >= -(2**(cTB_DATA_WIDTH-1)) and
           vScaled <=  (2**(cTB_DATA_WIDTH-1))-1
      report "fADC8: value outside the signed ADC8 range"
      severity failure;
    return std_logic_vector(to_signed(vScaled, cTB_DATA_WIDTH));
  end function fADC8;

  function fHeader(iAddress : natural) return tOutputWord is
  begin
    return '0' & std_logic_vector(
      to_unsigned(16#8000# + iAddress, cTB_DATA_WIDTH));
  end function fHeader;

  function fSample(iData : tAdcWord) return tOutputWord is
  begin
    return '0' & iData;
  end function fSample;

  constant cEOP          : tOutputWord := '1' & x"A000";
  constant cLIMITED_DATA : tAdcWord := x"C000";

  signal iCLK       : std_logic := '0';
  signal iRST       : std_logic := '1';
  signal iTRIG      : std_logic := '0';
  signal iREADY     : std_logic := '1';
  signal iFULL      : std_logic := '0';

  signal iRD_DATA   : tAdcWord := (others => '0');
  signal iHT        : tAdcWord := (others => '0');
  signal iLT        : tAdcWord := (others => '0');
  signal iFLG       : std_logic_vector(3 downto 0) := (others => '0');

  signal oRD_ADDR   : std_logic_vector(cTB_ADDR_WIDTH-1 downto 0);
  signal oRD_EN     : std_logic;
  signal oWR_DATA   : tOutputWord;
  signal oWR_EN     : std_logic;
  signal oBUSY      : std_logic;
  signal oLOST      : std_logic;

  -- MEMORIE DI RIFERIMENTO
  -- Vengono utilizzate soltanto dagli assert. Gli ingressi del DUT vengono
  -- pilotati esclusivamente dalle quattro parametric_ram_tp sottostanti.
  signal sDataReference : tAdcRam  := (others => (others => '0'));
  signal sHthReference  : tAdcRam  := (others => (others => '0'));
  signal sLthReference  : tAdcRam  := (others => (others => '0'));
  signal sFlgReference  : tFlagRam := (others => (others => '0'));
  signal sFlgRamQ   : tFlagWord := (others => '0');

  signal sRamWE        : std_logic := '0';
  signal sRamWAddress  : std_logic_vector(cTB_ADDR_WIDTH-1 downto 0) :=
                         (others => '0');
  signal sRamWData     : tAdcWord := (others => '0');
  signal sRamWHth      : tAdcWord := (others => '0');
  signal sRamWLth      : tAdcWord := (others => '0');
  signal sRamWFlg      : tFlagWord := (others => '0');

  signal sExpected       : tExpectedRam := (others => (others => '0'));
  signal sExpectedCount  : natural range 0 to cMAX_EXPECTED := 0;
  signal sObservedCount  : natural range 0 to cMAX_EXPECTED := 0;
  signal sScoreClear     : std_logic := '0';

  signal sReadRequestCount : natural range 0 to 100000 := 0;
  signal sCaseSeen         : std_logic_vector(7 downto 0) := (others => '0');

  signal sForceFull            : std_logic := '0';
  signal sPeriodicBackpressure : std_logic := '0';

begin

  iCLK <= not iCLK after CLK_PERIOD/2;

  iFLG <= sFlgRamQ(3 downto 0);

  DUT : entity work.ClusterModule
    generic map (
      pADC_NUM     => cTB_ADC_NUM,
      pADC_STRIPS  => cTB_ADC_STRIPS,
      pDATA_WIDTH  => cTB_DATA_WIDTH,
      pUSEDW_WIDTH => cTB_ADDR_WIDTH
    )
    port map (
      iCLK     => iCLK,
      iRST     => iRST,
      iTRIG    => iTRIG,
      iRD_DATA => iRD_DATA,
      oRD_ADDR => oRD_ADDR,
      oRD_EN   => oRD_EN,
      iREADY   => iREADY,
      iHT      => iHT,
      iLT      => iLT,
      iFLG     => iFLG,
      oWR_DATA => oWR_DATA,
      oWR_EN   => oWR_EN,
      iFULL    => iFULL,
      oBUSY    => oBUSY,
      oLOST    => oLOST
    );

  -- RAM DEL PROGETTO
  -- iRd_Addr viene registrato dalla parametric_ram_tp su un rising edge;
  -- il relativo oData viene quindi visto dal ClusterModule al rising edge
  -- successivo, come nell'integrazione finale.
  DATA_RAM : parametric_ram_tp
    generic map (
      pWIDTH       => cTB_DATA_WIDTH,
      pDEPTH       => cTB_TOTAL_STRIPS,
      pUSEDW_WIDTH => cTB_ADDR_WIDTH,
      pFORCE_MLAB  => 0
    )
    port map (
      iCLK     => iCLK,
      iData    => sRamWData,
      iRd_Addr => oRD_ADDR,
      iWr_Addr => sRamWAddress,
      iWr_En   => sRamWE,
      oData    => iRD_DATA
    );

  HTH_RAM : parametric_ram_tp
    generic map (
      pWIDTH       => cTB_DATA_WIDTH,
      pDEPTH       => cTB_TOTAL_STRIPS,
      pUSEDW_WIDTH => cTB_ADDR_WIDTH,
      pFORCE_MLAB  => 0
    )
    port map (
      iCLK     => iCLK,
      iData    => sRamWHth,
      iRd_Addr => oRD_ADDR,
      iWr_Addr => sRamWAddress,
      iWr_En   => sRamWE,
      oData    => iHT
    );

  LTH_RAM : parametric_ram_tp
    generic map (
      pWIDTH       => cTB_DATA_WIDTH,
      pDEPTH       => cTB_TOTAL_STRIPS,
      pUSEDW_WIDTH => cTB_ADDR_WIDTH,
      pFORCE_MLAB  => 0
    )
    port map (
      iCLK     => iCLK,
      iData    => sRamWLth,
      iRd_Addr => oRD_ADDR,
      iWr_Addr => sRamWAddress,
      iWr_En   => sRamWE,
      oData    => iLT
    );

  FLG_RAM : parametric_ram_tp
    generic map (
      pWIDTH       => cTB_DATA_WIDTH,
      pDEPTH       => cTB_TOTAL_STRIPS,
      pUSEDW_WIDTH => cTB_ADDR_WIDTH,
      pFORCE_MLAB  => 0
    )
    port map (
      iCLK     => iCLK,
      iData    => sRamWFlg,
      iRd_Addr => oRD_ADDR,
      iWr_Addr => sRamWAddress,
      iWr_En   => sRamWE,
      oData    => sFlgRamQ
    );

  -- PROCESSO PER VERIFICARE LA LATENZA DELLE RAM
  -- Verifica esplicitamente la latenza di un clock per tutte le quattro RAM.
  RAM_LATENCY_CHECK : process(iCLK, iRST)
    variable vPreviousValid   : boolean := false;
    variable vPreviousAddress : natural range 0 to cTB_TOTAL_STRIPS-1 := 0;
  begin
    if iRST = '1' then
      vPreviousValid   := false;
      vPreviousAddress := 0;
    elsif rising_edge(iCLK) then
      if vPreviousValid then
        assert iRD_DATA = sDataReference(vPreviousAddress)
          report "DATA RAM latency/alignment mismatch at address " &
                 integer'image(vPreviousAddress)
          severity failure;
        assert iHT = sHthReference(vPreviousAddress)
          report "HTH RAM latency/alignment mismatch at address " &
                 integer'image(vPreviousAddress)
          severity failure;
        assert iLT = sLthReference(vPreviousAddress)
          report "LTH RAM latency/alignment mismatch at address " &
                 integer'image(vPreviousAddress)
          severity failure;
        assert sFlgRamQ = sFlgReference(vPreviousAddress)
          report "FLG RAM latency/alignment mismatch at address " &
                 integer'image(vPreviousAddress)
          severity failure;
        assert iFLG = sFlgReference(vPreviousAddress)(3 downto 0)
          report "FLG low-nibble connection mismatch at address " &
                 integer'image(vPreviousAddress)
          severity failure;
      end if;

      vPreviousValid := oRD_EN = '1';
      if oRD_EN = '1' then
        vPreviousAddress := to_integer(unsigned(oRD_ADDR));
      end if;
    end if;
  end process RAM_LATENCY_CHECK;

  -- PROCESSO PER VERIFICARE GLI INDIRIZZI DI LETTURA
  -- Ogni scansione deve partire da zero e restare sequenziale anche quando
  -- lo stato HOLD inserisce delle pause tra le richieste alla RAM.
  READ_ADDRESS_CHECK : process(iCLK, iRST)
    variable vFirstRequest : boolean := true;
    variable vLastAddress  : natural range 0 to cTB_TOTAL_STRIPS-1 := 0;
    variable vAddress      : natural range 0 to cTB_TOTAL_STRIPS-1;
  begin
    if iRST = '1' then
      sReadRequestCount <= 0;
      vFirstRequest := true;
      vLastAddress  := 0;
    elsif rising_edge(iCLK) then
      if oRD_EN = '1' then
        vAddress := to_integer(unsigned(oRD_ADDR));
        if vFirstRequest then
          assert vAddress = 0
            report "Event RAM scan did not start from address zero"
            severity failure;
        else
          assert vAddress = vLastAddress + 1
            report "Event RAM address skipped or repeated after " &
                   integer'image(vLastAddress)
            severity failure;
        end if;

        sReadRequestCount <= sReadRequestCount + 1;
        vLastAddress := vAddress;
        if vAddress = cTB_TOTAL_STRIPS-1 then
          vFirstRequest := true;
        else
          vFirstRequest := false;
        end if;
      end if;
    end if;
  end process READ_ADDRESS_CHECK;

  -- PROCESSO PER LA COPERTURA DEI CASE
  -- Ricostruisce soltanto la pipeline LT per raccogliere la copertura dei CASE.
  -- È un monitor di copertura e non il modello di riferimento dell'uscita.
  CASE_COVERAGE : process(iCLK, iRST)
    variable vP0          : std_logic := '0';
    variable vP1          : std_logic := '0';
    variable vP2          : std_logic := '0';
    variable vNewP0       : std_logic;
    variable vWindow      : std_logic_vector(2 downto 0);
    variable vRequestD    : boolean := false;
  begin
    if iRST = '1' then
      vP0       := '0';
      vP1       := '0';
      vP2       := '0';
      vRequestD := false;
    elsif rising_edge(iCLK) then
      if oBUSY = '0' then
        vP0       := '0';
        vP1       := '0';
        vP2       := '0';
        vRequestD := false;
      else
        if vRequestD then
          vWindow := vP2 & vP1 & vP0;
          sCaseSeen(to_integer(unsigned(vWindow))) <= '1';

          if signed(iRD_DATA) > signed(iLT) and iFLG = "0000" then
            vNewP0 := '1';
          else
            vNewP0 := '0';
          end if;

          vP2 := vP1;
          vP1 := vP0;
          vP0 := vNewP0;
        end if;
        vRequestD := oRD_EN = '1';
      end if;
    end if;
  end process CASE_COVERAGE;

  -- PROCESSO PER LO SCOREBOARD DI USCITA
  -- oWR_EN indica che la FIFO successiva ha accettato la parola, perché il
  -- ClusterModule lo mantiene basso quando iFULL è attivo.
  OUTPUT_SCOREBOARD : process(iCLK, iRST)
  begin
    if iRST = '1' then
      sObservedCount <= 0;
    elsif rising_edge(iCLK) then
      if sScoreClear = '1' then
        sObservedCount <= 0;
      else
        assert not (oWR_EN = '1' and iFULL = '1')
          report "ClusterModule asserted oWR_EN while iFULL was high"
          severity failure;

        if oWR_EN = '1' then
          assert sObservedCount < sExpectedCount
            report "Unexpected extra output word " & to_hstring(oWR_DATA)
            severity failure;
          assert oWR_DATA = sExpected(sObservedCount)
            report "Output mismatch at index " &
                   integer'image(sObservedCount) & ": expected " &
                   to_hstring(sExpected(sObservedCount)) & ", received " &
                   to_hstring(oWR_DATA)
            severity failure;
          sObservedCount <= sObservedCount + 1;
        end if;
      end if;
    end if;
  end process OUTPUT_SCOREBOARD;

  -- PROCESSO PER IL BACKPRESSURE
  -- sForceFull serve a riempire la FIFO interna dei descrittori; la modalità
  -- periodica verifica il comportamento di pausa e ripartenza.
  BACKPRESSURE_PROC : process(iCLK, iRST)
    variable vCount : natural range 0 to 4 := 0;
  begin
    if iRST = '1' then
      iFULL  <= '0';
      vCount := 0;
    elsif rising_edge(iCLK) then
      if sForceFull = '1' then
        iFULL  <= '1';
        vCount := 0;
      elsif sPeriodicBackpressure = '1' then
        if vCount = 0 or vCount = 1 then
          iFULL <= '1';
        else
          iFULL <= '0';
        end if;

        if vCount = 4 then
          vCount := 0;
        else
          vCount := vCount + 1;
        end if;
      else
        iFULL  <= '0';
        vCount := 0;
      end if;
    end if;
  end process BACKPRESSURE_PROC;

  STIMULUS : process
    variable vExpectedCount : natural range 0 to cMAX_EXPECTED := 0;
    variable vReadBase      : natural := 0;
    variable vLastRead      : natural := 0;
    variable vStableCycles  : natural := 0;
    variable vWord          : tAdcWord;

    procedure pClearScore is
    begin
      sExpectedCount <= 0;
      sScoreClear    <= '1';
      wait until rising_edge(iCLK);
      wait for 1 ns;
      sScoreClear    <= '0';
      vExpectedCount := 0;
    end procedure pClearScore;

    procedure pWriteRam(
      constant iAddress : in natural;
      constant iData    : in tAdcWord;
      constant iLth     : in tAdcWord;
      constant iHth     : in tAdcWord;
      constant iFlagWord : in tFlagWord
    ) is
    begin
      sRamWAddress <= std_logic_vector(to_unsigned(iAddress, cTB_ADDR_WIDTH));
      sRamWData    <= iData;
      sRamWLth     <= iLth;
      sRamWHth     <= iHth;
      sRamWFlg     <= iFlagWord;
      sDataReference(iAddress) <= iData;
      sLthReference(iAddress)  <= iLth;
      sHthReference(iAddress)  <= iHth;
      sFlgReference(iAddress)  <= iFlagWord;
      sRamWE       <= '1';
      wait until rising_edge(iCLK);
    end procedure pWriteRam;

    procedure pFillRam(
      constant iData : in tAdcWord;
      constant iLth  : in tAdcWord;
      constant iHth  : in tAdcWord;
      constant iFlagWord : in tFlagWord
    ) is
    begin
      for i in 0 to cTB_TOTAL_STRIPS-1 loop
        pWriteRam(i, iData, iLth, iHth, iFlagWord);
      end loop;
    end procedure pFillRam;

    procedure pEndRamLoad is
    begin
      sRamWE <= '0';
      wait until rising_edge(iCLK);
      wait for 1 ns;
    end procedure pEndRamLoad;

    procedure pExpect(constant iWord : in tOutputWord) is
    begin
      assert vExpectedCount < cMAX_EXPECTED
        report "Expected-output memory overflow"
        severity failure;
      sExpected(vExpectedCount) <= iWord;
      vExpectedCount := vExpectedCount + 1;
    end procedure pExpect;

    procedure pExpectHeader(constant iAddress : in natural) is
    begin
      pExpect(fHeader(iAddress));
    end procedure pExpectHeader;

    procedure pExpectSample(constant iData : in tAdcWord) is
    begin
      pExpect(fSample(iData));
    end procedure pExpectSample;

    procedure pCommitExpected is
    begin
      sExpectedCount <= vExpectedCount;
      wait for 0 ns;
    end procedure pCommitExpected;

    procedure pPulseTrigger is
    begin
      wait for TRIG_GAP;
      assert oBUSY = '0'
        report "New event triggered while ClusterModule was still busy"
        severity failure;
      wait until falling_edge(iCLK);
      iTRIG <= '1';
      wait until falling_edge(iCLK);
      iTRIG <= '0';
    end procedure pPulseTrigger;

    procedure pWaitEventDone(
      constant iReadBase : in natural;
      constant iName     : in string
    ) is
    begin
      if oBUSY /= '1' then
        wait until oBUSY = '1';
      end if;
      wait until oBUSY = '0';
      wait for 1 ns;

      assert sObservedCount = sExpectedCount
        report iName & ": output length mismatch, expected " &
               integer'image(sExpectedCount) & ", received " &
               integer'image(sObservedCount)
        severity failure;
      assert sReadRequestCount-iReadBase = cTB_TOTAL_STRIPS
        report iName & ": RAM read count mismatch"
        severity failure;
    end procedure pWaitEventDone;

  begin
    -- RESET ASINCRONO INIZIALE
    -- Viene mantenuto attivo per più fronti in modo da campionare anche gli
    -- ingressi sclr sincroni delle FIFO.
    iRST  <= '1';
    iTRIG <= '0';
    iREADY <= '1';
    sForceFull <= '0';
    sPeriodicBackpressure <= '0';
    wait for 5*CLK_PERIOD;
    wait until falling_edge(iCLK);
    iRST <= '0';
    wait until rising_edge(iCLK);
    wait for 1 ns;

    -- EVENTO 1: NESSUN CLUSTER, WAIT_READY E IMPULSO DI TRIGGER PERSO
    pClearScore;
    pFillRam(fADC8(0.0), fADC8(1.0), fADC8(3.0), x"F000");
    pEndRamLoad;
    pExpect(cEOP);
    pCommitExpected;

    iREADY <= '0';
    vReadBase := sReadRequestCount;
    pPulseTrigger;
    wait for 1 ns;
    assert oBUSY = '1'
      report "WAIT_READY event did not assert BUSY"
      severity failure;

    for i in 1 to 5 loop
      wait until rising_edge(iCLK);
      wait for 1 ns;
      assert sReadRequestCount = vReadBase and oRD_EN = '0'
        report "RAM read issued before iREADY"
        severity failure;
    end loop;

    -- Violo intenzionalmente TRIG_GAP per verificare oLOST mentre oBUSY è attivo.
    wait until falling_edge(iCLK);
    iTRIG <= '1';
    wait until rising_edge(iCLK);
    wait for 1 ns;
    assert oLOST = '1'
      report "oLOST was not asserted for a trigger received while busy"
      severity failure;
    wait until falling_edge(iCLK);
    iTRIG <= '0';
    wait until rising_edge(iCLK);
    wait for 1 ns;
    assert oLOST = '0'
      report "oLOST did not return low after one clock"
      severity failure;

    iREADY <= '1';
    pWaitEventDone(vReadBase, "EVENT 1 - WAIT_READY/no cluster");

    -- EVENTO 2: COPERTURA COMPLETA DI CASE, SOGLIE, FLAG E LIMITER
    -- Verifica tutti i casi P2|P1|P0, keep/scarto, HTH/LTH per strip,
    -- confronti stretti, nibble dei flag e limiter xC000.
    pClearScore;
    pFillRam(fADC8(0.0), fADC8(1.0), fADC8(3.0), x"F000");

    -- Cluster isolato valido con pre-strip e post-strip inferiori a xC000.
    pWriteRam(10, fADC8(-3000.0), fADC8(1.0), fADC8(3.0), x"F000");
    pWriteRam(11, fADC8(4.0),     fADC8(1.0), fADC8(3.0), x"F000");
    pWriteRam(12, fADC8(-2500.0), fADC8(1.0), fADC8(3.0), x"F000");

    -- Possibile cluster isolato non valido: sopra LTH ma mai sopra HTH.
    pWriteRam(21, fADC8(2.0), fADC8(1.0), fADC8(3.0), x"F000");

    -- Cluster valido su più strip: copre i casi 011, 111 e 110.
    pWriteRam(31, fADC8(2.0), fADC8(1.0), fADC8(3.0), x"F000");
    pWriteRam(32, fADC8(4.0), fADC8(1.0), fADC8(3.0), x"F000");
    pWriteRam(33, fADC8(2.0), fADC8(1.0), fADC8(3.0), x"F000");

    -- Caso 101 con possibile cluster precedente valido.
    pWriteRam(41, fADC8(4.0), fADC8(1.0), fADC8(3.0), x"F000");
    pWriteRam(43, fADC8(4.0), fADC8(1.0), fADC8(3.0), x"F000");

    -- Caso 101 con possibile cluster precedente non valido; l'indirizzo 52
    -- diventa la nuova pre-strip e deve restare in testa alla DATA FIFO.
    pWriteRam(51, fADC8(2.0), fADC8(1.0), fADC8(3.0), x"F000");
    pWriteRam(53, fADC8(4.0), fADC8(1.0), fADC8(3.0), x"F000");

    -- I dodici bit alti di FLG non sono rilevanti all'indirizzo 61. Il bit 0
    -- del nibble basso all'indirizzo 62 forza il campione sotto LTH, anche se
    -- il relativo valore ADC8 è sopra HTH.
    pWriteRam(61, fADC8(4.0), fADC8(1.0), fADC8(3.0), x"F000");
    pWriteRam(62, fADC8(4.0), fADC8(1.0), fADC8(3.0), x"F001");
    pWriteRam(63, fADC8(4.0), fADC8(1.0), fADC8(3.0), x"0000");

    -- L'uguaglianza non basta perché il ClusterModule usa il confronto strettamente maggiore.
    pWriteRam(71, fADC8(3.0), fADC8(1.0), fADC8(3.0), x"0000");

    -- Verifica allineamento HTH per indirizzo: solo la strip 82 è seed.
    pWriteRam(81, fADC8(2.0), fADC8(1.0), fADC8(3.0),  x"0000");
    pWriteRam(82, fADC8(2.0), fADC8(1.5), fADC8(1.75), x"0000");

    -- Verifica allineamento LTH per indirizzo: valore uguale a LTH, quindi sotto soglia.
    pWriteRam(91, fADC8(2.0), fADC8(2.0), fADC8(1.5), x"0000");
    pEndRamLoad;

    pExpectHeader(10);
    pExpectSample(cLIMITED_DATA);
    pExpectSample(fADC8(4.0));
    pExpectSample(cLIMITED_DATA);

    pExpectHeader(30);
    pExpectSample(fADC8(0.0));
    pExpectSample(fADC8(2.0));
    pExpectSample(fADC8(4.0));
    pExpectSample(fADC8(2.0));
    pExpectSample(fADC8(0.0));

    pExpectHeader(40);
    pExpectSample(fADC8(0.0));
    pExpectSample(fADC8(4.0));
    pExpectSample(fADC8(0.0));
    pExpectHeader(43);
    pExpectSample(fADC8(4.0));
    pExpectSample(fADC8(0.0));

    pExpectHeader(52);
    pExpectSample(fADC8(0.0));
    pExpectSample(fADC8(4.0));
    pExpectSample(fADC8(0.0));

    pExpectHeader(60);
    pExpectSample(fADC8(0.0));
    pExpectSample(fADC8(4.0));
    pExpectSample(fADC8(4.0));
    pExpectHeader(63);
    pExpectSample(fADC8(4.0));
    pExpectSample(fADC8(0.0));

    pExpectHeader(80);
    pExpectSample(fADC8(0.0));
    pExpectSample(fADC8(2.0));
    pExpectSample(fADC8(2.0));
    pExpectSample(fADC8(0.0));
    pExpect(cEOP);
    pCommitExpected;

    vReadBase := sReadRequestCount;
    pPulseTrigger;
    pWaitEventDone(vReadBase, "EVENT 2 - complete CASE/threshold/flag coverage");

    -- EVENTO 3: LIMITER A 128 PAROLE E BACKPRESSURE DETERMINISTICO
    -- Dopo il primo cluster limitato viene generato un secondo descrittore.
    pClearScore;
    pFillRam(fADC8(0.0), fADC8(1.0), fADC8(3.0), x"0000");
    for i in 101 to 230 loop
      vWord := fADC8(real(4 + (i mod 3)));
      pWriteRam(i, vWord, fADC8(1.0), fADC8(3.0), x"0000");
    end loop;
    pEndRamLoad;

    pExpectHeader(100);
    pExpectSample(fADC8(0.0));
    for i in 101 to 227 loop
      pExpectSample(fADC8(real(4 + (i mod 3))));
    end loop;
    pExpectHeader(228);
    for i in 228 to 230 loop
      pExpectSample(fADC8(real(4 + (i mod 3))));
    end loop;
    pExpectSample(fADC8(0.0));
    pExpect(cEOP);
    pCommitExpected;

    sPeriodicBackpressure <= '1';
    vReadBase := sReadRequestCount;
    pPulseTrigger;
    pWaitEventDone(vReadBase, "EVENT 3 - 128-word limiter/backpressure");
    sPeriodicBackpressure <= '0';
    wait until rising_edge(iCLK);

    -- EVENTO 4: PRIMA E ULTIMA STRIP FISICA
    -- Il primo cluster riceve una pre-strip virtuale; l'ultimo riceve una
    -- post-strip virtuale durante lo svuotamento della pipeline.
    pClearScore;
    pFillRam(fADC8(0.0), fADC8(1.0), fADC8(3.0), x"0000");
    pWriteRam(0, fADC8(4.0), fADC8(1.0), fADC8(3.0), x"0000");
    pWriteRam(cTB_TOTAL_STRIPS-2, fADC8(4.0),
              fADC8(1.0), fADC8(3.0), x"0000");
    pWriteRam(cTB_TOTAL_STRIPS-1, fADC8(5.0),
              fADC8(1.0), fADC8(3.0), x"0000");
    pEndRamLoad;

    pExpectHeader(0);
    pExpectSample(fADC8(0.0));
    pExpectSample(fADC8(4.0));
    pExpectSample(fADC8(0.0));
    pExpectHeader(cTB_TOTAL_STRIPS-3);
    pExpectSample(fADC8(0.0));
    pExpectSample(fADC8(4.0));
    pExpectSample(fADC8(5.0));
    pExpectSample(fADC8(0.0));
    pExpect(cEOP);
    pCommitExpected;

    vReadBase := sReadRequestCount;
    pPulseTrigger;
    pWaitEventDone(vReadBase, "EVENT 4 - first/last strip and pipeline flush");

    -- EVENTO 5: ADDRESS FIFO QUASI PIENA, HOLD E RIPARTENZA
    -- Al rilascio di iFULL la lettura deve ripartire dall'indirizzo RAM
    -- successivo senza duplicare la finestra di analisi.
    pClearScore;
    pFillRam(fADC8(0.0), fADC8(1.0), fADC8(3.0), x"0000");
    for i in 0 to cHOLD_CLUSTERS-1 loop
      pWriteRam(4*i+1, fADC8(5.0),
                fADC8(1.0), fADC8(3.0), x"0000");
    end loop;
    pEndRamLoad;

    for i in 0 to cHOLD_CLUSTERS-1 loop
      pExpectHeader(4*i);
      pExpectSample(fADC8(0.0));
      pExpectSample(fADC8(5.0));
      pExpectSample(fADC8(0.0));
    end loop;
    pExpect(cEOP);
    pCommitExpected;

    sForceFull <= '1';
    wait until rising_edge(iCLK);
    wait for 1 ns;
    assert iFULL = '1'
      report "Forced downstream full was not applied"
      severity failure;

    vReadBase := sReadRequestCount;
    pPulseTrigger;

    vLastRead := sReadRequestCount;
    vStableCycles := 0;
    while vStableCycles < 20 loop
      wait until rising_edge(iCLK);
      wait for 1 ns;
      if sReadRequestCount = vLastRead then
        vStableCycles := vStableCycles + 1;
      else
        vStableCycles := 0;
        vLastRead := sReadRequestCount;
      end if;
    end loop;

    assert sReadRequestCount-vReadBase > 100 and
           sReadRequestCount-vReadBase < cTB_TOTAL_STRIPS
      report "ADDRESS_FIFO almost-full did not suspend the RAM scan"
      severity failure;
    assert sObservedCount = 0
      report "Output advanced while downstream was forced full"
      severity failure;

    sForceFull <= '0';
    sPeriodicBackpressure <= '1';
    pWaitEventDone(vReadBase, "EVENT 5 - HOLD and resume");
    sPeriodicBackpressure <= '0';
    wait until rising_edge(iCLK);

    -- EVENTO 6: RESET ASINCRONO DURANTE LA LETTURA
    -- Il reset viene applicato mentre è in corso un possibile cluster lungo.
    -- Non essendoci ancora un descrittore, non deve uscire alcuna parola.
    pClearScore;
    pFillRam(fADC8(4.0), fADC8(1.0), fADC8(3.0), x"0000");
    pEndRamLoad;
    pCommitExpected;

    vReadBase := sReadRequestCount;
    pPulseTrigger;
    while sReadRequestCount-vReadBase < 20 loop
      wait until rising_edge(iCLK);
      wait for 1 ns;
    end loop;
    assert sObservedCount = 0
      report "Unexpected output before asynchronous-reset test"
      severity failure;

    wait until falling_edge(iCLK);
    wait for 2 ns;
    iRST <= '1';
    wait for 1 ns;
    assert oBUSY = '0' and oRD_EN = '0' and oWR_EN = '0'
      report "Asynchronous reset did not immediately stop ClusterModule"
      severity failure;

    -- Mantengo il reset per un rising edge per campionare gli sclr sincroni delle FIFO.
    wait until rising_edge(iCLK);
    wait until falling_edge(iCLK);
    iRST <= '0';
    wait until rising_edge(iCLK);
    wait for 1 ns;
    assert oBUSY = '0'
      report "ClusterModule did not return to IDLE after reset"
      severity failure;

    -- EVENTO 7: EVENTO VALIDO DOPO IL RESET ASINCRONO
    pClearScore;
    pFillRam(fADC8(0.0), fADC8(1.0), fADC8(3.0), x"0000");
    pWriteRam(5, fADC8(6.0), fADC8(1.0), fADC8(3.0), x"0000");
    pEndRamLoad;

    pExpectHeader(4);
    pExpectSample(fADC8(0.0));
    pExpectSample(fADC8(6.0));
    pExpectSample(fADC8(0.0));
    pExpect(cEOP);
    pCommitExpected;

    vReadBase := sReadRequestCount;
    pPulseTrigger;
    pWaitEventDone(vReadBase, "EVENT 7 - recovery after asynchronous reset");

    assert sCaseSeen = x"FF"
      report "CASE coverage incomplete. Seen mask = " & to_hstring(sCaseSeen)
      severity failure;

    report "ClusterModule_tb completed successfully. CASE coverage = 0x" &
           to_hstring(sCaseSeen)
      severity note;
    std.env.stop;
    wait;
  end process STIMULUS;

end architecture Behavioral;
