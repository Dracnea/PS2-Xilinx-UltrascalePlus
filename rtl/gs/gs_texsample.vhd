-- gs_texsample.vhd -- a texel, fetched and combined with the fragment colour.
--
-- This is step 4 of docs/gs-texture.md, and it is the piece that makes the
-- other two useful: gs_texaddr says *where* a texel is and gs_clut holds the
-- palette, and this asks local memory for the bits, turns them into a colour,
-- and combines that colour with the fragment's. With it, a 2D textured
-- primitive can be drawn.
--
-- Nearest and bilinear. Bilinear waited on the read port, because four fetches
-- per pixel is a throughput decision and building the filter before that was
-- settled would have been building it twice; `gs_texcache` settled it, and with
-- the cache in front the three neighbours of a texel are overwhelmingly already
-- held, so the four fetches are four lookups rather than four memory reads.
--
-- ## The half texel, which decides whether the picture lines up
--
-- The GS samples bilinear at **(u - 0.5, v - 0.5)**, not at (u, v).
--
-- UV counts texel *edges*, so texel n occupies [n, n+1) and its centre is at
-- n + 0.5. Subtracting the half texel before the split into integer and
-- fractional parts is what makes u = n + 0.5 return texel n unmixed and u = n an
-- even blend of n-1 and n. Leave it out and every filtered texture is displaced
-- half a texel, which reads as a sampling offset in the rasteriser rather than
-- as a filter bug -- and the nearest path, which has no such shift, then
-- disagrees with the bilinear path by half a texel as well.
--
-- The nearest path keeps **no** shift and its truncation. The two are not the
-- same operation and making them so is the plausible wrong answer in both
-- directions at once.
--
-- ## Sixteenths, and an arithmetic shift
--
-- The weights are the four fractional bits of the 12.4 coordinate, so there are
-- sixteen positions between texels and no more. That is not an approximation of
-- something finer -- 12.4 *is* the coordinate format, and a filter that lerped
-- with more precision than sixteenths would be smoother than the console.
--
-- The lerp is `a + ((b - a) * f >> 4)` with an **arithmetic** shift, which
-- floors rather than truncating toward zero. When b < a the difference is
-- negative and the two round in opposite directions, by one least significant
-- bit, on exactly the pixels where a texture gets darker from left to right.
-- The model uses Python's `>>`, which floors; a logical shift or a division
-- would disagree with it on half the gradients in a picture.
--
-- No saturation is needed and none is applied: with a and b in 0..255 and f in
-- 0..15 the result is in 15..239, so a clamp here would be dead logic that
-- looked like a safety net.
--
-- ## Nearest truncates, it does not round
--
-- UV arrives in 12.4 fixed point and the fractional bits are simply discarded.
-- The GS does not round them. That is half a texel, and on any texture with a
-- hard edge it is visible -- and it is also why the nearest path and the
-- bilinear path disagree by half a texel unless bilinear applies its own
-- (u - 0.5) shift, which is the detail gs-texture.md spends a paragraph on.
--
-- ## The multiply is by seven, not eight
--
-- `texture_function` multiplies by the fragment colour **shifted right by
-- seven**. The GS's fixed point puts 1.0 at 0x80 throughout, the same
-- convention the alpha blender already uses. Shifting by eight is the obvious
-- guess and darkens every textured surface by exactly a factor of two, which
-- reads as a lighting bug rather than as an arithmetic one.
--
-- ## The read port -- answered elsewhere, on purpose
--
-- `gs_lmem` has one read port. The rasteriser and the display already share it
-- (`a3451fe`), the CLUT's loader is a third customer, and this is a fourth --
-- and unlike the others it wants a texel for *every pixel drawn*. The real GS
-- does not do this: it gives texture its own 512-bit path with its own page
-- buffer, which is why a textured pixel there costs roughly twice an untextured
-- one rather than four times.
--
-- The answer taken is `gs_texcache`, which presents exactly this port's shape on
-- both of its sides and sits between this block and the memory. That is why
-- nothing here changed when it landed, and why nothing here arbitrates: an
-- arbiter written into this block would have had to be taken out again. What is
-- here is correct at one fetch at a time, and the throughput question is
-- measured next door rather than guessed at here.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library work;
use work.gs_addr_pkg.all;
use work.gs_texaddr_pkg.all;

package gs_texsample_pkg is

   subtype t_rgba is std_logic_vector(31 downto 0);   -- a,b,g,r from the top

   constant TFX_MODULATE   : unsigned(1 downto 0) := "00";
   constant TFX_DECAL      : unsigned(1 downto 0) := "01";
   constant TFX_HIGHLIGHT  : unsigned(1 downto 0) := "10";
   constant TFX_HIGHLIGHT2 : unsigned(1 downto 0) := "11";

   -- One stored texel -> r, g, b, a, eight bits each.
   function expand_texel(raw : std_logic_vector(31 downto 0);
                         psm : unsigned(5 downto 0)) return t_rgba;

   -- Combine the fragment colour with the texel.
   function texture_function(tfx   : unsigned(1 downto 0);
                             tcc   : std_logic;
                             frag  : t_rgba;
                             texel : t_rgba) return t_rgba;

   -- One channel, then all four: a + ((b - a) * f >> 4), arithmetic.
   function lerp8(a, b : unsigned(7 downto 0);
                  f    : unsigned(3 downto 0)) return unsigned;
   function lerp_rgba(a, b : t_rgba; f : unsigned(3 downto 0)) return t_rgba;

   -- The bilinear combination, in the model's own order: the two horizontal
   -- lerps first and the vertical one between their results. Doing the vertical
   -- pair first is algebraically the same in exact arithmetic and *not* the same
   -- here, because each lerp truncates.
   function bilerp(c00, c10, c01, c11 : t_rgba;
                   fu, fv : unsigned(3 downto 0)) return t_rgba;

end package;

package body gs_texsample_pkg is

   function sat8(x : signed) return std_logic_vector is
   begin
      if x < 0 then
         return x"00";
      elsif x > 255 then
         return x"FF";
      else
         return std_logic_vector(resize(unsigned(std_logic_vector(x)), 8));
      end if;
   end function;

   function expand_texel(raw : std_logic_vector(31 downto 0);
                         psm : unsigned(5 downto 0)) return t_rgba is
   begin
      case psm is
         when PSMCT24 =>
            -- PSMCT24 has no alpha of its own: the top byte is not part of the
            -- pixel. It reads as zero and TEXA would normally supply a value.
            -- That register is not modelled yet, and zero is returned rather
            -- than a guessed 0x80 -- a wrong constant alpha looks like a
            -- blending bug several stages later.
            return x"00" & raw(23 downto 0);
         when PSMCT16 | PSMCT16S =>
            -- expand16 is the GS's own 5551 -> 8888, already verified from the
            -- frame buffer side: five bits become eight by a shift, and the
            -- single alpha bit becomes 0x80 rather than 0xFF, because 0x80 is
            -- what 1.0 is in this fixed point.
            return expand16(raw(15 downto 0));
         when others =>
            -- PSMCT32, the H formats, and anything that has already been
            -- through the palette: the stored word is the colour.
            return raw;
      end case;
   end function;

   function texture_function(tfx   : unsigned(1 downto 0);
                             tcc   : std_logic;
                             frag  : t_rgba;
                             texel : t_rgba) return t_rgba is
      variable fr, fg, fb, fa : unsigned(7 downto 0);
      variable tr, tg, tb, ta : unsigned(7 downto 0);
      variable mr, mg, mb, ma : unsigned(15 downto 0);
      variable r, g, b, a     : std_logic_vector(7 downto 0);
   begin
      fr := unsigned(frag(7 downto 0));    tr := unsigned(texel(7 downto 0));
      fg := unsigned(frag(15 downto 8));   tg := unsigned(texel(15 downto 8));
      fb := unsigned(frag(23 downto 16));  tb := unsigned(texel(23 downto 16));
      fa := unsigned(frag(31 downto 24));  ta := unsigned(texel(31 downto 24));

      if tfx = TFX_DECAL then
         -- The texel replaces the fragment entirely; only the alpha is a
         -- question, and TCC answers it.
         if tcc = '1' then
            return std_logic_vector(ta) & std_logic_vector(tb)
                 & std_logic_vector(tg) & std_logic_vector(tr);
         else
            return std_logic_vector(fa) & std_logic_vector(tb)
                 & std_logic_vector(tg) & std_logic_vector(tr);
         end if;
      end if;

      -- >> 7, not >> 8. See the header.
      mr := shift_right(fr * tr, 7);
      mg := shift_right(fg * tg, 7);
      mb := shift_right(fb * tb, 7);
      ma := shift_right(fa * ta, 7);

      if tfx = TFX_MODULATE then
         r := sat8(signed('0' & mr));
         g := sat8(signed('0' & mg));
         b := sat8(signed('0' & mb));
         if tcc = '1' then
            a := sat8(signed('0' & ma));
         else
            a := std_logic_vector(fa);
         end if;
         return a & b & g & r;
      end if;

      -- HIGHLIGHT and HIGHLIGHT2 add the fragment's alpha to the colour, which
      -- is what lets a specular pass happen in one primitive. They differ only
      -- in where the output alpha comes from.
      r := sat8(signed('0' & mr) + signed("00000000" & fa));
      g := sat8(signed('0' & mg) + signed("00000000" & fa));
      b := sat8(signed('0' & mb) + signed("00000000" & fa));
      if tcc = '0' then
         a := std_logic_vector(fa);
      elsif tfx = TFX_HIGHLIGHT then
         a := sat8(signed("00000000" & ta) + signed("00000000" & fa));
      else
         a := std_logic_vector(ta);
      end if;
      return a & b & g & r;
   end function;

   function lerp8(a, b : unsigned(7 downto 0);
                  f    : unsigned(3 downto 0)) return unsigned is
      variable d : signed(8 downto 0);    -- b - a, -255 .. 255
      variable p : signed(13 downto 0);   -- d * f,  -3825 .. 3825
      variable r : signed(9 downto 0);
   begin
      d := signed('0' & b) - signed('0' & a);
      p := d * signed('0' & f);
      -- shift_right on a *signed* floors. That is the whole point; see the
      -- header. The model is Python's >>, which floors too.
      r := resize(signed('0' & a), 10) + resize(shift_right(p, 4), 10);
      return unsigned(std_logic_vector(r(7 downto 0)));
   end function;

   function lerp_rgba(a, b : t_rgba; f : unsigned(3 downto 0)) return t_rgba is
   begin
      return std_logic_vector(lerp8(unsigned(a(31 downto 24)), unsigned(b(31 downto 24)), f))
           & std_logic_vector(lerp8(unsigned(a(23 downto 16)), unsigned(b(23 downto 16)), f))
           & std_logic_vector(lerp8(unsigned(a(15 downto  8)), unsigned(b(15 downto  8)), f))
           & std_logic_vector(lerp8(unsigned(a( 7 downto  0)), unsigned(b( 7 downto  0)), f));
   end function;

   function bilerp(c00, c10, c01, c11 : t_rgba;
                   fu, fv : unsigned(3 downto 0)) return t_rgba is
      variable top, bot : t_rgba;
   begin
      top := lerp_rgba(c00, c10, fu);
      bot := lerp_rgba(c01, c11, fu);
      return lerp_rgba(top, bot, fv);
   end function;

end package body;

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library work;
use work.gs_addr_pkg.all;
use work.gs_texaddr_pkg.all;
use work.gs_texsample_pkg.all;

entity gs_texsample is
   port
   (
      clk       : in  std_logic;
      reset     : in  std_logic;

      -- one sample. req is a pulse; the inputs must be stable with it.
      req       : in  std_logic;
      u_fixed   : in  signed(16 downto 0);    -- 12.4
      v_fixed   : in  signed(16 downto 0);
      frag      : in  t_rgba;
      tex0      : in  std_logic_vector(63 downto 0);
      clamp     : in  std_logic_vector(63 downto 0);
      -- Nearest or bilinear. This is one bit rather than TEX1 because what TEX1
      -- actually says is MMAG and MMIN, and reducing those to a filter needs the
      -- LOD, which needs Q, which needs the perspective divide that does not
      -- exist yet. Taking TEX1 here would be pretending mipmapping is wired.
      linear    : in  std_logic := '0';

      -- local memory, the shape gs_lmem presents
      rd_en     : out std_logic;
      rd_addr   : out std_logic_vector(16 downto 0);
      rd_data   : in  std_logic_vector(255 downto 0);
      rd_valid  : in  std_logic;

      -- the palette, which lives in gs_clut. Its `entry` is registered, so the
      -- colour for an index appears the clock after the index is presented.
      clut_idx  : out unsigned(7 downto 0);
      clut_data : in  std_logic_vector(31 downto 0);

      done      : out std_logic;              -- one pulse per req
      colour    : out t_rgba;
      busy      : out std_logic
   );
end entity;

architecture rtl of gs_texsample is

   -- TEX0, from the manual's layout. CBP at 37 is the field gs_ref.py's CLUT
   -- already depends on, so the rest of the layout is being used consistently
   -- with something the tests exercise rather than taken on its own.
   alias t_tbp : std_logic_vector(13 downto 0) is tex0(13 downto 0);
   alias t_tbw : std_logic_vector(5 downto 0)  is tex0(19 downto 14);
   alias t_psm : std_logic_vector(5 downto 0)  is tex0(25 downto 20);
   alias t_tw  : std_logic_vector(3 downto 0)  is tex0(29 downto 26);
   alias t_th  : std_logic_vector(3 downto 0)  is tex0(33 downto 30);
   alias t_tcc : std_logic                     is tex0(34);
   alias t_tfx : std_logic_vector(1 downto 0)  is tex0(36 downto 35);

   -- CLAMP
   alias c_wms  : std_logic_vector(1 downto 0) is clamp(1 downto 0);
   alias c_wmt  : std_logic_vector(1 downto 0) is clamp(3 downto 2);
   alias c_minu : std_logic_vector(9 downto 0) is clamp(13 downto 4);
   alias c_maxu : std_logic_vector(9 downto 0) is clamp(23 downto 14);
   alias c_minv : std_logic_vector(9 downto 0) is clamp(33 downto 24);
   alias c_maxv : std_logic_vector(9 downto 0) is clamp(43 downto 34);

   -- gs_texaddr is combinational, so it is driven from the *latched* request
   -- and its answer is stable for as long as the fetch takes.
   --
   -- The integer texel coordinate and the weight are split apart on the way in
   -- rather than each corner re-deriving them: the half-texel shift happens once,
   -- and four copies of a subtract-then-shift is four places for it to differ.
   signal r_u0, r_v0 : signed(13 downto 0) := (others => '0');
   signal r_fu, r_fv : unsigned(3 downto 0) := (others => '0');
   signal r_linear   : std_logic := '0';
   signal r_frag     : t_rgba := (others => '0');
   signal r_tex0     : std_logic_vector(63 downto 0) := (others => '0');
   signal r_clamp    : std_logic_vector(63 downto 0) := (others => '0');

   -- Which of the four corners is in flight, and the four texels once they are
   -- expanded. Expansion happens per corner and before the lerp because the
   -- model filters colours, not stored words: two PSMCT16 texels averaged as
   -- 5551 and then expanded is not the same number as two expanded and averaged.
   signal corner     : unsigned(1 downto 0) := (others => '0');
   signal t00, t10, t01, t11 : t_rgba := (others => '0');

   alias r_psm : std_logic_vector(5 downto 0) is r_tex0(25 downto 20);
   alias r_tcc : std_logic                    is r_tex0(34);
   alias r_tfx : std_logic_vector(1 downto 0) is r_tex0(36 downto 35);

   signal a_u_in     : signed(12 downto 0);
   signal a_v_in     : signed(12 downto 0);
   signal a_lm       : unsigned(16 downto 0);
   signal a_off      : unsigned(7 downto 0);
   signal a_width    : unsigned(5 downto 0);

   -- FILT1 and FILT2 are register stages, not work. The filter and the texture
   -- function chained combinationally were the Graphics Synthesizer's longest
   -- path once this block was wired into gs_top: t00 -> three lerps -> TFX's
   -- multiply and saturate -> the consumer's register, 35 logic levels and
   -- 10.3 ns against the console's 6.782. Split three ways it is one lerp, one
   -- lerp, and TFX. The cost is one extra clock for nearest and two for
   -- bilinear, against a textured pixel that already takes a dozen.
   -- CALC is a register stage too. gs_texaddr is combinational and was feeding
   -- gs_texcache's tag compare in the same clock: coordinate -> page, block and
   -- column arithmetic -> the cache's set, tag and hit decision, 25 logic levels
   -- and the longest path in the GS once the filter above had been split. One
   -- clock per texel buys it back, and a corner that hits the cache still costs
   -- three.
   type t_state is (IDLE, CALC, FETCH, WAIT_D, CLUT1, CLUT2, FILT1, FILT2, EMIT);
   signal state : t_state := IDLE;

   -- The expanded texel for the corner that has just come back, stored into one
   -- of the four. A procedure rather than four copies of the same case.
   procedure keep (signal a, b, c, d : out t_rgba;
                   n : in unsigned(1 downto 0);
                   v : in t_rgba) is
   begin
      case n is
         when "00"   => a <= v;
         when "01"   => b <= v;
         when "10"   => c <= v;
         when others => d <= v;
      end case;
   end procedure;

   signal raw        : std_logic_vector(31 downto 0) := (others => '0');
   -- The address, held across the fetch so the arithmetic above and the lookup
   -- below are in different clocks.
   signal r_lm  : unsigned(16 downto 0) := (others => '0');
   signal r_off : unsigned(7 downto 0)  := (others => '0');
   signal r_w   : unsigned(5 downto 0)  := (others => '0');

   signal r_top, r_bot : t_rgba := (others => '0');
   signal r_filtered   : t_rgba := (others => '0');

   function is_indexed(psm : std_logic_vector(5 downto 0)) return boolean is
   begin
      return psm = "010011"      -- PSMT8
          or psm = "010100"      -- PSMT4
          or psm = "011011"      -- PSMT8H
          or psm = "100100"      -- PSMT4HL
          or psm = "101100";     -- PSMT4HH
   end function;

begin

   -- Where the texel is. The wrap happens in here too, so this block never
   -- duplicates it -- a second copy of REGION_REPEAT is exactly the kind of
   -- thing that drifts.
   -- (0,0), (1,0), (0,1), (1,1) -- the model's order, and the order t00/t10/t01/t11
   -- are combined in. Each corner is wrapped independently by gs_texaddr, which
   -- is what the model does too: REGION_CLAMP on a corner that has stepped off
   -- the edge is the reason the filter does not smear across a texture boundary.
   a_u_in <= resize(r_u0 + ("0000000000000" & corner(0)), 13);
   a_v_in <= resize(r_v0 + ("0000000000000" & corner(1)), 13);

   addr : entity work.gs_texaddr
      port map (
         u_in  => a_u_in,
         v_in  => a_v_in,
         tbp   => unsigned(r_tex0(13 downto 0)),
         tbw   => unsigned(r_tex0(19 downto 14)),
         psm   => unsigned(r_tex0(25 downto 20)),
         tw    => unsigned(r_tex0(29 downto 26)),
         th    => unsigned(r_tex0(33 downto 30)),
         wms   => unsigned(r_clamp(1 downto 0)),
         wmt   => unsigned(r_clamp(3 downto 2)),
         minu  => unsigned(r_clamp(13 downto 4)),
         maxu  => unsigned(r_clamp(23 downto 14)),
         minv  => unsigned(r_clamp(33 downto 24)),
         maxv  => unsigned(r_clamp(43 downto 34)),
         lm_addr => a_lm,
         bit_off => a_off,
         width   => a_width,
         u_out   => open,
         v_out   => open);

   rd_addr  <= std_logic_vector(r_lm);
   rd_en    <= '1' when state = FETCH else '0';
   busy     <= '0' when state = IDLE else '1';
   clut_idx <= unsigned(raw(7 downto 0));

   process (clk)
      variable shifted : unsigned(255 downto 0);
      variable w32     : std_logic_vector(31 downto 0);
      variable word    : std_logic_vector(31 downto 0);
      variable uu, vv  : signed(17 downto 0);
   begin
      if rising_edge(clk) then
         done <= '0';

         if reset = '1' then
            state <= IDLE;
         else
            case state is

               when IDLE =>
                  if req = '1' then
                     -- The half texel, once. 0.5 of a texel is 8 in 12.4, and
                     -- it is subtracted only on the bilinear path -- nearest
                     -- truncates the coordinate it was given. The subtract is
                     -- done at 18 bits so a coordinate at the bottom of the
                     -- range does not wrap into the top of it.
                     if linear = '1' then
                        uu := resize(u_fixed, 18) - 8;
                        vv := resize(v_fixed, 18) - 8;
                        r_u0 <= resize(shift_right(uu, 4), 14);
                        r_v0 <= resize(shift_right(vv, 4), 14);
                        -- A **slice**, not a resize. `resize` on a signed keeps
                        -- the sign bit and the low bits below it, so
                        -- resize(uu, 4) is uu(17) & uu(2 downto 0) -- which is
                        -- three of the four fractional bits with the sign
                        -- pasted on top, and it is zero for exactly the
                        -- half-texel positions that make a filter look right.
                        r_fu <= unsigned(std_logic_vector(uu(3 downto 0)));
                        r_fv <= unsigned(std_logic_vector(vv(3 downto 0)));
                     else
                        r_u0 <= resize(shift_right(u_fixed, 4), 14);
                        r_v0 <= resize(shift_right(v_fixed, 4), 14);
                        r_fu <= (others => '0');
                        r_fv <= (others => '0');
                     end if;
                     r_linear <= linear;
                     r_frag   <= frag;
                     r_tex0   <= tex0;
                     r_clamp  <= clamp;
                     corner   <= (others => '0');
                     state    <= CALC;
                  end if;

               when CALC =>
                  r_lm  <= a_lm;
                  r_off <= a_off;
                  r_w   <= a_width;
                  state <= FETCH;

               when FETCH =>
                  state <= WAIT_D;

               when WAIT_D =>
                  if rd_valid = '1' then
                     -- A variable shift rather than a variable slice: the texel
                     -- can start at any of 64 bit positions and VHDL will not
                     -- index a slice with a signal.
                     shifted := shift_right(unsigned(rd_data),
                                            to_integer(r_off));
                     w32 := std_logic_vector(shifted(31 downto 0));
                     case to_integer(r_w) is
                        when 4      => word := x"0000000" & w32(3 downto 0);
                        when 8      => word := x"000000"  & w32(7 downto 0);
                        when 16     => word := x"0000"    & w32(15 downto 0);
                        when 24     => word := x"00"      & w32(23 downto 0);
                        when others => word := w32;
                     end case;
                     raw <= word;
                     if is_indexed(r_psm) then
                        state <= CLUT1;
                     else
                        -- Expanded here rather than at the end: the four texels
                        -- are filtered as colours, and a stored word is not one
                        -- until its format has been applied to it. Two PSMCT16
                        -- texels averaged as 5551 and then expanded is a
                        -- different number from two expanded and averaged.
                        keep(t00, t10, t01, t11, corner,
                             expand_texel(word, unsigned(r_psm)));
                        if r_linear = '1' and corner /= "11" then
                           corner <= corner + 1;
                           state  <= CALC;
                        elsif r_linear = '1' then
                           state <= FILT1;
                        else
                           state <= FILT2;
                        end if;
                     end if;
                  end if;

               when CLUT1 =>
                  -- clut_idx is combinational on `raw`; gs_clut registers its
                  -- read, so the entry is there one clock later. One state per
                  -- clock rather than a counter, because two is not worth one.
                  state <= CLUT2;

               when CLUT2 =>
                  -- An index has been through the palette, so what comes back
                  -- is a PSMCT32 word whatever the texture's own format was.
                  keep(t00, t10, t01, t11, corner,
                       expand_texel(clut_data, PSMCT32));
                  if r_linear = '1' and corner /= "11" then
                     corner <= corner + 1;
                     state  <= CALC;
                  elsif r_linear = '1' then
                     state <= FILT1;
                  else
                     state <= FILT2;
                  end if;

               when FILT1 =>
                  -- The two horizontal lerps, which are independent of each
                  -- other and so cost one lerp of depth, not two.
                  r_top <= lerp_rgba(t00, t10, r_fu);
                  r_bot <= lerp_rgba(t01, t11, r_fu);
                  state <= FILT2;

               when FILT2 =>
                  -- The vertical one, or the nearest texel straight through.
                  if r_linear = '1' then
                     r_filtered <= lerp_rgba(r_top, r_bot, r_fv);
                  else
                     r_filtered <= t00;
                  end if;
                  state <= EMIT;

               when EMIT =>
                  -- `colour` is combinational on the stored texels, so it is
                  -- already the answer; this state exists to pulse done with it
                  -- stable.
                  state <= IDLE;
                  done  <= '1';

            end case;
         end if;
      end if;
   end process;

   -- The filter runs first and TFX second, which is the model's order and not an
   -- arbitrary one: TFX multiplies by the fragment colour and saturates, and
   -- saturating four texels and then averaging them is not the same as averaging
   -- four and saturating once. `bilerp` in the package states that composition
   -- in one expression and is what the model is read against; the FSM above
   -- evaluates the same thing one lerp per clock.
   --
   -- Combinational on the *registered* filtered texel, so the path that leaves
   -- this block is TFX alone and `colour` is still valid with `done`.
   colour <= texture_function(unsigned(r_tfx), r_tcc, r_frag, r_filtered);

end architecture;
