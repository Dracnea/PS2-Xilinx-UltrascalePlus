-- A thin wrapper so a SystemVerilog testbench can reach the package's
-- functions, which it cannot call directly.
library ieee;
use ieee.std_logic_1164.all;
use work.ee_fpu_pkg.all;

entity fpu_wrap is
   port (
      a, b : in  std_logic_vector(31 downto 0);
      ca, cb : out std_logic_vector(31 downto 0);
      eq, lt, le : out std_logic;
      mx, mn : out std_logic_vector(31 downto 0);
      ab, ng : out std_logic_vector(31 downto 0);
      mul : out std_logic_vector(31 downto 0);
      mul_o, mul_u : out std_logic
   );
end entity;

architecture rtl of fpu_wrap is
   signal r : fres_t;
begin
   r <= f_mul(a, b);
   mul   <= r.v;
   mul_o <= r.o;
   mul_u <= r.u;
   ca <= cond(a);
   cb <= cond(b);
   eq <= '1' when f_eq(a, b) else '0';
   lt <= '1' when f_lt(a, b) else '0';
   le <= '1' when f_le(a, b) else '0';
   mx <= f_max(a, b);
   mn <= f_min(a, b);
   ab <= f_abs(a);
   ng <= fneg(a);
end architecture;
