-- ee_core.vhd -- the R5900's integer datapath, written to the EE Core User's
-- Manual and checked against sim/ee/r5900_ref.py instruction by instruction.
--
-- Not pipelined.  One instruction at a time through a four-state machine, with
-- no cache and no forwarding.  That is deliberate: a hazard is easier to add to
-- something that already gives right answers than to find in something that does
-- not, and the reference this is checked against models no timing at all, so the
-- two can be compared on architectural state alone.
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
-- Traps are counted, not taken: there is no exception path yet, and a silent
-- difference would be worse than a loud unimplemented one.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity ee_core is
   port
   (
      clk        : in  std_logic;
      reset      : in  std_logic;
      pc_reset   : in  std_logic_vector(31 downto 0) := x"00000000";

      -- instruction port, 32 bits
      i_addr     : out std_logic_vector(31 downto 0) := (others => '0');
      i_read     : out std_logic := '0';
      i_data     : in  std_logic_vector(31 downto 0) := (others => '0');
      i_ready    : in  std_logic := '0';

      -- data port, 64 bits with byte enables
      d_addr     : out std_logic_vector(31 downto 0) := (others => '0');
      d_read     : out std_logic := '0';
      d_write    : out std_logic := '0';
      d_be       : out std_logic_vector(7 downto 0) := (others => '0');
      d_wdata    : out std_logic_vector(63 downto 0) := (others => '0');
      d_rdata    : in  std_logic_vector(63 downto 0) := (others => '0');
      d_ready    : in  std_logic := '0';

      -- for the testbench: one pulse per retired instruction, with the state
      -- that instruction produced.  This is what gets diffed against the model.
      retire     : out std_logic := '0';
      retire_pc  : out std_logic_vector(63 downto 0) := (others => '0');
      dbg_sel    : in  unsigned(4 downto 0) := (others => '0');
      dbg_gpr    : out std_logic_vector(63 downto 0) := (others => '0');
      dbg_hi     : out std_logic_vector(63 downto 0) := (others => '0');
      dbg_lo     : out std_logic_vector(63 downto 0) := (others => '0');
      dbg_traps  : out unsigned(15 downto 0) := (others => '0')
   );
end entity;

architecture arch of ee_core is
   type regfile_t is array (0 to 31) of std_logic_vector(127 downto 0);
   signal gpr : regfile_t := (others => (others => '0'));

   signal pc        : unsigned(63 downto 0) := (others => '0');
   signal hi, lo    : std_logic_vector(63 downto 0) := (others => '0');
   signal instr     : std_logic_vector(31 downto 0) := (others => '0');
   signal traps     : unsigned(15 downto 0) := (others => '0');

   -- A taken branch does not change the PC until the instruction after it has
   -- run.  br_pend holds the target across that delay slot.
   signal br_pend   : std_logic := '0';
   signal br_target : unsigned(63 downto 0) := (others => '0');

   type state_t is (S_FETCH, S_WAIT_I, S_EXEC, S_WAIT_D, S_DIV, S_MUL);
   signal state : state_t := S_FETCH;

   -- the load in flight, held while the data port answers
   signal ld_rt    : integer range 0 to 31 := 0;
   signal ld_width : integer range 1 to 8 := 4;
   signal ld_sign  : std_logic := '0';
   signal ld_shift : integer range 0 to 7 := 0;
   signal ld_pend  : std_logic := '0';        -- the access in flight is a load

   -- The 32-cycle restoring divider.  DIV and DIVU cannot be single
   -- combinational expressions: `/` and `rem` synthesise into a 155-level
   -- carry chain, and an out-of-context place-and-route of this core with a
   -- combinational divide came back at 24 MHz -- the divider alone was a 41 ns
   -- path from a GPR to HI, against a 3.39 ns budget.  Iterating one quotient
   -- bit per clock costs 32 cycles on an instruction the real R5900 already
   -- spends 37 cycles on, and takes the divide out of the critical path
   -- entirely.
   signal div_rem  : unsigned(32 downto 0) := (others => '0');
   signal div_quot : unsigned(31 downto 0) := (others => '0');
   signal div_dvsr : unsigned(31 downto 0) := (others => '0');
   signal div_cnt  : integer range 0 to 32 := 0;
   signal div_negq : std_logic := '0';       -- negate the quotient when it lands
   signal div_negr : std_logic := '0';       -- negate the remainder when it lands

   -- The pipelined multiplier.  A combinational 32x32 lands as an unregistered
   -- DSP48E2 cascade -- GPR through PREADD, MULTIPLIER, ALU and OUTPUT and back
   -- to a GPR in one cycle, 7.9 ns of it -- and once the divider stopped being
   -- the worst path, that became it.  Registering the operands and the product
   -- puts real flip-flops at the DSP's A/B, M and P stages, which is the only
   -- shape the primitive runs fast in.  MULT costs three cycles here against
   -- four on the real R5900, so this buys the clock back for free.
   --
   -- One 33-bit signed multiplier serves both MULT and MULTU: sign-extending
   -- the operands for one and zero-extending them for the other makes the low
   -- 64 bits of the product correct in both cases, so there is no second
   -- unsigned multiplier to place and no second path to time.
   signal mul_a, mul_b : signed(32 downto 0) := (others => '0');
   signal mul_p1       : signed(65 downto 0) := (others => '0');
   signal mul_p        : signed(65 downto 0) := (others => '0');
   signal mul_rd       : integer range 0 to 31 := 0;
   signal mul_cnt      : integer range 0 to 2 := 0;

   function sext32(v : std_logic_vector(31 downto 0)) return std_logic_vector is
   begin
      return std_logic_vector'(31 downto 0 => v(31)) & v;
   end function;

   function rd_gpr(r : regfile_t; n : integer) return std_logic_vector is
   begin
      if n = 0 then return (63 downto 0 => '0'); end if;
      return r(n)(63 downto 0);
   end function;
begin

   dbg_gpr <= rd_gpr(gpr, to_integer(dbg_sel));
   dbg_hi  <= hi;
   dbg_lo  <= lo;
   dbg_traps <= traps;

   process (clk)
      variable op, rs, rt, rd, sa, fn : integer;
      variable a, b, res              : std_logic_vector(63 downto 0);
      variable simm                   : signed(63 downto 0);
      variable imm                    : std_logic_vector(15 downto 0);
      variable nxt                    : unsigned(63 downto 0);
      variable tgt                    : unsigned(63 downto 0);
      variable take                   : boolean;
      variable wb_n                   : integer range 0 to 31;
      variable wb_v                   : std_logic_vector(63 downto 0);
      variable wb_en                  : boolean;
      variable ea                     : unsigned(63 downto 0);
      variable dvd_mag, dvsr_mag      : unsigned(31 downto 0);
      variable div_shift              : unsigned(32 downto 0);
      variable ldv, ldw               : std_logic_vector(63 downto 0);
      -- Whether this instruction goes to memory has to be a variable, not the
      -- state signal: a signal assigned earlier in this process still reads as
      -- the old state here, so testing `state /= S_WAIT_D` was always true and
      -- the later `state <= S_FETCH` overrode it.  Loads and stores never
      -- entered the wait state, and a load therefore never wrote its register.
      variable mem_op                 : boolean;
      -- likewise for the divider and the multiplier: each holds the machine in
      -- its own state for several cycles and must suppress the retire pulse
      -- without suppressing the PC advance.
      variable div_op                 : boolean;
      variable mul_op                 : boolean;
   begin
      if rising_edge(clk) then
         retire <= '0';
         i_read <= '0';
         d_read <= '0';
         d_write <= '0';

         if reset = '1' then
            state    <= S_FETCH;
            pc       <= resize(unsigned(pc_reset), 64);
            hi       <= (others => '0');
            lo       <= (others => '0');
            traps    <= (others => '0');
            br_pend  <= '0';
            gpr      <= (others => (others => '0'));
            div_cnt  <= 0;
            mul_cnt  <= 0;
         else
            case state is

               when S_FETCH =>
                  i_addr <= std_logic_vector(pc(31 downto 0));
                  i_read <= '1';
                  state  <= S_WAIT_I;

               when S_WAIT_I =>
                  i_addr <= std_logic_vector(pc(31 downto 0));
                  i_read <= '1';
                  if i_ready = '1' then
                     instr  <= i_data;
                     i_read <= '0';
                     state  <= S_EXEC;
                  end if;

               when S_EXEC =>
                  op := to_integer(unsigned(instr(31 downto 26)));
                  rs := to_integer(unsigned(instr(25 downto 21)));
                  rt := to_integer(unsigned(instr(20 downto 16)));
                  rd := to_integer(unsigned(instr(15 downto 11)));
                  sa := to_integer(unsigned(instr(10 downto 6)));
                  fn := to_integer(unsigned(instr(5 downto 0)));
                  imm := instr(15 downto 0);
                  simm := resize(signed(imm), 64);
                  a := rd_gpr(gpr, rs);
                  b := rd_gpr(gpr, rt);
                  nxt := pc + 4;
                  take := false;
                  wb_en := false;
                  mem_op := false;
                  div_op := false;
                  mul_op := false;
                  wb_n := 0;
                  wb_v := (others => '0');

                  case op is
                     when 0 =>                               -- SPECIAL
                        case fn is
                           when 0  => wb_en := true; wb_n := rd;   -- SLL
                                      wb_v := sext32(std_logic_vector(shift_left(unsigned(b(31 downto 0)), sa)));
                           when 2  => wb_en := true; wb_n := rd;   -- SRL
                                      wb_v := sext32(std_logic_vector(shift_right(unsigned(b(31 downto 0)), sa)));
                           when 3  => wb_en := true; wb_n := rd;   -- SRA
                                      wb_v := sext32(std_logic_vector(shift_right(signed(b(31 downto 0)), sa)));
                           when 4  => wb_en := true; wb_n := rd;   -- SLLV
                                      wb_v := sext32(std_logic_vector(shift_left(unsigned(b(31 downto 0)), to_integer(unsigned(a(4 downto 0))))));
                           when 6  => wb_en := true; wb_n := rd;   -- SRLV
                                      wb_v := sext32(std_logic_vector(shift_right(unsigned(b(31 downto 0)), to_integer(unsigned(a(4 downto 0))))));
                           when 7  => wb_en := true; wb_n := rd;   -- SRAV
                                      wb_v := sext32(std_logic_vector(shift_right(signed(b(31 downto 0)), to_integer(unsigned(a(4 downto 0))))));
                           when 8  => take := true; tgt := unsigned(a);              -- JR
                           when 9  => wb_en := true;                                  -- JALR
                                      if rd = 0 then wb_n := 31; else wb_n := rd; end if;
                                      wb_v := std_logic_vector(nxt + 4);
                                      take := true; tgt := unsigned(a);
                           when 16 => wb_en := true; wb_n := rd; wb_v := hi;          -- MFHI
                           when 17 => hi <= a;                                        -- MTHI
                           when 18 => wb_en := true; wb_n := rd; wb_v := lo;          -- MFLO
                           when 19 => lo <= a;                                        -- MTLO
                           when 20 => wb_en := true; wb_n := rd;                      -- DSLLV
                                      wb_v := std_logic_vector(shift_left(unsigned(b), to_integer(unsigned(a(5 downto 0)))));
                           when 22 => wb_en := true; wb_n := rd;                      -- DSRLV
                                      wb_v := std_logic_vector(shift_right(unsigned(b), to_integer(unsigned(a(5 downto 0)))));
                           when 23 => wb_en := true; wb_n := rd;                      -- DSRAV
                                      wb_v := std_logic_vector(shift_right(signed(b), to_integer(unsigned(a(5 downto 0)))));
                           when 24 | 25 =>                                            -- MULT / MULTU
                              if fn = 24 then
                                 mul_a <= resize(signed(a(31 downto 0)), 33);
                                 mul_b <= resize(signed(b(31 downto 0)), 33);
                              else
                                 mul_a <= signed(std_logic_vector'('0' & a(31 downto 0)));
                                 mul_b <= signed(std_logic_vector'('0' & b(31 downto 0)));
                              end if;
                              mul_rd  <= rd;
                              mul_cnt <= 2;
                              mul_op  := true;
                              state   <= S_MUL;
                           when 26 | 27 =>                                            -- DIV / DIVU
                              -- Magnitudes go into the iterative unit and the
                              -- signs are applied when the result lands, which
                              -- is what gives MIPS truncation-toward-zero with
                              -- the remainder taking the dividend's sign.
                              --
                              -- Divide by zero needs no special case.  A
                              -- restoring divider with a zero divisor subtracts
                              -- nothing, so it sets every quotient bit and
                              -- shifts the dividend intact into the remainder:
                              -- LO = 0xFFFFFFFF, HI = dividend, exactly what the
                              -- manual specifies for DIVU.  For DIV the sign
                              -- fixups below turn that into LO = -1 for a
                              -- non-negative dividend and LO = 1 for a negative
                              -- one, which is the specified result there too.
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
                              div_cnt  <= 32;
                              if fn = 26 then
                                 div_negq <= a(31) xor b(31);
                                 div_negr <= a(31);
                              else
                                 div_negq <= '0';
                                 div_negr <= '0';
                              end if;
                              div_op := true;
                              state  <= S_DIV;
                           when 32 | 33 => wb_en := true; wb_n := rd;                 -- ADD/ADDU
                              wb_v := sext32(std_logic_vector(signed(a(31 downto 0)) + signed(b(31 downto 0))));
                              if fn = 32 then null; end if;   -- overflow trap: not taken yet
                           when 34 | 35 => wb_en := true; wb_n := rd;                 -- SUB/SUBU
                              wb_v := sext32(std_logic_vector(signed(a(31 downto 0)) - signed(b(31 downto 0))));
                           when 36 => wb_en := true; wb_n := rd; wb_v := a and b;     -- AND
                           when 37 => wb_en := true; wb_n := rd; wb_v := a or b;      -- OR
                           when 38 => wb_en := true; wb_n := rd; wb_v := a xor b;     -- XOR
                           when 39 => wb_en := true; wb_n := rd; wb_v := not (a or b);-- NOR
                           when 42 => wb_en := true; wb_n := rd;                      -- SLT
                              if signed(a) < signed(b) then wb_v := (0 => '1', others => '0');
                              else wb_v := (others => '0'); end if;
                           when 43 => wb_en := true; wb_n := rd;                      -- SLTU
                              if unsigned(a) < unsigned(b) then wb_v := (0 => '1', others => '0');
                              else wb_v := (others => '0'); end if;
                           when 44 | 45 => wb_en := true; wb_n := rd;                 -- DADD/DADDU
                              wb_v := std_logic_vector(signed(a) + signed(b));
                           when 46 | 47 => wb_en := true; wb_n := rd;                 -- DSUB/DSUBU
                              wb_v := std_logic_vector(signed(a) - signed(b));
                           when 56 => wb_en := true; wb_n := rd;                      -- DSLL
                              wb_v := std_logic_vector(shift_left(unsigned(b), sa));
                           when 58 => wb_en := true; wb_n := rd;                      -- DSRL
                              wb_v := std_logic_vector(shift_right(unsigned(b), sa));
                           when 59 => wb_en := true; wb_n := rd;                      -- DSRA
                              wb_v := std_logic_vector(shift_right(signed(b), sa));
                           when 60 => wb_en := true; wb_n := rd;                      -- DSLL32
                              wb_v := std_logic_vector(shift_left(unsigned(b), sa + 32));
                           when 62 => wb_en := true; wb_n := rd;                      -- DSRL32
                              wb_v := std_logic_vector(shift_right(unsigned(b), sa + 32));
                           when 63 => wb_en := true; wb_n := rd;                      -- DSRA32
                              wb_v := std_logic_vector(shift_right(signed(b), sa + 32));
                           when others => traps <= traps + 1;
                        end case;

                     when 1 =>                                    -- REGIMM
                        case rt is
                           when 0  => take := signed(a) < 0;
                           when 1  => take := signed(a) >= 0;
                           when 16 => wb_en := true; wb_n := 31; wb_v := std_logic_vector(nxt + 4);
                                      take := signed(a) < 0;
                           when 17 => wb_en := true; wb_n := 31; wb_v := std_logic_vector(nxt + 4);
                                      take := signed(a) >= 0;
                           when others => traps <= traps + 1;
                        end case;
                        tgt := nxt + unsigned(shift_left(simm, 2));

                     when 2 =>                                    -- J
                        take := true;
                        tgt := (nxt(63 downto 28) & unsigned(instr(25 downto 0)) & "00");
                     when 3 =>                                    -- JAL
                        wb_en := true; wb_n := 31; wb_v := std_logic_vector(nxt + 4);
                        take := true;
                        tgt := (nxt(63 downto 28) & unsigned(instr(25 downto 0)) & "00");
                     when 4 => take := (a = b);  tgt := nxt + unsigned(shift_left(simm, 2));
                     when 5 => take := (a /= b); tgt := nxt + unsigned(shift_left(simm, 2));
                     when 6 => take := signed(a) <= 0; tgt := nxt + unsigned(shift_left(simm, 2));
                     when 7 => take := signed(a) > 0;  tgt := nxt + unsigned(shift_left(simm, 2));

                     when 8 | 9 => wb_en := true; wb_n := rt;      -- ADDI/ADDIU
                        wb_v := sext32(std_logic_vector(signed(a(31 downto 0)) + signed(simm(31 downto 0))));
                     when 10 => wb_en := true; wb_n := rt;         -- SLTI
                        if signed(a) < simm then wb_v := (0 => '1', others => '0');
                        else wb_v := (others => '0'); end if;
                     when 11 => wb_en := true; wb_n := rt;         -- SLTIU
                        if unsigned(a) < unsigned(simm) then wb_v := (0 => '1', others => '0');
                        else wb_v := (others => '0'); end if;
                     when 12 => wb_en := true; wb_n := rt; wb_v := a and (std_logic_vector'(x"000000000000") & imm);
                     when 13 => wb_en := true; wb_n := rt; wb_v := a or  (std_logic_vector'(x"000000000000") & imm);
                     when 14 => wb_en := true; wb_n := rt; wb_v := a xor (std_logic_vector'(x"000000000000") & imm);
                     when 15 => wb_en := true; wb_n := rt;         -- LUI
                        wb_v := sext32(imm & std_logic_vector'(x"0000"));
                     when 24 | 25 => wb_en := true; wb_n := rt;    -- DADDI/DADDIU
                        wb_v := std_logic_vector(signed(a) + simm);

                     when 32 | 33 | 35 | 36 | 37 | 39 | 55 =>      -- loads
                        ea := unsigned(signed(a) + simm);
                        d_addr <= std_logic_vector(ea(31 downto 0));
                        d_read <= '1';
                        ld_rt  <= rt;
                        case op is
                           when 32 => ld_width <= 1; ld_sign <= '1';
                           when 36 => ld_width <= 1; ld_sign <= '0';
                           when 33 => ld_width <= 2; ld_sign <= '1';
                           when 37 => ld_width <= 2; ld_sign <= '0';
                           when 35 => ld_width <= 4; ld_sign <= '1';
                           when 39 => ld_width <= 4; ld_sign <= '0';
                           when others => ld_width <= 8; ld_sign <= '0';
                        end case;
                        ld_shift <= to_integer(ea(2 downto 0));
                        ld_pend  <= '1';
                        mem_op := true;
                        state <= S_WAIT_D;

                     when 40 | 41 | 43 | 63 =>                     -- stores
                        ea := unsigned(signed(a) + simm);
                        d_addr  <= std_logic_vector(ea(31 downto 0));
                        d_write <= '1';
                        d_wdata <= std_logic_vector(shift_left(unsigned(b), 8 * to_integer(ea(2 downto 0))));
                        case op is
                           when 40 => d_be <= std_logic_vector(shift_left(unsigned'(x"01"), to_integer(ea(2 downto 0))));
                           when 41 => d_be <= std_logic_vector(shift_left(unsigned'(x"03"), to_integer(ea(2 downto 0))));
                           when 43 => d_be <= std_logic_vector(shift_left(unsigned'(x"0F"), to_integer(ea(2 downto 0))));
                           when others => d_be <= x"FF";
                        end case;
                        ld_pend <= '0';
                        mem_op := true;
                        state <= S_WAIT_D;

                     when others => traps <= traps + 1;
                  end case;

                  -- writeback, r0 discarded, upper 64 bits of the GPR untouched
                  if wb_en and wb_n /= 0 then
                     gpr(wb_n)(63 downto 0) <= wb_v;
                  end if;

                  -- advance, honouring a branch that is one instruction old
                  -- Capture the PC of the instruction being executed now, not
                  -- when it retires: a load retires from S_WAIT_D, by which time
                  -- the PC has already advanced, and reporting the next
                  -- instruction's address makes a divergence point at the wrong
                  -- line.  retire_pc is only sampled when retire is high, so
                  -- setting it here is safe for both paths.
                  retire_pc <= std_logic_vector(pc);

                  if not (mem_op or div_op or mul_op) then
                     if br_pend = '1' then
                        pc <= br_target; br_pend <= '0';
                     else
                        pc <= nxt;
                     end if;
                     if take then
                        br_pend <= '1'; br_target <= tgt;
                     end if;
                     retire    <= '1';
                     state     <= S_FETCH;
                  else
                     -- the branch bookkeeping still has to happen for a
                     -- load, store or divide sitting in a delay slot
                     if br_pend = '1' then
                        pc <= br_target; br_pend <= '0';
                     else
                        pc <= nxt;
                     end if;
                  end if;

               when S_MUL =>
                  case mul_cnt is
                     when 2 =>
                        mul_p1  <= mul_a * mul_b;
                        mul_cnt <= 1;
                     when 1 =>
                        -- a second register stage, so the tool has one to push
                        -- into the DSP's own output pipeline rather than
                        -- leaving the cascade adder in fabric
                        mul_p   <= mul_p1;
                        mul_cnt <= 0;
                     when others =>
                        lo <= sext32(std_logic_vector(mul_p(31 downto 0)));
                        hi <= sext32(std_logic_vector(mul_p(63 downto 32)));
                        -- MULT and MULTU are three-operand on the R5900: rd
                        -- takes the low word too, and rd = 0 writes nothing.
                        if mul_rd /= 0 then
                           gpr(mul_rd)(63 downto 0) <= sext32(std_logic_vector(mul_p(31 downto 0)));
                        end if;
                        retire <= '1';
                        state  <= S_FETCH;
                  end case;

               when S_DIV =>
                  if div_cnt = 0 then
                     if div_negq = '1' then
                        lo <= sext32(std_logic_vector(0 - div_quot));
                     else
                        lo <= sext32(std_logic_vector(div_quot));
                     end if;
                     if div_negr = '1' then
                        hi <= sext32(std_logic_vector(0 - div_rem(31 downto 0)));
                     else
                        hi <= sext32(std_logic_vector(div_rem(31 downto 0)));
                     end if;
                     retire <= '1';
                     state  <= S_FETCH;
                  else
                     -- one quotient bit per clock: shift the next dividend bit
                     -- into the running remainder, subtract the divisor if it
                     -- fits, and record whether it did.
                     div_shift := div_rem(31 downto 0) & div_quot(31);
                     if div_shift >= ('0' & div_dvsr) then
                        div_rem  <= div_shift - ('0' & div_dvsr);
                        div_quot <= div_quot(30 downto 0) & '1';
                     else
                        div_rem  <= div_shift;
                        div_quot <= div_quot(30 downto 0) & '0';
                     end if;
                     div_cnt <= div_cnt - 1;
                  end if;

               when S_WAIT_D =>
                  -- hold the request asserted until the port answers
                  if ld_pend = '1' then d_read <= '1'; else d_write <= '1'; end if;
                  if d_ready = '1' then
                     d_read  <= '0';
                     d_write <= '0';
                     if ld_pend = '1' then
                        -- The port answers with the whole 64-bit word that
                        -- contains the address, so the byte the instruction
                        -- asked for has to be selected out of it and then
                        -- extended.  Getting the extension wrong is invisible
                        -- until a value happens to have its top bit set.
                        ldv := std_logic_vector(shift_right(unsigned(d_rdata), 8 * ld_shift));
                        case ld_width is
                           when 1 =>
                              if ld_sign = '1' then
                                 ldw := std_logic_vector'(55 downto 0 => ldv(7)) & ldv(7 downto 0);
                              else
                                 ldw := std_logic_vector'(x"00000000000000") & ldv(7 downto 0);
                              end if;
                           when 2 =>
                              if ld_sign = '1' then
                                 ldw := std_logic_vector'(47 downto 0 => ldv(15)) & ldv(15 downto 0);
                              else
                                 ldw := std_logic_vector'(x"000000000000") & ldv(15 downto 0);
                              end if;
                           when 4 =>
                              if ld_sign = '1' then
                                 ldw := sext32(ldv(31 downto 0));
                              else
                                 ldw := std_logic_vector'(x"00000000") & ldv(31 downto 0);
                              end if;
                           when others =>
                              ldw := ldv;
                        end case;
                        if ld_rt /= 0 then
                           gpr(ld_rt)(63 downto 0) <= ldw;
                        end if;
                     end if;
                     retire    <= '1';
                     state     <= S_FETCH;
                  end if;
            end case;
         end if;
      end if;
   end process;

end architecture;
