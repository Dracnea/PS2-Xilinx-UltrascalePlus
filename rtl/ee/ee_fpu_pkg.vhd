-- ee_fpu_pkg.vhd -- the PlayStation 2's floating-point number system, in logic.
--
-- The half of COP1 that can be finished and known to be right.
--
-- docs/ee-fpu.md sets the order and it is worth restating, because the obvious
-- order is the wrong one: **do not start with ADD.S**. The last bit of MUL, DIV
-- and SQRT on real silicon is not settled by any document -- the multiplier is
-- described, by the only people who have measured it, as not quite exact -- so
-- those instructions cannot be finished, only implemented to the specification
-- and left pending a console sweep. The conditioner, the saturator, the flags
-- and the compares can be finished today, and they are what every arithmetic
-- instruction is built on.
--
-- ## The number system
--
-- Single precision with three deliberate omissions: **no denormals, no
-- infinities, and therefore no NaN**. Every value the unit can hold is an
-- ordinary finite number, and the range is closed by saturation at both ends
-- rather than by special encodings.
--
-- That makes the conditioner the whole of the special-case handling. Every
-- operand of every arithmetic instruction passes through it, and afterwards no
-- part of the unit ever has to consider a special value again:
--
--   * **exponent 0** -- a denormal, or zero -- reads as a signed zero, mantissa
--     discarded. The sign survives, which is why negative zero stays
--     distinguishable in a format with no other use for the bit.
--   * **exponent 255** -- what an IEEE machine would call an infinity or a NaN
--     -- reads as the **largest finite value of the same sign**. A pattern that
--     arrives from memory or from an integer move can have that exponent; the
--     unit itself never produces one.
--   * everything else is itself.
--
-- ## Rounding
--
-- Toward zero, always. It is not a mode and there is no register to change it.
-- A result is truncated, never rounded up and never rounded to even, and that
-- is the single most common way a model of this unit goes wrong -- a host
-- float rounds to nearest, and the two differ in the last bit of a large
-- fraction of all results.
--
-- SPDX-License-Identifier: GPL-2.0-only

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package ee_fpu_pkg is

   subtype f32_t is std_logic_vector(31 downto 0);

   -- The largest finite value, and what saturation produces.
   constant POS_MAX : f32_t := x"7F7FFFFF";
   constant NEG_MAX : f32_t := x"FF7FFFFF";

   -- The flags, at their positions in FCR31.
   constant FLAG_C   : integer := 23;    -- the condition bit, set by the compares
   constant CAUSE_I  : integer := 17;    -- invalid: zero divided by zero
   constant CAUSE_D  : integer := 16;    -- divide by zero
   constant CAUSE_O  : integer := 15;    -- overflow
   constant CAUSE_U  : integer := 14;    -- underflow
   constant STICKY_I : integer := 6;
   constant STICKY_D : integer := 5;
   constant STICKY_O : integer := 4;
   constant STICKY_U : integer := 3;

   function fsign(x : f32_t) return std_logic;
   function fexp (x : f32_t) return unsigned;
   function fman (x : f32_t) return unsigned;

   function cond(x : f32_t) return f32_t;
   function is_zero(x : f32_t) return boolean;

   function f_abs(x : f32_t) return f32_t;
   function fneg (x : f32_t) return f32_t;

   -- The compares. MIPS names sixteen conditions; the PS2 implements the four
   -- that mean anything without NaN, and the other twelve collapse onto them
   -- because "unordered" cannot happen here.
   function f_eq(a, b : f32_t) return boolean;
   function f_lt(a, b : f32_t) return boolean;
   function f_le(a, b : f32_t) return boolean;

   function f_max(a, b : f32_t) return f32_t;
   function f_min(a, b : f32_t) return f32_t;

end package;

package body ee_fpu_pkg is

   function fsign(x : f32_t) return std_logic is
   begin
      return x(31);
   end function;

   function fexp(x : f32_t) return unsigned is
   begin
      return unsigned(x(30 downto 23));
   end function;

   function fman(x : f32_t) return unsigned is
   begin
      return unsigned(x(22 downto 0));
   end function;

   function cond(x : f32_t) return f32_t is
   begin
      if fexp(x) = 0 then
         -- Denormal or zero: a signed zero, mantissa discarded. Keeping the
         -- sign is not a nicety -- MAX and MIN compare as integers and would
         -- order +0 and -0 differently if it were dropped.
         return x(31) & (30 downto 0 => '0');
      elsif fexp(x) = 255 then
         -- What IEEE would call infinity or NaN. The unit cannot produce one;
         -- it can be handed one, from memory or from MTC1.
         return x(31) & POS_MAX(30 downto 0);
      else
         return x;
      end if;
   end function;

   function is_zero(x : f32_t) return boolean is
   begin
      return fexp(x) = 0;
   end function;

   -- ABS and NEG touch the sign bit and nothing else. In particular they do
   -- NOT condition their operand: a denormal negated is still that denormal
   -- with the other sign, and only an arithmetic instruction flushes it.
   function f_abs(x : f32_t) return f32_t is
   begin
      return '0' & x(30 downto 0);
   end function;

   function fneg(x : f32_t) return f32_t is
   begin
      return (not x(31)) & x(30 downto 0);
   end function;

   -- The comparisons are done on the conditioned values, as integers.
   --
   -- That works here for a reason that does not hold on an IEEE machine: with
   -- no NaN there is nothing unordered, and the float format is monotonic in
   -- its bit pattern within each sign. So a signed-magnitude comparison is an
   -- ordinary one, and the only special case is that +0 and -0 have different
   -- patterns and must compare equal.
   function f_eq(a, b : f32_t) return boolean is
      variable ca, cb : f32_t;
   begin
      ca := cond(a);
      cb := cond(b);
      if is_zero(ca) and is_zero(cb) then
         return true;                     -- +0 = -0
      end if;
      return ca = cb;
   end function;

   function f_lt(a, b : f32_t) return boolean is
      variable ca, cb : f32_t;
      variable ma, mb : unsigned(30 downto 0);
   begin
      ca := cond(a);
      cb := cond(b);
      if is_zero(ca) and is_zero(cb) then
         return false;
      end if;
      ma := unsigned(ca(30 downto 0));
      mb := unsigned(cb(30 downto 0));
      if fsign(ca) /= fsign(cb) then
         return fsign(ca) = '1';          -- negative is less than positive
      elsif fsign(ca) = '1' then
         return ma > mb;                  -- both negative: larger magnitude is less
      else
         return ma < mb;
      end if;
   end function;

   function f_le(a, b : f32_t) return boolean is
   begin
      return f_lt(a, b) or f_eq(a, b);
   end function;

   function f_max(a, b : f32_t) return f32_t is
   begin
      if f_lt(a, b) then return cond(b); else return cond(a); end if;
   end function;

   function f_min(a, b : f32_t) return f32_t is
   begin
      if f_lt(b, a) then return cond(b); else return cond(a); end if;
   end function;

end package body;
