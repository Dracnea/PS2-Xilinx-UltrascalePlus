-- gs_texsample.vhd -- a texel, fetched and combined with the fragment colour.
--
-- This is step 4 of docs/gs-texture.md, and it is the piece that makes the
-- other two useful: gs_texaddr says *where* a texel is and gs_clut holds the
-- palette, and this asks local memory for the bits, turns them into a colour,
-- and combines that colour with the fragment's. With it, a 2D textured
-- primitive can be drawn.
--
-- Nearest sampling only. Bilinear needs four of these and a weighted sum, and
-- the reference model has it (step 5) -- but four fetches is a throughput
-- decision about the read port, which is the open question below, and building
-- the filter before that is settled would be building it twice.
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
-- ## The read port, stated plainly rather than solved here
--
-- `gs_lmem` has one read port. The rasteriser and the display already share it
-- (`a3451fe`), the CLUT's loader is a third customer, and this is a fourth --
-- and unlike the others it wants a texel for *every pixel drawn*. The real GS
-- does not do this: it gives texture its own 512-bit path with its own page
-- buffer, which is why a textured pixel there costs roughly twice an untextured
-- one rather than four times.
--
-- So this block takes a read port as an ordinary port and does not arbitrate.
-- Whether the answer is a second port on gs_lmem, a wider one time-sliced, or a
-- texture cache in front of it is a throughput decision that wants measuring,
-- and an arbiter written into this block now would have to be taken out of it
-- later. What is here is correct and one fetch at a time; what it costs is a
-- number the integrator can now measure rather than estimate.
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
   signal r_u, r_v   : signed(16 downto 0) := (others => '0');
   signal r_frag     : t_rgba := (others => '0');
   signal r_tex0     : std_logic_vector(63 downto 0) := (others => '0');
   signal r_clamp    : std_logic_vector(63 downto 0) := (others => '0');

   alias r_psm : std_logic_vector(5 downto 0) is r_tex0(25 downto 20);
   alias r_tcc : std_logic                    is r_tex0(34);
   alias r_tfx : std_logic_vector(1 downto 0) is r_tex0(36 downto 35);

   signal a_lm       : unsigned(16 downto 0);
   signal a_off      : unsigned(7 downto 0);
   signal a_width    : unsigned(5 downto 0);

   type t_state is (IDLE, FETCH, WAIT_D, CLUT1, CLUT2, EMIT);
   signal state : t_state := IDLE;

   signal raw        : std_logic_vector(31 downto 0) := (others => '0');

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
   addr : entity work.gs_texaddr
      port map (
         u_in  => resize(shift_right(r_u, 4), 13),
         v_in  => resize(shift_right(r_v, 4), 13),
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

   rd_addr  <= std_logic_vector(a_lm);
   rd_en    <= '1' when state = FETCH else '0';
   busy     <= '0' when state = IDLE else '1';
   clut_idx <= unsigned(raw(7 downto 0));

   process (clk)
      variable shifted : unsigned(255 downto 0);
      variable w32     : std_logic_vector(31 downto 0);
   begin
      if rising_edge(clk) then
         done <= '0';

         if reset = '1' then
            state <= IDLE;
         else
            case state is

               when IDLE =>
                  if req = '1' then
                     r_u     <= u_fixed;
                     r_v     <= v_fixed;
                     r_frag  <= frag;
                     r_tex0  <= tex0;
                     r_clamp <= clamp;
                     state   <= FETCH;
                  end if;

               when FETCH =>
                  state <= WAIT_D;

               when WAIT_D =>
                  if rd_valid = '1' then
                     -- A variable shift rather than a variable slice: the texel
                     -- can start at any of 64 bit positions and VHDL will not
                     -- index a slice with a signal.
                     shifted := shift_right(unsigned(rd_data),
                                            to_integer(a_off));
                     w32 := std_logic_vector(shifted(31 downto 0));
                     case to_integer(a_width) is
                        when 4      => raw <= x"0000000" & w32(3 downto 0);
                        when 8      => raw <= x"000000"  & w32(7 downto 0);
                        when 16     => raw <= x"0000"    & w32(15 downto 0);
                        when 24     => raw <= x"00"      & w32(23 downto 0);
                        when others => raw <= w32;
                     end case;
                     if is_indexed(r_psm) then
                        state <= CLUT1;
                     else
                        state <= EMIT;
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
                  raw   <= clut_data;
                  state <= EMIT;

               when EMIT =>
                  -- `colour` is combinational on `raw`, so it is already the
                  -- answer; this state exists to pulse done with it stable.
                  state <= IDLE;
                  done  <= '1';

            end case;
         end if;
      end if;
   end process;

   -- The texture function is combinational on the registered texel, so `colour`
   -- is valid with `done`.
   colour <= texture_function(unsigned(r_tfx), r_tcc, r_frag,
                              expand_texel(raw, PSMCT32)) when is_indexed(r_psm)
             else texture_function(unsigned(r_tfx), r_tcc, r_frag,
                                   expand_texel(raw, unsigned(r_psm)));

end architecture;
