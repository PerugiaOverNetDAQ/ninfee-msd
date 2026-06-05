--!@file CNSubtraction.vhd
--!@brief Common Noise compute and subtraction using CN RAM banks, instead of HeapArrays and FIFOs.
--!@details In this version ll pedestal-subtracted samples are written to the CN RAM. Only samples
--!         below or equal to RHT are inserted in SMA. Once the median for one
--!         64-strip VA bank is available, the completed RAM bank is read back
--!         while the opposite bank can already receive the next samples.
--!@author Luca Russo
--!@date 05/06/2026
--!@version 2.1.0 

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.basic_package.all;
use work.FOOTpackage.all;

entity CNSubtraction is
  generic (
    pADC_STRIPS        : natural := cADC_CHANNELS;
    pADC_NUM           : natural := cTOTAL_ADCS;
    pCN_RAM_ADDR_WIDTH : natural := ceil_log2(cFE_CHANNELS)
  );
  port (
    -- global control & clock
    iCLK                : in  std_logic;
    iRST                : in  std_logic;
    iEN                 : in  std_logic; -- New event

    -- PREVIOUS MODULE INTERFACE
    iWORD               : in t_FOOT_lef_data; -- Pedestal-subtracted word
    iPUTD               : in std_logic;       -- The word is valid

    -- CN RAM writer interface: all samples are written
    oCN_RAM_WR_en       : out std_logic;
    oCN_RAM_WR_bank     : out std_logic;
    oCN_RAM_WR_addr     : out std_logic_vector(pCN_RAM_ADDR_WIDTH-1 downto 0);
    oCN_RAM_WR_data     : out t_FOOT_lef_data;

    -- CN RAM reader interface: used after median computation for subtraction
    oCN_RAM_RD_req      : out std_logic;
    oCN_RAM_RD_en       : out std_logic;
    oCN_RAM_RD_bank     : out std_logic;
    oCN_RAM_RD_addr     : out std_logic_vector(pCN_RAM_ADDR_WIDTH-1 downto 0);
    iCN_RAM_RD_grant    : in  std_logic;
    iCN_RAM_RD_data     : in  t_FOOT_lef_data;
    iCN_RAM_RD_valid    : in  std_logic;

    -- CALIB RAM INTERFACE
    oRHT_ADDR           : out std_logic_vector(6 downto 0);
    iRHT_DATA           : in t_FOOT_lef_data;

    -- NEXT MODULE INTERFACE ** 2ND FIFO **
    oQ                  : out t_FOOT_lef_data;
    oPUTD               : out std_logic;
    iFULL               : in std_logic;

    -- SMA INTERFACE
    oSMA_NRST           : out std_logic;
    oSMA_INS_en         : out std_logic_vector(pADC_NUM-1 downto 0);
    oSMA_INS_data       : out t_FOOT_lef_data;
    iSMA_Median         : in  t_FOOT_lef_data;
    oSMA_Flush          : out std_logic_vector(pADC_NUM-1 downto 0);
    iSMA_Valid          : in  std_logic_vector(pADC_NUM-1 downto 0);

    oBUSY               : out std_logic
  );
end entity CNSubtraction;

architecture Behavioral of CNSubtraction is

  attribute syn_encoding : string;

  type Compute_type is (IDLE, F_FETCH, FETCH, TWAIT, STORE_MED, CHECK, FLUSHING);
  signal C_state : Compute_type;
  attribute syn_encoding of C_state : signal is "onehot";

  type Sub_type is (S_IDLE, S_COMP);
  signal S_state : Sub_type;
  attribute syn_encoding of S_state : signal is "onehot";

  type Sigma_type is (R_IDLE, R_FETCH, R_STORE, R_COMP);
  signal SR_state : Sigma_type;
  attribute syn_encoding of SR_state : signal is "onehot";

  type sSMA_cnt is array (0 to pADC_NUM-1) of natural range 0 to (pADC_STRIPS/2);

  signal intMedian      : t_FOOT_lef_data;
  signal sSubMedian     : t_FOOT_lef_data;
  signal intValid       : std_logic;

  signal strp_cnt_128   : natural range 0 to pADC_STRIPS-1;

  signal sRST           : std_logic;
  signal smRST          : std_logic;

  signal sValid_vec     : std_logic_vector(pADC_NUM-1 downto 0);
  signal sValid_latched : std_logic_vector(pADC_NUM-1 downto 0);
  signal sValid_rst     : std_logic;

  signal sRHT_ADDR      : std_logic_vector(6 downto 0);
  signal sRHT_strp_cnt  : natural range 0 to pADC_STRIPS-1;
  signal sRHT_data      : t_FOOT_lef_data;

  signal sSMA_putd      : std_logic_vector(pADC_NUM-1 downto 0);
  signal sSMA_pexp      : std_logic_vector(pADC_NUM-1 downto 0);
  signal sSMA_i_data    : t_FOOT_lef_data;
  signal sSMA_flush     : std_logic_vector(pADC_NUM-1 downto 0);
  signal sSMA_insertCnt : sSMA_cnt;

  signal sWriteBank     : std_logic := '0';
  signal sCompletedBank : std_logic := '0';
  signal sReadBank      : std_logic := '0';

  signal sRdIssueCnt    : natural range 0 to (pADC_STRIPS/2);
  signal sRdOutCnt      : natural range 0 to (pADC_STRIPS/2);
  signal sRdReq         : std_logic;
  signal sRdEn          : std_logic;
  signal sRdAddr        : std_logic_vector(pCN_RAM_ADDR_WIDTH-1 downto 0);

  function f_addr64(iCnt : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(iCnt mod cFE_CHANNELS, pCN_RAM_ADDR_WIDTH));
  end function;

begin

  oBUSY <= '1' when (C_state /= IDLE or S_state /= S_IDLE) else '0';

  smRST <= iRST or sRST;

  oRHT_ADDR      <= sRHT_ADDR;
  oSMA_NRST      <= smRST;
  oSMA_INS_en    <= sSMA_putd;
  oSMA_INS_data  <= sSMA_i_data;
  oSMA_Flush     <= sSMA_flush;
  sValid_vec     <= iSMA_Valid;

  oCN_RAM_WR_bank <= sWriteBank;
  oCN_RAM_RD_bank <= sReadBank;
  oCN_RAM_RD_req  <= sRdReq;
  oCN_RAM_RD_en   <= sRdEn;
  oCN_RAM_RD_addr <= sRdAddr;

  -----------------------------------------------------------------------------
  -- Latch SMA valid pulses until the expected set of ADCs has answered.
  -----------------------------------------------------------------------------
  process(iCLK, iRST)
  begin
    if iRST = '1' then
      sValid_latched <= (others => '0');
    elsif rising_edge(iCLK) then
      if sValid_rst = '1' then
        sValid_latched <= (others => '0');
      else
        for i in 0 to pADC_NUM-1 loop
          sValid_latched(i) <= sValid_latched(i) or sValid_vec(i);
        end loop;
      end if;
    end if;
  end process;

  -----------------------------------------------------------------------------
  -- RHT comparison + CN RAM write.
  -- Every sample is written to the active write bank. Only samples <= RHT are
  -- inserted in SMA.
  -----------------------------------------------------------------------------
  process(iCLK, iRST)
  begin
    if iRST = '1' then
      sRHT_strp_cnt   <= 0;
      sRHT_ADDR       <= (others => '0');
      SR_state        <= R_IDLE;
      sSMA_i_data     <= (others => (others => '0'));
      sSMA_putd       <= (others => '0');
      oCN_RAM_WR_en   <= '0';
      oCN_RAM_WR_addr <= (others => '0');
      oCN_RAM_WR_data <= (others => (others => '0'));

    elsif rising_edge(iCLK) then
      sSMA_putd     <= (others => '0');
      oCN_RAM_WR_en <= '0';

      case SR_state is
        when R_IDLE =>
          sRHT_strp_cnt <= 0;
          if iEN = '1' then
            SR_state <= R_FETCH;
          end if;

        when R_FETCH =>
          sRHT_ADDR <= std_logic_vector(to_unsigned(sRHT_strp_cnt, 7));
          SR_state  <= R_STORE;

        when R_STORE =>
          sRHT_data <= iRHT_DATA;
          SR_state  <= R_COMP;

        when R_COMP =>
          if iPUTD = '1' then
            sSMA_i_data     <= iWORD;
            oCN_RAM_WR_en   <= '1';
            oCN_RAM_WR_addr <= f_addr64(sRHT_strp_cnt);
            oCN_RAM_WR_data <= iWORD;

            for j in 0 to pADC_NUM-1 loop
              if signed(iWORD(j)) > signed(sRHT_data(j)) then
                sSMA_putd(j) <= '0';
              else
                sSMA_putd(j) <= '1';
              end if;
            end loop;

            if sRHT_strp_cnt = pADC_STRIPS - 1 then
              SR_state       <= R_IDLE;
              sRHT_strp_cnt <= 0;
            else
              SR_state       <= R_FETCH;
              sRHT_strp_cnt <= sRHT_strp_cnt + 1;
            end if;
          end if;
      end case;
    end if;
  end process;

  -----------------------------------------------------------------------------
  -- Median computation control. At every VA boundary the completed write bank is
  -- marked for readout and the write bank toggles.
  -----------------------------------------------------------------------------
  process(iCLK, iRST)
  begin
    if iRST = '1' then
      C_state        <= IDLE;
      intValid       <= '0';
      sRST           <= '0';
      strp_cnt_128   <= 0;
      sSMA_flush     <= (others => '0');
      sSMA_pexp      <= (others => '0');
      sSMA_insertCnt <= (others => 0);
      intMedian      <= (others => (others => '0'));
      sValid_rst     <= '0';
      sWriteBank     <= '0';
      sCompletedBank <= '0';

    elsif rising_edge(iCLK) then
      -- Default pulses.
      sRST     <= '0';
      intValid <= '0';

      case C_state is
        when IDLE =>
          strp_cnt_128   <= 0;
          sSMA_flush     <= (others => '0');
          sSMA_pexp      <= (others => '0');
          sSMA_insertCnt <= (others => 0);
          sValid_rst     <= '1';

          if iEN = '1' then
            C_state      <= F_FETCH;
            sValid_rst   <= '0';
            strp_cnt_128 <= 0;
            sWriteBank   <= '0';
          end if;

        when F_FETCH =>
          sValid_rst <= '0';
          if iPUTD = '1' then
            C_state   <= TWAIT;
            intMedian <= (others => (others => '0'));
          end if;

        when FETCH =>
          sValid_rst <= '0';
          if iPUTD = '1' then
            C_state <= TWAIT;
          end if;

        when TWAIT =>
          sValid_rst <= '0';
          sSMA_pexp  <= sSMA_putd;
          C_state    <= STORE_MED;

        when STORE_MED =>
          sValid_rst <= '0';
          for i in 0 to pADC_NUM-1 loop
            if sValid_vec(i) = '1' then
              intMedian(i)      <= iSMA_Median(i);
              sSMA_insertCnt(i) <= sSMA_insertCnt(i) + 1;
            end if;
          end loop;

          if (sValid_latched = sSMA_pexp) or (sValid_vec = sSMA_pexp) then
            C_state     <= CHECK;
            sValid_rst  <= '1';
            sSMA_pexp   <= (others => '0');
          end if;

        when CHECK =>
          sValid_rst <= '1';

          if (strp_cnt_128 = pADC_STRIPS-1) or
             (strp_cnt_128 = (pADC_STRIPS/2)-1) then
            C_state <= FLUSHING;
            for i in 0 to pADC_NUM-1 loop
              if sSMA_insertCnt(i) /= (pADC_STRIPS/2) then
                sSMA_flush(i) <= '1';
                sSMA_pexp(i)  <= '1';
              end if;
            end loop;
          else
            strp_cnt_128 <= strp_cnt_128 + 1;
            C_state      <= FETCH;
            sSMA_pexp    <= (others => '0');
          end if;

        when FLUSHING =>
          sValid_rst <= '0';
          sSMA_flush <= (others => '0');

          for i in 0 to pADC_NUM-1 loop
            if sValid_vec(i) = '1' then
              intMedian(i) <= iSMA_Median(i);
            end if;
          end loop;

          if (sValid_latched = sSMA_pexp) or (sValid_vec = sSMA_pexp) then
            intValid       <= '1';
            sCompletedBank <= sWriteBank;
            sWriteBank     <= not sWriteBank;
            sValid_rst     <= '1';
            sSMA_pexp      <= (others => '0');
            sSMA_insertCnt <= (others => 0);
            sRST           <= '1';

            if strp_cnt_128 = pADC_STRIPS-1 then
              C_state <= IDLE;
            else
              C_state      <= FETCH;
              strp_cnt_128 <= strp_cnt_128 + 1;
            end if;
          end if;
      end case;
    end if;
  end process;

  -----------------------------------------------------------------------------
  -- Sequential readback of the completed 64-word bank and median subtraction.
  -- Address 3F is issued and the FSM stops only after the corresponding data has
  -- been received through iCN_RAM_RD_valid.
  -----------------------------------------------------------------------------
  process(iCLK, iRST)
  begin
    if iRST = '1' then
      S_state      <= S_IDLE;
      oPUTD        <= '0';
      oQ           <= (others => (others => '0'));
      sSubMedian   <= (others => (others => '0'));
      sReadBank    <= '0';
      sRdIssueCnt  <= 0;
      sRdOutCnt    <= 0;
      sRdReq       <= '0';
      sRdEn        <= '0';
      sRdAddr      <= (others => '0');

    elsif rising_edge(iCLK) then
      oPUTD  <= '0';
      sRdEn  <= '0';
      sRdReq <= '0';

      case S_state is
        when S_IDLE =>
          sRdIssueCnt <= 0;
          sRdOutCnt   <= 0;

          if intValid = '1' then
            sSubMedian <= intMedian;
            sReadBank  <= sCompletedBank;
            S_state    <= S_COMP;
          elsif iPUTD = '1' and iEN /= '1' then
            oQ    <= iWORD;
            oPUTD <= '1';
          end if;

        when S_COMP =>
          if sRdIssueCnt < (pADC_STRIPS/2) then
            sRdReq <= '1';
            if (iCN_RAM_RD_grant = '1') and (iFULL = '0') then
              sRdEn       <= '1';
              sRdAddr     <= std_logic_vector(to_unsigned(sRdIssueCnt, pCN_RAM_ADDR_WIDTH));
              sRdIssueCnt <= sRdIssueCnt + 1;
            end if;
          end if;

          if iCN_RAM_RD_valid = '1' then
            for i in 0 to pADC_NUM-1 loop
              oQ(i) <= std_logic_vector(signed(iCN_RAM_RD_data(i)) - signed(sSubMedian(i)));
            end loop;
            oPUTD <= '1';

            if sRdOutCnt = (pADC_STRIPS/2)-1 then
              sRdOutCnt <= 0;
              S_state   <= S_IDLE;
            else
              sRdOutCnt <= sRdOutCnt + 1;
            end if;
          end if;
      end case;
    end if;
  end process;

end architecture Behavioral;
