-- gs_chan_dda.vhd -- one Gouraud colour channel, interpolated the way the GS
-- interpolates rather than the way a plane equation says it should be.
--
-- The GS does not evaluate its plane per pixel and does not evaluate it
-- exactly.  Both facts were measured on real silicon, not read out of a manual
-- -- Sony's GS User's Manual specifies the fill rule to the letter and says
-- nothing whatever about interpolation precision -- and they are the difference
-- between agreeing with hardware and being systematically wrong on almost every
-- gradient:
--
--   * one DDA step spans EIGHT pixels.  A span is seeded at its first pixel,
--     each of the eight lanes in a block carries a fixed offset, and one step
--     is added per block;
--   * the lane offsets and the block step both land on a 2**-10 grid.
--
-- The convenient part is that this is *cheaper* to build than the exact thing.
-- Everything below is an integer count of 2**-10, so the whole interpolator is
-- one division per channel for the gradient, one per channel per scanline for
-- the seed, and an add per block -- no per-pixel division at all.
--
-- Working in window space with X, Y in 12.4 and the three vertices carrying
-- c0, c1, c2, the plane through them has
--
--     det = dx10*dy20 - dx20*dy10                  (12.4 units, squared)
--     nx  = (c1-c0)*dy20 - (c2-c0)*dy10
--     ny  = (c2-c0)*dx10 - (c1-c0)*dx20
--
-- and then, with everything scaled to the 2**-10 grid,
--
--     gradient  = floor(16 * 1024 * nx / det)                    per pixel
--     seed(x,y) = floor(1024 * (c0*det + nx*(16x - X0) + ny*(16y - Y0)) / det)
--
-- The sixteens are the 12.4 fraction cancelling: det carries it twice and nx
-- once, so the pixel-space gradient is sixteen times the raw ratio.  Deriving
-- them rather than fitting them is the only reason the model and this agree at
-- the first attempt.
--
-- The eight lane offsets are *not* eight divisions.  With
-- 16384*nx = q*det + r and 0 <= r < det,
--
--     floor(j * 16384 * nx / det) = j*q + floor(j*r / det)
--
-- and since r < det the correction is at most j-1, so it falls out of eight
-- accumulate-and-subtract cycles alongside the one division that is needed.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity gs_chan_dda is
   port
   (
      clk    : in  std_logic;
      reset  : in  std_logic;

      -- Per triangle.  The caller passes det already made positive, with sgn
      -- set when it had to negate it, so the divider below only ever sees a
      -- positive denominator and one floor fixup covers every case.
      start  : in  std_logic;
      det    : in  signed(47 downto 0);
      sgn    : in  std_logic;
      dx10, dx20, dy10, dy20 : in signed(19 downto 0);
      x0, y0 : in  signed(17 downto 0);
      c0, c1, c2 : in unsigned(7 downto 0);
      busy   : out std_logic := '0';

      -- Per scanline: seed the walk at the span's first pixel.
      sstart : in  std_logic;
      sx, sy : in  signed(12 downto 0);
      sbusy  : out std_logic := '0';

      -- Per pixel.
      adv    : in  std_logic;
      val    : out unsigned(7 downto 0)
   );
end entity;

architecture arch of gs_chan_dda is
   type state_t is (S_IDLE, S_GLOAD, S_GDIV, S_GFIX, S_LANE,
                    S_READY, S_SLOAD, S_SDIV, S_SFIX);
   signal state : state_t := S_IDLE;

   constant W : natural := 64;         -- the divider's width

   -- The gradient can be enormous for a triangle whose det is tiny: a sliver
   -- covers no pixels, but it still runs through this arithmetic, so nothing
   -- here is sized to the sensible case only.  The clamp at the output is what
   -- makes the answer sane; the datapath just has to not wrap on the way.
   type lane_a is array (0 to 7) of signed(W - 1 downto 0);
   signal lane  : lane_a := (others => (others => '0'));
   signal step  : signed(W - 1 downto 0) := (others => '0');
   signal acc   : signed(W - 1 downto 0) := (others => '0');
   signal lane_i : integer range 0 to 7 := 0;

   signal nx, ny : signed(W - 1 downto 0) := (others => '0');
   signal dq, dr : signed(W - 1 downto 0) := (others => '0');
   signal jrem   : signed(W - 1 downto 0) := (others => '0');
   signal jcnt   : integer range 0 to 8 := 0;
   signal jq     : signed(W - 1 downto 0) := (others => '0');
   signal jcorr  : signed(W - 1 downto 0) := (others => '0');
   signal detp   : signed(W - 1 downto 0) := (others => '0');

   -- the restoring divider, shared between the gradient and every seed
   signal dv_n, dv_d, dv_q, dv_r : unsigned(W - 1 downto 0) := (others => '0');
   signal dv_cnt : integer range 0 to W + 1 := 0;
   signal dv_neg : std_logic := '0';
begin
   -- The value at the current pixel: the block accumulator plus this lane's
   -- offset, brought off the 2**-10 grid by an arithmetic shift -- floor, which
   -- is what the model does -- and clamped into a byte.
   process (acc, lane, lane_i)
      variable t : signed(W - 1 downto 0);
   begin
      t := shift_right(acc + lane(lane_i), 10);
      if t < 0 then
         val <= (others => '0');
      elsif t > 255 then
         val <= (others => '1');
      else
         val <= unsigned(t(7 downto 0));
      end if;
   end process;

   process (clk)
      variable sh   : unsigned(W - 1 downto 0);
      variable num  : signed(W - 1 downto 0);
      variable qq, rr : signed(W - 1 downto 0);
      variable nrem, ncor, nq : signed(W - 1 downto 0);

      -- Setup is reachable from two places: an idle unit, and one that has
      -- finished a triangle and is sitting in S_READY holding the last one's
      -- gradients.  Writing it once as a procedure is what stops the second
      -- entry from being forgotten -- which in the edge DDA it was, and every
      -- edge after the first quietly reused the previous triangle's quotient.
      procedure setup is
         variable vnx, vny : signed(W - 1 downto 0);
      begin
         busy <= '1';
         -- Both numerators, at their natural widths.  A VHDL product is as
         -- wide as its operands together, so these are formed first and
         -- resized once; resizing the operands instead is how the edge DDA
         -- failed to elaborate.
         vnx := resize((signed('0' & c1) - signed('0' & c0)) * dy20, W)
              - resize((signed('0' & c2) - signed('0' & c0)) * dy10, W);
         vny := resize((signed('0' & c2) - signed('0' & c0)) * dx10, W)
              - resize((signed('0' & c1) - signed('0' & c0)) * dx20, W);
         if sgn = '1' then
            vnx := -vnx;
            vny := -vny;
         end if;
         nx    <= vnx;
         ny    <= vny;
         detp  <= resize(det, W);
         state <= S_GLOAD;
      end procedure;
   begin
      if rising_edge(clk) then
         if reset = '1' then
            state <= S_IDLE;
            busy  <= '0';
            sbusy <= '0';
         else
            case state is

               when S_IDLE =>
                  if start = '1' then
                     setup;
                  end if;

               when S_GLOAD =>
                  -- gradient = floor(16384 * nx / det)
                  num := shift_left(nx, 14);
                  dv_neg <= '1' when num < 0 else '0';
                  if num < 0 then dv_n <= unsigned(-num); else dv_n <= unsigned(num); end if;
                  dv_d   <= unsigned(detp);
                  dv_q   <= (others => '0');
                  dv_r   <= (others => '0');
                  dv_cnt <= W;
                  state  <= S_GDIV;

               when S_GDIV =>
                  sh := dv_r(W - 2 downto 0) & dv_n(W - 1);
                  if sh >= dv_d then
                     dv_r <= sh - dv_d;
                     dv_q <= dv_q(W - 2 downto 0) & '1';
                  else
                     dv_r <= sh;
                     dv_q <= dv_q(W - 2 downto 0) & '0';
                  end if;
                  dv_n   <= dv_n(W - 2 downto 0) & '0';
                  dv_cnt <= dv_cnt - 1;
                  if dv_cnt = 1 then
                     state <= S_GFIX;
                  end if;

               when S_GFIX =>
                  -- Truncation into floor.  A negative numerator that left a
                  -- remainder rounds the other way, and the remainder has to
                  -- come back into [0, det) or the lane correction below --
                  -- which assumes exactly that -- is wrong.
                  if dv_neg = '1' and dv_r /= 0 then
                     qq := -signed(dv_q) - 1;
                     rr := detp - signed(dv_r);
                  elsif dv_neg = '1' then
                     qq := -signed(dv_q);
                     rr := (others => '0');
                  else
                     qq := signed(dv_q);
                     rr := signed(dv_r);
                  end if;
                  dq    <= qq;
                  dr    <= rr;
                  jq    <= (others => '0');
                  jrem  <= (others => '0');
                  jcorr <= (others => '0');
                  jcnt  <= 0;
                  lane(0) <= (others => '0');
                  state <= S_LANE;

               when S_LANE =>
                  -- One lane per cycle: j*q accumulated, plus however many
                  -- times det has fitted into j*r so far.
                  nq   := jq + dq;
                  nrem := jrem + dr;
                  ncor := jcorr;
                  if nrem >= detp then
                     nrem := nrem - detp;
                     ncor := ncor + 1;
                  end if;
                  jq    <= nq;
                  jrem  <= nrem;
                  jcorr <= ncor;
                  if jcnt = 7 then
                     step  <= nq + ncor;         -- j = 8: one whole block
                     busy  <= '0';
                     state <= S_READY;
                  else
                     lane(jcnt + 1) <= nq + ncor;
                     jcnt <= jcnt + 1;
                  end if;

               when S_READY =>
                  if start = '1' then
                     setup;
                  elsif sstart = '1' then
                     sbusy <= '1';
                     state <= S_SLOAD;
                  elsif adv = '1' then
                     if lane_i = 7 then
                        lane_i <= 0;
                        acc    <= acc + step;
                     else
                        lane_i <= lane_i + 1;
                     end if;
                  end if;

               when S_SLOAD =>
                  -- seed = floor(1024 * (c0*det + nx*(16x - X0) + ny*(16y - Y0)) / det)
                  num := shift_left(
                            resize(signed('0' & c0) * detp, W)
                          + resize(nx * (shift_left(resize(sx, 20), 4) - resize(x0, 20)), W)
                          + resize(ny * (shift_left(resize(sy, 20), 4) - resize(y0, 20)), W),
                          10);
                  dv_neg <= '1' when num < 0 else '0';
                  if num < 0 then dv_n <= unsigned(-num); else dv_n <= unsigned(num); end if;
                  dv_d   <= unsigned(detp);
                  dv_q   <= (others => '0');
                  dv_r   <= (others => '0');
                  dv_cnt <= W;
                  state  <= S_SDIV;

               when S_SDIV =>
                  sh := dv_r(W - 2 downto 0) & dv_n(W - 1);
                  if sh >= dv_d then
                     dv_r <= sh - dv_d;
                     dv_q <= dv_q(W - 2 downto 0) & '1';
                  else
                     dv_r <= sh;
                     dv_q <= dv_q(W - 2 downto 0) & '0';
                  end if;
                  dv_n   <= dv_n(W - 2 downto 0) & '0';
                  dv_cnt <= dv_cnt - 1;
                  if dv_cnt = 1 then
                     state <= S_SFIX;
                  end if;

               when S_SFIX =>
                  if dv_neg = '1' and dv_r /= 0 then
                     acc <= -signed(dv_q) - 1;
                  elsif dv_neg = '1' then
                     acc <= -signed(dv_q);
                  else
                     acc <= signed(dv_q);
                  end if;
                  lane_i <= 0;
                  sbusy  <= '0';
                  state  <= S_READY;

            end case;
         end if;
      end if;
   end process;
end architecture;
