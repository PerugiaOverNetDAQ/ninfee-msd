--!@file ClusterModule.vhd
--!@brief Modulo di clusterizzazione streaming con pipeline a tre stadi
--!@author Luca Russo, luca.russo@cern.ch, luca.russo912@gmail.com
--!@date 15/07/2026
--!@version 1.2.0

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.basic_package.all;
use work.FOOTpackage.all;

entity ClusterModule is
  generic (
    pADC_NUM        : natural := cTOTAL_ADCS;                           --!Numero di ADC
    pADC_STRIPS     : natural := cADC_CHANNELS;                         --!Numero di canali per ADC
    pDATA_WIDTH     : natural := cADC_DATA_WIDTH;                       --!Larghezza dati della EVENT RAM
    pUSEDW_WIDTH    : natural := ceil_log2(cTOTAL_ADCS*cADC_CHANNELS)   --!Larghezza indirizzo lineare dell'evento
  );
  port (
    iCLK                : in  std_logic;
    iRST                : in  std_logic;

    iTRIG               : in  std_logic;

    -- INTERFACCIA RAM EVENTO E CALIBRAZIONE
    -- Indirizzo ed enable di lettura vengono campionati su rising edge
    -- iRD_DATA, iHT, iLT e iFLG sono validi al rising edge successivo.
    iRD_DATA            : in  std_logic_vector(pDATA_WIDTH-1 downto 0);
    oRD_ADDR            : out std_logic_vector(pUSEDW_WIDTH-1 downto 0);
    oRD_EN              : out std_logic;
    iREADY              : in  std_logic;

    iHT                 : in  std_logic_vector(pDATA_WIDTH-1 downto 0);
    iLT                 : in  std_logic_vector(pDATA_WIDTH-1 downto 0);
    iFLG                : in  std_logic_vector(3 downto 0);

    -- USCITA FIFO STREAMING
    -- Il bit pDATA_WIDTH identifica EOP
    oWR_DATA            : out std_logic_vector(pDATA_WIDTH downto 0);
    oWR_EN              : out std_logic;
    iFULL               : in  std_logic;

    oBUSY               : out std_logic;
    oLOST               : out std_logic
  );
end entity ClusterModule;

architecture Behavioral of ClusterModule is

  constant cTOTAL_STRIPS          : positive := pADC_NUM*pADC_STRIPS;
  constant cCLUSTER_LEN_WIDTH     : positive := 7;
  constant cFIFO_HEADROOM         : positive := 8;
  constant cADDRESS_FIFO_WIDTH    : positive :=
    1 + pUSEDW_WIDTH + cCLUSTER_LEN_WIDTH;

  constant cPIPE_HT_BIT : natural := pDATA_WIDTH+1;
  constant cPIPE_LT_BIT : natural := pDATA_WIDTH;

  type tState is (
    IDLE,
    WAIT_READY,
    PIPE,
    HOLD,
    FLUSH_PIPE,
    WAIT_DRAIN,
    SEND_EOP
  );

  type tUnloadState is (
    U_IDLE,
    U_DESC_WAIT,
    U_HEADER,
    U_KEEP_WAIT_DATA,
    U_KEEP_DATA,
    U_DISCARD_DATA
  );

  signal sState              : tState := IDLE;
  signal sUnloadState        : tUnloadState := U_IDLE;
  signal sFifoReset          : std_logic;
  signal sLost               : std_logic := '0';

  -- GESTIONE RICHIESTE E RISPOSTE DELLA EVENT RAM
  signal sIssueRead          : std_logic;
  signal sNextReadAddress    : natural range 0 to cTOTAL_STRIPS-1;
  signal sRequestAddressD    : natural range 0 to cTOTAL_STRIPS-1;
  signal sRequestValidD      : std_logic;
  signal sRequestsDone       : std_logic;
  signal sFlushRemaining     : natural range 0 to 3;

  -- SEGNALI PIPELINE
  -- Pipeline a tre stadi: P0 -> P1 -> P2.
  -- P0 contiene la strip nuova, P1 la strip centrale analizzata e P2 la strip
  -- precedente. Ogni stadio contiene i flag HT, LT e il dato.
  signal sP0                 : std_logic_vector(pDATA_WIDTH+1 downto 0);
  signal sP1                 : std_logic_vector(pDATA_WIDTH+1 downto 0);
  signal sP2                 : std_logic_vector(pDATA_WIDTH+1 downto 0);
  signal sP0Address          : natural range 0 to cTOTAL_STRIPS-1;
  signal sP1Address          : natural range 0 to cTOTAL_STRIPS-1;
  signal sP2Address          : natural range 0 to cTOTAL_STRIPS-1;

  -- CONTATORI DEL POSSIBILE CLUSTER
  -- I campioni vengono inseriti nella DATA FIFO e il "descrittore" scritto nella
  -- ADDRESS FIFO stabilisce se mantenerli oppure scartarli.
  signal sCandidateWords     : natural range 0 to cMAX_CLUSTER_WORDS-1;
  signal sCandidateStart     : natural range 0 to cTOTAL_STRIPS-1;
  signal sCandidateSeed      : std_logic;

  -- SEGNALI DATA FIFO
  -- Contiene i campioni del possibile cluster
  signal sDataFifoIn         : std_logic_vector(pDATA_WIDTH-1 downto 0);
  signal sDataFifoQ          : std_logic_vector(pDATA_WIDTH-1 downto 0);
  signal sDataFifoWE         : std_logic;
  signal sDataFifoRE         : std_logic;
  signal sDataFifoEmpty      : std_logic;
  signal sDataFifoAFull      : std_logic;
  signal sDataFifoFull       : std_logic;

  -- SEGNALI ADDRESS FIFO
  -- Contiene keep/discard, primo indirizzo e lunghezza cluster meno uno
  signal sAddressFifoIn      :
    std_logic_vector(cADDRESS_FIFO_WIDTH-1 downto 0);
  signal sAddressFifoQ       :
    std_logic_vector(cADDRESS_FIFO_WIDTH-1 downto 0);
  signal sAddressFifoWE      : std_logic;
  signal sAddressFifoRE      : std_logic;
  signal sAddressFifoEmpty   : std_logic;
  signal sAddressFifoAFull   : std_logic;
  signal sAddressFifoFull    : std_logic;

  -- DESCRITTORE IN SCARICO
  signal sUnloadAddress      : natural range 0 to cTOTAL_STRIPS-1;
  signal sUnloadRemaining    : natural range 0 to cMAX_CLUSTER_WORDS;
  signal sStreamData         : std_logic_vector(pDATA_WIDTH downto 0);
  signal sStreamWrite        : std_logic;

begin
  sFifoReset <= '1' when iRST = '1' or sState = IDLE else '0';

  sIssueRead <= '1' when
    sState = PIPE and
    sRequestsDone = '0' and
    sDataFifoAFull = '0' and
    sAddressFifoAFull = '0' else '0';

  oRD_ADDR <= std_logic_vector(to_unsigned(sNextReadAddress, pUSEDW_WIDTH));
  oRD_EN   <= sIssueRead;

  oBUSY <= '0' when sState = IDLE else '1';
  oLOST <= sLost;

  -- Durante l'evento l'uscita viene gestita dal processo di scarico.
  -- L'EOP viene inviato solo dopo lo svuotamento delle FIFO e del descrittore addr.
  oWR_EN   <= '1' when sState = SEND_EOP and iFULL = '0' else
              sStreamWrite when sState /= SEND_EOP else
              '0';

  -- FORMATO EOP
  -- Bit di marker in MSB seguito da x"A000" con payload standard a 16 bit
  -- Bit assegnati singolarmente per mantenere generica la larghezza
  OUTPUT_FORMATTER : process(sState, sStreamData)
  begin
    oWR_DATA <= sStreamData;

    if sState = SEND_EOP then
      oWR_DATA <= (others => '0');
      oWR_DATA(pDATA_WIDTH)   <= '1';
      oWR_DATA(pDATA_WIDTH-1) <= '1';
      oWR_DATA(pDATA_WIDTH-3) <= '1';
    end if;
  end process OUTPUT_FORMATTER;

  -- DATA FIFO
  -- Può contenere un intero evento non compresso quando l'uscita è bloccata.
  -- Il comportamento non show-ahead è uguale alla ClustFIFO originale.
  DATA_FIFO : parametric_fifo_synch
    generic map (
      pWIDTH       => pDATA_WIDTH,
      pDEPTH       => cCOLL_FIFO_DEPTH,
      pUSEDW_WIDTH => ceil_log2(cCOLL_FIFO_DEPTH),
      pAEMPTY_VAL  => 3,
      pAFULL_VAL   => cCOLL_FIFO_DEPTH-cFIFO_HEADROOM,
      pSHOW_AHEAD  => "OFF"
    )
    port map (
      iCLK    => iCLK,
      iRST    => sFifoReset,
      oAEMPTY => open,
      oEMPTY  => sDataFifoEmpty,
      oAFULL  => sDataFifoAFull,
      oFULL   => sDataFifoFull,
      oUSEDW  => open,
      iRD_REQ => sDataFifoRE,
      iWR_REQ => sDataFifoWE,
      iDATA   => sDataFifoIn,
      oQ      => sDataFifoQ
    );

  -- ADDRESS FIFO
  -- Un descrittore per ogni possibile cluster, nel formato [keep][primo indirizzo lineare][lunghezza-1].
  ADDRESS_FIFO : parametric_fifo_synch_MLAB
    generic map (
      pWIDTH       => cADDRESS_FIFO_WIDTH,
      pDEPTH       => cADDRESS_FIFO_DEPTH,
      pUSEDW_WIDTH => ceil_log2(cADDRESS_FIFO_DEPTH),
      pAEMPTY_VAL  => 3,
      pAFULL_VAL   => cADDRESS_FIFO_DEPTH-cFIFO_HEADROOM,
      pSHOW_AHEAD  => "OFF"
    )
    port map (
      iCLK    => iCLK,
      iRST    => sFifoReset,
      oAEMPTY => open,
      oEMPTY  => sAddressFifoEmpty,
      oAFULL  => sAddressFifoAFull,
      oFULL   => sAddressFifoFull,
      oUSEDW  => open,
      iRD_REQ => sAddressFifoRE,
      iWR_REQ => sAddressFifoWE,
      iDATA   => sAddressFifoIn,
      oQ      => sAddressFifoQ
    );

  -- RICHIESTE DI LETTURA ALLE FIFO NON SHOW-AHEAD
  -- Una parola viene estratta solo quando può essere utilizzata oppure scartata
  sAddressFifoRE <= '1' when
    sUnloadState = U_IDLE and sAddressFifoEmpty = '0' else '0';

  sDataFifoRE <= '1' when
    (sUnloadState = U_HEADER and iFULL = '0' and
     sDataFifoEmpty = '0') or
    (sUnloadState = U_KEEP_WAIT_DATA and sDataFifoEmpty = '0') or
    (sUnloadState = U_KEEP_DATA and iFULL = '0' and
     sUnloadRemaining > 1 and sDataFifoEmpty = '0') or
    (sUnloadState = U_DISCARD_DATA and sDataFifoEmpty = '0') else '0';

  -- MULTIPLEXER DI USCITA
  -- L'header viene costruito come nel modulo originale: il bit 15 viene posto
  -- a uno e i bit inferiori contengono l'indirizzo della prima strip.
  OUTPUT_DATA_MUX : process(sUnloadState, sUnloadAddress, sDataFifoQ)
  begin
    sStreamData <= (others => '0');

    if sUnloadState = U_HEADER then
      sStreamData(pDATA_WIDTH-1) <= '1';
      sStreamData(pUSEDW_WIDTH-1 downto 0) <=
        std_logic_vector(to_unsigned(sUnloadAddress, pUSEDW_WIDTH));
    elsif sUnloadState = U_KEEP_DATA then
      sStreamData(pDATA_WIDTH-1 downto 0) <= sDataFifoQ;
    end if;
  end process OUTPUT_DATA_MUX;

  sStreamWrite <= '1' when
    (sUnloadState = U_HEADER or sUnloadState = U_KEEP_DATA) and
    iFULL = '0' else '0';

  -- PROCESSO PER LETTURA, PIPELINE E CLUSTERIZZAZIONE
  -- Le otto configurazioni LT sono mantenute esplicite come nel ClusterModule
  -- originale.
  PIPELINE_MANAGER : process(iCLK, iRST)
    variable vNewP0      : std_logic_vector(pDATA_WIDTH+1 downto 0);
    variable vCase       : std_logic_vector(2 downto 0);
    variable vAnalyze    : boolean;
    variable vNewLength  : natural range 0 to cMAX_CLUSTER_WORDS;
    variable vStart      : natural range 0 to cTOTAL_STRIPS-1;
    variable vKeep       : std_logic;
    variable vMinData    : signed(pDATA_WIDTH-1 downto 0);
  begin
    if iRST = '1' then
      sState            <= IDLE;
      sLost             <= '0';
      sNextReadAddress  <= 0;
      sRequestAddressD  <= 0;
      sRequestValidD    <= '0';
      sRequestsDone     <= '0';
      sFlushRemaining   <= 0;
      sP0               <= (others => '0');
      sP1               <= (others => '0');
      sP2               <= (others => '0');
      sP0Address        <= 0;
      sP1Address        <= 0;
      sP2Address        <= 0;
      sCandidateWords   <= 0;
      sCandidateStart   <= 0;
      sCandidateSeed    <= '0';
      sDataFifoIn       <= (others => '0');
      sDataFifoWE       <= '0';
      sAddressFifoIn    <= (others => '0');
      sAddressFifoWE    <= '0';

    elsif rising_edge(iCLK) then
        vNewP0    := (others => '0');
        vCase     := (others => '0');
        vAnalyze  := false;
        vNewLength := 0;
        vStart     := 0;
        vKeep      := '0';
        
        vMinData   := (others => '0');
        vMinData(pDATA_WIDTH-1 downto pDATA_WIDTH-2) := "11";

        sLost          <= '0';
        sDataFifoWE    <= '0';
        sAddressFifoWE <= '0';

        if iTRIG = '1' and sState /= IDLE then
          sLost <= '1';
        end if;

        assert not (sDataFifoWE = '1' and sDataFifoFull = '1')
          report "ClusterModule: DATA_FIFO overflow"
          severity failure;
        assert not (sAddressFifoWE = '1' and sAddressFifoFull = '1')
          report "ClusterModule: ADDRESS_FIFO overflow"
          severity failure;

        case sState is
          when IDLE =>
            sNextReadAddress <= 0;
            sRequestAddressD <= 0;
            sRequestValidD   <= '0';
            sRequestsDone    <= '0';
            sFlushRemaining  <= 0;
            sP0              <= (others => '0');
            sP1              <= (others => '0');
            sP2              <= (others => '0');
            sP0Address       <= 0;
            sP1Address       <= 0;
            sP2Address       <= 0;
            sCandidateWords  <= 0;
            sCandidateStart  <= 0;
            sCandidateSeed   <= '0';

            if iTRIG = '1' then
              if iREADY = '1' then
                sState <= PIPE;
              else
                sState <= WAIT_READY;
              end if;
            end if;

          when WAIT_READY =>
            sRequestValidD <= '0';
            if iREADY = '1' then
              sState <= PIPE;
            end if;

          when PIPE | HOLD =>
            -- Registro la richiesta per utilizzare la risposta della RAM un
            -- rising edge dopo il campionamento di indirizzo ed enable.
            sRequestValidD <= sIssueRead;
            if sIssueRead = '1' then
              sRequestAddressD <= sNextReadAddress;
              if sNextReadAddress = cTOTAL_STRIPS-1 then
                sRequestsDone <= '1';
              else
                sNextReadAddress <= sNextReadAddress + 1;
              end if;
            end if;

            if sState = PIPE and
               (sDataFifoAFull = '1' or sAddressFifoAFull = '1') then
              sState <= HOLD;
            elsif sState = HOLD and
                  sDataFifoAFull = '0' and sAddressFifoAFull = '0' then
              sState <= PIPE;
            end if;

            if sRequestValidD = '1' then
              -- Mantengo il comportamento originale dei flag: una strip con
              -- flag non può essere seed o sopra LT, mentre HT viene alzato per
              -- sicurezza per non interrompere un cluster con una strip morta.
              if signed(iRD_DATA) > signed(iHT) then
                vNewP0(cPIPE_HT_BIT) := '1';
              elsif iFLG /= "0000" then
                vNewP0(cPIPE_HT_BIT) := '1';
              end if;

              if signed(iRD_DATA) > signed(iLT) and iFLG = "0000" then
                vNewP0(cPIPE_LT_BIT) := '1';
              end if;

              -- LIMITER IMPOSTO PER I DATI
              -- Come nel ClusterModule originale, con formato standard a
              -- 16 bit cMIN_DATA corrisponde a x"C000".
              if signed(iRD_DATA) > vMinData then
                vNewP0(pDATA_WIDTH-1 downto 0) := iRD_DATA;
              else
                vNewP0(pDATA_WIDTH-1 downto 0) :=
                  std_logic_vector(vMinData);
              end if;

              vAnalyze := true;

              sP0        <= vNewP0;
              sP1        <= sP0;
              sP2        <= sP1;
              sP0Address <= sRequestAddressD;
              sP1Address <= sP0Address;
              sP2Address <= sP1Address;

              if sRequestAddressD = cTOTAL_STRIPS-1 then
                -- Servono tre clock per spostare l'ultima parola della RAM in
                -- P0 e P1 e analizzarla con la post-strip virtuale.
                sFlushRemaining <= 3;
                sState          <= FLUSH_PIPE;
              end if;
            end if;

          when FLUSH_PIPE =>
            sRequestValidD <= '0';
            vNewP0 := (others => '0');
            vAnalyze := true;

            sP0        <= vNewP0;
            sP1        <= sP0;
            sP2        <= sP1;
            sP0Address <= cTOTAL_STRIPS-1;
            sP1Address <= sP0Address;
            sP2Address <= sP1Address;

            if sFlushRemaining = 1 then
              sFlushRemaining <= 0;
              sState          <= WAIT_DRAIN;
            else
              sFlushRemaining <= sFlushRemaining - 1;
            end if;

          when WAIT_DRAIN =>
            sRequestValidD <= '0';
            if sDataFifoEmpty = '1' and
               sAddressFifoEmpty = '1' and
               sUnloadState = U_IDLE and
               sDataFifoWE = '0' and
               sAddressFifoWE = '0' then
              sState <= SEND_EOP;
            end if;

          when SEND_EOP =>
            sRequestValidD <= '0';
            if iFULL = '0' then
              sState <= IDLE;
            end if;

          when others =>
            sState <= IDLE;
        end case;

        -- FLUSSO DATI: nuova strip -> P0 -> P1 -> P2
        -- Finestra di analisi: P2 | P1 | P0. P1 è sempre la strip centrale,
        -- P2 la strip precedente e P0 la strip successiva.
        if vAnalyze then
          vCase := sP2(cPIPE_LT_BIT) & sP1(cPIPE_LT_BIT) &
                   sP0(cPIPE_LT_BIT);

          -- vCase(2) = P2, vCase(1) = P1, vCase(0) = P0.
          case vCase is
            when "001" =>
              -- P2=0 | P1=0 | P0=1
              -- Nessun cluster precedente: P1 è la pre-strip del nuovo
              -- possibile cluster che inizia in P0.
              sDataFifoIn     <= sP1(pDATA_WIDTH-1 downto 0);
              sDataFifoWE     <= '1';
              sCandidateStart <= sP1Address;
              sCandidateWords <= 1;
              sCandidateSeed  <= '0';

            when "010" =>
              -- P2=0 | P1=1 | P0=0: singola strip sopra LT in P1.
              sDataFifoIn <= sP1(pDATA_WIDTH-1 downto 0);
              sDataFifoWE <= '1';

              vNewLength := sCandidateWords + 1;
              if sCandidateWords = 0 then
                vStart := sP1Address;
              else
                vStart := sCandidateStart;
              end if;

              if sCandidateSeed = '1' or sP1(cPIPE_HT_BIT) = '1' then
                vKeep := '1';
              else
                vKeep := '0';
              end if;

              if vNewLength = cMAX_CLUSTER_WORDS then
                sAddressFifoIn <=
                  vKeep &
                  std_logic_vector(to_unsigned(vStart, pUSEDW_WIDTH)) &
                  std_logic_vector(to_unsigned(vNewLength-1,
                                               cCLUSTER_LEN_WIDTH));
                sAddressFifoWE  <= '1';
                sCandidateWords <= 0;
                sCandidateSeed  <= '0';
              else
                sCandidateWords <= vNewLength;
                sCandidateStart <= vStart;
                sCandidateSeed  <= vKeep;
              end if;

            when "011" =>
              -- P2=0 | P1=1 | P0=1: inizio di un possibile cluster.
              sDataFifoIn <= sP1(pDATA_WIDTH-1 downto 0);
              sDataFifoWE <= '1';

              vNewLength := sCandidateWords + 1;
              if sCandidateWords = 0 then
                vStart := sP1Address;
              else
                vStart := sCandidateStart;
              end if;

              if sCandidateSeed = '1' or sP1(cPIPE_HT_BIT) = '1' then
                vKeep := '1';
              else
                vKeep := '0';
              end if;

              if vNewLength = cMAX_CLUSTER_WORDS then
                sAddressFifoIn <=
                  vKeep &
                  std_logic_vector(to_unsigned(vStart, pUSEDW_WIDTH)) &
                  std_logic_vector(to_unsigned(vNewLength-1,
                                               cCLUSTER_LEN_WIDTH));
                sAddressFifoWE  <= '1';
                sCandidateWords <= 0;
                sCandidateSeed  <= '0';
              else
                sCandidateWords <= vNewLength;
                sCandidateStart <= vStart;
                sCandidateSeed  <= vKeep;
              end if;

            when "100" =>
              -- P2=1 | P1=0 | P0=0: fine regolare. P1 è la post-strip.
              -- ADDR mantiene il possibile cluster soltanto se è
              -- stata vista una strip sopra HT.
              if sCandidateWords > 0 then
                vNewLength := sCandidateWords + 1;
                sDataFifoIn <= sP1(pDATA_WIDTH-1 downto 0);
                sDataFifoWE <= '1';
                sAddressFifoIn <=
                  sCandidateSeed &
                  std_logic_vector(to_unsigned(sCandidateStart,
                                               pUSEDW_WIDTH)) &
                  std_logic_vector(to_unsigned(vNewLength-1,
                                               cCLUSTER_LEN_WIDTH));
                sAddressFifoWE  <= '1';
                sCandidateWords <= 0;
                sCandidateSeed  <= '0';
              end if;

            when "101" =>
              -- P2=1 | P1=0 | P0=1: una sola strip sotto LT in P1 separa
              -- due possibili cluster.
              sDataFifoIn <= sP1(pDATA_WIDTH-1 downto 0);
              sDataFifoWE <= '1';

              if sCandidateWords = 0 then
                -- Il possibile cluster precedente è già stato chiuso dal limite
                -- di 128 (standard ma non fisso) parole. P1 diventa la nuova pre-strip.
                sCandidateStart <= sP1Address;
                sCandidateWords <= 1;
                sCandidateSeed  <= '0';

              elsif sCandidateSeed = '1' then
                -- Possibile cluster valido: P1 viene usata come post-strip e non
                -- viene duplicata come pre-strip del cluster successivo.
                vNewLength := sCandidateWords + 1;
                sAddressFifoIn <=
                  '1' &
                  std_logic_vector(to_unsigned(sCandidateStart,
                                               pUSEDW_WIDTH)) &
                  std_logic_vector(to_unsigned(vNewLength-1,
                                               cCLUSTER_LEN_WIDTH));
                sAddressFifoWE  <= '1';
                sCandidateWords <= 0;
                sCandidateSeed  <= '0';

              else
                -- Possibile cluster non valido: il descrittore scarta solo le
                -- parole precedenti. P1 resta in testa alla DATA FIFO ed è
                -- la pre-strip del possibile cluster successivo.
                sAddressFifoIn <=
                  '0' &
                  std_logic_vector(to_unsigned(sCandidateStart,
                                               pUSEDW_WIDTH)) &
                  std_logic_vector(to_unsigned(sCandidateWords-1,
                                               cCLUSTER_LEN_WIDTH));
                sAddressFifoWE  <= '1';
                sCandidateStart <= sP1Address;
                sCandidateWords <= 1;
                sCandidateSeed  <= '0';
              end if;

            when "110" =>
              -- P2=1 | P1=1 | P0=0: possibile cluster in terminazione
              -- P1 è ancora sopra LT.
              sDataFifoIn <= sP1(pDATA_WIDTH-1 downto 0);
              sDataFifoWE <= '1';

              vNewLength := sCandidateWords + 1;
              if sCandidateWords = 0 then
                vStart := sP1Address;
              else
                vStart := sCandidateStart;
              end if;

              if sCandidateSeed = '1' or sP1(cPIPE_HT_BIT) = '1' then
                vKeep := '1';
              else
                vKeep := '0';
              end if;

              if vNewLength = cMAX_CLUSTER_WORDS then
                sAddressFifoIn <=
                  vKeep &
                  std_logic_vector(to_unsigned(vStart, pUSEDW_WIDTH)) &
                  std_logic_vector(to_unsigned(vNewLength-1,
                                               cCLUSTER_LEN_WIDTH));
                sAddressFifoWE  <= '1';
                sCandidateWords <= 0;
                sCandidateSeed  <= '0';
              else
                sCandidateWords <= vNewLength;
                sCandidateStart <= vStart;
                sCandidateSeed  <= vKeep;
              end if;

            when "111" =>
              -- P2=1 | P1=1 | P0=1: possibile cluster in corso.
              sDataFifoIn <= sP1(pDATA_WIDTH-1 downto 0);
              sDataFifoWE <= '1';

              vNewLength := sCandidateWords + 1;
              if sCandidateWords = 0 then
                vStart := sP1Address;
              else
                vStart := sCandidateStart;
              end if;

              if sCandidateSeed = '1' or sP1(cPIPE_HT_BIT) = '1' then
                vKeep := '1';
              else
                vKeep := '0';
              end if;

              if vNewLength = cMAX_CLUSTER_WORDS then
                sAddressFifoIn <=
                  vKeep &
                  std_logic_vector(to_unsigned(vStart, pUSEDW_WIDTH)) &
                  std_logic_vector(to_unsigned(vNewLength-1,
                                               cCLUSTER_LEN_WIDTH));
                sAddressFifoWE  <= '1';
                sCandidateWords <= 0;
                sCandidateSeed  <= '0';
              else
                sCandidateWords <= vNewLength;
                sCandidateStart <= vStart;
                sCandidateSeed  <= vKeep;
              end if;

            when "000" =>
              -- P2=0 | P1=0 | P0=0: nessun cluster attivo o in partenza.
              null;

            when others =>
              null;
          end case;
        end if;
    end if;
  end process PIPELINE_MANAGER;

  -- PROCESSO PER SCARICARE ADDRESS FIFO E DATA FIFO
  -- Un descrittore valido genera l'header seguito dai relativi campioni; un
  -- descrittore non valido consuma e scarta le parole della DATA FIFO.
  -- Il backpressure non perde e non duplica parole perché la lettura successiva
  -- dalla FIFO è legata all'accettazione della parola in uscita.
  FIFO_UNLOADER : process(iCLK, iRST)
    variable vLength : natural range 1 to cMAX_CLUSTER_WORDS;
  begin
    if iRST = '1' then
      sUnloadState     <= U_IDLE;
      sUnloadAddress   <= 0;
      sUnloadRemaining <= 0;

    elsif rising_edge(iCLK) then
      if sState = IDLE then
        sUnloadState     <= U_IDLE;
        sUnloadAddress   <= 0;
        sUnloadRemaining <= 0;
      else
        case sUnloadState is
          when U_IDLE =>
            if sAddressFifoEmpty = '0' then
              sUnloadState <= U_DESC_WAIT;
            end if;

          when U_DESC_WAIT =>
            vLength :=
              to_integer(unsigned(sAddressFifoQ(cCLUSTER_LEN_WIDTH-1 downto 0))) + 1;
            sUnloadRemaining <= vLength;
            sUnloadAddress <= to_integer(unsigned(
              sAddressFifoQ(cCLUSTER_LEN_WIDTH+pUSEDW_WIDTH-1 downto
                            cCLUSTER_LEN_WIDTH)));

            if sAddressFifoQ(cADDRESS_FIFO_WIDTH-1) = '1' then
              sUnloadState <= U_HEADER;
            else
              sUnloadState <= U_DISCARD_DATA;
            end if;

          when U_HEADER =>
            if iFULL = '0' then
              if sDataFifoEmpty = '0' then
                sUnloadState <= U_KEEP_DATA;
              else
                sUnloadState <= U_KEEP_WAIT_DATA;
              end if;
            end if;

          when U_KEEP_WAIT_DATA =>
            if sDataFifoEmpty = '0' then
              sUnloadState <= U_KEEP_DATA;
            end if;

          when U_KEEP_DATA =>
            if iFULL = '0' then
              if sUnloadRemaining = 1 then
                sUnloadRemaining <= 0;
                sUnloadState     <= U_IDLE;
              else
                sUnloadRemaining <= sUnloadRemaining - 1;
                if sDataFifoEmpty = '1' then
                  sUnloadState <= U_KEEP_WAIT_DATA;
                end if;
              end if;
            end if;

          when U_DISCARD_DATA =>
            if sDataFifoEmpty = '0' then
              if sUnloadRemaining = 1 then
                sUnloadRemaining <= 0;
                sUnloadState     <= U_IDLE;
              else
                sUnloadRemaining <= sUnloadRemaining - 1;
              end if;
            end if;

          when others =>
            sUnloadState <= U_IDLE;
        end case;
      end if;
    end if;
  end process FIFO_UNLOADER;

end architecture Behavioral;
