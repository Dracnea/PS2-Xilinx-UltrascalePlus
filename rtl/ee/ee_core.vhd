-- ee_core.vhd -- the R5900's integer datapath, written to the EE Core User's
-- Manual and checked against sim/ee/r5900_ref.py instruction by instruction.
--
-- Five stages, single issue, in order:
--
--   IF   a two-entry fetch queue with one request outstanding
--   ID   decode and register read
--   A1   forwarding, the ALU, the branch condition, the effective address,
--        and the multi-cycle multiply and divide
--   A2   the data port, and the branch redirect
--   WB   the register file, HI and LO
--
-- Execution is split across two stages, as it is on the real R5900, whose
-- integer pipeline is Q, R, A1, A2, S.  Here the split is where the work
-- genuinely did not fit in one cycle: A1 decides *whether* a branch is taken
-- and *where* it goes, A2 acts on that decision.  Leaving both in one stage put
-- the operand-forwarding mux, a 64-bit comparison and the fetch-PC adder in
-- series -- three structures deep, and shortening any one of them left the
-- other two.  A register through the middle is the only thing that cuts a chain
-- like that, and it costs one more killed instruction on a taken branch.
--
-- The first version of this core was not pipelined -- one instruction at a
-- time through a four-state machine -- because a hazard is easier to add to
-- something that already gives right answers than to find in something that
-- does not.  It gave right answers, and then place-and-route said what that
-- cost: with decode, the register-file read mux, the ALU and the writeback mux
-- all in one cycle, the critical path was 5.4 ns against a 3.39 ns budget and
-- no arithmetic unit could be made multi-cycle to fix it.  Pipelining is the
-- answer to that, and it is also the answer to a second question that timing
-- has nothing to do with: the R5900 is a six-stage dual-issue machine, and a
-- model that retires one instruction at a time cannot be cycle-accurate to it
-- at any clock.  Both demands point the same way.
--
-- Three things about this core that are not stock MIPS III, and that the shape
-- of the RTL has to carry from the start rather than acquire later:
--
--   * **GPRs are 128 bits.**  Integer instructions define only the low 64 and
--     leave the upper half alone -- MMI reads it later.  The register file is
--     128 bits wide here even though nothing in this slice writes the top half,
--     because widening it afterwards touches every path that carries a register.
--   * **MULT and MULTU write a GPR as well as HI/LO**, as a three-operand
--     instruction.  rd = 0 is the MIPS-compatible encoding and writes nothing.
--   * **A 32-bit result is sign-extended through all 64 bits.**  Every op that
--     the manual calls a word operation ends in sext32, including the shifts.
--
-- Two rules govern where architectural state is written, and both exist so the
-- differential trace stays meaningful:
--
--   * **Nothing commits before WB.**  HI and LO are computed in A1 but carried
--     down the pipeline and written in WB with the register file, because the
--     testbench samples all architectural state at each retire and an early
--     write would make an instruction's result visible while an *older* one is
--     still retiring.
--   * **Every read is forwarded.**  ID bypasses the instruction in WB; EX
--     forwards from MEM and from WB.  Between them those cover every distance
--     except a load whose value is still in flight, which is what the load-use
--     interlock stalls for.
--
-- Two different things are called traps here and the distinction matters.
--
--   * **Architectural exceptions are taken.**  SYSCALL, BREAK and integer
--     overflow raise in A1, travel down the pipeline and commit in WB like any
--     other result, writing EPC and Cause -- including Cause.BD, which needs the
--     branch-delay-slot question answered a stage earlier than it is asked.
--     ERET returns.  Nothing about them is counted rather than performed.
--
--   * **`dbg_traps` counts instructions this core does not implement**, which
--     is a debugging aid and not an architectural feature.  An undecoded
--     instruction increments it and writes nothing, so a differential test that
--     agrees on every register while this counter climbs is a test that proved
--     less than it looks: a silent difference would be worse than a loud
--     unimplemented one, which is the reason the counter exists at all.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity ee_core is
   port
   (
      clk        : in  std_logic;
      reset      : in  std_logic;
      pc_reset   : in  std_logic_vector(31 downto 0) := x"00000000";

      -- instruction port, 32 bits.  One request may be outstanding; the reply
      -- may arrive any number of cycles later, and i_ready marks it.
      i_addr     : out std_logic_vector(31 downto 0) := (others => '0');
      i_read     : out std_logic := '0';
      i_data     : in  std_logic_vector(31 downto 0) := (others => '0');
      i_ready    : in  std_logic := '0';

      -- data port, 128 bits with byte enables.  A quadword, not a doubleword,
      -- for two reasons that agree: LQ and SQ move all 128 bits of a register
      -- and cannot be expressed on a narrower port without a second beat, and
      -- ee_ram.vhd -- the 32 MB main memory this core will attach to -- already
      -- presents exactly this width.  Every narrower access picks its bytes out
      -- of the quadword with the byte enables and the address's low four bits.
      d_addr     : out std_logic_vector(31 downto 0) := (others => '0');
      d_read     : out std_logic := '0';
      d_write    : out std_logic := '0';
      d_be       : out std_logic_vector(15 downto 0) := (others => '0');
      d_wdata    : out std_logic_vector(127 downto 0) := (others => '0');
      d_rdata    : in  std_logic_vector(127 downto 0) := (others => '0');
      d_ready    : in  std_logic := '0';

      -- for the testbench: one pulse per retired instruction, with the state
      -- that instruction produced.  This is what gets diffed against the model.
      retire     : out std_logic := '0';
      retire_pc  : out std_logic_vector(63 downto 0) := (others => '0');
      dbg_sel    : in  unsigned(4 downto 0) := (others => '0');
      -- All 128 bits: MMI writes the upper half, and a trace that showed only
      -- the low 64 would call two different machine states identical.
      dbg_gpr    : out std_logic_vector(127 downto 0) := (others => '0');
      dbg_hi     : out std_logic_vector(63 downto 0) := (others => '0');
      dbg_lo     : out std_logic_vector(63 downto 0) := (others => '0');
      dbg_hi1    : out std_logic_vector(63 downto 0) := (others => '0');
      -- the shift-amount register, four bits: a byte offset in a quadword
      dbg_sa     : out std_logic_vector(3 downto 0) := (others => '0');
      dbg_lo1    : out std_logic_vector(63 downto 0) := (others => '0');
      dbg_traps  : out unsigned(15 downto 0) := (others => '0');
      -- why no instruction entered A1 on this edge, so that cycles lost to the
      -- fetch unit can be told apart from cycles lost to the memory port or to
      -- an interlock.  0 issued, 1 data port, 2 multiply/divide, 3 load-use,
      -- 4 fetch starved, 5 killed by a branch redirect.
      dbg_stall  : out unsigned(2 downto 0) := (others => '0')
   );
end entity;

architecture arch of ee_core is
   type regfile_t is array (0 to 31) of std_logic_vector(127 downto 0);
   signal gpr    : regfile_t := (others => (others => '0'));
   signal hi, lo : std_logic_vector(63 downto 0) := (others => '0');
   -- The R5900's second HI/LO pair, written by the MMI pipeline-1 forms.  MULT1
   -- and its relatives are not SIMD: they are the ordinary multiply and divide
   -- aimed at this pair, so two multiply chains can be in flight without
   -- spilling.  Their function codes mirror the SPECIAL ones exactly, which is
   -- why the decode below reuses the same arms rather than duplicating them --
   -- duplicated arms are how the second pair would quietly drift from the first.
   signal hi1, lo1 : std_logic_vector(63 downto 0) := (others => '0');

   -- The shift-amount register.  Four bits, because it names a byte within a
   -- quadword and nothing else: QFSRV is its only reader, and MTSAB and MTSAH
   -- already mask their operands to that much.  It is architectural state, so
   -- it is written in WB with everything else and forwarded like HI and LO --
   -- an MTSAB immediately before a QFSRV is the way the pair is actually used.
   signal sa_reg : std_logic_vector(3 downto 0) := (others => '0');

   -- COP0, the system control coprocessor: 32 registers of 32 bits.  This slice
   -- is the register file and MFC0/MTC0 only.  Count is deliberately not
   -- free-running: the reference has no notion of time, and a counter that
   -- advanced would make every trace disagree for a reason unrelated to either
   -- side being wrong.  The timer belongs with the exception path.
   constant PRID : std_logic_vector(31 downto 0) := x"00002E20";
   -- COP0 register numbers and exception codes used by the exception path
   constant C0_STATUS : integer := 12;
   constant C0_CAUSE  : integer := 13;
   constant C0_EPC    : integer := 14;
   constant EXC_SYSCALL : integer := 8;
   constant EXC_BREAK   : integer := 9;
   constant EXC_OV      : integer := 12;
   type cop0_t is array (0 to 31) of std_logic_vector(31 downto 0);
   signal cop0 : cop0_t := (15 => PRID, others => (others => '0'));
   signal traps  : unsigned(15 downto 0) := (others => '0');

   -- ---- IF -----------------------------------------------------------------
   -- Several requests may be outstanding at once, and the queue is deep enough
   -- to hold every reply that could arrive.
   --
   -- The first version allowed exactly one outstanding request, on the reasoning
   -- that a two-entry queue would absorb replies and keep the rate up.  That was
   -- simply wrong, and profiling said so: a reply is observed two edges after
   -- the request is issued, and with one request in flight the next cannot go
   -- out until the previous comes back, so the unit issues on every *other*
   -- edge and the whole core is stuck at CPI 2 no matter what the pipeline does.
   -- Fetch starvation was 67% of all cycles on a program with no memory
   -- operations in it at all.  Sustaining one instruction per cycle needs as
   -- many requests in flight as there are cycles of latency to cover, which is
   -- Little's law and not something a buffer can substitute for.
   --
   -- The PC of each reply does not have to be carried alongside the request.
   -- Replies come back in order, so resp_pc -- the PC of the next reply that
   -- will be kept -- simply advances by four each time one is kept, and is
   -- reloaded with the target on a redirect, because the first reply kept after
   -- a redirect is by definition the first request issued after it.
   constant FQ_DEPTH : integer := 4;   -- queue entries
   constant MAX_OUT  : integer := 3;   -- requests in flight

   -- The program counter is 32 bits, which is the width of the R5900's address
   -- bus and of this core's instruction port.  Carrying it as 64 doubled every
   -- PC adder and every PC mux in the design.  The link value and the retired
   -- PC are sign-extended back to 64 bits at the two points that need them,
   -- which is what the manual specifies anyway.
   signal fetch_pc   : unsigned(31 downto 0) := (others => '0');
   signal resp_pc    : unsigned(31 downto 0) := (others => '0');
   signal outst      : integer range 0 to MAX_OUT := 0;   -- requests in flight
   signal drop       : integer range 0 to MAX_OUT := 0;   -- of which wrong-path
   signal redir_pend : std_logic := '0';
   -- An exception invalidates the pipeline on the cycle it commits, but the
   -- fetch redirect waits one more.  Committing and redirecting together put
   -- the vector-or-EPC mux in front of the branch redirect that was already
   -- there, and an ablation costed that at about 9% of the clock.  Precision is
   -- unaffected -- the latches are cleared immediately, so nothing younger can
   -- commit in the intervening cycle -- and an extra cycle on an exception is
   -- free, since exceptions are rare and the pipeline is empty anyway.
   signal exc_redir  : std_logic := '0';
   signal exc_pc     : unsigned(31 downto 0) := (others => '0');
   signal redir_tgt  : unsigned(31 downto 0) := (others => '0');

   type q_pc_t is array (0 to FQ_DEPTH - 1) of unsigned(31 downto 0);
   type q_ir_t is array (0 to FQ_DEPTH - 1) of std_logic_vector(31 downto 0);
   signal q_pc  : q_pc_t := (others => (others => '0'));
   signal q_ir  : q_ir_t := (others => (others => '0'));
   signal q_cnt : integer range 0 to FQ_DEPTH := 0;

   -- ---- ID/A1 --------------------------------------------------------------
   signal d_valid   : std_logic := '0';
   signal d_pc      : unsigned(31 downto 0) := (others => '0');
   signal d_ir      : std_logic_vector(31 downto 0) := (others => '0');
   signal d_a, d_b  : std_logic_vector(127 downto 0) := (others => '0');
   signal d_rs      : integer range 0 to 31 := 0;
   signal d_rt      : integer range 0 to 31 := 0;
   -- The branch target and the link address are computed in ID, not EX.  Both
   -- depend only on the PC and the instruction word, which ID already has, and
   -- leaving them in A1 put two chained 64-bit adders between the ID/A1 latch
   -- and the fetch PC -- 11 of the 20 logic levels on the critical path, for
   -- arithmetic that had no reason to be there.  EX now only decides whether
   -- the branch is taken and, for JR and JALR, substitutes the register.
   -- whether this instruction sits in a branch delay slot, which Cause.BD
   -- reports and which decides whether EPC names it or the branch before it
   signal d_bd      : std_logic := '0';
   -- Set when a branch leaves A1 and cleared when its delay slot enters.  It
   -- cannot be derived from "is the instruction in A1 a branch", because the
   -- two are only adjacent when the fetch keeps up: let the queue run dry and a
   -- bubble sits between them, the derivation says no, and EPC then names the
   -- delay slot instead of the branch -- so an exception in a delay slot
   -- resumes past the branch and takes the wrong path.  It shows up only at
   -- slower instruction memories, which is what the latency matrix is for.
   signal bd_pend   : std_logic := '0';
   signal d_tgt     : unsigned(31 downto 0) := (others => '0');
   signal d_link    : std_logic_vector(63 downto 0) := (others => '0');

   -- ---- A1/A2 -------------------------------------------------------------
   signal m_valid   : std_logic := '0';
   signal m_pc      : unsigned(31 downto 0) := (others => '0');
   signal m_we      : std_logic := '0';
   signal m_rd      : integer range 0 to 31 := 0;
   signal m_val     : std_logic_vector(127 downto 0) := (others => '0');
   signal m_w128    : std_logic := '0';
   signal m_p1      : std_logic := '0';
   -- An exception is raised in A1 and committed in WB.  WB is the in-order
   -- commit point, so raising it there is precise by construction: everything
   -- older has already written, the faulting instruction writes nothing, and
   -- everything younger is still in a latch that gets invalidated.
   signal m_exc     : std_logic := '0';
   signal m_exc_code: integer range 0 to 31 := 0;
   signal m_eret    : std_logic := '0';
   signal m_bd      : std_logic := '0';
   signal m_c0_we   : std_logic := '0';
   signal m_c0_idx  : integer range 0 to 31 := 0;
   signal m_c0_val  : std_logic_vector(31 downto 0) := (others => '0');
   signal m_hi_we   : std_logic := '0';
   signal m_sa_we   : std_logic := '0';
   -- PMTHI and PMTLO write HI or LO whole, and HI on the R5900 is 128 bits
   -- -- which is exactly the pair this core already keeps as hi and hi1.
   -- Every other writer touches one half, chosen by p1, so the wide write
   -- is a flag beside the existing path rather than a change to it.
   signal m_wide    : std_logic := '0';
   signal m_hiu, m_lou : std_logic_vector(63 downto 0) := (others => '0');
   signal m_sa      : std_logic_vector(3 downto 0) := (others => '0');
   signal m_lo_we   : std_logic := '0';
   signal m_hi      : std_logic_vector(63 downto 0) := (others => '0');
   signal m_lo      : std_logic_vector(63 downto 0) := (others => '0');
   -- the branch decision, made in A1 and acted on in A2
   signal m_take    : std_logic := '0';
   signal m_tgt     : unsigned(31 downto 0) := (others => '0');
   signal m_ismem   : std_logic := '0';
   -- the unaligned group: which of LWL/LWR/LDL/LDR is in flight, and the value
   -- rt held before it, which is what the loaded bytes merge into
   signal m_unal    : std_logic := '0';
   signal m_unal_dw : std_logic := '0';
   signal m_unal_l  : std_logic := '0';
   signal m_mbase   : std_logic_vector(63 downto 0) := (others => '0');
   signal m_isload  : std_logic := '0';
   signal m_width   : integer range 1 to 16 := 4;
   signal m_sign    : std_logic := '0';
   signal m_shift   : integer range 0 to 15 := 0;

   -- ---- A2/WB -------------------------------------------------------------
   signal w_valid   : std_logic := '0';
   signal w_pc      : unsigned(31 downto 0) := (others => '0');
   signal w_we      : std_logic := '0';
   signal w_rd      : integer range 0 to 31 := 0;

   -- Forward selects, decided a cycle early.  "Does A2 write the register A1
   -- is about to read" compares two register outputs, so it does not have to
   -- be asked in A1: both operands of the compare are known at the end of the
   -- previous cycle, once the stage advances have been decided.  Resolving it
   -- there and registering the answer takes the comparator, and the wide
   -- fan-out of its output, off the path that runs mux -> ALU -> A1/A2 latch.
   -- fa_* selects the A operand, fb_* the B; _m from the A1/A2 latch, _w from
   -- the A2/WB latch.  Each already folds in valid, write-enable and rd /= 0.
   signal fa_m, fb_m : std_logic := '0';
   signal fa_w, fb_w : std_logic := '0';
   signal w_val     : std_logic_vector(127 downto 0) := (others => '0');
   signal w_w128    : std_logic := '0';
   signal w_p1      : std_logic := '0';
   signal w_exc     : std_logic := '0';
   signal w_exc_code: integer range 0 to 31 := 0;
   signal w_eret    : std_logic := '0';
   signal w_bd      : std_logic := '0';
   signal w_c0_we   : std_logic := '0';
   signal w_c0_idx  : integer range 0 to 31 := 0;
   signal w_c0_val  : std_logic_vector(31 downto 0) := (others => '0');
   signal w_hi_we   : std_logic := '0';
   signal w_sa_we   : std_logic := '0';
   signal w_wide    : std_logic := '0';
   signal w_hiu, w_lou : std_logic_vector(63 downto 0) := (others => '0');
   signal w_sa      : std_logic_vector(3 downto 0) := (others => '0');
   signal w_lo_we   : std_logic := '0';
   signal w_hi      : std_logic_vector(63 downto 0) := (others => '0');
   signal w_lo      : std_logic_vector(63 downto 0) := (others => '0');

   -- ---- the multi-cycle units, which live in A1 ----------------------------
   -- ex_cnt is the number of cycles the instruction in A1 still needs.  It is
   -- 0 for a single-cycle instruction and for the first cycle of a multi-cycle
   -- one; 1 means "the result is on the wires now", which is the only value at
   -- which A1 is allowed to advance.
   -- Long enough for PDIVBW, which is two passes of the pair of dividers with
   -- one cycle between them to swap the operands over.
   signal ex_cnt   : integer range 0 to 66 := 0;

   signal div_rem  : unsigned(32 downto 0) := (others => '0');
   signal div_quot : unsigned(31 downto 0) := (others => '0');
   signal div_dvsr : unsigned(31 downto 0) := (others => '0');
   signal div_negq : std_logic := '0';
   signal div_negr : std_logic := '0';

   -- A second, identical iterative divider.  PDIVW and PDIVUW divide two word
   -- pairs at once and both results have to be ready together, so the choice is
   -- a second unit or twice the latency; the R5900 does it in one pass and so
   -- does this.  It is only 32 bits of adder, which is cheap next to the
   -- 128-bit datapath it sits beside.
   signal div2_rem  : unsigned(32 downto 0) := (others => '0');
   signal div2_quot : unsigned(31 downto 0) := (others => '0');
   signal div2_dvsr : unsigned(31 downto 0) := (others => '0');
   signal div2_negq : std_logic := '0';
   signal div2_negr : std_logic := '0';

   -- PDIVBW divides four words by one halfword, which is two passes of the two
   -- dividers.  The first pass's results wait here while the second runs.  A
   -- third and fourth divider would spend four times the area to save
   -- thirty-three cycles on an instruction that is rare in real code, which is
   -- not a trade worth making in a part where the divider is already the
   -- widest thing in the execute stage.
   signal div_p1lo0, div_p1hi0 : std_logic_vector(31 downto 0) := (others => '0');
   signal div_p1lo1, div_p1hi1 : std_logic_vector(31 downto 0) := (others => '0');

   signal mul_a, mul_b  : signed(32 downto 0) := (others => '0');
   signal mul_p1, mul_p : signed(65 downto 0) := (others => '0');

   -- A second multiplier, for PMULTW's and PMULTUW's upper word.  It exists for
   -- the same reason the second divider does -- both products have to arrive
   -- together -- but it was added for a different one, which is worth keeping:
   -- PMULTW originally computed both products *combinationally* in the single
   -- cycle its result was written, and a 32x32 multiply in that path cost the
   -- core about sixty megahertz.  The scalar MULT had solved this on the first
   -- day by walking its product through the DSP's own pipeline registers over
   -- three cycles; PMULTW simply had not been given the same treatment.
   signal mul2_a, mul2_b  : signed(32 downto 0) := (others => '0');
   signal mul2_p1, mul2_p : signed(65 downto 0) := (others => '0');

   -- Eight more, sixteen bits wide, for MMI's halfword multiply-accumulate
   -- group: PMULTH, PMADDH, PHMADH, PMSUBH and PHMSBH all form the same eight
   -- products of rs and rt taken as signed halfwords, and differ only in what
   -- they do with them afterwards.  Eight multipliers is what the R5900 has
   -- and it is what makes these single instructions rather than loops; on this
   -- part they are DSP48s, which the core has plenty of spare.
   --
   -- They are pipelined for three cycles like every other multiply here, and
   -- that is not an optimisation but the lesson from PMULTW: a multiply left
   -- combinationally in the cycle its result is written cost this core sixty
   -- megahertz and went unnoticed for two sessions.
   type hprod_t is array (0 to 7) of signed(31 downto 0);
   type hop_t   is array (0 to 7) of signed(15 downto 0);
   signal hm_a, hm_b   : hop_t   := (others => (others => '0'));
   signal hm_p1, hm_p  : hprod_t := (others => (others => '0'));

   function sext32(v : std_logic_vector(31 downto 0)) return std_logic_vector is
   begin
      return std_logic_vector'(31 downto 0 => v(31)) & v;
   end function;

   function rd_gpr(r : regfile_t; n : integer) return std_logic_vector is
   begin
      if n = 0 then return (127 downto 0 => '0'); end if;
      return r(n);
   end function;

   -- Does this opcode read rs / rt?  Getting these wrong in the safe direction
   -- only costs a stall, so anything unrecognised is assumed to read both.
   -- ---- MMI's parallel ALU ------------------------------------------------
   -- MMI0 (function 0x08) and MMI1 (0x28) are the same handful of operations
   -- over 4 x 32, 8 x 16 or 16 x 8 lanes, in wrapping, signed-saturating and
   -- unsigned-saturating forms.
   --
   -- **One adder per width, with the lane boundaries fixed at elaboration.**
   -- Two earlier shapes are worth knowing about because both were measured:
   --
   --   * thirty separate lane arrays, one per (operation, width) pair, because
   --     every decode arm called a generic function with literal arguments and
   --     synthesis specialised each call.  212.3 MHz, 16597 LUTs.
   --   * one adder shared across all three widths, with its carry broken at
   --     whichever boundary the width selected *at run time*.  Smaller, and 36
   --     MHz slower: a run-time break puts a multiplexer between every pair of
   --     bytes, which is what a fast carry chain cannot tolerate.
   --
   -- This is the third shape and the point of it: the break is chosen when the
   -- design elaborates, so each lane is one ordinary fixed-width addition and
   -- maps to a clean carry chain -- while every *operation* at that width still
   -- shares the one adder, which is where the area went.
   type par_op_t is (P_ADD, P_SUB, P_CGT, P_CEQ, P_MAX, P_MIN,
                     P_ADDS, P_SUBS, P_ADDU, P_SUBU, P_ABS);

   -- One lane's result, from the operands, that lane's sum, and its carry out.
   -- Bounds come from the lane's own width so that one cannot be right at 16
   -- bits and wrong at 8.
   function par_out(op : par_op_t; a, b, sum : std_logic_vector;
                    cout : std_logic) return std_logic_vector is
      constant W    : natural := a'length;
      constant ONES : unsigned(W-1 downto 0) := (others => '1');
      constant SMAX : std_logic_vector(W-1 downto 0)
                    := std_logic_vector(shift_right(ONES, 1));
      constant SMIN : std_logic_vector(W-1 downto 0)
                    := std_logic_vector(not shift_right(ONES, 1));
      constant ZERO : std_logic_vector(W-1 downto 0) := (others => '0');
      constant FULL : std_logic_vector(W-1 downto 0) := (others => '1');
      variable asb, bsb, rsb : std_logic;
      variable ovf, lt, eq   : std_logic;
   begin
      asb := a(a'left); bsb := b(b'left); rsb := sum(sum'left);
      if a = b then eq := '1'; else eq := '0'; end if;
      -- Signed overflow: for a + b the operands must agree in sign and the
      -- result disagree; for a - b they must differ and the result disagree
      -- with a.  Three sign bits, no extra arithmetic.
      case op is
         when P_ADD | P_ADDS | P_ADDU =>
            ovf := (asb xnor bsb) and (rsb xor asb);
         when others =>
            ovf := (asb xor bsb) and (rsb xor asb);
      end case;
      lt := rsb xor ovf;                      -- signed a < b, from the subtract

      case op is
         when P_ADD | P_SUB => return sum;
         when P_ADDS | P_SUBS =>
            -- The saturated value depends only on a's sign: two positives
            -- overflowing add upward, and a positive minus a negative does too.
            if ovf = '1' then
               if asb = '0' then return SMAX; else return SMIN; end if;
            end if;
            return sum;
         when P_ADDU =>
            if cout = '1' then return FULL; else return sum; end if;
         when P_SUBU =>
            -- a + not b + 1 carries out when a >= b, so no carry is a borrow.
            if cout = '0' then return ZERO; else return sum; end if;
         when P_CEQ =>
            if eq = '1' then return FULL; else return ZERO; end if;
         when P_CGT =>
            if lt = '0' and eq = '0' then return FULL; else return ZERO; end if;
         when P_MAX =>
            if lt = '1' then return b; else return a; end if;
         when P_MIN =>
            if lt = '1' then return a; else return b; end if;
         when P_ABS =>
            -- rt only; rs is not read, and the adder was given zero for a, so
            -- sum is already -b.  Negating the most negative value cannot be
            -- represented and the R5900 saturates rather than wrapping.
            if b = SMIN then return SMAX;
            elsif bsb = '1' then return sum;
            else return b; end if;
      end case;
   end function;

   function par_alu(op : par_op_t; a, b : std_logic_vector(127 downto 0);
                    w : natural) return std_logic_vector is
      variable neg : std_logic;
      variable av  : std_logic_vector(127 downto 0);
      variable res : std_logic_vector(127 downto 0) := (others => '0');
      variable n8  : unsigned(7 downto 0);
      variable n16 : unsigned(15 downto 0);
      variable n32 : unsigned(31 downto 0);
      variable s9  : unsigned(8 downto 0);
      variable s17 : unsigned(16 downto 0);
      variable s33 : unsigned(32 downto 0);
   begin
      case op is
         when P_SUB | P_SUBS | P_SUBU | P_CGT | P_MAX | P_MIN | P_ABS =>
            neg := '1';
         when others =>
            neg := '0';
      end case;
      -- PABS is |b|, which is the same subtractor with zero on the other side.
      if op = P_ABS then av := (others => '0'); else av := a; end if;
      n8 := (others => neg); n16 := (others => neg); n32 := (others => neg);

      -- Three static lane structures.  Each addition below has a width the
      -- compiler knows, so the carry chain inside a lane is ordinary and the
      -- break between lanes is free -- there is simply no carry wire there.
      case w is
         when 8 =>
            for k in 0 to 15 loop
               s9 := resize(unsigned(av(8*k+7 downto 8*k)), 9)
                   + resize(unsigned(b(8*k+7 downto 8*k)) xor n8, 9)
                   + unsigned'("" & neg);
               res(8*k+7 downto 8*k) :=
                  par_out(op, av(8*k+7 downto 8*k), b(8*k+7 downto 8*k),
                          std_logic_vector(s9(7 downto 0)), s9(8));
            end loop;
         when 16 =>
            for k in 0 to 7 loop
               s17 := resize(unsigned(av(16*k+15 downto 16*k)), 17)
                    + resize(unsigned(b(16*k+15 downto 16*k)) xor n16, 17)
                    + unsigned'("" & neg);
               res(16*k+15 downto 16*k) :=
                  par_out(op, av(16*k+15 downto 16*k), b(16*k+15 downto 16*k),
                          std_logic_vector(s17(15 downto 0)), s17(16));
            end loop;
         when others =>
            for k in 0 to 3 loop
               s33 := resize(unsigned(av(32*k+31 downto 32*k)), 33)
                    + resize(unsigned(b(32*k+31 downto 32*k)) xor n32, 33)
                    + unsigned'("" & neg);
               res(32*k+31 downto 32*k) :=
                  par_out(op, av(32*k+31 downto 32*k), b(32*k+31 downto 32*k),
                          std_logic_vector(s33(31 downto 0)), s33(32));
            end loop;
      end case;
      return res;
   end function;

   -- ---- MMI's pack, extend and shuffle group -------------------------------
   -- These move lanes about rather than computing anything, so they are wires
   -- and multiplexers and share nothing with the adder above.  Three families,
   -- each one rule at three widths:
   --
   --   PEXTL*  interleave the *low* half of rt and rs, rt supplying even lanes
   --   PEXTU*  the same from the upper half
   --   PPAC*   keep every other lane -- rt's into the low half, rs's the upper
   --
   -- PPAC is the truncating partner of PEXT: taking every other lane of a
   -- 2W-bit value keeps the low W bits of each of its lanes, which is why the
   -- two are encoded adjacently.
   type shf_op_t is (S_PEXTL, S_PEXTU, S_PPAC, S_PEXT5, S_PPAC5,
                     S_PADSBH, S_QFSRV);

   function par_shuf(op : shf_op_t; w : natural;
                     a, b : std_logic_vector(127 downto 0);
                     sa : std_logic_vector(3 downto 0))
      return std_logic_vector is
      variable r : std_logic_vector(127 downto 0) := (others => '0');
      variable q : std_logic_vector(255 downto 0);
      variable o : natural;
   begin
      case op is
         when S_PEXTL | S_PEXTU =>
            if op = S_PEXTL then o := 0; else o := 64; end if;
            case w is
               when 8 =>
                  for i in 0 to 7 loop
                     r(16*i+7  downto 16*i)   := b(o+8*i+7 downto o+8*i);
                     r(16*i+15 downto 16*i+8) := a(o+8*i+7 downto o+8*i);
                  end loop;
               when 16 =>
                  for i in 0 to 3 loop
                     r(32*i+15 downto 32*i)    := b(o+16*i+15 downto o+16*i);
                     r(32*i+31 downto 32*i+16) := a(o+16*i+15 downto o+16*i);
                  end loop;
               when others =>
                  for i in 0 to 1 loop
                     r(64*i+31 downto 64*i)    := b(o+32*i+31 downto o+32*i);
                     r(64*i+63 downto 64*i+32) := a(o+32*i+31 downto o+32*i);
                  end loop;
            end case;

         when S_PPAC =>
            case w is
               when 8 =>
                  for i in 0 to 7 loop
                     r(8*i+7 downto 8*i)          := b(16*i+7 downto 16*i);
                     r(8*(i+8)+7 downto 8*(i+8))  := a(16*i+7 downto 16*i);
                  end loop;
               when 16 =>
                  for i in 0 to 3 loop
                     r(16*i+15 downto 16*i)         := b(32*i+15 downto 32*i);
                     r(16*(i+4)+15 downto 16*(i+4)) := a(32*i+15 downto 32*i);
                  end loop;
               when others =>
                  for i in 0 to 1 loop
                     r(32*i+31 downto 32*i)         := b(64*i+31 downto 64*i);
                     r(32*(i+2)+31 downto 32*(i+2)) := a(64*i+31 downto 64*i);
                  end loop;
            end case;

         when S_PEXT5 =>
            -- RGBA5551 in each word, spread to a byte per channel: five bits
            -- shifted up by three with zeros below, never replicated, and alpha
            -- to bit 31.  The same expansion the GS applies to a 16-bit frame
            -- buffer, minus the 0x80 that only a pixel read wants.
            for k in 0 to 3 loop
               r(32*k+31 downto 32*k) :=
                  b(32*k+15) & "0000000"
                  & b(32*k+14 downto 32*k+10) & "000"
                  & b(32*k+9  downto 32*k+5)  & "000"
                  & b(32*k+4  downto 32*k)    & "000";
            end loop;

         when S_PPAC5 =>
            for k in 0 to 3 loop
               r(32*k+31 downto 32*k) :=
                  x"0000" & b(32*k+31) & b(32*k+23 downto 32*k+19)
                  & b(32*k+15 downto 32*k+11) & b(32*k+7 downto 32*k+3);
            end loop;

         when S_PADSBH =>
            -- The one instruction whose halves do different things: the low
            -- four halfwords subtract and the upper four add.
            for k in 0 to 3 loop
               r(16*k+15 downto 16*k) := std_logic_vector(
                  unsigned(a(16*k+15 downto 16*k)) - unsigned(b(16*k+15 downto 16*k)));
            end loop;
            for k in 4 to 7 loop
               r(16*k+15 downto 16*k) := std_logic_vector(
                  unsigned(a(16*k+15 downto 16*k)) + unsigned(b(16*k+15 downto 16*k)));
            end loop;

         when S_QFSRV =>
            -- {rs, rt} shifted right by SA *bytes*, low 128 bits kept.  SA
            -- counting bytes is what makes this the instruction for realigning
            -- a quadword that straddles a boundary, and is why its shift amount
            -- lives in a register rather than in the instruction word.
            --
            -- Written as sixteen byte-wide selections rather than as
            -- shift_right on the 256-bit value.  The two are the same function
            -- and not the same hardware: the shift builds a barrel shifter
            -- sized for its operand, and this builds exactly what the
            -- instruction needs, sixteen 16-to-1 byte multiplexers.  It is
            -- worth 20 MHz on this core -- more than deleting QFSRV outright
            -- was -- and is the same lesson the load and store alignment
            -- networks taught: make the shifter the width of the answer, not
            -- the width of the operand.
            q := a & b;
            for j in 0 to 15 loop
               r(8*j+7 downto 8*j) :=
                  q(8*(j + to_integer(unsigned(sa)))+7
                    downto 8*(j + to_integer(unsigned(sa))));
            end loop;
      end case;
      return r;
   end function;

   -- ---- MMI2 and MMI3: the permutes ---------------------------------------
   -- Pure lane selections, so they are one function driven by a table rather
   -- than nine hand-written sets of assignments.  't' picks a lane of rt and
   -- 's' a lane of rs; the tables read lowest lane first, as the manual and
   -- PCSX2's MMI.cpp both list them.
   type perm_sel_t is array (natural range <>) of integer;
   type perm_src_t is array (natural range <>) of character;

   function perm_h(srcs : perm_src_t; sel : perm_sel_t;
                   a, b : std_logic_vector(127 downto 0))
      return std_logic_vector is
      variable r : std_logic_vector(127 downto 0);
   begin
      for i in 0 to 7 loop
         if srcs(i) = 's' then
            r(16*i+15 downto 16*i) := a(16*sel(i)+15 downto 16*sel(i));
         else
            r(16*i+15 downto 16*i) := b(16*sel(i)+15 downto 16*sel(i));
         end if;
      end loop;
      return r;
   end function;

   function perm_w(sel : perm_sel_t; b : std_logic_vector(127 downto 0))
      return std_logic_vector is
      variable r : std_logic_vector(127 downto 0);
   begin
      for i in 0 to 3 loop
         r(32*i+31 downto 32*i) := b(32*sel(i)+31 downto 32*sel(i));
      end loop;
      return r;
   end function;

   -- PSLLVW, PSRLVW and PSRAVW: words 0 and 2 of rt, shifted by the low five
   -- bits of the matching word of rs, each sign-extended to a doubleword.  A
   -- 128-bit register in and out, but only half the lanes read and the widths
   -- different on each side, which is why these are not part of the parallel
   -- ALU's table.
   function pshiftv(kind : character; a, b : std_logic_vector(127 downto 0))
      return std_logic_vector is
      variable r  : std_logic_vector(127 downto 0);
      variable v  : unsigned(31 downto 0);
      variable sh : natural range 0 to 31;
      variable q  : unsigned(31 downto 0);
   begin
      for n in 0 to 1 loop
         v  := unsigned(b(64*n+31 downto 64*n));
         sh := to_integer(unsigned(a(64*n+4 downto 64*n)));
         case kind is
            when 'l'    => q := shift_left(v, sh);
            when 'r'    => q := shift_right(v, sh);
            when others => q := unsigned(shift_right(signed(v), sh));
         end case;
         r(64*n+63 downto 64*n) := sext32(std_logic_vector(q));
      end loop;
      return r;
   end function;

   -- PMULTW and PMULTUW: two 32x32 products, into rd, LO and HI at once.
   -- Words 0 and 2 of each operand multiply into doublewords 0 and 1; the low
   -- word of each product goes to LO and the high word to HI, each
   -- sign-extended from 32 bits, while rd gets the products whole.  Three
   -- 128-bit destinations from one instruction, which is what the wide HI/LO
   -- write exists for.
   -- Where PMULTW's and PMULTUW's two products go.  The products themselves are
   -- formed by the two multipliers over three cycles and arrive here already
   -- made; the signed and unsigned forms differ only in how the operands were
   -- widened on the way in, which is why there is one procedure and not two.
   --
   -- Each product is sixty-four bits and goes three places at once: whole into
   -- rd, its low word sign-extended into LO, its high word sign-extended into
   -- HI.  A word landing in a doubleword is always sign-extended on this
   -- machine, unsigned operands or not.
   procedure pmultw(p0, p1 : in signed(63 downto 0);
                    rdv, lov, hiv : out std_logic_vector(127 downto 0)) is
      variable p : signed(63 downto 0);
   begin
      for n in 0 to 1 loop
         if n = 0 then p := p0; else p := p1; end if;
         rdv(64*n+63 downto 64*n) := std_logic_vector(p);
         lov(64*n+63 downto 64*n) := sext32(std_logic_vector(p(31 downto 0)));
         hiv(64*n+63 downto 64*n) := sext32(std_logic_vector(p(63 downto 32)));
      end loop;
   end procedure;

   -- The halfword group's destination map, which is the whole of what
   -- distinguishes these five instructions from eight independent multiplies.
   --
   -- The eight products are dealt out to HI and LO in *pairs*, alternating
   -- between them and working up the register:
   --
   --     p0 p1 -> LO words 0,1      p2 p3 -> HI words 0,1
   --     p4 p5 -> LO words 2,3      p6 p7 -> HI words 2,3
   --
   -- and rd gets the first word of each pair -- LO0, HI0, LO2, HI2 -- which is
   -- why it is written here rather than assembled by the caller. Four groups,
   -- one loop, and the five instructions differ only in the two values each
   -- group produces:
   --
   --     PMULTH  v0 = p(2g)             v1 = p(2g+1)
   --     PMADDH  v0 = LO/HI + p(2g)     v1 = LO/HI + p(2g+1)
   --     PMSUBH  v0 = LO/HI - p(2g)     v1 = LO/HI - p(2g+1)
   --     PHMADH  v0 = p(2g+1) + p(2g)   v1 = p(2g+1)
   --     PHMSBH  v0 = p(2g+1) - p(2g)   v1 = NOT p(2g+1)
   --
   -- > **UNVERIFIED:** `PHMSBH`'s second word is the *complement* of the
   -- > product, not the product.  No manual this project has says so; it is
   -- > PCSX2's behaviour, marked in its own source as undocumented, and this
   -- > is the only account of it anywhere. It is implemented because a guess
   -- > that matches the only known description is better than a different
   -- > guess, and it is tagged because it is still a guess. See
   -- > hw/ps2probe/README.md.
   procedure hmac(form : integer; p : in hprod_t;
                  curlo, curhi : in std_logic_vector(127 downto 0);
                  rdv, lov, hiv : out std_logic_vector(127 downto 0)) is
      variable v0, v1 : signed(31 downto 0);
      variable c0, c1 : signed(31 downto 0);
      variable w      : integer;
   begin
      for g in 0 to 3 loop
         w := 64 * (g / 2);          -- bit offset of this group's first word
         if g mod 2 = 0 then
            c0 := signed(curlo(w + 31 downto w));
            c1 := signed(curlo(w + 63 downto w + 32));
         else
            c0 := signed(curhi(w + 31 downto w));
            c1 := signed(curhi(w + 63 downto w + 32));
         end if;
         case form is
            when 16#1C# => v0 := p(2*g);            v1 := p(2*g+1);       -- PMULTH
            when 16#10# => v0 := c0 + p(2*g);       v1 := c1 + p(2*g+1);  -- PMADDH
            when 16#14# => v0 := c0 - p(2*g);       v1 := c1 - p(2*g+1);  -- PMSUBH
            when 16#11# => v0 := p(2*g+1) + p(2*g); v1 := p(2*g+1);       -- PHMADH
            when others => v0 := p(2*g+1) - p(2*g); v1 := not p(2*g+1);   -- PHMSBH
         end case;
         if g mod 2 = 0 then
            lov(w + 31 downto w)      := std_logic_vector(v0);
            lov(w + 63 downto w + 32) := std_logic_vector(v1);
         else
            hiv(w + 31 downto w)      := std_logic_vector(v0);
            hiv(w + 63 downto w + 32) := std_logic_vector(v1);
         end if;
         rdv(32 * g + 31 downto 32 * g) := std_logic_vector(v0);
      end loop;
   end procedure;

   function reads_rs(ir : std_logic_vector(31 downto 0)) return boolean is
      variable op : integer := to_integer(unsigned(ir(31 downto 26)));
      variable fn : integer := to_integer(unsigned(ir(5 downto 0)));
   begin
      case op is
         when 2 | 3 | 15 => return false;                       -- J, JAL, LUI
         when 16 => return false;                              -- COP0 reads no rs
         when 28 =>
            case fn is
               when 16 | 18 => return false;                     -- MFHI1, MFLO1
               when others  => return true;
            end case;
         when 0 =>
            case fn is
               when 0 | 2 | 3   => return false;                -- shifts by sa
               when 16 | 18     => return false;                -- MFHI, MFLO
               when others      => return true;
            end case;
         when others => return true;
      end case;
   end function;

   function reads_rt(ir : std_logic_vector(31 downto 0)) return boolean is
      variable op : integer := to_integer(unsigned(ir(31 downto 26)));
      variable fn : integer := to_integer(unsigned(ir(5 downto 0)));
   begin
      case op is
         when 0 =>
            case fn is
               when 8 | 9       => return false;                -- JR, JALR
               when 16 | 18     => return false;                -- MFHI, MFLO
               when 17 | 19     => return false;                -- MTHI, MTLO
               when others      => return true;
            end case;
         when 16 =>                                             -- COP0
            return ir(25 downto 21) = "00100";                  -- only MTC0
         when 28 =>                                             -- MMI pipeline-1
            case fn is
               when 16 | 18 | 17 | 19 => return false;
               when others            => return true;
            end case;
         when 4 | 5 => return true;                             -- BEQ, BNE
         when 40 | 41 | 43 | 63 => return true;                 -- stores
         -- LWL/LWR/LDL/LDR merge into rt, so they *read* the register they
         -- write; the store forms read it for their data.  Leaving these out
         -- would mean the merge base was never forwarded, and the bug would
         -- only appear when a compiler emitted the pair back to back -- which
         -- is the only way it ever emits them.
         when 34 | 38 | 26 | 27 => return true;                 -- LWL/LWR/LDL/LDR
         when 42 | 46 | 44 | 45 => return true;                 -- SWL/SWR/SDL/SDR
         when 31 => return true;                               -- SQ stores rt
         when others => return false;   -- rt is the destination, or unused
      end case;
   end function;

   function is_load(ir : std_logic_vector(31 downto 0)) return boolean is
      variable op : integer := to_integer(unsigned(ir(31 downto 26)));
   begin
      case op is
         when 32 | 33 | 35 | 36 | 37 | 39 | 55 => return true;
         when 34 | 38 | 26 | 27 => return true;   -- the unaligned load forms
         when 30 => return true;                  -- LQ
         when others => return false;
      end case;
   end function;

   function is_branch(ir : std_logic_vector(31 downto 0)) return boolean is
      variable op : integer := to_integer(unsigned(ir(31 downto 26)));
      variable fn : integer := to_integer(unsigned(ir(5 downto 0)));
   begin
      case op is
         when 1 | 2 | 3 | 4 | 5 | 6 | 7 => return true;
         when 0 => return fn = 8 or fn = 9;                 -- JR, JALR
         when others => return false;
      end case;
   end function;

   -- PDIVW (MMI2) and PDIVUW (MMI3) share a sub-opcode and differ only in
   -- whether the words are read as signed.
   function is_pdiv(ir : std_logic_vector(31 downto 0)) return boolean is
      variable op : integer := to_integer(unsigned(ir(31 downto 26)));
      variable fn : integer := to_integer(unsigned(ir(5 downto 0)));
      variable sa : integer := to_integer(unsigned(ir(10 downto 6)));
   begin
      return op = 28 and (fn = 16#09# or fn = 16#29#) and sa = 16#0D#;
   end function;

   -- MMI2's halfword multiply-accumulate group, all five of which want the
   -- same eight products and so share one kick-off.
   function is_hmac(ir : std_logic_vector(31 downto 0)) return boolean is
      variable op : integer := to_integer(unsigned(ir(31 downto 26)));
      variable fn : integer := to_integer(unsigned(ir(5 downto 0)));
      variable sa : integer := to_integer(unsigned(ir(10 downto 6)));
   begin
      return op = 28 and fn = 16#09#
             and (sa = 16#10# or sa = 16#11# or sa = 16#14#
                  or sa = 16#15# or sa = 16#1C#);
   end function;

   -- PMULTW (MMI2) and PMULTUW (MMI3): two 32x32 products, multi-cycle.
   function is_pmultw(ir : std_logic_vector(31 downto 0)) return boolean is
      variable op : integer := to_integer(unsigned(ir(31 downto 26)));
      variable fn : integer := to_integer(unsigned(ir(5 downto 0)));
      variable sa : integer := to_integer(unsigned(ir(10 downto 6)));
   begin
      return op = 28 and (fn = 16#09# or fn = 16#29#) and sa = 16#0C#;
   end function;

   -- PMADDUW (MMI3): the same two unsigned products as PMULTUW, accumulated
   -- into a 64-bit value assembled from one word of LO and one of HI.
   function is_pmadduw(ir : std_logic_vector(31 downto 0)) return boolean is
      variable op : integer := to_integer(unsigned(ir(31 downto 26)));
      variable fn : integer := to_integer(unsigned(ir(5 downto 0)));
      variable sa : integer := to_integer(unsigned(ir(10 downto 6)));
   begin
      return op = 28 and fn = 16#29# and sa = 16#00#;
   end function;

   -- PDIVBW is MMI2's other divide: four words by one halfword.
   function is_pdivbw(ir : std_logic_vector(31 downto 0)) return boolean is
      variable op : integer := to_integer(unsigned(ir(31 downto 26)));
      variable fn : integer := to_integer(unsigned(ir(5 downto 0)));
      variable sa : integer := to_integer(unsigned(ir(10 downto 6)));
   begin
      return op = 28 and fn = 16#09# and sa = 16#1D#;
   end function;

   -- Load one of the two dividers with a dividend and a divisor.  Written once
   -- because PDIVBW loads them a second time half way through, and a second
   -- pass that disagreed with the first about how magnitudes are taken would be
   -- wrong on exactly the two words nothing else tests.
   procedure load_div(signal rem_r  : out unsigned(32 downto 0);
                      signal quot_r : out unsigned(31 downto 0);
                      signal dvsr_r : out unsigned(31 downto 0);
                      signal negq_r : out std_logic;
                      signal negr_r : out std_logic;
                      sgn : boolean;
                      d   : std_logic_vector(31 downto 0);
                      v   : std_logic_vector(31 downto 0)) is
   begin
      rem_r <= (others => '0');
      if sgn and d(31) = '1' then
         quot_r <= 0 - unsigned(d);
      else
         quot_r <= unsigned(d);
      end if;
      if sgn and v(31) = '1' then
         dvsr_r <= 0 - unsigned(v);
      else
         dvsr_r <= unsigned(v);
      end if;
      if sgn then
         negq_r <= d(31) xor v(31);
         negr_r <= d(31);
      else
         negq_r <= '0';
         negr_r <= '0';
      end if;
   end procedure;

   function is_muldiv(ir : std_logic_vector(31 downto 0)) return boolean is
      variable op : integer := to_integer(unsigned(ir(31 downto 26)));
      variable fn : integer := to_integer(unsigned(ir(5 downto 0)));
   begin
      if op /= 0 and op /= 28 then return false; end if;
      if fn >= 24 and fn <= 27 then return true; end if;
      return is_pdiv(ir) or is_pdivbw(ir) or is_pmultw(ir) or is_hmac(ir)
             or is_pmadduw(ir);
   end function;

   -- The dividers work in magnitudes; this puts the sign back on and widens
   -- the 32-bit result to the 64-bit half of HI or LO it occupies.
   function dfix32(neg : std_logic; v : unsigned(31 downto 0))
      return std_logic_vector is
   begin
      if neg = '1' then
         return std_logic_vector(0 - v);
      else
         return std_logic_vector(v);
      end if;
   end function;

   function dfix(neg : std_logic; v : unsigned(31 downto 0))
      return std_logic_vector is
   begin
      return sext32(dfix32(neg, v));
   end function;
begin

   dbg_gpr   <= rd_gpr(gpr, to_integer(dbg_sel));
   dbg_hi    <= hi;
   dbg_lo    <= lo;
   dbg_hi1   <= hi1;
   dbg_sa    <= sa_reg;
   dbg_lo1   <= lo1;
   dbg_traps <= traps;

   process (clk)
      -- EX decode and result
      variable op, rs, rt, rd, sa, fn : integer;
      variable a128, b128             : std_logic_vector(127 downto 0);
      variable a, b                   : std_logic_vector(63 downto 0);
      variable simm                   : signed(63 downto 0);
      variable imm                    : std_logic_vector(15 downto 0);
      variable tgt                    : unsigned(31 downto 0);
      variable ea                     : unsigned(63 downto 0);
      variable hi_f, lo_f             : std_logic_vector(63 downto 0);
      variable sa_f                   : std_logic_vector(3 downto 0);
      variable hi1_f, lo1_f           : std_logic_vector(63 downto 0);
      variable hi_r, lo_r             : std_logic_vector(63 downto 0);
      variable ex_p1                  : std_logic;
      variable c0_f                   : std_logic_vector(31 downto 0);
      variable ex_exc, ex_eret        : std_logic;
      variable ex_code                : integer range 0 to 31;
      variable sum32                  : std_logic_vector(31 downto 0);
      variable ex_c0_we               : std_logic;
      variable ex_c0_idx              : integer range 0 to 31;
      variable ex_c0_val              : std_logic_vector(31 downto 0);
      variable op_eff                 : integer;
      variable ex_we                  : std_logic;
      variable ex_rd                  : integer range 0 to 31;
      -- The ALU's result stays 64 bits, because every instruction but MMI
      -- defines only that much.  MMI supplies the upper half separately rather
      -- than widening every assignment in the decode below.
      variable ex_val                 : std_logic_vector(63 downto 0);
      variable ex_valhi               : std_logic_vector(63 downto 0);
      variable ex_w128                : std_logic;
      variable par_v                  : std_logic_vector(127 downto 0);
      variable par_ok                 : boolean;
      variable pv                     : std_logic_vector(127 downto 0);
      variable plo, phi               : std_logic_vector(127 downto 0);
      variable par_alu_on             : boolean;
      variable par_o                  : par_op_t;
      variable par_w                  : natural range 8 to 32;
      variable ex_hi_we, ex_lo_we     : std_logic;
      variable ex_sa_we               : std_logic;
      variable ex_wide                : std_logic;
      variable ex_hiu, ex_lou         : std_logic_vector(63 downto 0);
      variable ex_sa                  : std_logic_vector(3 downto 0);
      variable ex_hi, ex_lo           : std_logic_vector(63 downto 0);
      variable ex_ismem, ex_isload    : std_logic;
      variable ex_width               : integer range 1 to 16;
      variable ex_sign                : std_logic;
      variable ex_shift               : integer range 0 to 15;
      variable ex_addr                : std_logic_vector(31 downto 0);
      variable ex_be                  : std_logic_vector(15 downto 0);
      variable ex_wdata               : std_logic_vector(127 downto 0);
      variable ex_unal, ex_unal_dw    : std_logic;
      variable ex_unal_l              : std_logic;
      variable ex_mbase               : std_logic_vector(63 downto 0);
      variable kk, hw, dh             : integer range 0 to 7;
      variable ex_take                : boolean;
      variable ex_trap                : boolean;
      variable ex_busy                : boolean;
      variable dvd_mag, dvsr_mag      : unsigned(31 downto 0);
      variable dvd2_mag, dvsr2_mag    : unsigned(31 downto 0);
      variable div_shift, div2_shift  : unsigned(32 downto 0);
      variable pdiv, psgn, pdivbw, pmul, hmul : boolean;
      variable acc64                  : unsigned(63 downto 0);
      variable bw_dvsr                : std_logic_vector(31 downto 0);
      variable bw_lo, bw_hi           : integer;

      -- stage handshakes
      variable a2_adv, a1_adv, id_adv  : boolean;
      -- Shadows of the latch fields the forward selects compare.  Each is
      -- written wherever its signal is, in the same order, so that at the end
      -- of the process it holds exactly what the signal will hold next cycle.
      variable n_d_rs, n_d_rt          : integer range 0 to 31;
      variable n_m_valid, n_m_we       : std_logic;
      variable n_m_rd                  : integer range 0 to 31;
      variable n_w_valid, n_w_we       : std_logic;
      variable n_w_rd                  : integer range 0 to 31;
      variable kill_id                 : boolean;
      variable exc_now, eret_now       : boolean;
      variable br_leaving              : boolean;
      variable load_use                : boolean;

      -- ID
      variable id_ir             : std_logic_vector(31 downto 0);
      variable id_rs, id_rt      : integer range 0 to 31;
      variable id_op             : integer;
      variable id_a, id_b        : std_logic_vector(127 downto 0);
      variable id_nxt, id_tgt    : unsigned(31 downto 0);
      variable id_link           : std_logic_vector(63 downto 0);

      -- MEM
      variable ldv, ldw          : std_logic_vector(63 downto 0);
      variable uw, um, uv        : unsigned(31 downto 0);
      variable uv64, udw, ldh64  : unsigned(63 downto 0);
      variable sw64              : unsigned(63 downto 0);
      variable sbe8              : unsigned(7 downto 0);
      variable ku, shu           : integer range 0 to 63;

      -- IF queue bookkeeping
      variable vq_pc   : q_pc_t;
      variable vq_ir   : q_ir_t;
      variable vcnt    : integer range 0 to FQ_DEPTH;
      variable vouts   : integer range 0 to MAX_OUT;
      variable vdrop   : integer range 0 to MAX_OUT;
      variable vresp   : unsigned(31 downto 0);
      variable push    : boolean;
      variable push_pc : unsigned(31 downto 0);
      variable do_flush: boolean;
      variable new_pc  : unsigned(31 downto 0);
   begin
      if rising_edge(clk) then
         retire  <= '0';
         i_read  <= '0';

         if reset = '1' then
            gpr        <= (others => (others => '0'));
            hi         <= (others => '0');
            lo         <= (others => '0');
            hi1        <= (others => '0');
            lo1        <= (others => '0');
            cop0       <= (15 => PRID, others => (others => '0'));
            m_c0_we    <= '0';
            w_c0_we    <= '0';
            m_exc      <= '0';
            w_exc      <= '0';
            exc_redir  <= '0';
            m_eret     <= '0';
            w_eret     <= '0';
            d_bd       <= '0';
            bd_pend    <= '0';
            traps      <= (others => '0');
            fetch_pc   <= unsigned(pc_reset);
            outst      <= 0;
            drop       <= 0;
            resp_pc    <= unsigned(pc_reset);
            redir_pend <= '0';
            q_cnt      <= 0;
            d_valid    <= '0';
            m_valid    <= '0';
            m_ismem    <= '0';
            m_unal     <= '0';
            m_take     <= '0';
            w_valid    <= '0';
            ex_cnt     <= 0;
            d_read     <= '0';
            d_write    <= '0';
            fa_m       <= '0';
            fb_m       <= '0';
            fa_w       <= '0';
            fb_w       <= '0';
         else

            -- The shadows start as "unchanged", and every assignment to one of
            -- the real latch fields below is mirrored onto its shadow.
            n_d_rs    := d_rs;
            n_d_rt    := d_rt;
            n_m_valid := m_valid;
            n_m_we    := m_we;
            n_m_rd    := m_rd;
            n_w_valid := w_valid;
            n_w_we    := w_we;
            n_w_rd    := w_rd;

            -- ============================================================
            -- A2: can the instruction in the A1/A2 latch leave this cycle?
            -- ============================================================
            a2_adv := true;
            if m_valid = '1' and m_ismem = '1' and d_ready = '0' then
               a2_adv := false;
            end if;

            -- ============================================================
            -- A1: decode the instruction in the ID/A1 latch and compute
            -- ============================================================
            op   := to_integer(unsigned(d_ir(31 downto 26)));
            rs   := to_integer(unsigned(d_ir(25 downto 21)));
            rt   := to_integer(unsigned(d_ir(20 downto 16)));
            rd   := to_integer(unsigned(d_ir(15 downto 11)));
            sa   := to_integer(unsigned(d_ir(10 downto 6)));
            fn   := to_integer(unsigned(d_ir(5 downto 0)));
            imm  := d_ir(15 downto 0);
            simm := resize(signed(imm), 64);

            -- The MMI forms of MFHI/MTHI/MFLO/MTLO/MULT/MULTU/DIV/DIVU use the
            -- same function codes as SPECIAL, so they are decoded by the same
            -- arms with a flag saying which HI/LO pair they touch.  Only that
            -- subset is redirected: the rest of MMI is SIMD and unrelated.
            --
            -- This has to be settled here, before the forwarding block below,
            -- because that block picks which pair MFHI and MFLO will read.  It
            -- is also why ex_p1 is assigned unconditionally rather than reset
            -- with the other ex_* variables further down: a process variable
            -- keeps its value between invocations, so leaving it to a later
            -- default means one cycle reading the previous instruction's flag.
            op_eff := op;
            ex_p1  := '0';
            if op = 28 and (fn = 16 or fn = 17 or fn = 18 or fn = 19
                            or (fn >= 24 and fn <= 27)) then
               op_eff := 0;
               ex_p1  := '1';
            end if;

            -- Operand forwarding.  ID already bypassed the instruction in WB
            -- as it read the register file, so what is left is the two closer
            -- ones: the A2/WB latch first as the older, then the A1/A2 latch
            -- so the younger writer wins.  A load sitting in A2 has no value
            -- yet, which is what the load-use interlock below exists to
            -- prevent ever needing.
            a128 := d_a;
            b128 := d_b;
            if fa_w = '1' then
               if w_w128 = '1' then a128 := w_val;
               else a128 := a128(127 downto 64) & w_val(63 downto 0); end if;
            end if;
            if fb_w = '1' then
               if w_w128 = '1' then b128 := w_val;
               else b128 := b128(127 downto 64) & w_val(63 downto 0); end if;
            end if;
            if fa_m = '1' then
               if m_w128 = '1' then a128 := m_val;
               else a128 := a128(127 downto 64) & m_val(63 downto 0); end if;
            end if;
            if fb_m = '1' then
               if m_w128 = '1' then b128 := m_val;
               else b128 := b128(127 downto 64) & m_val(63 downto 0); end if;
            end if;
            -- Everything but MMI defines only the low 64 bits, so the ALU below
            -- reads the halves it always did and the upper half travels
            -- alongside for the instructions that want it.
            a := a128(63 downto 0);
            b := b128(63 downto 0);

            -- HI and LO are read in A1 and written in WB, so they need the
            -- same two forwarding steps and the same priority.
            hi_f  := hi;
            lo_f  := lo;
            hi1_f := hi1;
            lo1_f := lo1;
            sa_f  := sa_reg;
            if w_valid = '1' then
               if w_sa_we = '1' then sa_f := w_sa; end if;
               if w_hi_we = '1' then
                  if w_wide = '1' then hi_f := w_hi; hi1_f := w_hiu;
                  elsif w_p1 = '1' then hi1_f := w_hi; else hi_f := w_hi; end if;
               end if;
               if w_lo_we = '1' then
                  if w_wide = '1' then lo_f := w_lo; lo1_f := w_lou;
                  elsif w_p1 = '1' then lo1_f := w_lo; else lo_f := w_lo; end if;
               end if;
            end if;
            if m_valid = '1' then
               if m_sa_we = '1' then sa_f := m_sa; end if;
               if m_hi_we = '1' then
                  if m_wide = '1' then hi_f := m_hi; hi1_f := m_hiu;
                  elsif m_p1 = '1' then hi1_f := m_hi; else hi_f := m_hi; end if;
               end if;
               if m_lo_we = '1' then
                  if m_wide = '1' then lo_f := m_lo; lo1_f := m_lou;
                  elsif m_p1 = '1' then lo1_f := m_lo; else lo_f := m_lo; end if;
               end if;
            end if;
            -- MFC0 reads a register MTC0 may have written two instructions
            -- ago, so it needs the same two forwarding steps as HI and LO.
            c0_f := cop0(rd);
            if w_valid = '1' and w_c0_we = '1' and w_c0_idx = rd then
               c0_f := w_c0_val;
            end if;
            if m_valid = '1' and m_c0_we = '1' and m_c0_idx = rd then
               c0_f := m_c0_val;
            end if;

            -- what the MFHI/MFLO arms below read, chosen by the same flag that
            -- decides where MTHI/MULT/DIV write
            if ex_p1 = '1' then
               hi_r := hi1_f; lo_r := lo1_f;
            else
               hi_r := hi_f;  lo_r := lo_f;
            end if;

            ex_we     := '0';
            ex_w128   := '0';
            ex_rd     := 0;
            ex_val    := (others => '0');
            ex_valhi  := (others => '0');
            ex_hi_we  := '0';
            ex_sa_we  := '0';
            ex_wide   := '0';
            ex_hiu    := (others => '0');
            ex_lou    := (others => '0');
            ex_sa     := (others => '0');
            ex_lo_we  := '0';
            ex_hi     := (others => '0');
            ex_lo     := (others => '0');
            ex_ismem  := '0';
            ex_isload := '0';
            ex_width  := 4;
            ex_sign   := '0';
            ex_shift  := 0;
            ex_addr   := (others => '0');
            ex_be     := (others => '0');
            ex_wdata  := (others => '0');
            ex_exc     := '0';
            ex_eret    := '0';
            ex_code    := 0;
            sum32      := (others => '0');
            ex_c0_we   := '0';
            ex_c0_idx  := 0;
            ex_c0_val  := (others => '0');
            ex_unal    := '0';
            ex_unal_dw := '0';
            ex_unal_l  := '0';
            ex_mbase   := (others => '0');
            kk := 0; hw := 0;
            ex_take   := false;
            ex_trap   := false;
            tgt       := (others => '0');
            ea        := (others => '0');

            case op_eff is
               when 0 =>                               -- SPECIAL
                  case fn is
                     when 0  => ex_we := '1'; ex_rd := rd;   -- SLL
                                ex_val := sext32(std_logic_vector(shift_left(unsigned(b(31 downto 0)), sa)));
                     when 2  => ex_we := '1'; ex_rd := rd;   -- SRL
                                ex_val := sext32(std_logic_vector(shift_right(unsigned(b(31 downto 0)), sa)));
                     when 3  => ex_we := '1'; ex_rd := rd;   -- SRA
                                ex_val := sext32(std_logic_vector(shift_right(signed(b(31 downto 0)), sa)));
                     when 4  => ex_we := '1'; ex_rd := rd;   -- SLLV
                                ex_val := sext32(std_logic_vector(shift_left(unsigned(b(31 downto 0)), to_integer(unsigned(a(4 downto 0))))));
                     when 6  => ex_we := '1'; ex_rd := rd;   -- SRLV
                                ex_val := sext32(std_logic_vector(shift_right(unsigned(b(31 downto 0)), to_integer(unsigned(a(4 downto 0))))));
                     when 7  => ex_we := '1'; ex_rd := rd;   -- SRAV
                                ex_val := sext32(std_logic_vector(shift_right(signed(b(31 downto 0)), to_integer(unsigned(a(4 downto 0))))));
                     when 8  => ex_take := true; tgt := unsigned(a(31 downto 0));  -- JR
                     when 9  => ex_we := '1';                                      -- JALR
                                if rd = 0 then ex_rd := 31; else ex_rd := rd; end if;
                                ex_val := d_link;
                                ex_take := true; tgt := unsigned(a(31 downto 0));
                     when 16 => ex_we := '1'; ex_rd := rd; ex_val := hi_r;         -- MFHI
                     when 17 => ex_hi_we := '1'; ex_hi := a;                       -- MTHI
                     when 18 => ex_we := '1'; ex_rd := rd; ex_val := lo_r;         -- MFLO
                     when 19 => ex_lo_we := '1'; ex_lo := a;                       -- MTLO
                     when 12 => ex_exc := '1'; ex_code := EXC_SYSCALL;             -- SYSCALL
                     when 13 => ex_exc := '1'; ex_code := EXC_BREAK;               -- BREAK
                     when 20 => ex_we := '1'; ex_rd := rd;                         -- DSLLV
                                ex_val := std_logic_vector(shift_left(unsigned(b), to_integer(unsigned(a(5 downto 0)))));
                     when 22 => ex_we := '1'; ex_rd := rd;                         -- DSRLV
                                ex_val := std_logic_vector(shift_right(unsigned(b), to_integer(unsigned(a(5 downto 0)))));
                     when 23 => ex_we := '1'; ex_rd := rd;                         -- DSRAV
                                ex_val := std_logic_vector(shift_right(signed(b), to_integer(unsigned(a(5 downto 0)))));

                     when 24 | 25 =>                                               -- MULT / MULTU
                        -- The operands are captured and the product is walked
                        -- through the DSP's pipeline registers below; by the
                        -- cycle EX is allowed to advance, mul_p holds it.
                        ex_lo    := sext32(std_logic_vector(mul_p(31 downto 0)));
                        ex_hi    := sext32(std_logic_vector(mul_p(63 downto 32)));
                        ex_hi_we := '1';
                        ex_lo_we := '1';
                        ex_we    := '1';
                        ex_rd    := rd;          -- rd = 0 writes nothing, at WB
                        ex_val   := ex_lo;

                     when 26 | 27 =>                                               -- DIV / DIVU
                        -- Magnitudes go through the iterative unit and the
                        -- signs are applied here, which is what gives MIPS
                        -- truncation toward zero with the remainder taking the
                        -- dividend's sign.
                        --
                        -- Divide by zero needs no special case.  A restoring
                        -- divider with a zero divisor subtracts nothing, so it
                        -- sets every quotient bit and shifts the dividend
                        -- intact into the remainder: LO = 0xFFFFFFFF,
                        -- HI = dividend, exactly what the manual specifies for
                        -- DIVU.  For DIV the sign fixups turn that into LO = -1
                        -- for a non-negative dividend and LO = 1 for a negative
                        -- one, which is the specified result there too.
                        if div_negq = '1' then
                           ex_lo := sext32(std_logic_vector(0 - div_quot));
                        else
                           ex_lo := sext32(std_logic_vector(div_quot));
                        end if;
                        if div_negr = '1' then
                           ex_hi := sext32(std_logic_vector(0 - div_rem(31 downto 0)));
                        else
                           ex_hi := sext32(std_logic_vector(div_rem(31 downto 0)));
                        end if;
                        ex_hi_we := '1';
                        ex_lo_we := '1';

                     when 32 | 33 =>                                               -- ADD/ADDU
                        -- Overflow is read off the sign bits rather than from a
                        -- 33-bit add: two operands of the same sign giving a sum
                        -- of the other sign is exactly what overflow means, and
                        -- that test runs *beside* the adder instead of after a
                        -- wider one.  The 33-bit form cost about 10% of the
                        -- clock, because this adder is the critical path.
                        sum32 := std_logic_vector(signed(a(31 downto 0)) + signed(b(31 downto 0)));
                        if fn = 32 and (a(31) = b(31)) and (sum32(31) /= a(31)) then
                           ex_exc := '1'; ex_code := EXC_OV;   -- and rd is left alone
                        else
                           ex_we := '1'; ex_rd := rd;
                           ex_val := sext32(sum32);
                        end if;
                     when 34 | 35 => ex_we := '1'; ex_rd := rd;                    -- SUB/SUBU
                        ex_val := sext32(std_logic_vector(signed(a(31 downto 0)) - signed(b(31 downto 0))));
                     when 36 => ex_we := '1'; ex_rd := rd; ex_val := a and b;      -- AND
                     when 37 => ex_we := '1'; ex_rd := rd; ex_val := a or b;       -- OR
                     when 38 => ex_we := '1'; ex_rd := rd; ex_val := a xor b;      -- XOR
                     when 39 => ex_we := '1'; ex_rd := rd; ex_val := not (a or b); -- NOR
                     when 42 => ex_we := '1'; ex_rd := rd;                         -- SLT
                        if signed(a) < signed(b) then ex_val := (0 => '1', others => '0');
                        else ex_val := (others => '0'); end if;
                     when 43 => ex_we := '1'; ex_rd := rd;                         -- SLTU
                        if unsigned(a) < unsigned(b) then ex_val := (0 => '1', others => '0');
                        else ex_val := (others => '0'); end if;
                     when 40 => ex_we := '1'; ex_rd := rd;                         -- MFSA
                        ex_val := x"000000000000000" & sa_f;
                     when 41 =>                                                    -- MTSA
                        ex_sa_we := '1'; ex_sa := a(3 downto 0);
                     when 44 | 45 => ex_we := '1'; ex_rd := rd;                    -- DADD/DADDU
                        ex_val := std_logic_vector(signed(a) + signed(b));
                     when 46 | 47 => ex_we := '1'; ex_rd := rd;                    -- DSUB/DSUBU
                        ex_val := std_logic_vector(signed(a) - signed(b));
                     when 56 => ex_we := '1'; ex_rd := rd;                         -- DSLL
                        ex_val := std_logic_vector(shift_left(unsigned(b), sa));
                     when 58 => ex_we := '1'; ex_rd := rd;                         -- DSRL
                        ex_val := std_logic_vector(shift_right(unsigned(b), sa));
                     when 59 => ex_we := '1'; ex_rd := rd;                         -- DSRA
                        ex_val := std_logic_vector(shift_right(signed(b), sa));
                     when 60 => ex_we := '1'; ex_rd := rd;                         -- DSLL32
                        ex_val := std_logic_vector(shift_left(unsigned(b), sa + 32));
                     when 62 => ex_we := '1'; ex_rd := rd;                         -- DSRL32
                        ex_val := std_logic_vector(shift_right(unsigned(b), sa + 32));
                     when 63 => ex_we := '1'; ex_rd := rd;                         -- DSRA32
                        ex_val := std_logic_vector(shift_right(signed(b), sa + 32));
                     when others => ex_trap := true;
                  end case;

               when 1 =>                                    -- REGIMM
                  case rt is
                     when 0  => ex_take := signed(a) < 0;
                     when 1  => ex_take := signed(a) >= 0;
                     when 16 => ex_we := '1'; ex_rd := 31; ex_val := d_link;
                                ex_take := signed(a) < 0;
                     when 17 => ex_we := '1'; ex_rd := 31; ex_val := d_link;
                                ex_take := signed(a) >= 0;
                     -- The two members of REGIMM that neither branch nor link:
                     -- they set the shift-amount register.  The exclusive-or is
                     -- what the manual specifies and is not a slip -- it lets a
                     -- byte offset be flipped without a read-modify-write.
                     when 24 =>                                  -- MTSAB
                        ex_sa_we := '1';
                        ex_sa := a(3 downto 0)
                                 xor std_logic_vector(simm(3 downto 0));
                     when 25 =>                                  -- MTSAH
                        ex_sa_we := '1';
                        ex_sa := (a(2 downto 0)
                                  xor std_logic_vector(simm(2 downto 0))) & '0';
                     when others => ex_trap := true;
                  end case;
                  tgt := d_tgt;

               when 2 =>                                    -- J
                  ex_take := true;  tgt := d_tgt;
               when 3 =>                                    -- JAL
                  ex_we := '1'; ex_rd := 31; ex_val := d_link;
                  ex_take := true;  tgt := d_tgt;
               when 4 => ex_take := (a = b);        tgt := d_tgt;
               when 5 => ex_take := (a /= b);       tgt := d_tgt;
               when 6 => ex_take := signed(a) <= 0; tgt := d_tgt;
               when 7 => ex_take := signed(a) > 0;  tgt := d_tgt;

               when 8 | 9 =>                                 -- ADDI/ADDIU
                  sum32 := std_logic_vector(signed(a(31 downto 0)) + signed(simm(31 downto 0)));
                  if op = 8 and (a(31) = simm(31)) and (sum32(31) /= a(31)) then
                     ex_exc := '1'; ex_code := EXC_OV;         -- and rt is left alone
                  else
                     ex_we := '1'; ex_rd := rt;
                     ex_val := sext32(sum32);
                  end if;
               when 10 => ex_we := '1'; ex_rd := rt;         -- SLTI
                  if signed(a) < simm then ex_val := (0 => '1', others => '0');
                  else ex_val := (others => '0'); end if;
               when 11 => ex_we := '1'; ex_rd := rt;         -- SLTIU
                  if unsigned(a) < unsigned(simm) then ex_val := (0 => '1', others => '0');
                  else ex_val := (others => '0'); end if;
               when 12 => ex_we := '1'; ex_rd := rt; ex_val := a and (std_logic_vector'(x"000000000000") & imm);
               when 13 => ex_we := '1'; ex_rd := rt; ex_val := a or  (std_logic_vector'(x"000000000000") & imm);
               when 14 => ex_we := '1'; ex_rd := rt; ex_val := a xor (std_logic_vector'(x"000000000000") & imm);
               when 15 => ex_we := '1'; ex_rd := rt;         -- LUI
                  ex_val := sext32(imm & std_logic_vector'(x"0000"));
               when 16 =>                                    -- COP0
                  case rs is
                     when 0 =>                                 -- MFC0
                        ex_we  := '1';
                        ex_rd  := rt;
                        ex_val := sext32(c0_f);
                     when 16 =>                                -- the CO forms
                        if fn = 24 then
                           ex_eret := '1';                     -- ERET
                        else
                           ex_trap := true;                    -- TLB: not here
                        end if;
                     when 4 =>                                 -- MTC0
                        if rd /= 15 then                       -- PRId is read-only
                           ex_c0_we  := '1';
                           ex_c0_idx := rd;
                           ex_c0_val := b(31 downto 0);
                        end if;
                     when others => ex_trap := true;
                  end case;

               when 28 =>                                    -- MMI2 / MMI3
                  -- The SIMD half of MMI, and the first instructions to touch
                  -- the upper 64 bits of a register.  The sub-opcode is in sa
                  -- rather than fn, which is why these cannot share the decode
                  -- that maps MMI's HI/LO forms onto the SPECIAL arms.
                  ex_we   := '1';
                  ex_rd   := rd;
                  ex_w128 := '1';
                  if fn = 16#08# or fn = 16#28# then         -- MMI0 / MMI1
                     -- MMI0 and MMI1 hold two different kinds of instruction
                     -- and they are built differently.  The arithmetic half
                     -- selects an operation and a lane width as *values* and
                     -- calls par_alu once, so one adder per width serves all of
                     -- them; calling a generic function thirty times with
                     -- literal arguments specialised each call and cost 2681
                     -- LUTs for no clock.  The shuffle half is wires and
                     -- multiplexers with nothing to share, so each arm names
                     -- its own permutation.
                     --
                     -- Before any of this existed, function 0x08 and 0x28 fell
                     -- through to the MMI3 arm below and were decoded as POR,
                     -- PNOR or PCPYUD.  Nothing noticed, because the generator
                     -- emitted neither.
                     par_v      := (others => '0');
                     par_ok     := true;
                     par_alu_on := false;
                     par_o      := P_ADD;
                     par_w      := 32;
                     if fn = 16#08# then                     -- MMI0
                        case sa is
                           when 16#00# => par_alu_on := true; par_o := P_ADD;  par_w := 32;
                           when 16#01# => par_alu_on := true; par_o := P_SUB;  par_w := 32;
                           when 16#02# => par_alu_on := true; par_o := P_CGT;  par_w := 32;
                           when 16#03# => par_alu_on := true; par_o := P_MAX;  par_w := 32;
                           when 16#04# => par_alu_on := true; par_o := P_ADD;  par_w := 16;
                           when 16#05# => par_alu_on := true; par_o := P_SUB;  par_w := 16;
                           when 16#06# => par_alu_on := true; par_o := P_CGT;  par_w := 16;
                           when 16#07# => par_alu_on := true; par_o := P_MAX;  par_w := 16;
                           when 16#08# => par_alu_on := true; par_o := P_ADD;  par_w := 8;
                           when 16#09# => par_alu_on := true; par_o := P_SUB;  par_w := 8;
                           when 16#0A# => par_alu_on := true; par_o := P_CGT;  par_w := 8;
                           when 16#10# => par_alu_on := true; par_o := P_ADDS; par_w := 32;
                           when 16#11# => par_alu_on := true; par_o := P_SUBS; par_w := 32;
                           when 16#14# => par_alu_on := true; par_o := P_ADDS; par_w := 16;
                           when 16#15# => par_alu_on := true; par_o := P_SUBS; par_w := 16;
                           when 16#18# => par_alu_on := true; par_o := P_ADDS; par_w := 8;
                           when 16#19# => par_alu_on := true; par_o := P_SUBS; par_w := 8;
                           when 16#12# => par_v := par_shuf(S_PEXTL,  32, a128, b128, sa_f);
                           when 16#13# => par_v := par_shuf(S_PPAC,   32, a128, b128, sa_f);
                           when 16#16# => par_v := par_shuf(S_PEXTL,  16, a128, b128, sa_f);
                           when 16#17# => par_v := par_shuf(S_PPAC,   16, a128, b128, sa_f);
                           when 16#1A# => par_v := par_shuf(S_PEXTL,   8, a128, b128, sa_f);
                           when 16#1B# => par_v := par_shuf(S_PPAC,    8, a128, b128, sa_f);
                           when 16#1E# => par_v := par_shuf(S_PEXT5,  32, a128, b128, sa_f);
                           when 16#1F# => par_v := par_shuf(S_PPAC5,  32, a128, b128, sa_f);
                           when others => par_ok := false;
                        end case;
                     else                                    -- MMI1
                        case sa is
                           when 16#01# => par_alu_on := true; par_o := P_ABS;  par_w := 32;
                           when 16#02# => par_alu_on := true; par_o := P_CEQ;  par_w := 32;
                           when 16#03# => par_alu_on := true; par_o := P_MIN;  par_w := 32;
                           when 16#05# => par_alu_on := true; par_o := P_ABS;  par_w := 16;
                           when 16#06# => par_alu_on := true; par_o := P_CEQ;  par_w := 16;
                           when 16#07# => par_alu_on := true; par_o := P_MIN;  par_w := 16;
                           when 16#0A# => par_alu_on := true; par_o := P_CEQ;  par_w := 8;
                           when 16#10# => par_alu_on := true; par_o := P_ADDU; par_w := 32;
                           when 16#11# => par_alu_on := true; par_o := P_SUBU; par_w := 32;
                           when 16#14# => par_alu_on := true; par_o := P_ADDU; par_w := 16;
                           when 16#15# => par_alu_on := true; par_o := P_SUBU; par_w := 16;
                           when 16#18# => par_alu_on := true; par_o := P_ADDU; par_w := 8;
                           when 16#19# => par_alu_on := true; par_o := P_SUBU; par_w := 8;
                           when 16#04# => par_v := par_shuf(S_PADSBH, 16, a128, b128, sa_f);
                           when 16#12# => par_v := par_shuf(S_PEXTU,  32, a128, b128, sa_f);
                           when 16#16# => par_v := par_shuf(S_PEXTU,  16, a128, b128, sa_f);
                           when 16#1A# => par_v := par_shuf(S_PEXTU,   8, a128, b128, sa_f);
                           when 16#1B# => par_v := par_shuf(S_QFSRV,   8, a128, b128, sa_f);
                           when others => par_ok := false;
                        end case;
                     end if;
                     if par_alu_on then
                        par_v := par_alu(par_o, a128, b128, par_w);
                     end if;
                     if par_ok then
                        ex_val   := par_v(63 downto 0);
                        ex_valhi := par_v(127 downto 64);
                     else
                        ex_we := '0'; ex_w128 := '0'; ex_trap := true;
                     end if;

                  elsif fn = 16#09# then                     -- MMI2
                     case sa is
                        when 16#12# =>                       -- PAND
                           ex_val   := a128(63 downto 0) and b128(63 downto 0);
                           ex_valhi := a128(127 downto 64) and b128(127 downto 64);
                        when 16#13# =>                       -- PXOR
                           ex_val   := a128(63 downto 0) xor b128(63 downto 0);
                           ex_valhi := a128(127 downto 64) xor b128(127 downto 64);
                        when 16#0E# =>                       -- PCPYLD
                           ex_val   := b128(63 downto 0);
                           ex_valhi := a128(63 downto 0);
                        when 16#0C# =>                       -- PMULTW
                           pmultw(mul_p(63 downto 0), mul2_p(63 downto 0),
                                  pv, plo, phi);
                           ex_val := pv(63 downto 0); ex_valhi := pv(127 downto 64);
                           ex_hi_we := '1'; ex_lo_we := '1'; ex_wide := '1';
                           ex_hi := phi(63 downto 0);  ex_hiu := phi(127 downto 64);
                           ex_lo := plo(63 downto 0);  ex_lou := plo(127 downto 64);
                        when 16#1C# | 16#10# | 16#11# | 16#14# | 16#15# =>
                           -- PMULTH, PMADDH, PHMADH, PMSUBH, PHMSBH.  The
                           -- accumulating pair read HI and LO, so they take the
                           -- *forwarded* copies: a PMADDH straight after a
                           -- PMULTH is how the group is actually used, and
                           -- reading the register file there would accumulate
                           -- onto a value one instruction out of date.
                           hmac(sa, hm_p, lo1_f & lo_f, hi1_f & hi_f,
                                pv, plo, phi);
                           ex_val := pv(63 downto 0); ex_valhi := pv(127 downto 64);
                           ex_hi_we := '1'; ex_lo_we := '1'; ex_wide := '1';
                           ex_hi := phi(63 downto 0);  ex_hiu := phi(127 downto 64);
                           ex_lo := plo(63 downto 0);  ex_lou := plo(127 downto 64);
                        when 16#0D# =>                       -- PDIVW
                           ex_we := '0'; ex_w128 := '0';
                           ex_hi_we := '1'; ex_lo_we := '1'; ex_wide := '1';
                           ex_lo  := dfix(div_negq,  div_quot);
                           ex_hi  := dfix(div_negr,  div_rem(31 downto 0));
                           ex_lou := dfix(div2_negq, div2_quot);
                           ex_hiu := dfix(div2_negr, div2_rem(31 downto 0));
                        when 16#1D# =>                       -- PDIVBW
                           -- Four words, so four quotients into the four lanes
                           -- of LO and four remainders into HI.  Nothing is
                           -- widened to sixty-four bits here, unlike PDIVW:
                           -- these results are words and the lanes are full.
                           ex_we := '0'; ex_w128 := '0';
                           ex_hi_we := '1'; ex_lo_we := '1'; ex_wide := '1';
                           ex_lo  := div_p1lo1 & div_p1lo0;
                           ex_hi  := div_p1hi1 & div_p1hi0;
                           ex_lou := dfix32(div2_negq, div2_quot)
                                     & dfix32(div_negq, div_quot);
                           ex_hiu := dfix32(div2_negr, div2_rem(31 downto 0))
                                     & dfix32(div_negr, div_rem(31 downto 0));
                        when 16#02# =>                       -- PSLLVW
                           pv := pshiftv('l', a128, b128);
                           ex_val := pv(63 downto 0); ex_valhi := pv(127 downto 64);
                        when 16#03# =>                       -- PSRLVW
                           pv := pshiftv('r', a128, b128);
                           ex_val := pv(63 downto 0); ex_valhi := pv(127 downto 64);
                        when 16#08# =>                       -- PMFHI
                           ex_val := hi_f; ex_valhi := hi1_f;
                        when 16#09# =>                       -- PMFLO
                           ex_val := lo_f; ex_valhi := lo1_f;
                        when 16#0A# =>                       -- PINTH
                           pv := perm_h("tstststs", (0,4,1,5,2,6,3,7), a128, b128);
                           ex_val := pv(63 downto 0); ex_valhi := pv(127 downto 64);
                        when 16#1A# =>                       -- PEXEH
                           pv := perm_h("tttttttt", (2,1,0,3,6,5,4,7), a128, b128);
                           ex_val := pv(63 downto 0); ex_valhi := pv(127 downto 64);
                        when 16#1B# =>                       -- PREVH
                           pv := perm_h("tttttttt", (3,2,1,0,7,6,5,4), a128, b128);
                           ex_val := pv(63 downto 0); ex_valhi := pv(127 downto 64);
                        when 16#1E# =>                       -- PEXEW
                           pv := perm_w((2,1,0,3), b128);
                           ex_val := pv(63 downto 0); ex_valhi := pv(127 downto 64);
                        when 16#1F# =>                       -- PROT3W
                           pv := perm_w((1,2,0,3), b128);
                           ex_val := pv(63 downto 0); ex_valhi := pv(127 downto 64);
                        when others =>
                           ex_we := '0'; ex_w128 := '0'; ex_trap := true;
                     end case;
                  elsif fn = 16#29# then                     -- MMI3
                     case sa is
                        when 16#12# =>                       -- POR
                           ex_val   := a128(63 downto 0) or b128(63 downto 0);
                           ex_valhi := a128(127 downto 64) or b128(127 downto 64);
                        when 16#13# =>                       -- PNOR
                           ex_val   := not (a128(63 downto 0) or b128(63 downto 0));
                           ex_valhi := not (a128(127 downto 64) or b128(127 downto 64));
                        when 16#0E# =>                       -- PCPYUD
                           ex_val   := a128(127 downto 64);
                           ex_valhi := b128(127 downto 64);
                        when 16#0C# =>                       -- PMULTUW
                           pmultw(mul_p(63 downto 0), mul2_p(63 downto 0),
                                  pv, plo, phi);
                           ex_val := pv(63 downto 0); ex_valhi := pv(127 downto 64);
                           ex_hi_we := '1'; ex_lo_we := '1'; ex_wide := '1';
                           ex_hi := phi(63 downto 0);  ex_hiu := phi(127 downto 64);
                           ex_lo := plo(63 downto 0);  ex_lou := plo(127 downto 64);
                        when 16#00# =>                       -- PMADDUW
                           -- The accumulator is not a doubleword of HI or LO
                           -- but one word of *each*: LO's word holds the low
                           -- half and HI's the high, which is the same shape
                           -- PMULTUW leaves behind and is what makes the two
                           -- compose into a running 64-bit product sum.
                           for n in 0 to 1 loop
                              if n = 0 then
                                 acc64 := unsigned(hi_f(31 downto 0))
                                          & unsigned(lo_f(31 downto 0));
                                 acc64 := acc64 + unsigned(mul_p(63 downto 0));
                                 ex_lo    := sext32(std_logic_vector(acc64(31 downto 0)));
                                 ex_hi    := sext32(std_logic_vector(acc64(63 downto 32)));
                                 ex_val   := std_logic_vector(acc64);
                              else
                                 acc64 := unsigned(hi1_f(31 downto 0))
                                          & unsigned(lo1_f(31 downto 0));
                                 acc64 := acc64 + unsigned(mul2_p(63 downto 0));
                                 ex_lou   := sext32(std_logic_vector(acc64(31 downto 0)));
                                 ex_hiu   := sext32(std_logic_vector(acc64(63 downto 32)));
                                 ex_valhi := std_logic_vector(acc64);
                              end if;
                           end loop;
                           ex_hi_we := '1'; ex_lo_we := '1'; ex_wide := '1';
                        when 16#0D# =>                       -- PDIVUW
                           -- Unsigned division, but the 32-bit results are
                           -- still sign-extended into their 64-bit halves:
                           -- the result is a word, and every word this core
                           -- writes to a doubleword is sign-extended.
                           ex_we := '0'; ex_w128 := '0';
                           ex_hi_we := '1'; ex_lo_we := '1'; ex_wide := '1';
                           ex_lo  := dfix('0', div_quot);
                           ex_hi  := dfix('0', div_rem(31 downto 0));
                           ex_lou := dfix('0', div2_quot);
                           ex_hiu := dfix('0', div2_rem(31 downto 0));
                        when 16#03# =>                       -- PSRAVW
                           pv := pshiftv('a', a128, b128);
                           ex_val := pv(63 downto 0); ex_valhi := pv(127 downto 64);
                        when 16#08# =>                       -- PMTHI
                           ex_we := '0'; ex_w128 := '0';
                           ex_hi_we := '1'; ex_wide := '1';
                           ex_hi := a128(63 downto 0); ex_hiu := a128(127 downto 64);
                        when 16#09# =>                       -- PMTLO
                           ex_we := '0'; ex_w128 := '0';
                           ex_lo_we := '1'; ex_wide := '1';
                           ex_lo := a128(63 downto 0); ex_lou := a128(127 downto 64);
                        when 16#0A# =>                       -- PINTEH
                           pv := perm_h("tstststs", (0,0,2,2,4,4,6,6), a128, b128);
                           ex_val := pv(63 downto 0); ex_valhi := pv(127 downto 64);
                        when 16#1A# =>                       -- PEXCH
                           pv := perm_h("tttttttt", (0,2,1,3,4,6,5,7), a128, b128);
                           ex_val := pv(63 downto 0); ex_valhi := pv(127 downto 64);
                        when 16#1B# =>                       -- PCPYH
                           pv := perm_h("tttttttt", (0,0,0,0,4,4,4,4), a128, b128);
                           ex_val := pv(63 downto 0); ex_valhi := pv(127 downto 64);
                        when 16#1E# =>                       -- PEXCW
                           pv := perm_w((0,2,1,3), b128);
                           ex_val := pv(63 downto 0); ex_valhi := pv(127 downto 64);
                        when others =>
                           ex_we := '0'; ex_w128 := '0'; ex_trap := true;
                     end case;
                  else
                     ex_we := '0'; ex_w128 := '0'; ex_trap := true;
                  end if;

               when 24 | 25 => ex_we := '1'; ex_rd := rt;    -- DADDI/DADDIU
                  ex_val := std_logic_vector(signed(a) + simm);

               when 32 | 33 | 35 | 36 | 37 | 39 | 55 =>      -- loads
                  ea := unsigned(signed(a) + simm);
                  ex_addr   := std_logic_vector(ea(31 downto 0));
                  ex_ismem  := '1';
                  ex_isload := '1';
                  ex_we     := '1';
                  ex_rd     := rt;
                  case op is
                     when 32 => ex_width := 1; ex_sign := '1';
                     when 36 => ex_width := 1; ex_sign := '0';
                     when 33 => ex_width := 2; ex_sign := '1';
                     when 37 => ex_width := 2; ex_sign := '0';
                     when 35 => ex_width := 4; ex_sign := '1';
                     when 39 => ex_width := 4; ex_sign := '0';
                     when others => ex_width := 8; ex_sign := '0';
                  end case;
                  ex_shift := to_integer(ea(3 downto 0));

               when 34 | 38 | 26 | 27 =>                     -- LWL/LWR/LDL/LDR
                  ea := unsigned(signed(a) + simm);
                  ex_addr   := std_logic_vector(ea(31 downto 0));
                  ex_ismem  := '1';
                  ex_isload := '1';
                  ex_we     := '1';
                  ex_rd     := rt;
                  ex_shift  := to_integer(ea(3 downto 0));
                  ex_unal   := '1';
                  if op = 26 or op = 27 then ex_unal_dw := '1'; end if;
                  if op = 34 or op = 26 then ex_unal_l  := '1'; end if;
                  ex_mbase  := b;      -- the value the loaded bytes merge into

               when 40 | 41 | 43 | 63 =>                     -- stores
                  ea := unsigned(signed(a) + simm);
                  ex_addr  := std_logic_vector(ea(31 downto 0));
                  ex_ismem := '1';
                  -- SD reached the port with ex_be = x"FF" and no shift when
                  -- the port was 64 bits wide, because the address's low three
                  -- bits were all there was and an aligned doubleword filled it.
                  -- On a quadword port bit 3 chooses which half, so every store
                  -- shifts -- including the one that did not have to before.
                  --
                  -- The shift stays **64 bits wide with eight positions**, and
                  -- bit 3 of the address then picks a half.  Written as one
                  -- 128-bit shift by ea(3 downto 0) it is a sixteen-position
                  -- barrel shifter twice as wide -- about four times the
                  -- multiplexer -- and none of that is needed: SB, SH, SW and SD
                  -- are all naturally aligned, so none of them can straddle the
                  -- eight-byte boundary that the half is chosen on.
                  kk := to_integer(ea(2 downto 0));
                  dh := to_integer(ea(3 downto 3));
                  sw64 := shift_left(unsigned(b), 8 * kk);
                  case op is
                     when 40 => sbe8 := shift_left(unsigned'(x"01"), kk);
                     when 41 => sbe8 := shift_left(unsigned'(x"03"), kk);
                     when 43 => sbe8 := shift_left(unsigned'(x"0F"), kk);
                     when others => sbe8 := x"FF";
                  end case;
                  if dh = 0 then
                     ex_wdata(63 downto 0)   := std_logic_vector(sw64);
                     ex_be(7 downto 0)       := std_logic_vector(sbe8);
                  else
                     ex_wdata(127 downto 64) := std_logic_vector(sw64);
                     ex_be(15 downto 8)      := std_logic_vector(sbe8);
                  end if;

               when 30 | 31 =>                               -- LQ / SQ
                  -- The only instructions that move all 128 bits of a register.
                  -- The low four bits of the address are *ignored*, not checked:
                  -- the manual is explicit that neither takes an address error
                  -- exception, they access the quadword containing the address.
                  -- So the shift is zero and the byte enables are all on, and a
                  -- misaligned LQ is a legal instruction with a defined result
                  -- rather than a trap.
                  --
                  -- The mask below is defensive rather than load-bearing, and
                  -- saying so is better than letting the next reader assume it
                  -- was measured: this port's targets ignore the low four bits
                  -- themselves -- ee_ram.vhd picks its half with addr(4) and
                  -- never reads bits 3:0 -- so removing the mask changes no
                  -- simulation result.  It is here for a target that is less
                  -- forgiving.  What *is* checked is the architectural rule,
                  -- that a misaligned LQ reads the containing quadword and does
                  -- not fault; sim/ee/gen_quad.py walks all sixteen offsets.
                  ea := unsigned(signed(a) + simm);
                  ex_addr  := std_logic_vector(ea(31 downto 4)) & "0000";
                  ex_ismem := '1';
                  ex_shift := 0;
                  if op = 30 then                            -- LQ
                     ex_isload := '1';
                     ex_we     := '1';
                     ex_w128   := '1';
                     ex_rd     := rt;
                     ex_width  := 16;
                     ex_sign   := '0';
                  else                                       -- SQ
                     ex_wdata := b128;
                     ex_be    := x"FFFF";
                  end if;

               when 42 | 46 | 44 | 45 =>                     -- SWL/SWR/SDL/SDR
                  -- Each writes part of the aligned unit containing the
                  -- address, so the byte enables carry the whole of the
                  -- meaning: the data port sees an ordinary write of a
                  -- 64-bit word with only some lanes on.
                  ea := unsigned(signed(a) + simm);
                  ex_addr  := std_logic_vector(ea(31 downto 0));
                  ex_ismem := '1';
                  -- Each of these addresses a unit *inside* the quadword: a
                  -- doubleword form works within the half named by address bit
                  -- 3, a word form within the quarter named by bits 3:2.  The
                  -- within-unit arithmetic is unchanged; only the final shift
                  -- into the wider port is new.
                  if op = 44 or op = 45 then                 -- doubleword forms
                     kk := to_integer(ea(2 downto 0));
                     dh := to_integer(ea(3 downto 3));       -- which half of the quadword
                     if op = 44 then                         -- SDL
                        ex_wdata := std_logic_vector(shift_left(
                                       resize(shift_right(unsigned(b), 8 * (7 - kk)), 128),
                                       64 * dh));
                        ex_be    := std_logic_vector(shift_left(
                                       resize(unsigned'(x"FF") srl (7 - kk), 16), 8 * dh));
                     else                                    -- SDR
                        ex_wdata := std_logic_vector(shift_left(
                                       resize(shift_left(unsigned(b), 8 * kk), 128),
                                       64 * dh));
                        ex_be    := std_logic_vector(shift_left(
                                       resize(shift_left(unsigned'(x"FF"), kk), 16), 8 * dh));
                     end if;
                  else                                       -- word forms
                     kk := to_integer(ea(1 downto 0));
                     hw := to_integer(ea(3 downto 2));       -- which quarter of the quadword
                     if op = 42 then                         -- SWL
                        ex_wdata := std_logic_vector(shift_left(
                                       resize(shift_right(unsigned(b(31 downto 0)), 8 * (3 - kk)), 128),
                                       32 * hw));
                        ex_be    := std_logic_vector(shift_left(
                                       resize(unsigned'(x"0F") srl (3 - kk), 16), 4 * hw));
                     else                                    -- SWR
                        ex_wdata := std_logic_vector(shift_left(
                                       resize(shift_left(unsigned(b(31 downto 0)), 8 * kk), 128),
                                       32 * hw));
                        ex_be    := std_logic_vector(shift_left(
                                       resize(shift_left(unsigned'(x"0F"), kk) and x"0F", 16), 4 * hw));
                     end if;
                  end if;

               when others => ex_trap := true;
            end case;

            -- Is EX able to hand a result on?  A multi-cycle instruction is
            -- busy on its first cycle (ex_cnt = 0, when it is kicked off) and
            -- through the middle of its run, and free only at ex_cnt = 1.
            ex_busy := false;
            if d_valid = '1' and is_muldiv(d_ir) and ex_cnt /= 1 then
               ex_busy := true;
            end if;
            a1_adv := a2_adv and not ex_busy;

            -- ============================================================
            -- ID: decode, read the register file, check for a load-use stall
            -- ============================================================
            id_ir := q_ir(0);
            id_rs := to_integer(unsigned(id_ir(25 downto 21)));
            id_rt := to_integer(unsigned(id_ir(20 downto 16)));
            id_op := to_integer(unsigned(id_ir(31 downto 26)));
            id_nxt := q_pc(0) + 4;
            if id_op = 2 or id_op = 3 then                    -- J, JAL
               id_tgt := id_nxt(31 downto 28) & unsigned(id_ir(25 downto 0)) & "00";
            else
               id_tgt := id_nxt + unsigned(shift_left(resize(signed(id_ir(15 downto 0)), 32), 2));
            end if;
            id_link := sext32(std_logic_vector(id_nxt + 4));
            id_a  := rd_gpr(gpr, id_rs);
            id_b  := rd_gpr(gpr, id_rt);
            -- The instruction in WB writes the register file on this same edge,
            -- so a read issued now would miss it.  Bypass it here rather than
            -- adding a third forwarding input to EX.
            if w_valid = '1' and w_we = '1' and w_rd /= 0 then
               -- the bypass has to carry the whole register, or an MMI result
               -- forwarded at this distance would lose its upper half
               if w_rd = id_rs then
                  if w_w128 = '1' then id_a := w_val;
                  else id_a := id_a(127 downto 64) & w_val(63 downto 0); end if;
               end if;
               if w_rd = id_rt then
                  if w_w128 = '1' then id_b := w_val;
                  else id_b := id_b(127 downto 64) & w_val(63 downto 0); end if;
               end if;
            end if;

            -- The one hazard forwarding cannot cover: a load in A1 moves to
            -- A2 as this instruction would move to A1, and its value does not
            -- exist until the port answers.  One bubble puts the load in WB
            -- instead, where A1 can forward from it.
            load_use := false;
            if d_valid = '1' and is_load(d_ir) and rt /= 0 and q_cnt > 0 then
               if (reads_rs(id_ir) and id_rs = rt) or
                  (reads_rt(id_ir) and id_rt = rt) then
                  load_use := true;
               end if;
            end if;

            id_adv := a1_adv and q_cnt > 0 and not load_use;

            -- ============================================================
            -- WB: commit.  Everything architectural is written here.
            -- ============================================================
            retire    <= w_valid;
            retire_pc <= sext32(std_logic_vector(w_pc));
            exc_now   := (w_valid = '1' and w_exc = '1');
            eret_now  := (w_valid = '1' and w_eret = '1');

            if exc_now then
               -- The faulting instruction writes nothing.  EPC names the branch
               -- rather than the delay slot when the fault happened in one:
               -- resuming at the slot alone would skip the branch and take the
               -- wrong path.  An exception raised while EXL is already set does
               -- not overwrite EPC -- the first one is the one worth keeping.
               if cop0(C0_STATUS)(1) = '0' then
                  if w_bd = '1' then
                     cop0(C0_EPC) <= std_logic_vector(w_pc - 4);
                  else
                     cop0(C0_EPC) <= std_logic_vector(w_pc);
                  end if;
                  cop0(C0_CAUSE) <= (w_bd & "000000000000000000000000"
                                     & std_logic_vector(to_unsigned(w_exc_code, 5))
                                     & "00")
                                    or (cop0(C0_CAUSE) and x"7FFFFF83");
                  cop0(C0_STATUS)(1) <= '1';       -- EXL
               end if;
            elsif eret_now then
               cop0(C0_STATUS)(1) <= '0';          -- clear EXL and resume
            elsif w_valid = '1' then
               if w_we = '1' and w_rd /= 0 then
                  if w_w128 = '1' then
                     gpr(w_rd) <= w_val;
                  else
                     gpr(w_rd)(63 downto 0) <= w_val(63 downto 0);
                  end if;
               end if;
               if w_sa_we = '1' then sa_reg <= w_sa; end if;
               if w_hi_we = '1' then
                  if w_wide = '1' then
                     hi <= w_hi; hi1 <= w_hiu;
                  elsif w_p1 = '1' then hi1 <= w_hi;
                  else hi <= w_hi; end if;
               end if;
               if w_lo_we = '1' then
                  if w_wide = '1' then
                     lo <= w_lo; lo1 <= w_lou;
                  elsif w_p1 = '1' then lo1 <= w_lo;
                  else lo <= w_lo; end if;
               end if;
               if w_c0_we = '1' then
                  cop0(w_c0_idx) <= w_c0_val;
               end if;
            end if;

            -- ============================================================
            -- A2 -> WB
            -- ============================================================
            if a2_adv then
               w_valid  <= m_valid;   n_w_valid := m_valid;
               w_pc     <= m_pc;
               w_we     <= m_we;      n_w_we    := m_we;
               w_rd     <= m_rd;      n_w_rd    := m_rd;
               w_w128   <= m_w128;
               w_p1     <= m_p1;
               w_exc     <= m_exc;
               w_exc_code<= m_exc_code;
               w_eret    <= m_eret;
               w_bd      <= m_bd;
               w_c0_we  <= m_c0_we;
               w_c0_idx <= m_c0_idx;
               w_c0_val <= m_c0_val;
               w_hi_we  <= m_hi_we;
               w_lo_we  <= m_lo_we;
               w_sa_we  <= m_sa_we;
               w_wide   <= m_wide;
               w_hiu    <= m_hiu;
               w_lou    <= m_lou;
               w_sa     <= m_sa;
               w_hi     <= m_hi;
               w_lo     <= m_lo;
               if m_isload = '1' and m_unal = '1' then
                  -- LWL/LWR/LDL/LDR: take part of the aligned unit the address
                  -- falls in and merge it with what rt already held.  The base
                  -- travelled down the pipeline in m_mbase because rt is both a
                  -- source and the destination here, which is why these had to
                  -- be added to the forwarding decode as readers of rt.
                  if m_unal_dw = '0' then                       -- word forms
                     -- which of the quadword's four words the address falls in
                     uw := unsigned(d_rdata(32 * (m_shift / 4) + 31
                                            downto 32 * (m_shift / 4)));
                     ku := m_shift mod 4;
                     if m_unal_l = '1' then                     -- LWL
                        shu := 8 * (3 - ku);
                        um  := shift_left(to_unsigned(1, 32), shu) - 1;
                        uv  := (shift_left(uw, shu) or (unsigned(m_mbase(31 downto 0)) and um));
                     else                                       -- LWR
                        shu := 8 * ku;
                        um  := not shift_right(unsigned'(x"FFFFFFFF"), shu);
                        uv  := (shift_right(uw, shu) or (unsigned(m_mbase(31 downto 0)) and um));
                     end if;
                     ldw := sext32(std_logic_vector(uv));
                  else                                          -- doubleword forms
                     -- and which of its two halves, for the doubleword forms
                     udw := unsigned(d_rdata(64 * (m_shift / 8) + 63
                                             downto 64 * (m_shift / 8)));
                     ku := m_shift mod 8;
                     if m_unal_l = '1' then                     -- LDL
                        shu := 8 * (7 - ku);
                        uv64 := (shift_left(udw, shu)
                                 or (unsigned(m_mbase)
                                     and (shift_left(to_unsigned(1, 64), shu) - 1)));
                     else                                       -- LDR
                        shu := 8 * ku;
                        uv64 := (shift_right(udw, shu)
                                 or (unsigned(m_mbase)
                                     and not shift_right(unsigned'(x"FFFFFFFFFFFFFFFF"), shu)));
                     end if;
                     ldw := std_logic_vector(uv64);
                  end if;
                  w_val <= x"0000000000000000" & ldw;
               elsif m_isload = '1' then
                  -- The port answers with the whole 64-bit word that contains
                  -- the address, so the bytes the instruction asked for have to
                  -- be selected out of it and then extended.  Getting the
                  -- extension wrong is invisible until a value happens to have
                  -- its top bit set.
                  -- Same reasoning as the store side: choose the doubleword
                  -- with address bit 3, then shift within it by the low three
                  -- bits.  A 128-bit shift by all four bits is four times the
                  -- multiplexer and buys nothing, because every load narrower
                  -- than a quadword is aligned and lies inside one half.  LQ is
                  -- the exception and takes no shift at all -- its m_shift is
                  -- zero and it reads d_rdata whole, below.
                  if m_shift >= 8 then
                     ldh64 := unsigned(d_rdata(127 downto 64));
                  else
                     ldh64 := unsigned(d_rdata(63 downto 0));
                  end if;
                  ldv := std_logic_vector(shift_right(ldh64, 8 * (m_shift mod 8)));
                  case m_width is
                     when 1 =>
                        if m_sign = '1' then
                           ldw := std_logic_vector'(55 downto 0 => ldv(7)) & ldv(7 downto 0);
                        else
                           ldw := std_logic_vector'(x"00000000000000") & ldv(7 downto 0);
                        end if;
                     when 2 =>
                        if m_sign = '1' then
                           ldw := std_logic_vector'(47 downto 0 => ldv(15)) & ldv(15 downto 0);
                        else
                           ldw := std_logic_vector'(x"000000000000") & ldv(15 downto 0);
                        end if;
                     when 4 =>
                        if m_sign = '1' then
                           ldw := sext32(ldv(31 downto 0));
                        else
                           ldw := std_logic_vector'(x"00000000") & ldv(31 downto 0);
                        end if;
                     when others =>
                        ldw := ldv;
                  end case;
                  if m_width = 16 then                  -- LQ: the whole quadword
                     w_val <= d_rdata;
                  else
                     w_val <= x"0000000000000000" & ldw;
                  end if;
               else
                  w_val <= m_val;
               end if;
               -- the port request is finished with
               d_read  <= '0';
               d_write <= '0';
            else
               w_valid <= '0';        n_w_valid := '0';
               w_exc   <= '0';
               w_eret  <= '0';
            end if;

            -- ============================================================
            -- A1 -> A2
            -- ============================================================
            if a2_adv then
               if a1_adv then
                  m_valid  <= d_valid;   n_m_valid := d_valid;
                  m_pc     <= d_pc;
                  m_we     <= ex_we;     n_m_we    := ex_we;
                  m_rd     <= ex_rd;     n_m_rd    := ex_rd;
                  m_val    <= ex_valhi & ex_val;
                  m_w128   <= ex_w128;
                  m_p1     <= ex_p1;
                  m_exc     <= ex_exc and d_valid;
                  m_exc_code<= ex_code;
                  m_eret    <= ex_eret and d_valid;
                  m_bd      <= d_bd;
                  m_c0_we  <= ex_c0_we and d_valid;
                  m_c0_idx <= ex_c0_idx;
                  m_c0_val <= ex_c0_val;
                  m_hi_we  <= ex_hi_we;
                  m_lo_we  <= ex_lo_we;
                  m_sa_we  <= ex_sa_we;
                  m_wide   <= ex_wide;
                  m_hiu    <= ex_hiu;
                  m_lou    <= ex_lou;
                  m_sa     <= ex_sa;
                  m_hi     <= ex_hi;
                  m_lo     <= ex_lo;
                  m_ismem  <= ex_ismem and d_valid;
                  m_unal    <= ex_unal;
                  m_unal_dw <= ex_unal_dw;
                  m_unal_l  <= ex_unal_l;
                  m_mbase   <= ex_mbase;
                  if ex_take and d_valid = '1' then
                     m_take <= '1';
                  else
                     m_take <= '0';
                  end if;
                  m_tgt    <= tgt;
                  m_isload <= ex_isload;
                  m_width  <= ex_width;
                  m_sign   <= ex_sign;
                  m_shift  <= ex_shift;
                  -- A store is the one thing an exception cannot take back.
                  -- Registers and HI/LO are still in latches when the exception
                  -- commits, so invalidating those latches is enough for them;
                  -- a store has already been handed to the memory port and is
                  -- gone.  So an instruction older than this one that is about
                  -- to raise -- sitting in A2 with m_exc set, one edge from
                  -- committing -- has to stop the port request being issued at
                  -- all, rather than being undone afterwards.
                  --
                  -- Found by a wide random campaign: an ADD overflowed, the
                  -- store behind it should never have run, and it left a word in
                  -- memory that no register trace could show, because a store
                  -- writes no register.
                  if d_valid = '1' and ex_ismem = '1'
                     and m_exc = '0' and m_eret = '0'
                     and w_exc = '0' and w_eret = '0' then
                     d_addr <= ex_addr;
                     if ex_isload = '1' then
                        d_read <= '1';
                     else
                        d_write <= '1';
                        d_be    <= ex_be;
                        d_wdata <= ex_wdata;
                     end if;
                  end if;
                  if d_valid = '1' and ex_trap then
                     traps <= traps + 1;
                  end if;
               else
                  m_valid <= '0';        n_m_valid := '0';
                  m_ismem <= '0';
                  m_unal  <= '0';
                  m_we    <= '0';        n_m_we    := '0';
                  m_hi_we <= '0';
                  m_lo_we <= '0';
                  m_sa_we <= '0';
                  m_take  <= '0';
                  m_c0_we <= '0';
                  m_exc   <= '0';
                  m_eret  <= '0';
               end if;
            end if;

            -- ============================================================
            -- the multi-cycle units, stepped only when A1 may make progress
            -- ============================================================
            if a2_adv and d_valid = '1' and is_muldiv(d_ir) then
               pdiv   := is_pdiv(d_ir);
               pdivbw := is_pdivbw(d_ir);
               -- PMADDUW loads the multipliers exactly as PMULTUW does --
               -- both words, both unsigned -- and differs only in what happens
               -- to the products at retire, so it shares the kick-off.
               pmul   := is_pmultw(d_ir) or is_pmadduw(d_ir);
               hmul   := is_hmac(d_ir);
               psgn   := fn = 16#09#;        -- MMI2 is PDIVW, MMI3 is PDIVUW
               if ex_cnt = 0 then
                  -- kick off
                  if pdiv or pdivbw then
                     -- Two words in, two quotients and two remainders out, in
                     -- the same 33 cycles a scalar DIV takes.  Both units are
                     -- the plain restoring divider, so the awkward cases -- a
                     -- zero divisor, and 0x80000000 / -1 -- come out with the
                     -- architectural results without a case of their own, in
                     -- each lane independently.
                     --
                     -- PDIVBW takes its single divisor from rt's low halfword
                     -- read as signed, and starts on words 0 and 1; words 2
                     -- and 3 go through the same two units on a second pass.
                     bw_dvsr := (31 downto 16 => b128(15)) & b128(15 downto 0);
                     if pdivbw then
                        load_div(div_rem,  div_quot,  div_dvsr,
                                 div_negq,  div_negr,  true,
                                 a128(31 downto 0),  bw_dvsr);
                        load_div(div2_rem, div2_quot, div2_dvsr,
                                 div2_negq, div2_negr, true,
                                 a128(63 downto 32), bw_dvsr);
                        ex_cnt <= 66;
                     else
                        load_div(div_rem,  div_quot,  div_dvsr,
                                 div_negq,  div_negr,  psgn,
                                 a128(31 downto 0),  b128(31 downto 0));
                        load_div(div2_rem, div2_quot, div2_dvsr,
                                 div2_negq, div2_negr, psgn,
                                 a128(95 downto 64), b128(95 downto 64));
                        ex_cnt <= 33;
                     end if;
                  elsif hmul then
                     -- Eight halfword pairs, straight in.  All five
                     -- instructions in the group load identically; what they
                     -- differ about happens three cycles later.
                     for i in 0 to 7 loop
                        hm_a(i) <= signed(a128(16*i+15 downto 16*i));
                        hm_b(i) <= signed(b128(16*i+15 downto 16*i));
                     end loop;
                     ex_cnt <= 3;
                  elsif fn = 24 or fn = 25 or pmul then
                     -- MULT, MULTU, PMULTW and PMULTUW all load the same way.
                     -- The signed and unsigned forms differ only in how the
                     -- 32-bit operands are widened to the multiplier's 33 bits,
                     -- and the parallel forms differ only in also loading the
                     -- second multiplier from word 2.
                     if fn = 24 or (pmul and fn = 16#09#) then
                        mul_a  <= resize(signed(a128(31 downto 0)), 33);
                        mul_b  <= resize(signed(b128(31 downto 0)), 33);
                        mul2_a <= resize(signed(a128(95 downto 64)), 33);
                        mul2_b <= resize(signed(b128(95 downto 64)), 33);
                     else
                        mul_a  <= signed(std_logic_vector'('0' & a128(31 downto 0)));
                        mul_b  <= signed(std_logic_vector'('0' & b128(31 downto 0)));
                        mul2_a <= signed(std_logic_vector'('0' & a128(95 downto 64)));
                        mul2_b <= signed(std_logic_vector'('0' & b128(95 downto 64)));
                     end if;
                     ex_cnt <= 3;
                  else
                     if fn = 26 and a(31) = '1' then
                        dvd_mag := 0 - unsigned(a(31 downto 0));
                     else
                        dvd_mag := unsigned(a(31 downto 0));
                     end if;
                     if fn = 26 and b(31) = '1' then
                        dvsr_mag := 0 - unsigned(b(31 downto 0));
                     else
                        dvsr_mag := unsigned(b(31 downto 0));
                     end if;
                     div_rem  <= (others => '0');
                     div_quot <= dvd_mag;
                     div_dvsr <= dvsr_mag;
                     if fn = 26 then
                        div_negq <= a(31) xor b(31);
                        div_negr <= a(31);
                     else
                        div_negq <= '0';
                        div_negr <= '0';
                     end if;
                     ex_cnt <= 33;
                  end if;
               elsif ex_cnt > 1 then
                  if hmul then
                     if ex_cnt = 3 then
                        for i in 0 to 7 loop
                           hm_p1(i) <= hm_a(i) * hm_b(i);
                        end loop;
                     else
                        for i in 0 to 7 loop
                           hm_p(i) <= hm_p1(i);
                        end loop;
                     end if;
                  elsif fn = 24 or fn = 25 or pmul then
                     if ex_cnt = 3 then
                        mul_p1  <= mul_a * mul_b;
                        mul2_p1 <= mul2_a * mul2_b;
                     else
                        -- a second register stage, so the tool has one to push
                        -- into the DSP's own output pipeline rather than
                        -- leaving the cascade adder in fabric
                        mul_p  <= mul_p1;
                        mul2_p <= mul2_p1;
                     end if;
                  else
                     -- one quotient bit per clock: shift the next dividend bit
                     -- into the running remainder, subtract the divisor if it
                     -- fits, and record whether it did.
                     if pdivbw and ex_cnt = 34 then
                        -- Between the passes.  What the first pass found has to
                        -- survive the second, so it is copied out before the
                        -- units are reloaded with the other two words.  This
                        -- cycle runs no iteration, which is why the count is
                        -- 66 and not 65.
                        div_p1lo0 <= dfix32(div_negq,  div_quot);
                        div_p1hi0 <= dfix32(div_negr,  div_rem(31 downto 0));
                        div_p1lo1 <= dfix32(div2_negq, div2_quot);
                        div_p1hi1 <= dfix32(div2_negr, div2_rem(31 downto 0));
                        bw_dvsr := (31 downto 16 => b128(15)) & b128(15 downto 0);
                        load_div(div_rem,  div_quot,  div_dvsr,
                                 div_negq,  div_negr,  true,
                                 a128(95 downto 64),  bw_dvsr);
                        load_div(div2_rem, div2_quot, div2_dvsr,
                                 div2_negq, div2_negr, true,
                                 a128(127 downto 96), bw_dvsr);
                     else
                     div_shift := div_rem(31 downto 0) & div_quot(31);
                     if div_shift >= ('0' & div_dvsr) then
                        div_rem  <= div_shift - ('0' & div_dvsr);
                        div_quot <= div_quot(30 downto 0) & '1';
                     else
                        div_rem  <= div_shift;
                        div_quot <= div_quot(30 downto 0) & '0';
                     end if;
                     -- The second unit steps beside it unconditionally.  A
                     -- scalar DIV leaves it churning on stale operands whose
                     -- result nothing reads, which costs a little toggling and
                     -- saves an enable term on a path that is already tight.
                     div2_shift := div2_rem(31 downto 0) & div2_quot(31);
                     if div2_shift >= ('0' & div2_dvsr) then
                        div2_rem  <= div2_shift - ('0' & div2_dvsr);
                        div2_quot <= div2_quot(30 downto 0) & '1';
                     else
                        div2_rem  <= div2_shift;
                        div2_quot <= div2_quot(30 downto 0) & '0';
                     end if;
                     end if;
                  end if;
                  ex_cnt <= ex_cnt - 1;
               else
                  ex_cnt <= 0;         -- the result leaves EX this cycle
               end if;
            end if;

            -- ============================================================
            -- ID -> A1, and the branch redirect (acted on in A2)
            -- ============================================================
            do_flush := false;
            kill_id  := false;
            new_pc   := (others => '0');
            if exc_redir = '1' then
               -- the redirect itself, one cycle after the commit
               do_flush   := true;
               kill_id    := true;
               new_pc     := exc_pc;
               exc_redir  <= '0';
               d_valid    <= '0';
            elsif exc_now or eret_now then
               -- Everything younger than the committing instruction is in a
               -- latch, so invalidating those latches is the whole flush; there
               -- is nothing to undo because nothing younger has written.  Only
               -- the fetch redirect is deferred, and it is deferred by setting
               -- exc_redir rather than driving fetch_pc from here.
               kill_id  := true;
               -- Everything younger dies, and that includes the instruction
               -- already moving from A2 into WB on this very edge: the A2 -> WB
               -- transfer happens earlier in this process, so clearing m_valid
               -- alone stops the *next* one and lets this one retire behind the
               -- exception.  Precise means nothing younger commits, so w_valid
               -- has to be cancelled here as well.
               w_valid  <= '0';       n_w_valid := '0';
               w_exc    <= '0';
               w_eret   <= '0';
               d_valid  <= '0';
               m_valid  <= '0';       n_m_valid := '0';
               m_ismem  <= '0';
               m_exc    <= '0';
               m_eret   <= '0';
               m_take   <= '0';
               m_c0_we  <= '0';
               redir_pend <= '0';
               bd_pend    <= '0';
               exc_redir  <= '1';
               if exc_now then
                  -- BEV picks the vector base; the offset for a general
                  -- exception is 0x180 either way.
                  if cop0(C0_STATUS)(22) = '1' then
                     exc_pc <= x"BFC00380";
                  else
                     exc_pc <= x"80000180";
                  end if;
               else
                  exc_pc <= unsigned(cop0(C0_EPC));
               end if;
            elsif a2_adv and m_valid = '1' and m_take = '1' then
               -- The branch is leaving A2.  Whatever is in A1 is its delay slot
               -- and must run; everything behind that is wrong-path and dies --
               -- including the instruction ID is holding, which is one more
               -- than the old single-stage redirect had to kill.
               -- The delay slot can be in one of three places when the
               -- branch reaches A2, and all three have to be told apart.
               if d_valid = '1' then
                  -- Already in A1.  Whatever ID is holding is wrong-path.
                  do_flush := true;
                  kill_id  := true;
                  new_pc   := m_tgt;
               elsif id_adv then
                  -- Entering A1 on this very edge.  Flush everything behind it
                  -- but let it through -- killing it here, or deferring as if
                  -- it had not arrived, both go wrong.  Deferring is the
                  -- subtler of the two: redir_pend would then fire on the
                  -- *next* instruction to enter A1, which is the one after the
                  -- delay slot, and the redirect would be applied an
                  -- instruction too late.  When the branch target happens to be
                  -- the next sequential address -- which a short forward branch
                  -- often makes true -- that late redirect re-fetches an
                  -- instruction already in the pipeline and executes it twice.
                  do_flush := true;
                  new_pc   := m_tgt;
               else
                  -- Still in the fetch path: the queue ran dry and the reply is
                  -- in flight.  Flushing now would discard the delay slot
                  -- itself, so the redirect waits for it.
                  redir_pend <= '1';
                  redir_tgt  <= m_tgt;
               end if;
            elsif redir_pend = '1' and id_adv then
               -- The delay slot has reached A1 at last.  It is the instruction
               -- entering A1 on this edge, so it is *not* killed -- only the
               -- queue behind it is.
               do_flush   := true;
               new_pc     := redir_tgt;
               redir_pend <= '0';
            end if;

            if a1_adv then
               br_leaving := (d_valid = '1' and is_branch(d_ir));
               if id_adv and not kill_id then
                  d_valid <= '1';
                  d_pc    <= q_pc(0);
                  d_ir    <= id_ir;
                  d_a     <= id_a;
                  d_b     <= id_b;
                  d_rs    <= id_rs;      n_d_rs := id_rs;
                  d_rt    <= id_rt;      n_d_rt := id_rt;
                  -- a delay slot either follows the branch immediately, or the
                  -- branch left earlier and bubbles have been going in since
                  if br_leaving or bd_pend = '1' then
                     d_bd <= '1';
                  else
                     d_bd <= '0';
                  end if;
                  bd_pend <= '0';
                  d_tgt   <= id_tgt;
                  d_link  <= id_link;
               else
                  d_valid <= '0';
                  if br_leaving then
                     bd_pend <= '1';     -- remember it for whenever the slot arrives
                  end if;
               end if;
            else
               -- A1 is held up, so capture the operands forwarding just
               -- produced.  Forwarding is recomputed every cycle from whatever
               -- is in A2 and WB, but only the value present on the cycle A1
               -- finally advances is the one that gets latched -- and by then
               -- the instruction that produced it may have retired and moved
               -- out of both stages.  The register file is no help either: ID
               -- read it cycles ago and A1 never reads it.  Writing the
               -- forwarded value back into the ID/A1 latch each stalled cycle
               -- is what makes a forwarded operand survive a stall of any
               -- length.
               --
               -- Only older instructions can ever be in A2 or WB, so a
               -- capture can only ever move an operand forward in time.
               d_a <= a128;
               d_b <= b128;
            end if;

            -- ============================================================
            -- IF: the request in flight, the queue, and the next request
            -- ============================================================
            vq_pc := q_pc;
            vq_ir := q_ir;
            vcnt  := q_cnt;
            vouts := outst;
            vdrop := drop;
            vresp := resp_pc;
            push  := false;
            push_pc := resp_pc;

            if i_ready = '1' and vouts > 0 then
               vouts := vouts - 1;
               if vdrop > 0 then
                  vdrop := vdrop - 1;         -- wrong-path reply, discarded
               else
                  push    := true;
                  push_pc := vresp;
                  vresp   := vresp + 4;
               end if;
            end if;

            if id_adv then
               for k in 0 to FQ_DEPTH - 2 loop
                  vq_pc(k) := vq_pc(k + 1);
                  vq_ir(k) := vq_ir(k + 1);
               end loop;
               vcnt := vcnt - 1;
            end if;
            if push then
               vq_pc(vcnt) := push_pc;
               vq_ir(vcnt) := i_data;
               vcnt        := vcnt + 1;
            end if;
            if do_flush then
               vcnt     := 0;
               vdrop    := vouts;          -- everything in flight is wrong-path
               vresp    := new_pc;
               fetch_pc <= new_pc;
            end if;

            -- Issue while there is both a slot in flight and somewhere for the
            -- reply to land.  i_read is a single-cycle pulse per request, so
            -- back-to-back issues are back-to-back requests.
            if vouts < MAX_OUT and vouts + vcnt < FQ_DEPTH then
               i_read <= '1';
               if do_flush then
                  i_addr   <= std_logic_vector(new_pc);
                  fetch_pc <= new_pc + 4;
               else
                  i_addr   <= std_logic_vector(fetch_pc);
                  fetch_pc <= fetch_pc + 4;
               end if;
               vouts := vouts + 1;
            end if;

            if not a2_adv then           dbg_stall <= to_unsigned(1, 3);
            elsif ex_busy then           dbg_stall <= to_unsigned(2, 3);
            elsif load_use then          dbg_stall <= to_unsigned(3, 3);
            elsif q_cnt = 0 then         dbg_stall <= to_unsigned(4, 3);
            elsif kill_id then           dbg_stall <= to_unsigned(5, 3);
            else                         dbg_stall <= to_unsigned(0, 3);
            end if;

            q_pc  <= vq_pc;
            q_ir  <= vq_ir;
            q_cnt <= vcnt;
            outst   <= vouts;
            drop    <= vdrop;
            resp_pc <= vresp;

            -- Every latch field the forward selects depend on has now been
            -- decided, so the comparisons A1 would otherwise make next cycle
            -- can be made here instead and handed over already resolved.  A2
            -- is checked after WB so that the younger writer still wins: an
            -- fa_m of '1' overrides fa_w in A1 exactly as the nested ifs did.
            fa_m <= '0';  fb_m <= '0';
            fa_w <= '0';  fb_w <= '0';
            if n_w_valid = '1' and n_w_we = '1' and n_w_rd /= 0 then
               if n_w_rd = n_d_rs then fa_w <= '1'; end if;
               if n_w_rd = n_d_rt then fb_w <= '1'; end if;
            end if;
            if n_m_valid = '1' and n_m_we = '1' and n_m_rd /= 0 then
               if n_m_rd = n_d_rs then fa_m <= '1'; end if;
               if n_m_rd = n_d_rt then fb_m <= '1'; end if;
            end if;
         end if;
      end if;
   end process;

end architecture;
