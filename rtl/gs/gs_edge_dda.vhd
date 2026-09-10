-- gs_edge_dda.vhd -- one triangle edge, stepped a scanline at a time.
--
-- A triangle's span on scanline y is bounded by ceil(x) of two of its three
-- edges, and sim/gs/gs_ref.py computes that with exact rational arithmetic:
-- one division per scanline per edge, in unbounded precision.  Hardware divides
-- once per edge and steps.  Those are the same answer only if the stepping is
-- exact, so the formulation was checked against the reference before this file
-- existed -- sim/gs/test_dda.py, about 300,000 scanlines a seed -- and this
-- implements exactly that recurrence.
--
-- In pixel space with y an integer scanline, and all terms integers:
--
--     x(y) = [ x0*dy + dx*(16*y - y0) ] / (16*dy)
--
-- so with num stepping by 16*dx per scanline and den = 16*dy held constant, the
-- edge is ceil(num/den).  Splitting that into a quotient and a remainder at
-- setup turns each scanline into an add and at most one correction:
--
--     q += qstep;  r += rstep;  if r >= den then q += 1; r -= den
--     x = q + (1 if r > 0 else 0)          -- ceil, from floor plus remainder
--
-- The two divisions are *floor* divisions, and VHDL's integer division
-- truncates toward zero.  For a leftward edge -- dx negative -- those differ,
-- and the remainder has to stay in [0, den) or the single correction above is
-- not enough.  That is what the sign fixup in S_FIX exists for, and getting it
-- wrong produces an edge that is right in the middle and wrong at its ends,
-- which is exactly where a fill rule matters.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity gs_edge_dda is
   port
   (
      clk    : in  std_logic;
      reset  : in  std_logic;

      -- Set up one edge.  The caller orders it so y0 < y1; ytop is the first
      -- scanline the triangle covers, which is shared by all three edges so
      -- that they step together.
      start  : in  std_logic;
      x0, y0 : in  signed(15 downto 0);        -- 12.4 fixed point
      x1, y1 : in  signed(15 downto 0);
      ytop   : in  signed(11 downto 0);        -- whole pixels
      busy   : out std_logic := '0';

      -- One scanline down.
      step   : in  std_logic;

      -- ceil(x) at the current scanline, valid while busy is low
      x      : out signed(12 downto 0) := (others => '0')
   );
end entity;

architecture arch of gs_edge_dda is
   type state_t is (S_IDLE, S_DIV, S_FIX, S_RUN);
   signal state : state_t := S_IDLE;

   -- Wide enough for the worst case with room to spare.  A VHDL multiplication
   -- returns the sum of its operands' widths, so the products below are formed
   -- at their natural width and resized once, rather than resizing the operands
   -- first and assigning an 82-bit result to a 41-bit signal -- which is what
   -- the first version of this did, and it does not even elaborate.
   signal num, den   : signed(47 downto 0) := (others => '0');
   signal q, r       : signed(47 downto 0) := (others => '0');
   signal qstep      : signed(47 downto 0) := (others => '0');
   signal rstep      : signed(47 downto 0) := (others => '0');
   signal dstep      : signed(47 downto 0) := (others => '0');   -- 16*dx

   -- a restoring divider, shared by the two divisions this needs
   signal dv_n, dv_d : unsigned(47 downto 0) := (others => '0');
   signal dv_q, dv_r : unsigned(47 downto 0) := (others => '0');
   signal dv_cnt     : integer range 0 to 49 := 0;
   signal dv_neg     : std_logic := '0';
   signal which      : integer range 0 to 1 := 0;   -- 0: the initial num, 1: the step
begin
   process (clk)
      variable sh    : unsigned(47 downto 0);
      variable dyv, dxv : signed(17 downto 0);
      variable ytv      : signed(23 downto 0);

      procedure setup is
      begin
         busy  <= '1';
         -- den = 16*dy, positive because the caller ordered the edge
         dyv := resize(y1, 18) - resize(y0, 18);
         dxv := resize(x1, 18) - resize(x0, 18);
         ytv := shift_left(resize(ytop, 24), 4) - resize(y0, 24);
         den   <= shift_left(resize(dyv, 48), 4);
         dstep <= shift_left(resize(dxv, 48), 4);
         num   <= resize(x0 * dyv, 48) + resize(dxv * ytv, 48);
         which <= 0;
         state <= S_DIV;
         dv_cnt <= 0;
      end procedure;
      variable qq, rr: signed(47 downto 0);
   begin
      if rising_edge(clk) then
         if reset = '1' then
            state <= S_IDLE;
            busy  <= '0';
         else
            case state is

               when S_IDLE =>
                  if start = '1' then
                     setup;
                  end if;

               when S_DIV =>
                  if dv_cnt = 0 then
                     -- load the divider with |n| and d; the sign is put back in S_FIX
                     if which = 0 then
                        dv_neg <= '1' when num < 0 else '0';
                        if num < 0 then
                           dv_n <= unsigned(-num);
                        else
                           dv_n <= unsigned(num);
                        end if;
                     else
                        dv_neg <= '1' when dstep < 0 else '0';
                        if dstep < 0 then
                           dv_n <= unsigned(-dstep);
                        else
                           dv_n <= unsigned(dstep);
                        end if;
                     end if;
                     dv_d   <= unsigned(den);
                     dv_q   <= (others => '0');
                     dv_r   <= (others => '0');
                     dv_cnt <= 48;
                  elsif dv_cnt > 0 then
                     -- one quotient bit per clock, most significant first
                     sh := dv_r(46 downto 0) & dv_n(47);
                     if sh >= dv_d then
                        dv_r <= sh - dv_d;
                        dv_q <= dv_q(46 downto 0) & '1';
                     else
                        dv_r <= sh;
                        dv_q <= dv_q(46 downto 0) & '0';
                     end if;
                     dv_n   <= dv_n(46 downto 0) & '0';
                     dv_cnt <= dv_cnt - 1;
                     if dv_cnt = 1 then
                        state <= S_FIX;
                     end if;
                  end if;

               when S_FIX =>
                  -- Turn truncation into floor: a negative numerator whose
                  -- division left a remainder rounds the *other* way, and the
                  -- remainder has to come back into [0, den).
                  if dv_neg = '1' and dv_r /= 0 then
                     qq := -signed(dv_q) - 1;
                     rr := signed(dv_d) - signed(dv_r);
                  elsif dv_neg = '1' then
                     qq := -signed(dv_q);
                     rr := (others => '0');
                  else
                     qq := signed(dv_q);
                     rr := signed(dv_r);
                  end if;
                  if which = 0 then
                     q     <= qq;
                     r     <= rr;
                     which <= 1;
                     dv_cnt <= 0;
                     state <= S_DIV;
                  else
                     qstep <= qq;
                     rstep <= rr;
                     busy  <= '0';
                     state <= S_RUN;
                  end if;

               when S_RUN =>
                  -- start is a single-cycle pulse, so a new edge has to be taken
                  -- here rather than by returning to S_IDLE to wait for a pulse
                  -- that has already gone.  Doing that lost every edge after the
                  -- first and left the previous one's q and r in place, so the
                  -- output was a plausible constant rather than an obvious
                  -- failure -- which is the kind that survives a quick look.
                  if start = '1' then
                     setup;
                  elsif step = '1' then
                     if r + rstep >= den then
                        q <= q + qstep + 1;
                        r <= r + rstep - den;
                     else
                        q <= q + qstep;
                        r <= r + rstep;
                     end if;
                  end if;

            end case;
         end if;
      end if;
   end process;

   -- ceil(num/den) is the floor plus one whenever anything was left over
   x <= resize(q, 13) + 1 when r > 0 else resize(q, 13);

end architecture;
