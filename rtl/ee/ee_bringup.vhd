-- ee_bringup.vhd -- the R5900 with 64 KB of memory, for getting it onto a card.
--
-- This is not the Emotion Engine's memory system. That is ee_ram.vhd: 32 MB in
-- HBM behind a cache, because 32 MB is 1024 UltraRAM blocks and the C1100 has
-- 640. This file exists for the step before that one -- running the core on
-- real silicon at the console's clock, with a memory small enough to be made of
-- UltraRAM and simple enough to have no behaviour of its own.
--
-- The Graphics Synthesizer was brought up exactly this way and it was the right
-- order: gs_top with its local memory in UltraRAM ran on the card months before
-- anything DMA'd into it, and every fault found in that period was a fault in
-- the Graphics Synthesizer rather than in the plumbing around it. A bring-up
-- memory that answers in one cycle, always, cannot be the reason a test fails.
--
-- **Two ports, no arbitration.** ee_ram has one port and arbitrates, because
-- HBM has one port. A block RAM has two, so instruction fetch and data access
-- each get one and neither ever waits for the other. That is not how a
-- PlayStation 2 behaves and it is not meant to be: it removes a variable while
-- the clock is the thing being measured.
--
-- The host writes the program through the data port while the core is held in
-- reset. Doing it through the same port the core uses -- rather than a third --
-- means the memory has two ports on silicon and not three, which is what lets
-- it infer as UltraRAM instead of as registers.
--
-- SPDX-License-Identifier: GPL-2.0-only

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ee_bringup is
   generic (
      WORDS_LOG2 : integer := 12                       -- 4096 x 128 bit = 64 KB
   );
   port (
      clk        : in  std_logic;
      reset      : in  std_logic;                      -- holds the core; host may write
      pc_reset   : in  std_logic_vector(31 downto 0) := x"00000000";

      -- host access, valid only while reset is high
      h_we       : in  std_logic := '0';
      h_addr     : in  std_logic_vector(WORDS_LOG2-1 downto 0) := (others => '0');
      h_wdata    : in  std_logic_vector(127 downto 0) := (others => '0');
      h_rdata    : out std_logic_vector(127 downto 0);

      -- observation
      retires    : out unsigned(31 downto 0) := (others => '0');
      last_pc    : out std_logic_vector(63 downto 0) := (others => '0');
      dbg_sel    : in  unsigned(4 downto 0) := (others => '0');
      dbg_gpr    : out std_logic_vector(127 downto 0);
      dbg_hi     : out std_logic_vector(63 downto 0);
      dbg_lo     : out std_logic_vector(63 downto 0);
      dbg_traps  : out unsigned(15 downto 0);
      dbg_stall  : out unsigned(2 downto 0);

      -- The data port, brought out so a testbench can see it. xsim will not
      -- resolve a hierarchical reference from SystemVerilog into a VHDL
      -- entity's internals, so "just probe dut.d_ready" does not work and the
      -- signals have to be ports. They cost nothing: a board that leaves them
      -- unconnected has them trimmed.
      dbg_d_addr  : out std_logic_vector(31 downto 0);
      dbg_d_ready : out std_logic;
      dbg_d_write : out std_logic;
      dbg_d_rdata : out std_logic_vector(127 downto 0)
   );
end entity;

architecture rtl of ee_bringup is
   constant N : integer := 2 ** WORDS_LOG2;
   type mem_t is array (0 to N - 1) of std_logic_vector(127 downto 0);
   signal mem : mem_t := (others => (others => '0'));
   attribute ram_style : string;
   -- **Block RAM, and both ports in one process.**
   --
   -- The first version asked for "ultra" and wrote the two ports as two
   -- separate clocked processes. Vivado inferred neither UltraRAM nor block
   -- RAM: it built the whole 64 KB out of **29,268 LUTs of distributed RAM**,
   -- silently, and the design came back 77% route with its critical path
   -- ending at a RAMD64E. A memory that does not infer is not a warning, it is
   -- a different design.
   --
   -- Two things were wrong. Inference wants both ports of a dual-port memory in
   -- **one** clocked process, because that is the template it matches against;
   -- and block RAM is the right target here rather than UltraRAM, because this
   -- memory has byte enables and BRAM has them natively. 64 KB is about fifteen
   -- RAMB36 out of 1,344 on this part, so there is no reason to reach for URAM
   -- at all -- gs_lmem does, because 4 MB is 128 URAMs and would be 1,000
   -- BRAMs, but that argument does not transfer to a sixty-fourth of the size.
   attribute ram_style of mem : signal is "block";

   signal i_addr  : std_logic_vector(31 downto 0);
   signal i_read  : std_logic;
   signal i_data  : std_logic_vector(31 downto 0) := (others => '0');
   signal i_ready : std_logic := '0';

   signal d_addr  : std_logic_vector(31 downto 0);
   signal d_read  : std_logic;
   signal d_write : std_logic;
   signal d_be    : std_logic_vector(15 downto 0);
   signal d_wdata : std_logic_vector(127 downto 0);
   signal d_rdata : std_logic_vector(127 downto 0);
   signal d_ready : std_logic := '0';

   signal retire    : std_logic;
   signal retire_pc : std_logic_vector(63 downto 0);

   -- The instruction port reads a 128-bit word and picks a quarter of it, so
   -- the memory is one width throughout and the fetch unit still sees the
   -- 32-bit word it asked for.
   -- Port B's one address, one write and one read, so the template sees a
   -- memory with two ports rather than three.
   signal b_we    : std_logic := '0';
   signal b_addr  : std_logic_vector(WORDS_LOG2-1 downto 0) := (others => '0');
   signal b_wdata : std_logic_vector(127 downto 0) := (others => '0');
   signal b_be    : std_logic_vector(15 downto 0) := (others => '0');
   signal b_rdata : std_logic_vector(127 downto 0) := (others => '0');
   signal d_go    : std_logic;

   signal i_qsel : std_logic_vector(1 downto 0) := "00";
   signal i_line : std_logic_vector(127 downto 0) := (others => '0');
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
         dbg_sa => open, dbg_traps => dbg_traps, dbg_stall => dbg_stall);

   -- ---- both ports, in one process so the template is recognised -------
   --
   -- Port A is instruction fetch and reads only. Port B is data, and is the
   -- host's while the core is in reset -- doing the host's writes through the
   -- same port the core uses, rather than adding a third, is what keeps this a
   -- two-port memory and therefore inferrable at all.
   --
   -- **One read output per port.** The version before this had port B writing
   -- two different registers -- h_rdata in the reset branch and d_rdata in the
   -- other -- and Vivado answered with
   --
   --   [Synth 8-6849] Infeasible attribute ram_style = "block" ... trying to
   --   implement using LUTRAM
   --
   -- and built the whole 64 KB out of 29,268 lookup tables. A block RAM has
   -- exactly one data output per port; two conditional read destinations on one
   -- port do not match it. Reading once into b_rdata and fanning it out
   -- afterwards is the same behaviour and does match.
   --
   -- The lesson is the warning itself. "Infeasible attribute" is Vivado saying
   -- it could not do what was asked and did something else instead -- and it is
   -- a *warning*, so the design still builds, still places and routes, and is
   -- simply a different machine. The first EE build spent 29,268 LUTs and came
   -- back 77% route without anything failing.
   -- **One access per request.**
   --
   -- The core holds d_read or d_write asserted until it sees d_ready, which is
   -- at least two cycles. A port that answers "d_ready <= d_read or d_write"
   -- therefore performs the access again on the cycle the core is still
   -- holding the request, and raises a *second* d_ready behind the first --
   -- which the core reads as a later memory operation completing early.
   --
   -- sim/ee/tb_ee_core.sv has always had the guard for this:
   --
   --     if ((d_read || d_write) && !dpend && !d_ready)
   --
   -- and the omission here is exactly why the same program passed in
   -- simulation and failed twelve times out of twelve on the card. The
   -- testbench and the bring-up wrapper are two implementations of the same
   -- memory, and only one of them had been checked against the core.
   d_go    <= (d_read or d_write) and (not d_ready);
   b_we    <= (reset and h_we) or ((not reset) and d_write and d_go);
   b_addr  <= h_addr when reset = '1'
              else d_addr(WORDS_LOG2 + 3 downto 4);
   b_wdata <= h_wdata when reset = '1' else d_wdata;
   b_be    <= (others => '1') when reset = '1' else d_be;
   h_rdata <= b_rdata;
   d_rdata <= b_rdata;

   dbg_d_addr  <= d_addr;
   dbg_d_ready <= d_ready;
   dbg_d_write <= d_write;
   dbg_d_rdata <= d_rdata;

   process (clk)
      variable a : integer range 0 to N - 1;
   begin
      if rising_edge(clk) then
         -- port A: instruction fetch
         i_line  <= mem(to_integer(unsigned(i_addr(WORDS_LOG2 + 3 downto 4))));
         i_qsel  <= i_addr(3 downto 2);
         i_ready <= i_read;

         -- port B: data, or the host while the core is held in reset
         a := to_integer(unsigned(b_addr));
         if b_we = '1' then
            for k in 0 to 15 loop
               if b_be(k) = '1' then
                  mem(a)(8 * k + 7 downto 8 * k) <= b_wdata(8 * k + 7 downto 8 * k);
               end if;
            end loop;
         end if;
         b_rdata <= mem(a);
         if reset = '1' then
            d_ready <= '0';
         else
            d_ready <= d_go;
         end if;
      end if;
   end process;

   -- The fetch unit asked for a 32-bit word; the memory is 128 wide. This
   -- picks the quarter, one cycle behind, alongside the registered read.
   --
   -- **This assignment was deleted once**, by a careless region replacement
   -- while the memory was being restructured. i_data then had no driver at all,
   -- which is legal VHDL for a signal with an initialiser: it compiled, it
   -- elaborated, and synthesis trimmed the entire R5900 because nothing fed it
   -- instructions. `ee_core` came back as 42 LUTs and zero DSPs.
   --
   -- The tell was timing *improving*: the build met 294.912 MHz with positive
   -- slack, which should have been the first thing to disbelieve. An empty
   -- design always meets timing.
   with i_qsel select i_data <=
      i_line( 31 downto   0) when "00",
      i_line( 63 downto  32) when "01",
      i_line( 95 downto  64) when "10",
      i_line(127 downto  96) when others;

   -- ---- observation ------------------------------------------------------
   process (clk)
   begin
      if rising_edge(clk) then
         if reset = '1' then
            retires <= (others => '0');
            last_pc <= (others => '0');
         elsif retire = '1' then
            retires <= retires + 1;
            last_pc <= retire_pc;
         end if;
      end if;
   end process;

end architecture;
