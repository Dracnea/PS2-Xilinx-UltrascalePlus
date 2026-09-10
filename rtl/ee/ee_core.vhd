-- ee_core.vhd -- the R5900's integer datapath, written to the EE Core User's
-- Manual and checked against sim/ee/r5900_ref.py instruction by instruction.
--
-- Five stages, single issue, in order:
--
--   IF   a two-entry fetch queue with one request outstanding
--   ID   decode and register read
--   EX   ALU, branch resolution, and the multi-cycle multiply and divide
--   MEM  the data port
--   WB   the register file, HI and LO
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
--   * **Nothing commits before WB.**  HI and LO are computed in EX but carried
--     down the pipeline and written in WB with the register file, because the
--     testbench samples all architectural state at each retire and an early
--     write would make an instruction's result visible while an *older* one is
--     still retiring.
--   * **Every read is forwarded.**  ID bypasses the instruction in WB; EX
--     forwards from MEM and from WB.  Between them those cover every distance
--     except a load whose value is still in flight, which is what the load-use
--     interlock stalls for.
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

      -- instruction port, 32 bits.  One request may be outstanding; the reply
      -- may arrive any number of cycles later, and i_ready marks it.
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
   signal gpr    : regfile_t := (others => (others => '0'));
   signal hi, lo : std_logic_vector(63 downto 0) := (others => '0');
   signal traps  : unsigned(15 downto 0) := (others => '0');

   -- ---- IF -----------------------------------------------------------------
   -- One request may be outstanding at a time and the queue holds two, which
   -- is what it takes to deliver an instruction every cycle to a consumer that
   -- can stall: the queue absorbs the reply that arrives while ID is held up.
   -- Without that the pipeline runs at half rate, and -- far worse for a
   -- differential test -- dependent instructions are never adjacent, so every
   -- forwarding path goes untested.
   -- The program counter is 32 bits, which is the width of the R5900's address
   -- bus and of this core's instruction port.  Carrying it as 64 doubled every
   -- PC adder and every PC mux in the design, and the increment after a
   -- redirect -- a 64-bit add sitting behind the operand-forwarding mux and the
   -- branch decision, on the path from a JR's register operand to the fetch PC
   -- -- was the critical path once the branch target moved into ID.  The link
   -- value and the retired PC are sign-extended back to 64 bits at the two
   -- points that need them, which is what the manual specifies anyway.
   signal fetch_pc   : unsigned(31 downto 0) := (others => '0');
   signal req_pc     : unsigned(31 downto 0) := (others => '0');
   signal outst      : std_logic := '0';   -- a request is in flight
   signal drop       : std_logic := '0';   -- and it is wrong-path: discard it
   signal redir_pend : std_logic := '0';
   signal redir_tgt  : unsigned(31 downto 0) := (others => '0');

   type q_pc_t is array (0 to 1) of unsigned(31 downto 0);
   type q_ir_t is array (0 to 1) of std_logic_vector(31 downto 0);
   signal q_pc  : q_pc_t := (others => (others => '0'));
   signal q_ir  : q_ir_t := (others => (others => '0'));
   signal q_cnt : integer range 0 to 2 := 0;

   -- ---- ID/EX --------------------------------------------------------------
   signal d_valid   : std_logic := '0';
   signal d_pc      : unsigned(31 downto 0) := (others => '0');
   signal d_ir      : std_logic_vector(31 downto 0) := (others => '0');
   signal d_a, d_b  : std_logic_vector(63 downto 0) := (others => '0');
   signal d_rs      : integer range 0 to 31 := 0;
   signal d_rt      : integer range 0 to 31 := 0;
   -- The branch target and the link address are computed in ID, not EX.  Both
   -- depend only on the PC and the instruction word, which ID already has, and
   -- leaving them in EX put two chained 64-bit adders between the ID/EX latch
   -- and the fetch PC -- 11 of the 20 logic levels on the critical path, for
   -- arithmetic that had no reason to be there.  EX now only decides whether
   -- the branch is taken and, for JR and JALR, substitutes the register.
   signal d_tgt     : unsigned(31 downto 0) := (others => '0');
   signal d_link    : std_logic_vector(63 downto 0) := (others => '0');

   -- ---- EX/MEM -------------------------------------------------------------
   signal m_valid   : std_logic := '0';
   signal m_pc      : unsigned(31 downto 0) := (others => '0');
   signal m_we      : std_logic := '0';
   signal m_rd      : integer range 0 to 31 := 0;
   signal m_val     : std_logic_vector(63 downto 0) := (others => '0');
   signal m_hi_we   : std_logic := '0';
   signal m_lo_we   : std_logic := '0';
   signal m_hi      : std_logic_vector(63 downto 0) := (others => '0');
   signal m_lo      : std_logic_vector(63 downto 0) := (others => '0');
   signal m_ismem   : std_logic := '0';
   signal m_isload  : std_logic := '0';
   signal m_width   : integer range 1 to 8 := 4;
   signal m_sign    : std_logic := '0';
   signal m_shift   : integer range 0 to 7 := 0;

   -- ---- MEM/WB -------------------------------------------------------------
   signal w_valid   : std_logic := '0';
   signal w_pc      : unsigned(31 downto 0) := (others => '0');
   signal w_we      : std_logic := '0';
   signal w_rd      : integer range 0 to 31 := 0;
   signal w_val     : std_logic_vector(63 downto 0) := (others => '0');
   signal w_hi_we   : std_logic := '0';
   signal w_lo_we   : std_logic := '0';
   signal w_hi      : std_logic_vector(63 downto 0) := (others => '0');
   signal w_lo      : std_logic_vector(63 downto 0) := (others => '0');

   -- ---- the multi-cycle units, which live in EX ----------------------------
   -- ex_cnt is the number of cycles the instruction in EX still needs.  It is
   -- 0 for a single-cycle instruction and for the first cycle of a multi-cycle
   -- one; 1 means "the result is on the wires now", which is the only value at
   -- which EX is allowed to advance.
   signal ex_cnt   : integer range 0 to 33 := 0;

   signal div_rem  : unsigned(32 downto 0) := (others => '0');
   signal div_quot : unsigned(31 downto 0) := (others => '0');
   signal div_dvsr : unsigned(31 downto 0) := (others => '0');
   signal div_negq : std_logic := '0';
   signal div_negr : std_logic := '0';

   signal mul_a, mul_b  : signed(32 downto 0) := (others => '0');
   signal mul_p1, mul_p : signed(65 downto 0) := (others => '0');

   function sext32(v : std_logic_vector(31 downto 0)) return std_logic_vector is
   begin
      return std_logic_vector'(31 downto 0 => v(31)) & v;
   end function;

   function rd_gpr(r : regfile_t; n : integer) return std_logic_vector is
   begin
      if n = 0 then return (63 downto 0 => '0'); end if;
      return r(n)(63 downto 0);
   end function;

   -- Does this opcode read rs / rt?  Getting these wrong in the safe direction
   -- only costs a stall, so anything unrecognised is assumed to read both.
   function reads_rs(ir : std_logic_vector(31 downto 0)) return boolean is
      variable op : integer := to_integer(unsigned(ir(31 downto 26)));
      variable fn : integer := to_integer(unsigned(ir(5 downto 0)));
   begin
      case op is
         when 2 | 3 | 15 => return false;                       -- J, JAL, LUI
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
         when 4 | 5 => return true;                             -- BEQ, BNE
         when 40 | 41 | 43 | 63 => return true;                 -- stores
         when others => return false;   -- rt is the destination, or unused
      end case;
   end function;

   function is_load(ir : std_logic_vector(31 downto 0)) return boolean is
      variable op : integer := to_integer(unsigned(ir(31 downto 26)));
   begin
      case op is
         when 32 | 33 | 35 | 36 | 37 | 39 | 55 => return true;
         when others => return false;
      end case;
   end function;

   function is_muldiv(ir : std_logic_vector(31 downto 0)) return boolean is
      variable fn : integer := to_integer(unsigned(ir(5 downto 0)));
   begin
      if ir(31 downto 26) /= "000000" then return false; end if;
      return fn >= 24 and fn <= 27;
   end function;
begin

   dbg_gpr   <= rd_gpr(gpr, to_integer(dbg_sel));
   dbg_hi    <= hi;
   dbg_lo    <= lo;
   dbg_traps <= traps;

   process (clk)
      -- EX decode and result
      variable op, rs, rt, rd, sa, fn : integer;
      variable a, b                   : std_logic_vector(63 downto 0);
      variable simm                   : signed(63 downto 0);
      variable imm                    : std_logic_vector(15 downto 0);
      variable tgt                    : unsigned(31 downto 0);
      variable ea                     : unsigned(63 downto 0);
      variable hi_f, lo_f             : std_logic_vector(63 downto 0);
      variable ex_we                  : std_logic;
      variable ex_rd                  : integer range 0 to 31;
      variable ex_val                 : std_logic_vector(63 downto 0);
      variable ex_hi_we, ex_lo_we     : std_logic;
      variable ex_hi, ex_lo           : std_logic_vector(63 downto 0);
      variable ex_ismem, ex_isload    : std_logic;
      variable ex_width               : integer range 1 to 8;
      variable ex_sign                : std_logic;
      variable ex_shift               : integer range 0 to 7;
      variable ex_addr                : std_logic_vector(31 downto 0);
      variable ex_be                  : std_logic_vector(7 downto 0);
      variable ex_wdata               : std_logic_vector(63 downto 0);
      variable ex_take                : boolean;
      variable ex_trap                : boolean;
      variable ex_busy                : boolean;
      variable dvd_mag, dvsr_mag      : unsigned(31 downto 0);
      variable div_shift              : unsigned(32 downto 0);

      -- stage handshakes
      variable mem_adv, ex_adv, id_adv : boolean;
      variable load_use                : boolean;

      -- ID
      variable id_ir             : std_logic_vector(31 downto 0);
      variable id_rs, id_rt      : integer range 0 to 31;
      variable id_op             : integer;
      variable id_a, id_b        : std_logic_vector(63 downto 0);
      variable id_nxt, id_tgt    : unsigned(31 downto 0);
      variable id_link           : std_logic_vector(63 downto 0);

      -- MEM
      variable ldv, ldw          : std_logic_vector(63 downto 0);

      -- IF queue bookkeeping
      variable vq_pc   : q_pc_t;
      variable vq_ir   : q_ir_t;
      variable vcnt    : integer range 0 to 2;
      variable vouts   : std_logic;
      variable vdrop   : std_logic;
      variable push    : boolean;
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
            traps      <= (others => '0');
            fetch_pc   <= unsigned(pc_reset);
            outst      <= '0';
            drop       <= '0';
            redir_pend <= '0';
            q_cnt      <= 0;
            d_valid    <= '0';
            m_valid    <= '0';
            m_ismem    <= '0';
            w_valid    <= '0';
            ex_cnt     <= 0;
            d_read     <= '0';
            d_write    <= '0';
         else

            -- ============================================================
            -- MEM: can the instruction in the MEM latch leave this cycle?
            -- ============================================================
            mem_adv := true;
            if m_valid = '1' and m_ismem = '1' and d_ready = '0' then
               mem_adv := false;
            end if;

            -- ============================================================
            -- EX: decode the instruction in the ID/EX latch and compute
            -- ============================================================
            op   := to_integer(unsigned(d_ir(31 downto 26)));
            rs   := to_integer(unsigned(d_ir(25 downto 21)));
            rt   := to_integer(unsigned(d_ir(20 downto 16)));
            rd   := to_integer(unsigned(d_ir(15 downto 11)));
            sa   := to_integer(unsigned(d_ir(10 downto 6)));
            fn   := to_integer(unsigned(d_ir(5 downto 0)));
            imm  := d_ir(15 downto 0);
            simm := resize(signed(imm), 64);

            -- Operand forwarding.  ID already bypassed the instruction in WB
            -- as it read the register file, so what is left is the two closer
            -- ones: MEM first as the older, then EX/MEM last so the youngest
            -- writer wins.  A load in MEM has no value yet, which is what the
            -- load-use interlock below exists to prevent needing.
            a := d_a;
            b := d_b;
            if w_valid = '1' and w_we = '1' and w_rd /= 0 then
               if w_rd = d_rs then a := w_val; end if;
               if w_rd = d_rt then b := w_val; end if;
            end if;
            if m_valid = '1' and m_we = '1' and m_rd /= 0 then
               if m_rd = d_rs then a := m_val; end if;
               if m_rd = d_rt then b := m_val; end if;
            end if;

            -- HI and LO are read in EX and written in WB, so they need the
            -- same two forwarding steps and the same priority.
            hi_f := hi;
            lo_f := lo;
            if w_valid = '1' then
               if w_hi_we = '1' then hi_f := w_hi; end if;
               if w_lo_we = '1' then lo_f := w_lo; end if;
            end if;
            if m_valid = '1' then
               if m_hi_we = '1' then hi_f := m_hi; end if;
               if m_lo_we = '1' then lo_f := m_lo; end if;
            end if;

            ex_we     := '0';
            ex_rd     := 0;
            ex_val    := (others => '0');
            ex_hi_we  := '0';
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
            ex_take   := false;
            ex_trap   := false;
            tgt       := (others => '0');
            ea        := (others => '0');

            case op is
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
                     when 16 => ex_we := '1'; ex_rd := rd; ex_val := hi_f;         -- MFHI
                     when 17 => ex_hi_we := '1'; ex_hi := a;                       -- MTHI
                     when 18 => ex_we := '1'; ex_rd := rd; ex_val := lo_f;         -- MFLO
                     when 19 => ex_lo_we := '1'; ex_lo := a;                       -- MTLO
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

                     when 32 | 33 => ex_we := '1'; ex_rd := rd;                    -- ADD/ADDU
                        ex_val := sext32(std_logic_vector(signed(a(31 downto 0)) + signed(b(31 downto 0))));
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

               when 8 | 9 => ex_we := '1'; ex_rd := rt;      -- ADDI/ADDIU
                  ex_val := sext32(std_logic_vector(signed(a(31 downto 0)) + signed(simm(31 downto 0))));
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
                  ex_shift := to_integer(ea(2 downto 0));

               when 40 | 41 | 43 | 63 =>                     -- stores
                  ea := unsigned(signed(a) + simm);
                  ex_addr  := std_logic_vector(ea(31 downto 0));
                  ex_ismem := '1';
                  ex_wdata := std_logic_vector(shift_left(unsigned(b), 8 * to_integer(ea(2 downto 0))));
                  case op is
                     when 40 => ex_be := std_logic_vector(shift_left(unsigned'(x"01"), to_integer(ea(2 downto 0))));
                     when 41 => ex_be := std_logic_vector(shift_left(unsigned'(x"03"), to_integer(ea(2 downto 0))));
                     when 43 => ex_be := std_logic_vector(shift_left(unsigned'(x"0F"), to_integer(ea(2 downto 0))));
                     when others => ex_be := x"FF";
                  end case;

               when others => ex_trap := true;
            end case;

            -- Is EX able to hand a result on?  A multi-cycle instruction is
            -- busy on its first cycle (ex_cnt = 0, when it is kicked off) and
            -- through the middle of its run, and free only at ex_cnt = 1.
            ex_busy := false;
            if d_valid = '1' and is_muldiv(d_ir) and ex_cnt /= 1 then
               ex_busy := true;
            end if;
            ex_adv := mem_adv and not ex_busy;

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
               if w_rd = id_rs then id_a := w_val; end if;
               if w_rd = id_rt then id_b := w_val; end if;
            end if;

            -- The one hazard forwarding cannot cover: a load in EX moves to
            -- MEM as this instruction would move to EX, and its value does not
            -- exist until MEM answers.  One bubble puts the load in WB instead,
            -- where EX can forward from it.
            load_use := false;
            if d_valid = '1' and is_load(d_ir) and rt /= 0 and q_cnt > 0 then
               if (reads_rs(id_ir) and id_rs = rt) or
                  (reads_rt(id_ir) and id_rt = rt) then
                  load_use := true;
               end if;
            end if;

            id_adv := ex_adv and q_cnt > 0 and not load_use;

            -- ============================================================
            -- WB: commit.  Everything architectural is written here.
            -- ============================================================
            retire    <= w_valid;
            retire_pc <= sext32(std_logic_vector(w_pc));
            if w_valid = '1' then
               if w_we = '1' and w_rd /= 0 then
                  gpr(w_rd)(63 downto 0) <= w_val;
               end if;
               if w_hi_we = '1' then hi <= w_hi; end if;
               if w_lo_we = '1' then lo <= w_lo; end if;
            end if;

            -- ============================================================
            -- MEM -> WB
            -- ============================================================
            if mem_adv then
               w_valid  <= m_valid;
               w_pc     <= m_pc;
               w_we     <= m_we;
               w_rd     <= m_rd;
               w_hi_we  <= m_hi_we;
               w_lo_we  <= m_lo_we;
               w_hi     <= m_hi;
               w_lo     <= m_lo;
               if m_isload = '1' then
                  -- The port answers with the whole 64-bit word that contains
                  -- the address, so the bytes the instruction asked for have to
                  -- be selected out of it and then extended.  Getting the
                  -- extension wrong is invisible until a value happens to have
                  -- its top bit set.
                  ldv := std_logic_vector(shift_right(unsigned(d_rdata), 8 * m_shift));
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
                  w_val <= ldw;
               else
                  w_val <= m_val;
               end if;
               -- the port request is finished with
               d_read  <= '0';
               d_write <= '0';
            else
               w_valid <= '0';
            end if;

            -- ============================================================
            -- EX -> MEM
            -- ============================================================
            if mem_adv then
               if ex_adv then
                  m_valid  <= d_valid;
                  m_pc     <= d_pc;
                  m_we     <= ex_we;
                  m_rd     <= ex_rd;
                  m_val    <= ex_val;
                  m_hi_we  <= ex_hi_we;
                  m_lo_we  <= ex_lo_we;
                  m_hi     <= ex_hi;
                  m_lo     <= ex_lo;
                  m_ismem  <= ex_ismem and d_valid;
                  m_isload <= ex_isload;
                  m_width  <= ex_width;
                  m_sign   <= ex_sign;
                  m_shift  <= ex_shift;
                  if d_valid = '1' and ex_ismem = '1' then
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
                  m_valid <= '0';
                  m_ismem <= '0';
                  m_we    <= '0';
                  m_hi_we <= '0';
                  m_lo_we <= '0';
               end if;
            end if;

            -- ============================================================
            -- the multi-cycle units, stepped only when EX may make progress
            -- ============================================================
            if mem_adv and d_valid = '1' and is_muldiv(d_ir) then
               if ex_cnt = 0 then
                  -- kick off
                  if fn = 24 or fn = 25 then
                     if fn = 24 then
                        mul_a <= resize(signed(a(31 downto 0)), 33);
                        mul_b <= resize(signed(b(31 downto 0)), 33);
                     else
                        mul_a <= signed(std_logic_vector'('0' & a(31 downto 0)));
                        mul_b <= signed(std_logic_vector'('0' & b(31 downto 0)));
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
                  if fn = 24 or fn = 25 then
                     if ex_cnt = 3 then
                        mul_p1 <= mul_a * mul_b;
                     else
                        -- a second register stage, so the tool has one to push
                        -- into the DSP's own output pipeline rather than
                        -- leaving the cascade adder in fabric
                        mul_p <= mul_p1;
                     end if;
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
                  end if;
                  ex_cnt <= ex_cnt - 1;
               else
                  ex_cnt <= 0;         -- the result leaves EX this cycle
               end if;
            end if;

            -- ============================================================
            -- ID -> EX, and the branch redirect
            -- ============================================================
            do_flush := false;
            new_pc   := (others => '0');
            if ex_adv and d_valid = '1' and ex_take then
               -- The delay slot is the queue head right now.  If it is moving
               -- into EX on this edge it is safe to throw away everything
               -- behind it; if it is not (the queue is empty because the fetch
               -- has not come back yet) the redirect has to wait, or the flush
               -- would discard the delay slot itself.
               if id_adv then
                  do_flush := true;
                  new_pc   := tgt;
               else
                  redir_pend <= '1';
                  redir_tgt  <= tgt;
               end if;
            elsif redir_pend = '1' and id_adv then
               do_flush   := true;
               new_pc     := redir_tgt;
               redir_pend <= '0';
            end if;

            if ex_adv then
               if id_adv then
                  d_valid <= '1';
                  d_pc    <= q_pc(0);
                  d_ir    <= id_ir;
                  d_a     <= id_a;
                  d_b     <= id_b;
                  d_rs    <= id_rs;
                  d_rt    <= id_rt;
                  d_tgt   <= id_tgt;
                  d_link  <= id_link;
               else
                  d_valid <= '0';
               end if;
            else
               -- EX is held up, so capture the operands forwarding just
               -- produced.  Forwarding is recomputed every cycle from whatever
               -- is in MEM and WB, but only the value present on the cycle EX
               -- finally advances is the one that gets latched -- and by then
               -- the instruction that produced it may have retired and moved
               -- out of both stages.  The register file is no help either: ID
               -- read it cycles ago and EX never reads it.  Writing the
               -- forwarded value back into the ID/EX latch each stalled cycle
               -- is what makes a forwarded operand survive a stall of any
               -- length.
               --
               -- Only older instructions can ever be in MEM or WB, so a
               -- capture can only ever move an operand forward in time.
               d_a <= a;
               d_b <= b;
            end if;

            -- ============================================================
            -- IF: the request in flight, the queue, and the next request
            -- ============================================================
            vq_pc := q_pc;
            vq_ir := q_ir;
            vcnt  := q_cnt;
            vouts := outst;
            vdrop := drop;
            push  := false;

            if outst = '1' and i_ready = '1' then
               vouts := '0';
               if drop = '1' then
                  vdrop := '0';            -- wrong-path reply, discarded
               else
                  push := true;
               end if;
            end if;

            if id_adv then
               vq_pc(0) := vq_pc(1);
               vq_ir(0) := vq_ir(1);
               vcnt     := vcnt - 1;
            end if;
            if push then
               vq_pc(vcnt) := req_pc;
               vq_ir(vcnt) := i_data;
               vcnt        := vcnt + 1;
            end if;
            if do_flush then
               vcnt     := 0;
               vdrop    := vouts;          -- whatever is in flight is wrong-path
               fetch_pc <= new_pc;
            end if;

            -- One request outstanding at a time; the queue is what gives the
            -- throughput.  i_read is a single-cycle pulse, so the port is free
            -- to answer at whatever rate it likes.
            if vouts = '0' and vcnt < 2 then
               i_read <= '1';
               if do_flush then
                  i_addr   <= std_logic_vector(new_pc(31 downto 0));
                  req_pc   <= new_pc;
                  fetch_pc <= new_pc + 4;
               else
                  i_addr   <= std_logic_vector(fetch_pc(31 downto 0));
                  req_pc   <= fetch_pc;
                  fetch_pc <= fetch_pc + 4;
               end if;
               vouts := '1';
            end if;

            q_pc  <= vq_pc;
            q_ir  <= vq_ir;
            q_cnt <= vcnt;
            outst <= vouts;
            drop  <= vdrop;
         end if;
      end if;
   end process;

end architecture;
