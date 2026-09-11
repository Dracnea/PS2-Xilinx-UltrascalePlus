-- ee_top.vhd -- the Emotion Engine core wired to its own main memory.
--
-- ee_core and ee_ram had never been connected.  Each was verified against a
-- model of the other: sim/ee/tb_ee_core.sv gives the core a flat memory with a
-- settable latency, and sim/mem/tb_mem.sv gives the cache a behavioural HBM and
-- no processor.  This is the seam between them, and it is not just wiring --
-- there are three real differences to reconcile.
--
-- **Two masters, one port.**  ee_ram serves one 128-bit access at a time and the
-- core has two ports.  Data wins: a load or store is holding up an instruction
-- that is already half executed, while a fetch is speculative and has a queue
-- to wait in.
--
-- **A held strobe on one side, a pulsed request on the other.**  The core raises
-- d_read or d_write and holds it until d_ready.  ee_ram wants the opposite: it
-- latches the request in its IDLE state on the first cycle req is high, so req
-- must be a pulse.  Hold it until ack and ee_ram sees it still high when it
-- returns to IDLE and runs the same access again -- which costs no correctness
-- on a read and is simply wrong on a write.
--
-- Both sides therefore need adapting, in opposite directions.  req is driven as
-- a one-cycle pulse, and d_hold blocks a second issue for exactly the one cycle
-- in which the core is consuming d_ready.  Waiting instead for d_read to *fall*
-- does not work: on back-to-back loads the core clears d_read and raises it
-- again for the next access in the same clocked process, so the later
-- assignment wins and d_read is never seen low.  That deadlocked at instruction
-- 110, having looked perfectly healthy for sixty.
--
-- **Three fetches in flight, answered one at a time.**  i_read is a single-cycle
-- pulse per request and the core allows MAX_OUT = 3 of them outstanding, with
-- replies required *in order*.  ee_ram can only be asked one thing at a time, so
-- the addresses queue here and are served in turn.  Dropping one would not look
-- like a memory fault; it would look like the fetch unit losing an instruction.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity ee_top is
   generic
   (
      ADDR_BITS  : integer := 25;                      -- 2^25 = 32 MB
      LINE_LOG2  : integer := 6;
      INDEX_LOG2 : integer := 9;
      HBM_BASE   : std_logic_vector(32 downto 0) := "1" & x"80000000"
   );
   port
   (
      clk        : in  std_logic;
      reset      : in  std_logic;
      pc_reset   : in  std_logic_vector(31 downto 0) := x"00000000";

      -- cache counters, so the memory can be judged rather than assumed
      stat_hits  : out unsigned(31 downto 0);
      stat_miss  : out unsigned(31 downto 0);

      -- AXI4 master to one HBM pseudo-channel, straight out of ee_ram
      m_awaddr   : out std_logic_vector(32 downto 0);
      m_awlen    : out std_logic_vector(7 downto 0);
      m_awsize   : out std_logic_vector(2 downto 0);
      m_awburst  : out std_logic_vector(1 downto 0);
      m_awvalid  : out std_logic;
      m_awready  : in  std_logic;
      m_wdata    : out std_logic_vector(255 downto 0);
      m_wstrb    : out std_logic_vector(31 downto 0);
      m_wlast    : out std_logic;
      m_wvalid   : out std_logic;
      m_wready   : in  std_logic;
      m_bvalid   : in  std_logic;
      m_bready   : out std_logic;
      m_araddr   : out std_logic_vector(32 downto 0);
      m_arlen    : out std_logic_vector(7 downto 0);
      m_arsize   : out std_logic_vector(2 downto 0);
      m_arburst  : out std_logic_vector(1 downto 0);
      m_arvalid  : out std_logic;
      m_arready  : in  std_logic;
      m_rdata    : in  std_logic_vector(255 downto 0);
      m_rlast    : in  std_logic;
      m_rvalid   : in  std_logic;
      m_rready   : out std_logic;

      -- the core's observation points, passed through unchanged
      retire     : out std_logic;
      retire_pc  : out std_logic_vector(63 downto 0);
      dbg_sel    : in  unsigned(4 downto 0) := (others => '0');
      dbg_gpr    : out std_logic_vector(127 downto 0);
      dbg_hi     : out std_logic_vector(63 downto 0);
      dbg_lo     : out std_logic_vector(63 downto 0);
      dbg_hi1    : out std_logic_vector(63 downto 0);
      dbg_lo1    : out std_logic_vector(63 downto 0);
      dbg_sa     : out std_logic_vector(3 downto 0);
      dbg_traps  : out unsigned(15 downto 0);
      dbg_stall  : out unsigned(2 downto 0)
   );
end entity;

architecture arch of ee_top is
   -- core ports
   signal i_addr  : std_logic_vector(31 downto 0);
   signal i_read  : std_logic;
   signal i_data  : std_logic_vector(31 downto 0) := (others => '0');
   signal i_ready : std_logic := '0';
   signal d_addr  : std_logic_vector(31 downto 0);
   signal d_read, d_write : std_logic;
   signal d_be    : std_logic_vector(15 downto 0);
   signal d_wdata : std_logic_vector(127 downto 0);
   signal d_rdata : std_logic_vector(127 downto 0) := (others => '0');
   signal d_ready : std_logic := '0';

   -- memory port
   signal r_req   : std_logic := '0';
   signal r_we    : std_logic := '0';
   signal r_addr  : std_logic_vector(ADDR_BITS-1 downto 0) := (others => '0');
   signal r_wdata : std_logic_vector(127 downto 0) := (others => '0');
   signal r_wbe   : std_logic_vector(15 downto 0) := (others => '0');
   signal r_ack   : std_logic;
   signal r_rdata : std_logic_vector(127 downto 0);

   -- the fetch queue.  Four deep for three in flight, so a push on the cycle a
   -- pop happens never meets a full queue.
   constant FD : integer := 4;
   type fq_t is array (0 to FD-1) of std_logic_vector(31 downto 0);
   signal fq     : fq_t := (others => (others => '0'));
   signal fq_wr  : integer range 0 to FD-1 := 0;
   signal fq_rd  : integer range 0 to FD-1 := 0;
   signal fq_cnt : integer range 0 to FD := 0;

   type st_t is (S_IDLE, S_DATA, S_INST);
   signal st : st_t := S_IDLE;
   -- High for exactly the one cycle in which the core is consuming d_ready.
   --
   -- The first attempt at this was a flag cleared when d_read fell, which
   -- deadlocked at instruction 110: on back-to-back loads the core clears
   -- d_read and raises it again for the next access in the same clocked
   -- process, so the later assignment wins and **d_read is never observed
   -- low**.  A flag waiting for a falling edge that never comes waits forever.
   -- One cycle is all that is needed: the core cannot signal a new request
   -- until the cycle after it sees d_ready, because d_read is registered.
   signal d_hold : std_logic := '0';
   -- which 32-bit word of the quadword the fetch in progress wants
   signal i_sel : integer range 0 to 3 := 0;
begin

   core : entity work.ee_core
      port map (
         clk => clk, reset => reset, pc_reset => pc_reset,
         i_addr => i_addr, i_read => i_read, i_data => i_data, i_ready => i_ready,
         d_addr => d_addr, d_read => d_read, d_write => d_write,
         d_be => d_be, d_wdata => d_wdata, d_rdata => d_rdata, d_ready => d_ready,
         retire => retire, retire_pc => retire_pc,
         dbg_sel => dbg_sel, dbg_gpr => dbg_gpr,
         dbg_hi => dbg_hi, dbg_lo => dbg_lo,
         dbg_hi1 => dbg_hi1, dbg_lo1 => dbg_lo1, dbg_sa => dbg_sa,
         dbg_traps => dbg_traps, dbg_stall => dbg_stall);

   ram : entity work.ee_ram
      generic map (ADDR_BITS => ADDR_BITS, LINE_LOG2 => LINE_LOG2,
                   INDEX_LOG2 => INDEX_LOG2, HBM_BASE => HBM_BASE)
      port map (
         clk => clk, reset => reset,
         req => r_req, we => r_we, addr => r_addr,
         wdata => r_wdata, wbe => r_wbe, ack => r_ack, rdata => r_rdata,
         stat_hits => stat_hits, stat_miss => stat_miss,
         m_awaddr => m_awaddr, m_awlen => m_awlen, m_awsize => m_awsize,
         m_awburst => m_awburst, m_awvalid => m_awvalid, m_awready => m_awready,
         m_wdata => m_wdata, m_wstrb => m_wstrb, m_wlast => m_wlast,
         m_wvalid => m_wvalid, m_wready => m_wready,
         m_bvalid => m_bvalid, m_bready => m_bready,
         m_araddr => m_araddr, m_arlen => m_arlen, m_arsize => m_arsize,
         m_arburst => m_arburst, m_arvalid => m_arvalid, m_arready => m_arready,
         m_rdata => m_rdata, m_rlast => m_rlast, m_rvalid => m_rvalid,
         m_rready => m_rready);

   process (clk)
      variable pushed : boolean;
   begin
      if rising_edge(clk) then
         d_ready <= '0';
         i_ready <= '0';
         d_hold  <= '0';
         -- req is a *pulse*, not a level.  ee_ram latches the request in its
         -- IDLE state on the first cycle it sees req, so holding req up until
         -- ack means it is still high when ee_ram returns to IDLE and the same
         -- access is issued a second time.  sim/mem/tb_mem.sv drives it as a
         -- pulse and says nothing about why; this is why.
         r_req   <= '0';

         if reset = '1' then
            st     <= S_IDLE;
            r_req  <= '0';
            d_hold <= '0';
            fq_wr  <= 0; fq_rd <= 0; fq_cnt <= 0;
         else
            -- A fetch request is a one-cycle pulse, so it has to be taken the
            -- cycle it appears whatever else is going on.
            pushed := false;
            if i_read = '1' and fq_cnt < FD then
               fq(fq_wr) <= i_addr;
               fq_wr     <= (fq_wr + 1) mod FD;
               pushed    := true;
            end if;

            case st is
               when S_IDLE =>
                  if (d_read = '1' or d_write = '1') and d_hold = '0' then
                     r_req   <= '1';
                     r_we    <= d_write;
                     r_addr  <= d_addr(ADDR_BITS-1 downto 0);
                     r_wdata <= d_wdata;
                     r_wbe   <= d_be;
                     st      <= S_DATA;
                  elsif fq_cnt > 0 then
                     r_req  <= '1';
                     r_we   <= '0';
                     r_addr <= fq(fq_rd)(ADDR_BITS-1 downto 0);
                     i_sel  <= to_integer(unsigned(fq(fq_rd)(3 downto 2)));
                     st     <= S_INST;
                  end if;

               when S_DATA =>
                  if r_ack = '1' then
                     r_req   <= '0';
                     d_rdata <= r_rdata;
                     d_ready <= '1';
                     d_hold  <= '1';
                     st      <= S_IDLE;
                  end if;

               when S_INST =>
                  if r_ack = '1' then
                     r_req  <= '0';
                     i_data <= r_rdata(32 * i_sel + 31 downto 32 * i_sel);
                     i_ready <= '1';
                     fq_rd  <= (fq_rd + 1) mod FD;
                     st     <= S_IDLE;
                  end if;
            end case;

            -- the queue's count, once, counting this cycle's push and pop
            if pushed and not (st = S_INST and r_ack = '1') then
               fq_cnt <= fq_cnt + 1;
            elsif (st = S_INST and r_ack = '1') and not pushed then
               fq_cnt <= fq_cnt - 1;
            end if;
         end if;
      end if;
   end process;

end architecture;
