-- ee_ram.vhd -- the Emotion Engine's 32 MB of main memory, held in HBM.
--
-- Unlike the GS's local memory, this one has no choice about where it lives.
-- 32 MB is 1024 UltraRAM blocks: 160 % of the C1100's 640 and 320 % of the
-- FK33's 320 (docs/hbm.md). It does not fit on either part by a wide margin, so
-- HBM is not an optimisation here the way it is for the IOP's BIOS ROM -- it is
-- the precondition for an Emotion Engine existing on these cards at all.
--
-- What that costs is latency. HBM answers in something like 100-150 ns, and a
-- CPU that stalled that long on every load would run at a few MHz. The real
-- R5900 does not have this problem because it has caches; this block therefore
-- carries the cache that stands between the EE bus and HBM, and the EE core,
-- when it exists, sees a memory that usually answers immediately.
--
-- The cache is deliberately the simplest thing that is correct:
--
--   * Direct-mapped, 512 lines of 64 bytes = 32 KB, in block RAM. 64 bytes is
--     the R5900's own line size, so a line fill is exactly what the core would
--     have asked for.
--   * Write-through, no allocate on a write miss. A write hit updates the line
--     and HBM; a write miss goes only to HBM. There are no dirty bits and no
--     eviction write-back, which removes the entire class of bug where a line is
--     dropped with the only copy of something in it. It costs write bandwidth,
--     and that is the one thing there is no shortage of: a 256-bit port at
--     250 MHz is 8 GB/s against an EE that writes a small fraction of that.
--
-- A write-back cache would be faster on paper. It is not obviously faster in
-- practice here, and it is much easier to get wrong, so the burden of proof sits
-- with changing it -- once there is an EE to measure.
--
-- NOTE (unverified): the line size, the 32 KB capacity and write-through are
-- chosen by argument, not measurement, and no EE exists to measure. Verify by:
-- replaying a real EE memory trace against this and against a write-back
-- variant, once the R5900 core can produce one.
--
-- The AXI side is 256 bits, matching one HBM pseudo-channel. A 64-byte line is
-- two beats; a write is one beat with byte strobes.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity ee_ram is
   generic
   (
      ADDR_BITS  : integer := 25;                      -- 2^25 = 32 MB
      LINE_LOG2  : integer := 6;                       -- 64-byte lines
      INDEX_LOG2 : integer := 9;                       -- 512 lines = 32 KB
      HBM_BASE   : std_logic_vector(32 downto 0) := "1" & x"80000000"   -- 6 GiB
   );
   port
   (
      clk        : in  std_logic;
      reset      : in  std_logic;

      -- EE side: one 128-bit access at a time.  req is held until ack.
      req        : in  std_logic;
      we         : in  std_logic;
      addr       : in  std_logic_vector(ADDR_BITS-1 downto 0);   -- byte address
      wdata      : in  std_logic_vector(127 downto 0);
      wbe        : in  std_logic_vector(15 downto 0);
      ack        : out std_logic := '0';                          -- one cycle
      rdata      : out std_logic_vector(127 downto 0) := (others => '0');

      -- counters, so the cache can be judged rather than assumed
      stat_hits  : out unsigned(31 downto 0) := (others => '0');
      stat_miss  : out unsigned(31 downto 0) := (others => '0');

      -- AXI4 master to one HBM pseudo-channel (256-bit)
      m_awaddr   : out std_logic_vector(32 downto 0) := (others => '0');
      m_awlen    : out std_logic_vector(7 downto 0)  := (others => '0');
      m_awsize   : out std_logic_vector(2 downto 0)  := "101";     -- 32 bytes
      m_awburst  : out std_logic_vector(1 downto 0)  := "01";      -- INCR
      m_awvalid  : out std_logic := '0';
      m_awready  : in  std_logic;
      m_wdata    : out std_logic_vector(255 downto 0) := (others => '0');
      m_wstrb    : out std_logic_vector(31 downto 0)  := (others => '0');
      m_wlast    : out std_logic := '0';
      m_wvalid   : out std_logic := '0';
      m_wready   : in  std_logic;
      m_bvalid   : in  std_logic;
      m_bready   : out std_logic := '0';
      m_araddr   : out std_logic_vector(32 downto 0) := (others => '0');
      m_arlen    : out std_logic_vector(7 downto 0)  := (others => '0');
      m_arsize   : out std_logic_vector(2 downto 0)  := "101";
      m_arburst  : out std_logic_vector(1 downto 0)  := "01";
      m_arvalid  : out std_logic := '0';
      m_arready  : in  std_logic;
      m_rdata    : in  std_logic_vector(255 downto 0);
      m_rlast    : in  std_logic;
      m_rvalid   : in  std_logic;
      m_rready   : out std_logic := '0'
   );
end entity;

architecture arch of ee_ram is

   constant LINES     : integer := 2**INDEX_LOG2;
   constant TAG_BITS  : integer := ADDR_BITS - LINE_LOG2 - INDEX_LOG2;
   constant BEATS     : integer := 2**LINE_LOG2 / 32;    -- 256-bit beats per line

   subtype t_index is unsigned(INDEX_LOG2-1 downto 0);
   subtype t_tag   is std_logic_vector(TAG_BITS-1 downto 0);

   -- Tags and valid bits.  Small enough to be registers-plus-BRAM either way;
   -- left as an array so the tool picks.
   type t_tags is array (0 to LINES-1) of t_tag;
   signal tags  : t_tags := (others => (others => '0'));
   signal valid : std_logic_vector(LINES-1 downto 0) := (others => '0');

   -- Data store: one 256-bit word per beat, BEATS beats per line.
   type t_data is array (0 to LINES*BEATS-1) of std_logic_vector(255 downto 0);
   signal data : t_data := (others => (others => '0'));
   attribute ram_style : string;
   attribute ram_style of data : signal is "block";

   type t_state is (IDLE, LOOKUP, FILL_AR, FILL_R, WRITE_AW, WRITE_W, WRITE_B, DONE);
   signal state : t_state := IDLE;

   signal r_addr  : std_logic_vector(ADDR_BITS-1 downto 0) := (others => '0');
   signal r_we    : std_logic := '0';
   signal r_wdata : std_logic_vector(127 downto 0) := (others => '0');
   signal r_wbe   : std_logic_vector(15 downto 0) := (others => '0');
   signal beat    : integer range 0 to BEATS-1 := 0;
   signal fill_hit: std_logic := '0';

   -- address decomposition of the registered request
   signal idx     : t_index;
   signal tag     : t_tag;
   -- which 256-bit beat of the line, and which 128-bit half of that beat
   signal r_beat  : integer range 0 to BEATS-1;
   signal r_half  : std_logic;

   -- Speculative decomposition of the *incoming* address, so the tag and data
   -- arrays can be read on the same edge that latches the request.  That read
   -- has to be synchronous or the data array does not infer block RAM: an
   -- earlier version read it combinationally in LOOKUP and synthesis put the
   -- whole 32 KB in distributed RAM -- 9552 LUTs of it.  Reading tag and data
   -- speculatively in parallel and comparing the cycle after is also simply how
   -- a cache works.
   signal s_idx   : t_index;
   signal s_ln    : integer range 0 to LINES*BEATS-1;
   signal data_q  : std_logic_vector(255 downto 0) := (others => '0');
   signal tag_q   : t_tag := (others => '0');
   signal valid_q : std_logic := '0';

   signal hits, misses : unsigned(31 downto 0) := (others => '0');

   function line_base(a : std_logic_vector) return std_logic_vector is
      variable v : std_logic_vector(32 downto 0) := (others => '0');
   begin
      v(ADDR_BITS-1 downto 0) := a;
      v(LINE_LOG2-1 downto 0) := (others => '0');
      return v;
   end function;

begin

   s_idx  <= unsigned(addr(LINE_LOG2+INDEX_LOG2-1 downto LINE_LOG2));
   s_ln   <= to_integer(s_idx) * BEATS + to_integer(unsigned(addr(LINE_LOG2-1 downto 5)));

   idx    <= unsigned(r_addr(LINE_LOG2+INDEX_LOG2-1 downto LINE_LOG2));
   tag    <= r_addr(ADDR_BITS-1 downto LINE_LOG2+INDEX_LOG2);
   r_beat <= to_integer(unsigned(r_addr(LINE_LOG2-1 downto 5)));
   r_half <= r_addr(4);

   stat_hits <= hits;
   stat_miss <= misses;

   -- The data array gets exactly ONE read statement and ONE write statement, so
   -- it is a true dual-port memory and infers block RAM.  With the write-hit and
   -- the line-fill writing the array from two places, synthesis reported
   -- "Infeasible attribute ram_style = block" and put all 32 KB in distributed
   -- RAM -- 14208 LUTs.  The state machine now sets d_wr/d_wa/d_wd instead, and
   -- the single assignment at the end of the process does the write.
   process (clk)
      variable ln    : integer range 0 to LINES*BEATS-1;
      variable word  : std_logic_vector(255 downto 0);
      variable strb  : std_logic_vector(31 downto 0);
      variable wide  : std_logic_vector(255 downto 0);
      variable d_wr  : boolean;
      variable d_wa  : integer range 0 to LINES*BEATS-1;
      variable d_wd  : std_logic_vector(255 downto 0);
   begin
      if rising_edge(clk) then
         d_wr := false;
         d_wa := 0;
         d_wd := (others => '0');
         -- Only `ack` defaults.  The AXI valid lines must NOT: a valid stays up
         -- until its ready is seen, which is necessarily a later cycle, and
         -- defaulting them low here made the state code assert and cancel a
         -- valid in the same process pass -- the last assignment won and the
         -- beat was never presented at all.
         ack <= '0';

         if (reset = '1') then
            state  <= IDLE;
            valid  <= (others => '0');
            hits   <= (others => '0');
            misses <= (others => '0');
         else
            case state is

               when IDLE =>
                  if (req = '1') then
                     r_addr  <= addr;
                     r_we    <= we;
                     r_wdata <= wdata;
                     r_wbe   <= wbe;
                     -- speculative reads, from the address arriving now
                     data_q  <= data(s_ln);
                     tag_q   <= tags(to_integer(s_idx));
                     valid_q <= valid(to_integer(s_idx));
                     state   <= LOOKUP;
                  end if;

               -- One cycle after the request is registered, idx/tag are settled
               -- and the tag array has been read.
               when LOOKUP =>
                  ln := to_integer(idx) * BEATS + r_beat;
                  if (r_we = '1') then
                     -- Write-through.  Update the line only if it is resident;
                     -- never allocate, so a write can neither evict nor leave
                     -- the only copy of anything in the cache.
                     if (valid_q = '1' and tag_q = tag) then
                        word := data_q;
                        for b in 0 to 15 loop
                           if (r_wbe(b) = '1') then
                              if (r_half = '0') then
                                 word(b*8+7 downto b*8) := r_wdata(b*8+7 downto b*8);
                              else
                                 word(128 + b*8+7 downto 128 + b*8) := r_wdata(b*8+7 downto b*8);
                              end if;
                           end if;
                        end loop;
                        d_wr := true; d_wa := ln; d_wd := word;
                        hits <= hits + 1;
                     else
                        misses <= misses + 1;
                     end if;
                     state <= WRITE_AW;
                  else
                     if (valid_q = '1' and tag_q = tag) then
                        if (r_half = '0') then
                           rdata <= data_q(127 downto 0);
                        else
                           rdata <= data_q(255 downto 128);
                        end if;
                        hits  <= hits + 1;
                        ack   <= '1';
                        state <= IDLE;
                     else
                        misses <= misses + 1;
                        beat   <= 0;
                        state  <= FILL_AR;
                     end if;
                  end if;

               -- ---- read miss: fetch the whole line ----------------------
               when FILL_AR =>
                  if (m_arvalid = '0') then
                     m_araddr  <= std_logic_vector(unsigned(HBM_BASE) + unsigned(line_base(r_addr)));
                     m_arlen   <= std_logic_vector(to_unsigned(BEATS-1, 8));
                     m_arvalid <= '1';
                  elsif (m_arready = '1') then
                     m_arvalid <= '0';
                     m_rready  <= '1';
                     state     <= FILL_R;
                  end if;

               when FILL_R =>
                  if (m_rvalid = '1') then
                     d_wr := true;
                     d_wa := to_integer(idx) * BEATS + beat;
                     d_wd := m_rdata;
                     if (m_rlast = '1') then
                        m_rready <= '0';
                        tags(to_integer(idx))  <= tag;
                        valid(to_integer(idx)) <= '1';
                        -- serve the word that was asked for out of what just
                        -- arrived, rather than re-reading the array next cycle
                        if (beat = r_beat) then
                           if (r_half = '0') then rdata <= m_rdata(127 downto 0);
                           else                   rdata <= m_rdata(255 downto 128); end if;
                        end if;
                        ack   <= '1';
                        state <= IDLE;
                     else
                        if (beat = r_beat) then
                           if (r_half = '0') then rdata <= m_rdata(127 downto 0);
                           else                   rdata <= m_rdata(255 downto 128); end if;
                        end if;
                        beat <= beat + 1;
                     end if;
                  end if;

               -- ---- write-through -----------------------------------------
               when WRITE_AW =>
                  if (m_awvalid = '0') then
                     m_awaddr  <= std_logic_vector(unsigned(HBM_BASE) +
                                                   unsigned(line_base(r_addr)) +
                                                   to_unsigned(r_beat * 32, 33));
                     m_awlen   <= (others => '0');
                     m_awvalid <= '1';
                  elsif (m_awready = '1') then
                     m_awvalid <= '0';
                     state     <= WRITE_W;
                  end if;

               when WRITE_W =>
                  if (m_wvalid = '0') then
                     -- The 128-bit write sits in one half of the 256-bit beat;
                     -- the byte strobes keep the other half untouched.
                     wide := (others => '0');
                     strb := (others => '0');
                     if (r_half = '0') then
                        wide(127 downto 0)   := r_wdata;
                        strb(15 downto 0)    := r_wbe;
                     else
                        wide(255 downto 128) := r_wdata;
                        strb(31 downto 16)   := r_wbe;
                     end if;
                     m_wdata  <= wide;
                     m_wstrb  <= strb;
                     m_wlast  <= '1';
                     m_wvalid <= '1';
                  elsif (m_wready = '1') then
                     m_wvalid <= '0';
                     m_wlast  <= '0';
                     m_bready <= '1';
                     state    <= WRITE_B;
                  end if;

               when WRITE_B =>
                  if (m_bvalid = '1') then
                     m_bready <= '0';
                     ack      <= '1';
                     state    <= IDLE;
                  end if;

               when DONE =>
                  state <= IDLE;

            end case;
         end if;

         -- the one and only write to the data array
         if d_wr then
            data(d_wa) <= d_wd;
         end if;
      end if;
   end process;

end architecture;
