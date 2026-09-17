-- gs_stq.vhd -- the perspective divide: S, T and Q in, a 12.4 texture
-- coordinate out.
--
-- `PRIM.FST` chooses between the two texture coordinates. UV is what 2D work
-- uses and the rasteriser already interpolates it. STQ is what 3D work uses:
-- S and T are interpolated linearly **in screen space along with Q**, and the
-- coordinate is recovered per pixel by dividing. That division is the whole
-- reason perspective-correct texturing is expensive, and it is why the GS has a
-- divider in the pixel path at all.
--
--     u = (S / Q) * 2**TW        v = (T / Q) * 2**TH
--
-- This block is exactly `stq_to_uv` in `sim/gs/gs_ref.py`, which is exactly
-- `sim/ee/ps2_float.py` underneath. It is diffed against that model rather than
-- against a description of it.
--
-- ## The arithmetic is the PlayStation 2's float, not IEEE
--
-- No denormals, no infinities, no NaN, and round toward zero. The operand
-- conditioner comes from `ee_fpu_pkg` rather than being written again here:
-- the GS's float unit is different silicon from the EE's COP1, but it is the
-- same number system, and two blocks that must agree bit for bit should share
-- one definition of what a number is. That package is where "denormals read as
-- a signed zero" and "a full exponent field reads as the largest finite value"
-- are already written down and already tested.
--
-- **Q = 0 does not produce an infinity, because the format has no encoding for
-- one.** It saturates to the largest finite value, with the sign of the two
-- operands exclusive-ored. A divider that raised or produced an infinity there
-- would disagree with hardware about every pixel of a degenerate polygon --
-- which games do emit, at the horizon and at the exact moment a vertex crosses
-- the eye plane, so it is not a corner case that can be left for later.
--
-- ## One floor, not two roundings
--
-- The model computes the exact rational and truncates once. Doing that in
-- hardware without carrying a rational is the one trick in this file.
--
-- With A and B the 24-bit mantissas including their implicit ones, the ratio
-- A/B lies in (0.5, 2). The result's mantissa is
--
--     m = floor(N * 2**23 / B),  N = A - B   when A >= B   (exponent ea-eb)
--                                N = 2A - B  when A <  B   (exponent ea-eb-1)
--
-- and N < B in both cases, so m < 2**23 and there is nothing to normalise
-- afterwards. That is a **single** floor of an exact rational, which is what
-- `pack` does; computing a quotient and then rounding it to 23 bits would round
-- twice and differ in the last bit on about one input pair in two hundred.
--
-- ## Multiplying by 2**TW costs an exponent, not a multiplier
--
-- TW and TH are already logarithms -- the manual stores them that way -- so the
-- second operand of each multiply is an exact power of two and the mantissa
-- cannot change. It is an add on the exponent, and the only work is the
-- overflow and underflow the model's `pack` would do: saturate above, flush to
-- zero below.
--
-- ## The last step, and the part that is not verified
--
-- `value(u_f) * 16` truncated toward zero is a float-to-fixed conversion with
-- four fractional bits, and then the coordinate is **saturated** into the 14
-- integer bits plus 4 fractional that the UV path carries.
--
-- Saturating there is the conservative choice and matches what the format does
-- one step earlier. **It is not verified against silicon**, and the model says
-- so in the same words: a Q near zero makes S/Q enormous, the divide saturates
-- at the format's largest value rather than producing an infinity, and
-- multiplying that by sixteen gives a number no register holds. Wrapping is the
-- other possibility and would put a degenerate polygon's texels somewhere quite
-- different. Only a console can settle it; what matters here is that the RTL
-- and the model make the same choice and that the choice is written down.
--
-- ## Latency
--
-- Two dividers in parallel rather than one used twice, because this sits in the
-- pixel path: sharing one would double a latency that is already the longest
-- thing in a textured pixel. Each is a restoring divider, one quotient bit per
-- clock, 23 bits -- so a coordinate costs about 26 clocks and both axes cost
-- the same 26 rather than 52.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library work;
use work.ee_fpu_pkg.all;

entity gs_fdiv is
   port
   (
      clk    : in  std_logic;
      reset  : in  std_logic;
      start  : in  std_logic;                        -- a pulse
      a      : in  std_logic_vector(31 downto 0);    -- dividend
      b      : in  std_logic_vector(31 downto 0);    -- divisor
      q      : out std_logic_vector(31 downto 0) := (others => '0');
      done   : out std_logic := '0';
      busy   : out std_logic := '0'
   );
end entity;

architecture rtl of gs_fdiv is
   signal ca, cb   : std_logic_vector(31 downto 0) := (others => '0');

   signal ex       : signed(10 downto 0) := (others => '0');   -- unbiased result exponent + 127
   -- The running remainder of floor(N * 2**23 / B). It stays below B, and B is
   -- at most 0xFFFFFF, so doubling it needs 25 bits and no more -- this is a
   -- plain restoring division and not a wide shift of N through a 48-bit
   -- register, which is what the first version tried and which mis-aligned the
   -- comparison so badly that every quotient came out with a zero mantissa.
   signal rem_s    : unsigned(24 downto 0) := (others => '0');
   signal den      : unsigned(23 downto 0) := (others => '0');
   signal man      : unsigned(22 downto 0) := (others => '0');
   signal cnt      : integer range 0 to 23 := 0;
   type t_state is (IDLE, SETUP, DIV, FINISH);
   signal state    : t_state := IDLE;
begin

   busy <= '0' when state = IDLE else '1';

   process (clk)
      -- Named away from the ports `a` and `b`: VHDL is case-insensitive, so a
      -- variable called A shadows the port for the whole process and the
      -- conditioner above silently reads the wrong thing.
      variable ma_v, mb_v : unsigned(23 downto 0);
      variable n_v    : unsigned(24 downto 0);
      variable e      : signed(10 downto 0);
      variable rem_v  : unsigned(24 downto 0);
      variable sgn    : std_logic;
   begin
      if rising_edge(clk) then
         done <= '0';
         if reset = '1' then
            state <= IDLE;
         else
            case state is

               when IDLE =>
                  if start = '1' then
                     ca    <= cond(a);
                     cb    <= cond(b);
                     state <= SETUP;
                  end if;

               when SETUP =>
                  sgn := ca(31) xor cb(31);
                  if fexp(cb) = 0 then
                     -- **A zero divisor is not an error here.** The format has
                     -- no infinity, so the answer is the largest finite value
                     -- with the exclusive-or of the signs -- including for zero
                     -- divided by zero, which on this machine is a flag and not
                     -- a trap.
                     q     <= sgn & POS_MAX(30 downto 0);
                     done  <= '1';
                     state <= IDLE;
                  elsif fexp(ca) = 0 then
                     -- **A zero dividend gives +0, not a signed zero.** The
                     -- model reaches this through `pack`, whose sign-of-zero
                     -- argument `div` never passes -- so an exact zero result
                     -- is positive whatever the operands were. A signed zero
                     -- here is the obvious thing to write and disagrees on
                     -- every negative dividend. Underflow below is the opposite
                     -- case and does keep the sign, because there the exact
                     -- value is not zero, only too small to represent.
                     q     <= (31 downto 0 => '0');
                     done  <= '1';
                     state <= IDLE;
                  else
                     ma_v := '1' & fman(ca);
                     mb_v := '1' & fman(cb);
                     e := signed(resize(fexp(ca), 11)) - signed(resize(fexp(cb), 11))
                          + to_signed(127, 11);
                     if ma_v >= mb_v then
                        n_v := resize(ma_v - mb_v, 25);
                     else
                        n_v := resize(ma_v, 25) + resize(ma_v, 25) - resize(mb_v, 25);
                        e := e - 1;
                     end if;
                     -- N < B, so the 23 quotient bits below need no normalising
                     -- shift afterwards and the floor happens exactly once.
                     rem_s <= resize(n_v, 25);
                     den   <= mb_v;
                     ex  <= e;
                     man <= (others => '0');
                     cnt <= 0;
                     state <= DIV;
                  end if;

               when DIV =>
                  -- Restoring division, most significant quotient bit first:
                  -- double the remainder, subtract the divisor if it fits, and
                  -- the bit that says whether it did is the quotient bit.
                  rem_v := shift_left(rem_s, 1);
                  if rem_v >= resize(den, 25) then
                     rem_v := rem_v - resize(den, 25);
                     man <= man(21 downto 0) & '1';
                  else
                     man <= man(21 downto 0) & '0';
                  end if;
                  rem_s <= rem_v;
                  if cnt = 22 then
                     state <= FINISH;
                  else
                     cnt <= cnt + 1;
                  end if;

               when FINISH =>
                  if ex >= 255 then
                     q <= sgn & POS_MAX(30 downto 0);       -- saturate, no infinity
                  elsif ex <= 0 then
                     q <= sgn & (30 downto 0 => '0');       -- no denormals: zero
                  else
                     q <= sgn & std_logic_vector(resize(unsigned(std_logic_vector(ex)), 8))
                          & std_logic_vector(man);
                  end if;
                  done  <= '1';
                  state <= IDLE;

            end case;
         end if;
      end if;
   end process;

end architecture;


-- ---------------------------------------------------------------------------
-- gs_stq -- the whole of stq_to_uv: two divides, two exponent adds, and the
-- conversion into the 12.4 coordinate the rest of the texture unit speaks.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library work;
use work.ee_fpu_pkg.all;

entity gs_stq is
   port
   (
      clk     : in  std_logic;
      reset   : in  std_logic;

      req     : in  std_logic;                       -- a pulse
      s       : in  std_logic_vector(31 downto 0);   -- interpolated S
      t       : in  std_logic_vector(31 downto 0);   -- interpolated T
      qf      : in  std_logic_vector(31 downto 0);   -- interpolated Q
      tw      : in  unsigned(3 downto 0);            -- TEX0.TW, already a log2
      th      : in  unsigned(3 downto 0);

      -- 12.4, and nineteen bits because that is what the model produces: the
      -- saturation limit is 14 integer bits plus 4 fractional, and the negative
      -- side reaches one past it.
      u_out   : out signed(18 downto 0) := (others => '0');
      v_out   : out signed(18 downto 0) := (others => '0');
      done    : out std_logic := '0';
      busy    : out std_logic := '0'
   );
end entity;

architecture rtl of gs_stq is
   signal ds, dt   : std_logic_vector(31 downto 0);
   signal dds, ddt : std_logic;
   signal bs, bt   : std_logic;
   signal go       : std_logic := '0';
   signal r_tw, r_th : unsigned(3 downto 0) := (others => '0');
   type t_state is (IDLE, WAIT_D, EMIT);
   signal state : t_state := IDLE;

   -- Multiplying by 2**k is an exponent add and nothing else, because TW and TH
   -- are already logarithms and the mantissa cannot change. What is left is the
   -- part `pack` would still do: saturate above the format, flush to zero below
   -- it. Underflow keeps the sign -- the exact value is not zero there, only too
   -- small to represent -- while an operand that was already zero gives +0.
   function scale2(x : std_logic_vector(31 downto 0);
                   k : unsigned(3 downto 0)) return std_logic_vector is
      variable e : signed(10 downto 0);
   begin
      if fexp(x) = 0 then
         return (31 downto 0 => '0');
      end if;
      e := signed(resize(fexp(x), 11)) + signed(resize(k, 11));
      if e >= 255 then
         return x(31) & POS_MAX(30 downto 0);
      elsif e <= 0 then
         return x(31) & (30 downto 0 => '0');
      end if;
      return x(31) & std_logic_vector(resize(unsigned(std_logic_vector(e)), 8))
             & std_logic_vector(fman(x));
   end function;

   -- value(x) * 16, truncated toward zero, saturated into the coordinate.
   --
   -- value*16 is 1.m * 2**(e-123), so with M the 24-bit mantissa including its
   -- implicit one the magnitude is floor(M * 2**(sh-23)) for sh = e-123. Two
   -- ends fall out of that and neither needs a wide shifter:
   --
   --   sh <  0   the magnitude is below one, so the answer is zero;
   --   sh >= 18  the magnitude is at least 2**18, past the limit, so it
   --             saturates whatever the mantissa is.
   --
   -- Between them the shift is a right shift by 6 to 23 and the result is
   -- always inside the limit, so the clamp the model applies is unreachable
   -- there rather than merely unused.
   function to_124(x : std_logic_vector(31 downto 0)) return signed is
      constant LIM : integer := (2**18) - 1;
      variable sh  : integer;
      variable m   : unsigned(23 downto 0);
      variable mag : unsigned(18 downto 0);
   begin
      if fexp(x) = 0 then
         return to_signed(0, 19);
      end if;
      sh := to_integer(fexp(x)) - 123;
      if sh < 0 then
         return to_signed(0, 19);
      elsif sh >= 18 then
         if x(31) = '1' then
            return to_signed(-LIM - 1, 19);
         else
            return to_signed(LIM, 19);
         end if;
      end if;
      m   := '1' & fman(x);
      mag := resize(shift_right(m, 23 - sh), 19);
      if x(31) = '1' then
         return -signed(resize(mag, 19));
      else
         return signed(resize(mag, 19));
      end if;
   end function;
begin

   busy <= '0' when state = IDLE else '1';

   -- Two dividers rather than one used twice: this is in the pixel path and
   -- sharing would double a latency that is already the longest thing in a
   -- textured pixel. They are also genuinely two divisions and not one
   -- reciprocal and two multiplies -- 1/Q then S*(1/Q) rounds twice, and the
   -- model divides exactly and truncates once.
   du : entity work.gs_fdiv
      port map (clk => clk, reset => reset, start => go,
                a => s, b => qf, q => ds, done => dds, busy => bs);

   dv : entity work.gs_fdiv
      port map (clk => clk, reset => reset, start => go,
                a => t, b => qf, q => dt, done => ddt, busy => bt);

   process (clk)
   begin
      if rising_edge(clk) then
         done <= '0';
         go   <= '0';
         if reset = '1' then
            state <= IDLE;
         else
            case state is
               when IDLE =>
                  if req = '1' then
                     r_tw  <= tw;
                     r_th  <= th;
                     go    <= '1';
                     state <= WAIT_D;
                  end if;

               when WAIT_D =>
                  -- Both dividers are started together and take the same number
                  -- of clocks, but waiting for both is what makes that a fact
                  -- about this block rather than an assumption about that one.
                  if bs = '0' and bt = '0' and go = '0' then
                     state <= EMIT;
                  end if;

               when EMIT =>
                  u_out <= to_124(scale2(ds, r_tw));
                  v_out <= to_124(scale2(dt, r_th));
                  done  <= '1';
                  state <= IDLE;
            end case;
         end if;
      end if;
   end process;

end architecture;
