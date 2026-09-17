-- gs_gif.vhd -- the GIF: GIFtag decode, the general register file, and
-- host-to-local transfers.
--
-- This is the slice of the Graphics Synthesizer that can be checked without
-- drawing anything, and it is deliberately the first one built, for the same
-- reason the R5900's integer core came before its FPU: it produces state that
-- a reference model can be diffed against, so the harness is working before
-- there is anything hard to debug.  sim/gs/gs_ref.py is that model.
--
-- What it does:
--
--   * decodes a GIFtag and walks its register descriptor list, in PACKED,
--     REGLIST and IMAGE modes
--   * holds the 64 general registers, written either by a descriptor or
--     through the A+D path, which carries its own address
--   * runs a host-to-local transfer: BITBLTBUF, TRXPOS and TRXREG set it up,
--     a write to TRXDIR starts it, and the data arrives either through HWREG
--     or as an IMAGE-mode packet
--
-- The local memory swizzle is the part worth reading.  A PSMCT32 pixel's word
-- address is
--
--     page(8:0) & x5 & y4 & x4 & y3 & x3 & y2 & y1 & x2 & x1 & y0 & x0
--
-- -- the low eleven bits are nothing but the low bits of x and y interleaved in
-- a fixed order.  The GS manual presents this as three tables (page, block and
-- column), and PCSX2 stores two of them as literal arrays, but in hardware it
-- is a wire permutation and costs nothing at all.  Only the page number needs
-- arithmetic.  tools/gs/xcheck_swizzle.py checks the arithmetic form of this
-- against PCSX2 exhaustively.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.gs_addr_pkg.all;

entity gs_gif is
   port
   (
      clk       : in  std_logic;
      reset     : in  std_logic;

      -- GIF input: one quadword at a time
      gif_valid : in  std_logic;
      gif_data  : in  std_logic_vector(127 downto 0);
      gif_ready : out std_logic;

      -- local memory write port, shaped for gs_lmem
      wr_en     : out std_logic := '0';
      wr_addr   : out std_logic_vector(16 downto 0) := (others => '0');
      wr_data   : out std_logic_vector(255 downto 0) := (others => '0');
      wr_be     : out std_logic_vector(31 downto 0) := (others => '0');

      -- read port, for the read-modify-write that FBMSK requires.  The real GS
      -- reads the framebuffer for every drawn pixel anyway -- Z, alpha and the
      -- write mask all need it -- so this is where that path starts.
      rd_en     : out std_logic := '0';
      rd_addr   : out std_logic_vector(16 downto 0) := (others => '0');
      rd_data   : in  std_logic_vector(255 downto 0) := (others => '0');
      rd_valid  : in  std_logic := '0';

      -- The texture unit's own read port. It is separate from the one above
      -- because the two are wanted in the same pixel: the read-modify-write
      -- reads the frame buffer and this reads the texture, and muxing them
      -- here would serialise every textured pixel behind its own destination
      -- read. The palette loader shares this one -- see the note by the
      -- instantiation -- which is why there are two ports and not three.
      --
      -- Unlike the port above, this one has a ready: gs_texcache holds its
      -- request until the arbiter takes it, so the display never has to lose.
      t_rd_en    : out std_logic := '0';
      t_rd_addr  : out std_logic_vector(16 downto 0) := (others => '0');
      t_rd_data  : in  std_logic_vector(255 downto 0) := (others => '0');
      t_rd_valid : in  std_logic := '0';
      t_rd_ready : in  std_logic := '1';

      -- for the testbench: read any general register, and count writes to
      -- addresses the manual does not define rather than inventing behaviour
      dbg_sel     : in  unsigned(6 downto 0) := (others => '0');
      dbg_reg     : out std_logic_vector(63 downto 0) := (others => '0');
      dbg_unknown : out unsigned(15 downto 0) := (others => '0');
      -- pixels drawn, because a primitive that quietly draws nothing -- clipped
      -- away, wrong pixel format, empty rectangle -- otherwise looks exactly
      -- like a framebuffer that was never meant to change
      dbg_pixels  : out unsigned(31 downto 0) := (others => '0');
      -- The texture unit, observable for the same reason the rest is: a cache
      -- that never hits and a palette that never loaded both draw a picture.
      dbg_tex_hits   : out unsigned(31 downto 0);
      dbg_tex_misses : out unsigned(31 downto 0);
      dbg_clut_loads : out unsigned(15 downto 0);
      dbg_tex_unsup  : out std_logic;
      -- Textured primitives this rasteriser refused rather than drew wrong.
      dbg_tex_skip   : out unsigned(15 downto 0)
   );
end entity;

architecture arch of gs_gif is
   type regfile_t is array (0 to 127) of std_logic_vector(63 downto 0);
   signal reg : regfile_t := (others => (others => '0'));

   signal unknown : unsigned(15 downto 0) := (others => '0');
   signal pixels  : unsigned(31 downto 0) := (others => '0');

   type state_t is (S_TAG, S_PACKED, S_REGLIST, S_IMAGE, S_PIXELS, S_TEX,
                    S_SPR_CLAMP, S_SPR_TEST,
                    S_DRAW, S_DRAWRD,
                    S_DRAWWR,
                    S_TRI_SET, S_TRI_CEIL, S_TRI_GO, S_TRI_WAIT,
                    S_TRI_SCAN, S_TRI_CLAMP,
                    S_TRI_TEST, S_TRI_STEP,
                    S_TRI_SEED, S_ZRD);
   signal state : state_t := S_TAG;

   -- the tag in flight
   signal t_nloop : unsigned(14 downto 0) := (others => '0');
   signal t_eop   : std_logic := '0';
   signal t_nreg  : unsigned(4 downto 0) := (others => '0');
   signal t_regs  : std_logic_vector(63 downto 0) := (others => '0');
   signal t_loop  : unsigned(14 downto 0) := (others => '0');
   signal t_ri    : unsigned(4 downto 0) := (others => '0');

   -- the host-to-local transfer
   signal x_active : std_logic := '0';
   signal x_bp     : unsigned(13 downto 0) := (others => '0');
   signal x_bw     : unsigned(5 downto 0) := (others => '0');
   signal x_psm    : unsigned(5 downto 0) := (others => '0');
   signal x_x0     : unsigned(10 downto 0) := (others => '0');
   signal x_w      : unsigned(11 downto 0) := (others => '0');
   signal x_cx     : unsigned(10 downto 0) := (others => '0');
   signal x_cy     : unsigned(10 downto 0) := (others => '0');
   signal x_left   : unsigned(23 downto 0) := (others => '0');  -- pixels remaining

   -- the primitive being drawn.  A sprite is the first one: axis-aligned and
   -- flat-coloured, so there is no interpolation to get wrong before the
   -- addressing, the scissor and the write mask are known to be right.
   signal v_cnt   : unsigned(2 downto 0) := (others => '0');
   signal v0_x, v0_y : unsigned(15 downto 0) := (others => '0');
   signal v1_x, v1_y : unsigned(15 downto 0) := (others => '0');
   -- A triangle needs three vertices in flight, and a fan keeps its *first*
   -- for every triangle it draws, which a shift register alone cannot provide;
   -- the anchor is captured on the first vertex after PRIM.
   signal v2_x, v2_y : unsigned(15 downto 0) := (others => '0');
   signal vf_x, vf_y : unsigned(15 downto 0) := (others => '0');
   -- RGBAQ is written *before* the vertex it belongs to, so the colour in
   -- flight at each vertex write is that vertex's own, and it shifts down
   -- beside the coordinates.  Gouraud is the only thing that needs it; flat
   -- shading takes the last vertex's colour, which is simply the current one.
   signal v0_c, v1_c, v2_c : std_logic_vector(31 downto 0) := (others => '0');
   signal vf_c             : std_logic_vector(31 downto 0) := (others => '0');
   -- UV shifts down beside RGBAQ and for the same reason: the UV register is
   -- written *before* the vertex it belongs to, so the value current at the
   -- vertex write is that vertex's own. Reading UV at draw time instead would
   -- give all three corners the last vertex's coordinate, which looks like a
   -- broken interpolator and not like a latching bug.
   signal v0_uv, v1_uv, v2_uv : std_logic_vector(31 downto 0) := (others => '0');
   signal vf_uv               : std_logic_vector(31 downto 0) := (others => '0');
   signal v0_z, v1_z, v2_z : std_logic_vector(31 downto 0) := (others => '0');
   signal vf_z             : std_logic_vector(31 downto 0) := (others => '0');
   -- '1' while a triangle is being walked; sprites leave it clear
   signal tri_mode : std_logic := '0';

   -- Three edges, each stepped a scanline at a time by gs_edge_dda, which was
   -- verified against the reference on its own before being used here.  All
   -- three start at the triangle's first scanline and step together; exactly
   -- two span any scanline, and the span lies between their two ceil(x).
   -- Stepping the third as well costs nothing: the recurrence is linear, so an
   -- edge extrapolated outside its own y range is still correct when the
   -- scanline reaches it.
   type sv16_a is array (0 to 2) of signed(17 downto 0);
   type sv13_a is array (0 to 2) of signed(12 downto 0);
   signal e_x0, e_y0, e_x1, e_y1 : sv16_a := (others => (others => '0'));
   signal e_ytop  : signed(13 downto 0) := (others => '0');
   signal e_start : std_logic := '0';
   signal e_step  : std_logic := '0';
   signal e_busy  : std_logic_vector(2 downto 0);
   signal e_x     : sv13_a;
   signal e_yst, e_yen : sv13_a := (others => (others => '0'));
   signal t_x, t_y : sv16_a := (others => (others => '0'));
   type sv32_a is array (0 to 2) of std_logic_vector(31 downto 0);
   signal t_c : sv32_a := (others => (others => '0'));
   signal t_z : sv32_a := (others => (others => '0'));
   -- The three corners' texture coordinates, in the same order and latched on
   -- the same edge. A sprite fills these in too, with the three synthesised
   -- corners of its ramp -- see the note above the UV interpolators.
   signal t_uv : sv32_a := (others => (others => '0'));
   signal dr_x, dr_y : unsigned(10 downto 0) := (others => '0');
   signal dr_x0      : unsigned(10 downto 0) := (others => '0');

   -- A sprite's bounds, held between the three cycles that now compute them.
   --
   -- Everything from the arriving quadword to dr_empty used to happen on one
   -- edge: the register file read, the vertex minus XYOFFSET, the divide by
   -- sixteen, the swap that puts the corners in order, four clamps against the
   -- scissor, and the test for whether anything survived.  Thirty logic levels
   -- with ten carry chains, and after the pixel path and the seed numerator
   -- were cut it was the longest path in the Graphics Synthesizer.
   --
   -- It is now three: the coordinates, then the clamps, then the test.  A
   -- sprite covers hundreds of pixels, so two extra cycles per primitive is not
   -- a cost worth measuring -- which is the general reason the *setup* paths are
   -- the right ones to cut and the pixel loop is not.
   signal k_ax, k_ay, k_bx, k_by     : integer range -131072 to 131071 := 0;
   signal k_sx0, k_sx1, k_sy0, k_sy1 : integer range 0 to 2047 := 0;

   -- The scanline's span, and the scissor it is clamped against, carried
   -- between S_TRI_SCAN, S_TRI_CLAMP and S_TRI_TEST.  The low end of the range
   -- is -4097 and not -4096 because a scanline that no edge spans leaves the
   -- maximum at its initial -4096 and then subtracts one from it.
   signal q_lft, q_rgt : integer range -4097 to 4095 := 0;
   signal q_sx0, q_sx1 : integer range 0 to 2047 := 0;

   -- The triangle's vertical extent, carried across the three states that used
   -- to be one.  In context on the card -- with PCIe and HBM competing for the
   -- same die -- the path from a vertex's y through the three-way minimum, the
   -- ceiling, the scissor clamp and the emptiness test was the *entire* timing
   -- failure: 436 endpoints, all of them this one comparison fanning out to the
   -- reset pins of a register bank, ten carry chains deep.
   signal q_ylo, q_yhi : integer range -65536 to 65535 := 0;
   signal q_tya, q_tyb : integer range -65536 to 65535 := 0;
   signal q_sy0, q_sy1 : integer range 0 to 2047 := 0;
   signal q_detnz      : std_logic := '0';

   -- How many pixels the read-modify-write in flight covers, and whether it was
   -- issued as a wide one.  Both have to survive the two cycles the memory
   -- takes to answer, which is why they are signals and not the variables the
   -- same numbers are computed into.
   signal dr_run  : integer range 1 to 4 := 1;
   signal dr_wide : std_logic := '0';

   -- The wide read-modify-write's result, held for a cycle before it is
   -- written.
   --
   -- Four blenders, a mask and a lane-place in the same clock as the memory's
   -- answer did not fit: in context at 147.456 MHz it missed by 0.36 ns, and
   -- Explore placement with physical optimisation only brought that to 0.14.
   -- Splitting the blend from the write costs one cycle per *group* rather than
   -- per pixel, so the blended fill rate goes to five clocks per four pixels
   -- instead of four -- against the sixteen it started at.
   signal dr_nw   : std_logic_vector(255 downto 0) := (others => '0');
   signal dr_nbe  : std_logic_vector(31 downto 0) := (others => '0');
   signal k_ok  : std_logic := '0';
   signal dr_x1      : unsigned(10 downto 0) := (others => '0');
   signal dr_y1      : unsigned(10 downto 0) := (others => '0');
   signal dr_rgba    : std_logic_vector(31 downto 0) := (others => '0');
   signal dr_fbp     : unsigned(8 downto 0) := (others => '0');
   signal dr_fbw     : unsigned(5 downto 0) := (others => '0');
   signal dr_fbmsk   : std_logic_vector(31 downto 0) := (others => '0');
   -- the frame buffer's format: 16 bits per pixel, and the S block order
   signal dr_fb16    : std_logic := '0';
   signal dr_fbs     : std_logic := '0';
   signal dr_half    : integer range 0 to 1 := 0;
   -- the blender's settings, latched with the rest of the primitive
   signal dr_abe     : std_logic := '0';
   signal dr_alpha   : std_logic_vector(7 downto 0) := (others => '0');  -- A B C D
   signal dr_fix     : unsigned(7 downto 0) := (others => '0');
   signal dr_clamp   : std_logic := '0';
   signal dr_empty   : std_logic := '0';
   signal dr_iip     : std_logic := '0';
   -- The depth test, latched with the rest of the primitive.  dr_zon folds in
   -- every reason the Z buffer might not be touched at all, so the draw path
   -- asks one question rather than four.
   signal dr_zon     : std_logic := '0';
   signal dr_ztst    : std_logic_vector(1 downto 0) := "00";
   signal dr_zmsk    : std_logic := '0';
   signal dr_zbp     : unsigned(8 downto 0) := (others => '0');
   signal dr_zmask   : std_logic_vector(31 downto 0) := (others => '0');
   -- the depth buffer's format: 16 bits per value, and the S block order
   signal dr_z16     : std_logic := '0';
   signal dr_zs      : std_logic := '0';
   signal dr_zhalf   : integer range 0 to 1 := 0;
   signal dr_z       : std_logic_vector(31 downto 0) := (others => '0');
   signal dr_zdone   : std_logic := '0';    -- this pixel has passed its test

   -- ---- texture -----------------------------------------------------------
   -- Latched with the rest of the draw context at the kick, for the same reason
   -- everything else here is: a register written part-way through a primitive
   -- must not change the primitive already being drawn.
   signal dr_tme     : std_logic := '0';
   signal dr_tex0    : std_logic_vector(63 downto 0) := (others => '0');
   signal dr_tex1    : std_logic_vector(63 downto 0) := (others => '0');
   signal dr_tclamp  : std_logic_vector(63 downto 0) := (others => '0');
   -- RGBAQ's Q, as it stood at the kick -- which is the last vertex's, because
   -- RGBAQ is rewritten before each one. On the UV path Q does not produce the
   -- coordinate; it only says how far away the surface is, and that is what
   -- picks the filter.
   signal dr_q       : std_logic_vector(31 downto 0) := (others => '0');
   signal q_exp      : unsigned(7 downto 0);
   signal log2_invq  : signed(8 downto 0);
   signal tex_lod    : signed(15 downto 0);
   signal dr_texdone : std_logic := '0';    -- this pixel's texel has arrived
   signal tex_ref    : std_logic := '0';    -- this primitive was refused
   signal tex_colour : std_logic_vector(31 downto 0) := (others => '0');
   signal frag_rgba  : std_logic_vector(31 downto 0);

   signal tx_req, tx_done, tx_busy : std_logic := '0';
   signal tx_colour  : std_logic_vector(31 downto 0);
   signal tx_linear  : std_logic;
   signal tx_rd_en   : std_logic;
   signal tx_rd_addr : std_logic_vector(16 downto 0);
   signal tx_rd_data : std_logic_vector(255 downto 0);
   signal tx_rd_valid: std_logic;

   signal kc_we      : std_logic := '0';
   signal kc_idx     : unsigned(7 downto 0);
   signal kc_entry   : std_logic_vector(31 downto 0);
   signal kc_busy    : std_logic;
   signal kc_loads   : unsigned(15 downto 0);
   signal kc_unsup   : std_logic;
   signal kc_rd_en   : std_logic;
   signal kc_rd_addr : std_logic_vector(16 downto 0);

   -- A textured primitive this rasteriser will not draw is counted and skipped
   -- rather than drawn wrong: a sprite, whose UV ramp has no per-scanline seed
   -- in this path yet, or PRIM.FST = 0, which needs the per-pixel divide.
   signal dbg_tex_skip_i : unsigned(15 downto 0) := (others => '0');
   -- Driven from inside the process: the register write that starts a palette
   -- load, and the one that empties the texel cache. `w_addr` and `w_data` are
   -- process variables, so neither can be decoded concurrently.
   signal kc_tex0    : std_logic_vector(63 downto 0) := (others => '0');
   signal tex_flush  : std_logic := '0';
   signal tc_rd_en   : std_logic;
   signal tc_rd_addr : std_logic_vector(16 downto 0);
   signal dr_zaddr   : unsigned(19 downto 0) := (others => '0');
   signal dr_ytop    : unsigned(10 downto 0) := (others => '0');
   signal dr_ret     : state_t := S_TAG;
   signal dr_addr    : unsigned(19 downto 0) := (others => '0');

   -- Gouraud.  Four gs_chan_dda, one per channel, so a scanline's four seed
   -- divisions happen together rather than one after another: the divider is a
   -- few hundred LUTs and a scanline costs sixty-four cycles of setup either
   -- way, which is the difference between one of those and four.
   type u8_a is array (0 to 3) of unsigned(7 downto 0);
   signal c_start, c_sstart        : std_logic := '0';
   signal c_adv                    : std_logic;
   signal c_busy, c_sbusy          : std_logic_vector(3 downto 0);
   signal c_det   : signed(47 downto 0) := (others => '0');
   signal c_sgn   : std_logic := '0';
   signal c_dx10, c_dx20, c_dy10, c_dy20 : signed(19 downto 0) := (others => '0');
   signal c_sx, c_sy : signed(12 downto 0) := (others => '0');
   signal c_val   : u8_a;
   -- The interpolated texture coordinate, U then V, 14 bits each in 12.4.
   type u14_a is array (0 to 1) of unsigned(13 downto 0);
   signal uv_val   : u14_a;
   signal uv_busy  : std_logic_vector(1 downto 0);
   signal uv_sbusy : std_logic_vector(1 downto 0);
   -- Their own start pulses, not the colour channels'. c_start is raised only
   -- when PRIM.IIP is set, because a flat triangle has no colour to
   -- interpolate -- so a *textured* flat triangle sharing that pulse would
   -- never seed its UV walk and would sample one texel for the whole
   -- primitive. Depth already has its own pair for the same reason.
   signal uv_start, uv_sstart : std_logic := '0';
   -- Depth rides the same unit, one instance wide, with ZMODE on.
   signal z_start, z_sstart : std_logic := '0';
   signal z_busy, z_sbusy   : std_logic;
   signal z_val   : unsigned(31 downto 0);
   signal src_z   : std_logic_vector(31 downto 0);
   signal z_old   : std_logic_vector(31 downto 0);
   signal z_word  : std_logic_vector(31 downto 0);
   signal src_zc  : std_logic_vector(31 downto 0);
   signal z_pass  : std_logic;
   -- '1' on the cycle the current pixel is finished with, however it ended:
   -- written, masked away, or killed by the depth test.  One signal, so that
   -- the interpolators step on exactly the edge the pixel position does and
   -- there is a single place that decides a pixel is over.
   signal px_step : std_logic;
   -- what the pixel back end actually writes: the interpolated colour while a
   -- Gouraud triangle is being walked, the latched flat colour otherwise
   signal src_rgba : std_logic_vector(31 downto 0);

   -- The interpolated colour and depth, captured when the read that will
   -- consume them is issued.
   --
   -- The first fit of the whole GS closed at 110.8 MHz against the console's
   -- 147.456, and the critical path was the entire per-pixel colour path
   -- standing as one combinational chain: the Gouraud interpolator's lane
   -- accumulate (3.0 ns), into the blender (a further 5.4), into the format
   -- pack and the write mask, arriving at wr_data 9.07 ns after a register in
   -- gs_chan_dda.  Thirty-seven logic levels with fifteen carry chains.
   --
   -- Cutting it between the interpolator and the blender is free, because the
   -- interpolator is already standing still there: px_step is not asserted on
   -- the edge that moves S_DRAW to S_DRAWRD, so c_adv is low and the DDA holds
   -- its value across both cycles.  The blender was reading a value that had
   -- not changed since the cycle before; it now reads it from a register.
   signal dr_src  : std_logic_vector(31 downto 0) := (others => '0');
   signal dr_srcz : std_logic_vector(31 downto 0) := (others => '0');

   -- pixels waiting to be written, one per clock
   signal px_data  : std_logic_vector(127 downto 0) := (others => '0');
   signal px_n     : unsigned(2 downto 0) := (others => '0');
   signal px_ret   : state_t := S_TAG;

   -- Which register addresses the manual defines.  A write to anything else is
   -- counted, not performed: the alternative is to invent a behaviour and then
   -- be unable to tell an emulator bug from a game doing something odd.
   function defined(a : unsigned(6 downto 0)) return boolean is
   begin
      case to_integer(a) is
         when 16#00# to 16#0A# | 16#0C# | 16#0D#            => return true;
         when 16#14# to 16#1C#                              => return true;
         when 16#22#                                        => return true;
         when 16#34# to 16#37# | 16#3B# | 16#3D# | 16#3F#   => return true;
         when 16#40# to 16#4F#                              => return true;
         when 16#50# to 16#54#                              => return true;
         when 16#60# to 16#62#                              => return true;
         when others                                        => return false;
      end case;
   end function;

   -- PSMCT32 word address.  Everything below the page number is a permutation
   -- of the low bits of x and y; see the header.
   -- The two register fields that point at a buffer disagree on units:
   -- BITBLTBUF's DBP counts 256-byte blocks and FRAME's FBP counts 8 KB pages.
   -- Keeping that conversion at the call sites means one "bp" argument never
   -- silently means two different things.
   -- Cv = ((A - B) * C >> 7) + D per component, where A, B and D each select the
   -- source colour, the destination colour or zero, and C the source alpha, the
   -- destination alpha or a fixed value.  The subtraction is signed and the
   -- product leaves the byte range in both directions, so COLCLAMP chooses
   -- between clamping and wrapping -- and wrapping is not a degenerate case to
   -- skip, because content uses the overflow deliberately.  Only RGB is
   -- blended; the alpha written is the source's.
   function blend_px(src, dst : std_logic_vector(31 downto 0);
                     sel : std_logic_vector(7 downto 0);
                     fix : unsigned(7 downto 0);
                     clamp : std_logic) return std_logic_vector is
      variable res : std_logic_vector(31 downto 0);
      variable c   : signed(9 downto 0);
      variable a, b, d : signed(9 downto 0);
      variable t   : signed(19 downto 0);

      function pick(s : std_logic_vector(1 downto 0);
                    sv, dv : std_logic_vector(31 downto 0);
                    n : integer) return signed is
      begin
         case s is
            when "00"   => return signed(resize(unsigned(sv(8 * n + 7 downto 8 * n)), 10));
            when "01"   => return signed(resize(unsigned(dv(8 * n + 7 downto 8 * n)), 10));
            when others => return to_signed(0, 10);
         end case;
      end function;
   begin
      case sel(5 downto 4) is
         when "00"   => c := signed(resize(unsigned(src(31 downto 24)), 10));
         when "01"   => c := signed(resize(unsigned(dst(31 downto 24)), 10));
         when others => c := signed(resize(fix, 10));
      end case;
      res := src;
      for n in 0 to 2 loop
         a := pick(sel(1 downto 0), src, dst, n);
         b := pick(sel(3 downto 2), src, dst, n);
         d := pick(sel(7 downto 6), src, dst, n);
         t := shift_right((a - b) * c, 7) + resize(d, 20);
         if clamp = '1' then
            if t < 0 then
               res(8 * n + 7 downto 8 * n) := x"00";
            elsif t > 255 then
               res(8 * n + 7 downto 8 * n) := x"FF";
            else
               res(8 * n + 7 downto 8 * n) := std_logic_vector(t(7 downto 0));
            end if;
         else
            res(8 * n + 7 downto 8 * n) := std_logic_vector(t(7 downto 0));
         end if;
      end loop;
      return res;
   end function;

   -- PSMZ24, like PSMCT24, is 24 bits inside a 32-bit word: the top byte is
   -- not part of the value and must survive the write, which the byte enables
   -- express directly rather than by reading the word back to preserve it.
   function zbe(mask : std_logic_vector(31 downto 0)) return unsigned is
   begin
      if mask(31) = '1' then
         return unsigned'(x"F");
      else
         return unsigned'(x"7");
      end if;
   end function;

   -- The swizzle, fb16_half and the two 16-bit conversions live in
   -- gs_addr_pkg: PCRTC reads the frame buffer back through exactly the same
   -- addressing this writes it with, and two copies that drifted would scramble
   -- the picture in a way no differential test of either block alone could find
   -- -- each would still agree with its own model.

   -- ---- placing a pixel in a 256-bit word ---------------------------------
   -- The write port is 256 bits and a pixel is 32 or 16, so the pixel has to
   -- land in the lane its address names.  The obvious way is to shift it there,
   -- and that builds a 256-bit barrel shifter on the *end* of the
   -- read-modify-write path -- after the memory read, the expand, the blender
   -- and the format pack, which is already the longest path in the design.
   --
   -- It is not needed.  The byte enables already say which lane is being
   -- written, so the data can simply be repeated into every lane and the
   -- enables pick one.  Replication is wires; the shifter was about 0.8 ns of a
   -- 7.6 ns path, and this costs nothing in throughput because it changes no
   -- cycle counts at all.
   function spread32(v : std_logic_vector(31 downto 0))
      return std_logic_vector is
      variable r : std_logic_vector(255 downto 0);
   begin
      for i in 0 to 7 loop
         r(32*i+31 downto 32*i) := v;
      end loop;
      return r;
   end function;

   function spread16(v : std_logic_vector(15 downto 0))
      return std_logic_vector is
      variable r : std_logic_vector(255 downto 0);
   begin
      for i in 0 to 15 loop
         r(16*i+15 downto 16*i) := v;
      end loop;
      return r;
   end function;

   -- The four frame-buffer formats this rasteriser can draw to.
   function fb_drawable(psm : std_logic_vector(5 downto 0)) return boolean is
   begin
      return psm = "000000" or psm = "000001"      -- PSMCT32, PSMCT24
          or psm = "000010" or psm = "001010";     -- PSMCT16, PSMCT16S
   end function;
begin

   edges : for k in 0 to 2 generate
      u : entity work.gs_edge_dda
         port map (clk => clk, reset => reset, start => e_start,
                   x0 => e_x0(k), y0 => e_y0(k), x1 => e_x1(k), y1 => e_y1(k),
                   ytop => e_ytop, busy => e_busy(k), step => e_step,
                   x => e_x(k));
   end generate;

   chans : for n in 0 to 3 generate
      u : entity work.gs_chan_dda
         port map (clk => clk, reset => reset,
                   start => c_start, det => c_det, sgn => c_sgn,
                   dx10 => c_dx10, dx20 => c_dx20,
                   dy10 => c_dy10, dy20 => c_dy20,
                   x0 => t_x(0), y0 => t_y(0),
                   c0 => unsigned(t_c(0)(8 * n + 7 downto 8 * n)),
                   c1 => unsigned(t_c(1)(8 * n + 7 downto 8 * n)),
                   c2 => unsigned(t_c(2)(8 * n + 7 downto 8 * n)),
                   busy => c_busy(n),
                   sstart => c_sstart, sx => c_sx, sy => c_sy,
                   sbusy => c_sbusy(n),
                   adv => c_adv, val => c_val(n));
   end generate;

   -- **The texture coordinate rides the colour interpolator**, at 14 bits
   -- instead of 8. That the GS shares one interpolator design between colour,
   -- depth and UV is an assumption and not a measurement: the probes that
   -- established the 2**-10 grid and the eight-pixel block used flat and
   -- Gouraud triangles and say nothing about UV. It is the assumption that
   -- costs least if it is wrong -- one generic on one block -- and it is what
   -- makes this and sim/gs/gs_ref.py agree by construction rather than by
   -- coincidence. A probe drawing a textured triangle whose UV gradient lands
   -- just either side of a grid step would settle it.
   --
   -- **A sprite drives these too.** Its UV ramp is a plane: du/dx is
   -- (u1-u0)/(x1-x0), du/dy is zero, and the other axis is the mirror of that.
   -- Feeding the three synthesised corners (x0,y0,u0), (x1,y0,u1), (x0,y1,u0)
   -- through the same plane arithmetic gives exactly that, so the sprite path
   -- needs no divider of its own and the two primitives cannot drift apart.
   uvdda : for n in 0 to 1 generate
      u : entity work.gs_chan_dda
         generic map (CWIDTH => 14)
         port map (clk => clk, reset => reset,
                   start => uv_start, det => c_det, sgn => c_sgn,
                   dx10 => c_dx10, dx20 => c_dx20,
                   dy10 => c_dy10, dy20 => c_dy20,
                   x0 => t_x(0), y0 => t_y(0),
                   c0 => unsigned(t_uv(0)(16 * n + 13 downto 16 * n)),
                   c1 => unsigned(t_uv(1)(16 * n + 13 downto 16 * n)),
                   c2 => unsigned(t_uv(2)(16 * n + 13 downto 16 * n)),
                   busy => uv_busy(n),
                   sstart => uv_sstart, sx => c_sx, sy => c_sy,
                   sbusy => uv_sbusy(n),
                   adv => c_adv, val => uv_val(n));
   end generate;

   zdda : entity work.gs_chan_dda
      generic map (CWIDTH => 32, ZMODE => true)
      port map (clk => clk, reset => reset,
                start => z_start, det => c_det, sgn => c_sgn,
                dx10 => c_dx10, dx20 => c_dx20,
                dy10 => c_dy10, dy20 => c_dy20,
                x0 => t_x(0), y0 => t_y(0),
                c0 => unsigned(t_z(0)), c1 => unsigned(t_z(1)),
                c2 => unsigned(t_z(2)),
                busy => z_busy,
                sstart => z_sstart, sx => c_sx, sy => c_sy,
                sk => dr_y - dr_ytop, sbusy => z_sbusy,
                adv => c_adv, val => z_val);

   -- The fragment colour *before* the texture: interpolated for a Gouraud
   -- triangle, flat otherwise. This is what TFX combines with a texel.
   frag_rgba <= (std_logic_vector(c_val(3)) & std_logic_vector(c_val(2))
                 & std_logic_vector(c_val(1)) & std_logic_vector(c_val(0)))
                when dr_iip = '1' and tri_mode = '1' else dr_rgba;

   -- and what the back end writes. The texture, when there is one, has already
   -- been combined with the fragment by gs_texsample's TFX.
   src_rgba <= tex_colour when dr_tme = '1' else frag_rgba;

   -- ---- the texture unit ---------------------------------------------------
   --
   -- gs_texsample reads through gs_texcache, which is why this block has one
   -- memory port for texturing and not one per texel: the cache turns a raster
   -- walk's four bilinear corners into roughly one memory read per four pixels
   -- (docs/gs-texture.md).
   --
   -- **The palette loader and the cache share that one port**, and they are
   -- muxed here rather than in gs_top so the arbiter above stays at four
   -- customers. What makes that safe is an invariant rather than an arbiter:
   -- a CLUT load starts on a TEX0 *register write*, a texel fetch starts in
   -- S_DRAW, and the state machine is in exactly one of those at a time. The
   -- draw side also waits for `kc_busy` before asking for a texel -- which it
   -- has to anyway, because an indexed texture read against a half-loaded
   -- palette is wrong, not merely early.
   palette : entity work.gs_clut
      port map (clk => clk, reset => reset,
                we => kc_we, tex0 => kc_tex0, texclut => reg(16#1C#),
                rd_en => kc_rd_en, rd_ready => t_rd_ready,
                rd_addr => kc_rd_addr,
                rd_data => t_rd_data, rd_valid => t_rd_valid,
                idx => kc_idx, entry => kc_entry,
                busy => kc_busy, loads => kc_loads, unsupported => kc_unsup);

   -- **The filter comes from the LOD, not from MMAG alone.**
   --
   -- TEX1's MMAG and MMIN both exist because magnification and minification are
   -- different situations, and which one a pixel is in is what the LOD says.
   -- MMAG is one bit, because there is nothing above the base level to blend
   -- with; MMIN is three, because minification can also blend between levels.
   -- Wiring MMAG unconditionally would be right only for magnified surfaces and
   -- would quietly pick the wrong filter for every minified one -- and with a Q
   -- of zero, which is what a primitive that never wrote RGBAQ's upper half
   -- has, *every* surface is minified.
   --
   -- The arithmetic is small enough that there is no reason not to do it:
   -- log2(1/Q) is the negated exponent of Q and nothing else, the mantissa
   -- being discarded entirely, so the level is an integer before K and L touch
   -- it. LCM = 1 skips Q and takes K directly.
   --
   -- What is *not* here is the mipmap itself: MXL levels, MIPTBP and the
   -- between-level blend. The LOD selects a filter and not yet a level, and the
   -- model does the same, so the two agree -- but a texture with MXL > 0 is
   -- drawn from its base level by both, which is a limitation and not a
   -- behaviour. It stays that way until there is somewhere for the levels to
   -- come from.
   q_exp     <= unsigned(dr_q(30 downto 23));
   log2_invq <= to_signed(127, 9) when q_exp = 0
                else resize(to_signed(127, 9) - signed('0' & q_exp), 9);
   tex_lod   <= resize(signed(dr_tex1(43 downto 32)), 16) when dr_tex1(19) = '1'
                else resize(shift_left(log2_invq,
                                       to_integer(unsigned(dr_tex1(1 downto 0)))), 16)
                     + resize(signed(dr_tex1(43 downto 32)), 16);
   tx_linear <= dr_tex1(5) when tex_lod < 0
                else '1' when dr_tex1(8 downto 6) = "001"
                          or dr_tex1(8 downto 6) = "011"
                          or dr_tex1(8 downto 6) = "101"
                else '0';

   sampler : entity work.gs_texsample
      port map (clk => clk, reset => reset,
                req => tx_req,
                -- Both sides are 12.4; the interpolator carries the 14 bits the
                -- UV register has and the sampler takes 17 signed, so this is a
                -- zero-extension and nothing else. Concatenating a low '0' here
                -- instead would analyse perfectly and double every texture
                -- coordinate.
                u_fixed => signed(std_logic_vector(resize(uv_val(0), 17))),
                v_fixed => signed(std_logic_vector(resize(uv_val(1), 17))),
                frag => frag_rgba,
                tex0 => dr_tex0, clamp => dr_tclamp, linear => tx_linear,
                rd_en => tx_rd_en, rd_addr => tx_rd_addr,
                rd_data => tx_rd_data, rd_valid => tx_rd_valid,
                clut_idx => kc_idx, clut_data => kc_entry,
                done => tx_done, colour => tx_colour, busy => tx_busy);

   texcache : entity work.gs_texcache
      port map (clk => clk, reset => reset,
                c_rd_en => tx_rd_en, c_rd_addr => tx_rd_addr,
                c_rd_data => tx_rd_data, c_rd_valid => tx_rd_valid,
                c_ready => open,
                m_rd_en => tc_rd_en, m_rd_addr => tc_rd_addr,
                m_rd_data => t_rd_data, m_rd_valid => t_rd_valid,
                m_ready => t_rd_ready,
                -- Every write this rasteriser makes is snooped. The frame
                -- buffer it is filling and the texture it is reading are the
                -- same 4 MB, and rendering to a texture is an ordinary PS2
                -- idiom; a cache that did not watch this would serve the
                -- texture as it stood before the render.
                snoop_en => wr_en, snoop_addr => wr_addr,
                flush => tex_flush,
                dbg_hits => dbg_tex_hits, dbg_misses => dbg_tex_misses,
                dbg_inval => open, dbg_dropped => open);

   -- The palette loader wins the shared port whenever it is running; the
   -- invariant above says the cache is not asking when it is.
   t_rd_en   <= kc_rd_en or tc_rd_en;
   t_rd_addr <= kc_rd_addr when kc_rd_en = '1' else tc_rd_addr;

   dbg_tex_skip   <= dbg_tex_skip_i;
   dbg_clut_loads <= kc_loads;
   dbg_tex_unsup  <= kc_unsup;

   -- A triangle interpolates its depth; a sprite carries it as an integer from
   -- its second vertex and never interpolates at all, which is both what the
   -- manual says about Sprite and what the console probes found.
   src_z <= std_logic_vector(z_val) when tri_mode = '1' else dr_z;

   z_word <= std_logic_vector(shift_right(unsigned(rd_data),
                              32 * to_integer(dr_zaddr(2 downto 0)))(31 downto 0));
   -- At 16 bits two depths share a word, so which half is read is chosen the
   -- same way the colour path chooses it.
   z_old <= (x"0000" & z_word(16 * dr_zhalf + 15 downto 16 * dr_zhalf))
            when dr_z16 = '1' else z_word;

   -- A depth wider than the buffer format **clamps**; it does not wrap.  This
   -- was a mask until 2026-09-11, which is the same thing for every value that
   -- fits and the opposite for every value that does not: 0x01000000 against
   -- PSMZ24 compares as 0 after a mask and as 0xFFFFFF after a clamp, so a
   -- GREATER test flips from failing everything to passing everything.  It was
   -- invisible while the deepest generated vertex was 24 bits and the only
   -- narrow format was PSMZ24; PSMZ16 makes it central, since nearly every Z a
   -- vertex carries exceeds 16 bits.
   --
   -- Clamping is taken from PCSX2 and is *not* verified against a console; the
   -- manual gives the three Z formats and never says what happens to a value
   -- too wide for one.  hw/ps2probe asks it directly.
   src_zc <= dr_zmask when unsigned(src_z) > unsigned(dr_zmask) else src_z;

   z_pass <= '1' when dr_ztst = "10"
                      and unsigned(dr_srcz) >= unsigned(z_old and dr_zmask)
             else '1' when dr_ztst = "11"
                      and unsigned(dr_srcz) >  unsigned(z_old and dr_zmask)
             else '0';

   -- The one decision that a pixel is over.  Three ways out: the fast colour
   -- write, the read-modify-write coming back, and the depth test rejecting it
   -- -- either outright, because ZTST is NEVER, or on the comparison.
   -- A textured pixel is not finished until its texel has arrived, so the fast
   -- path out of S_DRAW has to wait for it. The NEVER case above it does not:
   -- a pixel the depth test rejects is never read, never textured and never
   -- written, which is both correct and the reason a rejected pixel costs the
   -- texture unit nothing.
   px_step <= '1' when state = S_DRAW and dr_empty = '0' and dr_y <= dr_y1
                       and ((dr_zon = '1' and dr_zdone = '0' and dr_ztst = "00")
                            or ((dr_zon = '0' or dr_zdone = '1')
                                and (dr_tme = '0' or dr_texdone = '1')
                                and dr_fbmsk = x"00000000" and dr_abe = '0'))
              else '1' when state = S_DRAWWR
              else '1' when state = S_DRAWRD and rd_valid = '1' and dr_wide = '0'
              else '1' when state = S_ZRD and rd_valid = '1' and z_pass = '0'
              else '0';

   c_adv <= px_step and tri_mode;

   -- The interpolators step on the same edge as the pixel address, which means
   -- combinationally on the cycle a pixel is committed rather than as a
   -- registered pulse.  A registered one lands on the edge that produces the
   -- *next* address, so the value the next pixel is written with is still the
   -- previous lane's: every span then repeats its first pixel and runs one
   -- behind for the rest of the scanline, a fault that looks like a half-pixel
   -- sampling error rather than like a pipeline mistake.  Mirroring the two
   -- places a span pixel commits is the price of putting the step on the right
   -- edge.  Stepping past the end of a span costs nothing, because the next
   -- scanline re-seeds the walk from its own first pixel.


   -- Combinational, because valid/ready only means anything if both sides agree
   -- on which edge the transfer happened.  A registered ready lags the state it
   -- describes by a cycle, and the producer then advances on an edge where
   -- nothing was taken -- which loses a quadword exactly when the consumer
   -- stops to do some work, which is the one case that matters.
   -- **A deny-list, so a new state defaults to "ready" -- which is wrong.**
   -- Anything not named here advertises the GIF as able to take a quadword,
   -- and a quadword taken by a state that does not consume one is not
   -- back-pressured, it is *dropped*. S_TEX was added to this block without
   -- being added here and the stream lost one quadword per textured pixel: the
   -- packets after it were parsed against the wrong tag, and the rasteriser
   -- ended up idle in S_TAG waiting for a tag the testbench believed it had
   -- already sent. Nothing reported an error, because nothing had noticed.
   --
   -- Left as a deny-list rather than inverted, because inverting it now would
   -- be a larger edit than the bug deserves -- but a state added below must be
   -- added here too unless it genuinely accepts input.
   gif_ready <= '0' when reset = '1' else
                '0' when state = S_PIXELS or state = S_DRAW or state = S_DRAWRD
                         or state = S_TEX
                         or state = S_DRAWWR
                         or state = S_SPR_CLAMP or state = S_SPR_TEST
                         or state = S_TRI_SET or state = S_TRI_CEIL
                         or state = S_TRI_GO or state = S_TRI_WAIT
                         or state = S_TRI_SCAN or state = S_TRI_CLAMP
                         or state = S_TRI_TEST or state = S_TRI_STEP
                         or state = S_TRI_SEED or state = S_ZRD
                else '1';

   dbg_reg     <= reg(to_integer(dbg_sel));
   dbg_unknown <= unknown;
   dbg_pixels  <= pixels;

   process (clk)
      variable qw      : std_logic_vector(127 downto 0);
      variable desc    : std_logic_vector(3 downto 0);
      variable w_addr  : unsigned(6 downto 0);
      variable w_data  : std_logic_vector(63 downto 0);
      variable w_do    : boolean;
      variable wa      : unsigned(19 downto 0);
      variable lane    : integer range 0 to 7;
      variable half    : integer range 0 to 1;
      variable last    : boolean;
      variable vri     : unsigned(4 downto 0);
      variable vloop   : unsigned(14 downto 0);
      variable vdone   : boolean;
      variable kick    : boolean;
      variable tkick   : boolean;
      variable ctxi    : integer range 0 to 1;
      variable ofx, ofy, ax, ay, bx, by, t : integer range -65536 to 65535;
      variable sx0, sx1, sy0, sy1          : integer range 0 to 2047;
      variable oldpx, newpx, blended       : std_logic_vector(31 downto 0);
      variable old16, new16, msk16         : std_logic_vector(15 downto 0);
      variable ylo, yhi, tya, tyb          : integer range -65536 to 65535;
      variable lft, rgt                    : integer range -4096 to 4095;
      variable ka, kb                      : integer range 0 to 2;
      variable d10x, d20x, d10y, d20y      : signed(19 downto 0);
      variable vdet                        : signed(47 downto 0);
      variable za                          : unsigned(19 downto 0);

      -- How many pixels the current step retires.  One, except on the wide
      -- write path below, where a whole memory word's worth of a span goes out
      -- at once.  A variable and not a signal, because next_px is called at the
      -- bottom of this same process and has to see what the case statement
      -- above it decided.
      variable px_run                      : integer range 1 to 4;
      variable nrun                        : integer range 1 to 4;
      variable wbe                         : unsigned(31 downto 0);
      variable ai                          : unsigned(19 downto 0);
      variable wide                        : boolean;
      variable nw                          : std_logic_vector(255 downto 0);
      variable opx, bl                     : std_logic_vector(31 downto 0);
      variable li                          : integer range 0 to 7;

      -- Retiring a pixel: the same three lines whichever way the pixel ended,
      -- so they live in one place and are reached from one condition.  px_step
      -- decides *whether*, this decides *what*, and because px_step is
      -- combinational the interpolators step on the very edge dr_x does --
      -- which is the whole reason the two are not written as one.
      procedure next_px is
      begin
         dr_zdone   <= '0';
         dr_texdone <= '0';
         -- resize before adding: dr_x + px_run can reach 2048, which wraps an
         -- eleven-bit unsigned to zero and would read as "not the end of the
         -- scanline" on the very last pixel of the widest possible span.
         if resize(dr_x, 12) + px_run > resize(dr_x1, 12) then
            -- end of a scanline: a sprite goes back to the same left edge, a
            -- triangle asks its edges for the next
            if tri_mode = '1' then
               e_step <= '1';
               if dr_y >= dr_y1 then
                  tri_mode <= '0';
                  state    <= dr_ret;
               else
                  dr_y  <= dr_y + 1;
                  state <= S_TRI_STEP;
               end if;
            else
               dr_x  <= dr_x0;
               dr_y  <= dr_y + 1;
               state <= S_DRAW;
            end if;
         else
            dr_x  <= dr_x + px_run;
            state <= S_DRAW;
         end if;
      end procedure;

      -- Everything that decides whether the Z buffer is touched at all.  ZTE=0
      -- is prohibited by the manual, so it is not a mode to model; the
      -- documented way to draw without a depth test is ALWAYS with ZMSK set,
      -- which the manual says leaves the buffer neither accessed nor updated --
      -- so that combination clears dr_zon and the buffer is not even addressed.
      -- The Z buffer has no width of its own: it is the frame buffer's.
      procedure latch_z(ctxi : integer) is
         variable zr : std_logic_vector(63 downto 0);
         variable tr : std_logic_vector(63 downto 0);
      begin
         tr := reg(16#47# + ctxi);
         zr := reg(16#4E# + ctxi);
         dr_ztst <= tr(18 downto 17);
         dr_zmsk <= zr(32);
         dr_zbp  <= unsigned(zr(8 downto 0));
         -- dr_zmask is the widest value the format can hold.  It is both the
         -- field mask and the value an out-of-range depth clamps to.
         dr_z16 <= '0';
         dr_zs  <= '0';
         case zr(27 downto 24) is
            when "0001" => dr_zmask <= x"00FFFFFF";           -- PSMZ24
            when "0010" => dr_zmask <= x"0000FFFF";            -- PSMZ16
                           dr_z16 <= '1';
            when "1010" => dr_zmask <= x"0000FFFF";            -- PSMZ16S
                           dr_z16 <= '1';
                           dr_zs  <= '1';
            when others => dr_zmask <= x"FFFFFFFF";            -- PSMZ32
         end case;
         if tr(16) = '0' then
            dr_zon <= '0';
         elsif tr(18 downto 17) = "01" and zr(32) = '1' then
            dr_zon <= '0';
         elsif zr(27 downto 24) = "0000" or zr(27 downto 24) = "0001"
            or zr(27 downto 24) = "0010" or zr(27 downto 24) = "1010" then
            dr_zon <= '1';
         else
            dr_zon <= '0';
         end if;
      end procedure;
   begin
      if rising_edge(clk) then
         -- One-cycle pulses, cleared whatever else happens this edge.
         kc_we     <= '0';
         tex_flush <= '0';

         wr_en     <= '0';
         rd_en     <= '0';
         e_step    <= '0';
         px_run    := 1;      -- one pixel a step, unless the wide path says more

         if reset = '1' then
            state    <= S_TAG;
            unknown  <= (others => '0');
            pixels   <= (others => '0');
            x_active <= '0';
            tri_mode <= '0';
            e_start  <= '0';
            v_cnt    <= (others => '0');
            dr_empty <= '1';
            px_n     <= (others => '0');
            reg      <= (others => (others => '0'));

         else
            case state is

               when S_TAG =>
                  if gif_valid = '1' then
                     qw := gif_data;
                     t_nloop <= unsigned(qw(14 downto 0));
                     t_eop   <= qw(15);
                     t_regs  <= qw(127 downto 64);
                     if qw(63 downto 60) = "0000" then
                        t_nreg <= to_unsigned(16, 5);
                     else
                        t_nreg <= resize(unsigned(qw(63 downto 60)), 5);
                     end if;
                     t_loop <= (others => '0');
                     t_ri   <= (others => '0');
                     -- PRE loads PRIM ahead of the data, except in IMAGE mode
                     if qw(46) = '1' and qw(59 downto 58) /= "10" then
                        reg(0) <= std_logic_vector(resize(unsigned(qw(57 downto 47)), 64));
                     end if;
                     if unsigned(qw(14 downto 0)) = 0 then
                        state <= S_TAG;            -- an empty packet is just a tag
                     else
                        case qw(59 downto 58) is
                           when "00"   => state <= S_PACKED;
                           when "01"   => state <= S_REGLIST;
                           when "10"   => state <= S_IMAGE;
                           when others => state <= S_TAG;    -- "disable"
                        end case;
                     end if;
                  end if;

               when S_PACKED =>
                  if gif_valid = '1' then
                     qw   := gif_data;
                     desc := t_regs(to_integer(t_ri) * 4 + 3 downto to_integer(t_ri) * 4);

                     -- One descriptor decodes to at most one register write.
                     -- Keeping that a single path rather than a case per
                     -- register is what makes the A+D form -- which carries its
                     -- own address -- fall out as an ordinary case rather than
                     -- a second mechanism.
                     kick   := false;
                     tkick  := false;
                     w_do   := true;
                     w_addr := to_unsigned(0, 7);
                     w_data := (others => '0');
                     case desc is
                        when x"0" => w_addr := to_unsigned(16#00#, 7);
                                     w_data := std_logic_vector(resize(unsigned(qw(10 downto 0)), 64));
                        when x"1" => w_addr := to_unsigned(16#01#, 7);
                                     w_data := x"00000000" & qw(103 downto 96) & qw(71 downto 64)
                                               & qw(39 downto 32) & qw(7 downto 0);
                        when x"2" => w_addr := to_unsigned(16#02#, 7); w_data := qw(63 downto 0);
                        when x"3" => w_addr := to_unsigned(16#03#, 7);
                                     w_data := x"00000000" & "00" & qw(45 downto 32)
                                               & "00" & qw(13 downto 0);
                        when x"4" => w_addr := to_unsigned(16#04#, 7);
                                     w_data := qw(107 downto 100) & qw(91 downto 68)
                                               & qw(47 downto 32) & qw(15 downto 0);
                        when x"5" => w_addr := to_unsigned(16#05#, 7);
                                     w_data := qw(95 downto 64)
                                               & qw(47 downto 32) & qw(15 downto 0);
                        when x"6" | x"7" | x"8" | x"9" | x"A" =>
                                     w_addr := resize(unsigned(desc), 7);
                                     w_data := qw(63 downto 0);
                        when x"C" => w_addr := to_unsigned(16#0C#, 7);
                                     w_data := qw(107 downto 100) & qw(91 downto 68)
                                               & qw(47 downto 32) & qw(15 downto 0);
                        when x"D" => w_addr := to_unsigned(16#0D#, 7);
                                     w_data := qw(95 downto 64)
                                               & qw(47 downto 32) & qw(15 downto 0);
                        when x"E" => w_addr := unsigned(qw(70 downto 64));
                                     w_data := qw(63 downto 0);
                        when others => w_do := false;      -- 0xF is NOP, 0xB reserved
                     end case;
                     if desc = x"B" then
                        unknown <= unknown + 1;
                     end if;

                     if w_do then
                        if not defined(w_addr) then
                           unknown <= unknown + 1;
                        else
                           reg(to_integer(w_addr)) <= w_data;
                           if w_addr = 16#53# and w_data(1 downto 0) = "00" then
                              -- TRXDIR: host-to-local.  The set-up registers
                              -- were written on earlier cycles, so reading them
                              -- here reads what the host put there.
                              x_active <= '1';
                              x_bp   <= unsigned(reg(16#50#)(45 downto 32));
                              x_bw   <= unsigned(reg(16#50#)(53 downto 48));
                              x_psm  <= unsigned(reg(16#50#)(61 downto 56));
                              x_x0   <= unsigned(reg(16#51#)(42 downto 32));
                              x_cx   <= unsigned(reg(16#51#)(42 downto 32));
                              x_cy   <= unsigned(reg(16#51#)(58 downto 48));
                              x_w    <= unsigned(reg(16#52#)(11 downto 0));
                              x_left <= resize(unsigned(reg(16#52#)(11 downto 0))
                                               * unsigned(reg(16#52#)(43 downto 32)), 24);
                           elsif w_addr = 16#54# then
                              -- HWREG: two PSMCT32 pixels of transfer data
                              px_data <= x"0000000000000000" & w_data;
                              px_n    <= to_unsigned(2, 3);
                           elsif w_addr = 16#06# or w_addr = 16#07# then
                              -- A palette reloads on the TEX0 *write*, not at
                              -- draw time. A load deferred to the draw would
                              -- read local memory as it stands then, so a
                              -- primitive rendering into the page its palette
                              -- came from would see its own output.
                              kc_we   <= '1';
                              kc_tex0 <= w_data;
                           elsif w_addr = 16#3F# then
                              -- TEXFLUSH carries no data: writing it is the
                              -- whole instruction. It is what content issues
                              -- after rendering into a page it is about to
                              -- texture from.
                              tex_flush <= '1';
                           elsif w_addr = 0 then
                              v_cnt <= (others => '0');   -- PRIM restarts it
                           elsif w_addr = 4 or w_addr = 5
                                 or w_addr = 16#0C# or w_addr = 16#0D# then
                              v0_x <= v1_x;  v0_y <= v1_y;  v0_c <= v1_c;
                              v1_x <= v2_x;  v1_y <= v2_y;  v1_c <= v2_c;
                              v0_z <= v1_z;  v1_z <= v2_z;
                              v0_uv <= v1_uv; v1_uv <= v2_uv;
                              v2_x <= unsigned(w_data(15 downto 0));
                              v2_y <= unsigned(w_data(31 downto 16));
                              v2_c <= reg(1)(31 downto 0);
                              v2_z <= w_data(63 downto 32);
                              v2_uv <= reg(3)(31 downto 0);
                              if v_cnt = 0 then          -- the fan's anchor
                                 vf_x <= unsigned(w_data(15 downto 0));
                                 vf_y <= unsigned(w_data(31 downto 16));
                                 vf_c <= reg(1)(31 downto 0);
                                 vf_z <= w_data(63 downto 32);
                                 vf_uv <= reg(3)(31 downto 0);
                              end if;
                              if v_cnt < 7 then
                                 v_cnt <= v_cnt + 1;
                              end if;
                              -- XYZ2 and XYZF2 kick the primitive; XYZ3 and
                              -- XYZF3 only queue the vertex.  A sprite needs two
                              -- vertices, a triangle three, and the counter here
                              -- is the value *before* this one is counted.
                              if w_addr = 4 or w_addr = 5 then
                                 if reg(0)(2 downto 0) = "110" and v_cnt >= 1 then
                                    kick := true;         -- SPRITE
                                 elsif (reg(0)(2 downto 0) = "011"
                                        or reg(0)(2 downto 0) = "100"
                                        or reg(0)(2 downto 0) = "101")
                                       and v_cnt >= 2 then
                                    tkick := true;        -- TRIANGLE / STRIP / FAN
                                 end if;
                              end if;
                           end if;
                        end if;
                     end if;

                     -- advance the descriptor and loop counters together
                     last := false;
                     if t_ri + 1 = t_nreg then
                        t_ri <= (others => '0');
                        if t_loop + 1 = t_nloop then
                           last := true;
                        else
                           t_loop <= t_loop + 1;
                        end if;
                     else
                        t_ri <= t_ri + 1;
                     end if;

                     if kick then
                        -- The two vertices are the one already queued and the
                        -- one arriving now; v1_* still holds the old value on
                        -- this edge, which is what makes that work.
                        ctxi := 0;
                        if reg(0)(9) = '1' then ctxi := 1; end if;
                        ofx := to_integer(unsigned(reg(16#18# + ctxi)(15 downto 0)));
                        ofy := to_integer(unsigned(reg(16#18# + ctxi)(47 downto 32)));
                        ax := (to_integer(v2_x) - ofx) / 16;
                        ay := (to_integer(v2_y) - ofy) / 16;
                        bx := (to_integer(unsigned(w_data(15 downto 0))) - ofx) / 16;
                        by := (to_integer(unsigned(w_data(31 downto 16))) - ofy) / 16;
                        if ax > bx then t := ax; ax := bx; bx := t; end if;
                        if ay > by then t := ay; ay := by; by := t; end if;
                        -- the corners and the scissor, held for the clamp that
                        -- now happens on the next edge
                        k_ax  <= ax;      k_ay  <= ay;
                        k_bx  <= bx - 1;  k_by  <= by - 1;
                        k_sx0 <= to_integer(unsigned(reg(16#40# + ctxi)(10 downto 0)));
                        k_sx1 <= to_integer(unsigned(reg(16#40# + ctxi)(26 downto 16)));
                        k_sy0 <= to_integer(unsigned(reg(16#40# + ctxi)(42 downto 32)));
                        k_sy1 <= to_integer(unsigned(reg(16#40# + ctxi)(58 downto 48)));
                        -- A textured sprite is refused here for now, by the
                        -- same gate a frame-buffer format this rasteriser
                        -- cannot write uses: its UV ramp is a plane and the
                        -- interpolators would take it, but this path has no
                        -- per-scanline seed state to pulse them with.
                        if fb_drawable(reg(16#4C# + ctxi)(29 downto 24))
                           and reg(0)(4) = '0' then
                           k_ok <= '1';
                        else
                           k_ok <= '0';
                        end if;

                        dr_fbp   <= unsigned(reg(16#4C# + ctxi)(8 downto 0));
                        dr_fbw   <= unsigned(reg(16#4C# + ctxi)(21 downto 16));
                        -- PSMCT24 is 24 bits inside a 32-bit word, addressed
                        -- exactly as PSMCT32 is; its top byte is not part of the
                        -- pixel and survives the write, which is what FBMSK
                        -- already means, so it is expressed as one.
                        if reg(16#4C# + ctxi)(29 downto 24) = "000001" then
                           dr_fbmsk <= reg(16#4C# + ctxi)(63 downto 32) or x"FF000000";
                        else
                           dr_fbmsk <= reg(16#4C# + ctxi)(63 downto 32);
                        end if;
                        dr_fb16 <= '0';
                        dr_fbs  <= '0';
                        if reg(16#4C# + ctxi)(29 downto 24) = "000010" then
                           dr_fb16 <= '1';
                        elsif reg(16#4C# + ctxi)(29 downto 24) = "001010" then
                           dr_fb16 <= '1';
                           dr_fbs  <= '1';
                        end if;
                        dr_rgba  <= reg(1)(31 downto 0);
                        dr_abe   <= reg(0)(6);
                        dr_alpha <= reg(16#42# + ctxi)(7 downto 0);
                        dr_fix   <= unsigned(reg(16#42# + ctxi)(39 downto 32));
                        dr_clamp <= reg(16#46#)(0);
                        latch_z(ctxi);
                        -- a Sprite's depth is the second vertex's, carried as
                        -- an integer: there is no DDA behind it at all
                        dr_z     <= w_data(63 downto 32);
                        dr_zdone <= '0';
                        -- A sprite's UV ramp is a plane and the interpolators
                        -- would take it, but this path has no per-scanline seed
                        -- state to pulse them with. Until it does, a textured
                        -- sprite is counted and drawn untextured is *not* the
                        -- choice made: dr_tme stays low and the count says so,
                        -- so a test sees a refusal rather than a wrong colour.
                        dr_tme <= '0';
                        if reg(0)(4) = '1' then
                           dbg_tex_skip_i <= dbg_tex_skip_i + 1;
                        end if;
                        v_cnt  <= (others => '0');
                        dr_ret <= S_PACKED;
                        if last then dr_ret <= S_TAG; end if;
                        state  <= S_SPR_CLAMP;
                     elsif tkick then
                        ctxi := 0;
                        if reg(0)(9) = '1' then ctxi := 1; end if;
                        ofx := to_integer(unsigned(reg(16#18# + ctxi)(15 downto 0)));
                        ofy := to_integer(unsigned(reg(16#18# + ctxi)(47 downto 32)));
                        -- a fan takes its first vertex from the anchor; a list
                        -- and a strip take the oldest of the three in flight
                        if reg(0)(2 downto 0) = "101" then
                           t_x(0) <= to_signed(to_integer(vf_x) - ofx, 18);
                           t_y(0) <= to_signed(to_integer(vf_y) - ofy, 18);
                           t_c(0) <= vf_c;
                           t_uv(0) <= vf_uv;
                        else
                           t_x(0) <= to_signed(to_integer(v1_x) - ofx, 18);
                           t_y(0) <= to_signed(to_integer(v1_y) - ofy, 18);
                           t_c(0) <= v1_c;
                           t_uv(0) <= v1_uv;
                        end if;
                        t_x(1) <= to_signed(to_integer(v2_x) - ofx, 18);
                        t_y(1) <= to_signed(to_integer(v2_y) - ofy, 18);
                        t_c(1) <= v2_c;
                        t_uv(1) <= v2_uv;
                        t_x(2) <= to_signed(to_integer(unsigned(w_data(15 downto 0))) - ofx, 18);
                        t_y(2) <= to_signed(to_integer(unsigned(w_data(31 downto 16))) - ofy, 18);
                        t_c(2) <= reg(1)(31 downto 0);
                        t_uv(2) <= reg(3)(31 downto 0);
                        dr_iip <= reg(0)(3);
                        -- The texture context, latched with everything else:
                        -- TEX0 written part-way through a primitive must not
                        -- change the primitive already being drawn.
                        --
                        -- PRIM.FST = 0 asks for STQ and the per-pixel divide,
                        -- which is not built. The primitive is counted and not
                        -- drawn rather than drawn with a coordinate nothing
                        -- produced -- the same rule the 16-bit CLUT layout is
                        -- under, and the alternative is a picture that is
                        -- wrong without saying so.
                        if reg(0)(4) = '1' and reg(0)(8) = '1' then
                           dr_tme  <= '1';
                           tex_ref <= '0';
                        elsif reg(0)(4) = '1' then
                           -- Refused, and refused means **not drawn**. Drawing
                           -- it untextured instead would put a flat-shaded
                           -- triangle where a textured one belongs, which is a
                           -- wrong picture rather than a missing one -- and a
                           -- wrong picture is the harder of the two to notice.
                           dr_tme  <= '0';
                           tex_ref <= '1';
                           dbg_tex_skip_i <= dbg_tex_skip_i + 1;
                        else
                           dr_tme  <= '0';
                           tex_ref <= '0';
                        end if;
                        dr_q      <= reg(1)(63 downto 32);
                        dr_tex0   <= reg(16#06# + ctxi);
                        dr_tex1   <= reg(16#14# + ctxi);
                        dr_tclamp <= reg(16#08# + ctxi);
                        if reg(0)(2 downto 0) = "101" then
                           t_z(0) <= vf_z;
                        else
                           t_z(0) <= v1_z;
                        end if;
                        t_z(1) <= v2_z;
                        t_z(2) <= w_data(63 downto 32);
                        latch_z(ctxi);
                        dr_zdone <= '0';
                        dr_fbp   <= unsigned(reg(16#4C# + ctxi)(8 downto 0));
                        dr_fbw   <= unsigned(reg(16#4C# + ctxi)(21 downto 16));
                        -- PSMCT24 is 24 bits inside a 32-bit word, addressed
                        -- exactly as PSMCT32 is; its top byte is not part of the
                        -- pixel and survives the write, which is what FBMSK
                        -- already means, so it is expressed as one.
                        if reg(16#4C# + ctxi)(29 downto 24) = "000001" then
                           dr_fbmsk <= reg(16#4C# + ctxi)(63 downto 32) or x"FF000000";
                        else
                           dr_fbmsk <= reg(16#4C# + ctxi)(63 downto 32);
                        end if;
                        dr_fb16 <= '0';
                        dr_fbs  <= '0';
                        if reg(16#4C# + ctxi)(29 downto 24) = "000010" then
                           dr_fb16 <= '1';
                        elsif reg(16#4C# + ctxi)(29 downto 24) = "001010" then
                           dr_fb16 <= '1';
                           dr_fbs  <= '1';
                        end if;
                        dr_rgba  <= reg(1)(31 downto 0);
                        dr_abe   <= reg(0)(6);
                        dr_alpha <= reg(16#42# + ctxi)(7 downto 0);
                        dr_fix   <= unsigned(reg(16#42# + ctxi)(39 downto 32));
                        dr_clamp <= reg(16#46#)(0);
                        if not fb_drawable(reg(16#4C# + ctxi)(29 downto 24))
                           or (reg(0)(4) = '1' and reg(0)(8) = '0') then
                           dr_empty <= '1';            -- a format this
                                                       -- rasteriser cannot
                                                       -- write, or a texture
                                                       -- mode it cannot sample
                        else
                           dr_empty <= '0';
                        end if;
                        -- a list starts over; a strip and a fan keep two
                        if reg(0)(2 downto 0) = "011" then
                           v_cnt <= (others => '0');
                        else
                           v_cnt <= to_unsigned(2, 3);
                        end if;
                        dr_ret <= S_PACKED;
                        if last then dr_ret <= S_TAG; end if;
                        state  <= S_TRI_SET;
                     elsif w_do and defined(w_addr) and w_addr = 16#54# then
                        px_ret <= S_PACKED;
                        if last then px_ret <= S_TAG; end if;
                        state  <= S_PIXELS;
                     elsif last then
                        state <= S_TAG;
                     end if;
                  end if;

               when S_REGLIST =>
                  -- Two registers per quadword.  The descriptor list is walked
                  -- once per register, not once per quadword: with NREG = 1 the
                  -- second half of a quadword is the *next loop iteration* and
                  -- uses descriptor 0 again.  Indexing it as descriptor 1 reads
                  -- past the end of the list and writes whatever register
                  -- happens to be named there, which is invisible until a
                  -- packet uses a short list -- and a short list is the common
                  -- case, since that is what REGLIST is for.
                  --
                  -- A+D is not meaningful here: there is no room for an
                  -- address, so it is counted rather than guessed at.
                  if gif_valid = '1' then
                     qw    := gif_data;
                     vri   := t_ri;
                     vloop := t_loop;
                     vdone := false;
                     for h in 0 to 1 loop
                        if not vdone then
                           desc := t_regs(to_integer(vri) * 4 + 3
                                          downto to_integer(vri) * 4);
                           if desc = x"E" or desc = x"B" then
                              unknown <= unknown + 1;
                           elsif desc /= x"F" then
                              if defined(resize(unsigned(desc), 7)) then
                                 reg(to_integer(unsigned(desc))) <=
                                    qw(64 * h + 63 downto 64 * h);
                              else
                                 unknown <= unknown + 1;
                              end if;
                           end if;
                           if vri + 1 = t_nreg then
                              vri := (others => '0');
                              if vloop + 1 = t_nloop then
                                 vdone := true;
                              else
                                 vloop := vloop + 1;
                              end if;
                           else
                              vri := vri + 1;
                           end if;
                        end if;
                     end loop;
                     t_ri   <= vri;
                     t_loop <= vloop;
                     if vdone then
                        state <= S_TAG;
                     end if;
                  end if;

               when S_IMAGE =>
                  if gif_valid = '1' then
                     px_data <= gif_data;
                     px_n    <= to_unsigned(4, 3);
                     if t_loop + 1 = t_nloop then
                        px_ret <= S_TAG;
                     else
                        px_ret <= S_IMAGE;
                     end if;
                     t_loop <= t_loop + 1;
                     state  <= S_PIXELS;
                  end if;

               when S_TRI_SET =>
                  -- Order each edge so y increases, note the scanlines it spans,
                  -- and start all three at the triangle's first scanline.  A
                  -- horizontal edge spans nothing and is left with an empty
                  -- range rather than special-cased: its divider divides by zero
                  -- and produces nonsense, which is harmless because the span
                  -- test never selects it.
                  ylo := to_integer(t_y(0));
                  yhi := ylo;
                  for k in 1 to 2 loop
                     if to_integer(t_y(k)) < ylo then ylo := to_integer(t_y(k)); end if;
                     if to_integer(t_y(k)) > yhi then yhi := to_integer(t_y(k)); end if;
                  end loop;
                  q_ylo <= ylo;
                  q_yhi <= yhi;
                  q_sy0 <= to_integer(unsigned(reg(16#40# + ctxi)(42 downto 32)));
                  q_sy1 <= to_integer(unsigned(reg(16#40# + ctxi)(58 downto 48)));
                  for k in 0 to 2 loop
                     ka := k;
                     kb := (k + 1) mod 3;
                     if t_y(ka) <= t_y(kb) then
                        e_x0(k) <= t_x(ka); e_y0(k) <= t_y(ka);
                        e_x1(k) <= t_x(kb); e_y1(k) <= t_y(kb);
                        e_yst(k) <= resize(shift_right(t_y(ka) + 15, 4), 13);
                        e_yen(k) <= resize(shift_right(t_y(kb) + 15, 4), 13);
                     else
                        e_x0(k) <= t_x(kb); e_y0(k) <= t_y(kb);
                        e_x1(k) <= t_x(ka); e_y1(k) <= t_y(ka);
                        e_yst(k) <= resize(shift_right(t_y(kb) + 15, 4), 13);
                        e_yen(k) <= resize(shift_right(t_y(ka) + 15, 4), 13);
                     end if;
                  end loop;
                  -- The plane the four colour channels share.  Its determinant
                  -- is handed over already positive, with c_sgn saying whether
                  -- it had to be negated, so each channel's divider only ever
                  -- sees a positive denominator -- one floor fixup then covers
                  -- both winding orders instead of two.
                  d10x := resize(t_x(1), 20) - resize(t_x(0), 20);
                  d20x := resize(t_x(2), 20) - resize(t_x(0), 20);
                  d10y := resize(t_y(1), 20) - resize(t_y(0), 20);
                  d20y := resize(t_y(2), 20) - resize(t_y(0), 20);
                  vdet := resize(d10x * d20y, 48) - resize(d20x * d10y, 48);
                  c_dx10 <= d10x;  c_dx20 <= d20x;
                  c_dy10 <= d10y;  c_dy20 <= d20y;
                  if vdet < 0 then
                     c_det <= -vdet;
                     c_sgn <= '1';
                  else
                     c_det <= vdet;
                     c_sgn <= '0';
                  end if;
                  if vdet /= 0 then
                     q_detnz <= '1';
                  else
                     q_detnz <= '0';
                  end if;
                  state <= S_TRI_CEIL;

               -- ceil(y/16) is floor((y+15)/16), and floor is an arithmetic
               -- shift.  Integer division truncates toward zero instead, which
               -- differs as soon as a coordinate is negative -- and a vertex
               -- above or left of XYOFFSET is exactly that.
               --
               -- The scissor clamp rides along here rather than waiting for a
               -- state of its own: both of its comparisons take the value this
               -- state has just produced, so they are a carry chain after a
               -- shift, not after a three-way minimum as well.
               when S_TRI_CEIL =>
                  tya := to_integer(shift_right(to_signed(q_ylo + 15, 24), 4));
                  tyb := to_integer(shift_right(to_signed(q_yhi + 15, 24), 4)) - 1;
                  if tya < q_sy0 then tya := q_sy0; end if;
                  if tyb > q_sy1 then tyb := q_sy1; end if;
                  q_tya <= tya;
                  q_tyb <= tyb;
                  state <= S_TRI_GO;

               -- Did anything survive, and start the interpolators.  This is
               -- one comparison on two registered values; before the split it
               -- was that comparison on top of everything above, and its
               -- fan-out to a register bank's reset pins was every failing
               -- endpoint in the design.
               when S_TRI_GO =>
                  if q_tya > q_tyb or q_tya < 0 then
                     dr_empty <= '1';
                     dr_y    <= (others => '0');
                     dr_y1   <= (others => '0');
                     dr_ytop <= (others => '0');
                  else
                     dr_y    <= to_unsigned(q_tya, 11);
                     dr_y1   <= to_unsigned(q_tyb, 11);
                     -- the primitive's first scanline, which the depth bias's
                     -- y term is exempt on
                     dr_ytop <= to_unsigned(q_tya, 11);
                  end if;
                  e_ytop  <= to_signed(q_tya, 14);
                  e_start <= '1';
                  -- A degenerate triangle has no plane; it also covers no
                  -- pixels, so the interpolators are simply left alone rather
                  -- than started on a division by zero.
                  if q_detnz = '1' then
                     if dr_iip = '1' then
                        c_start <= '1';
                     end if;
                     if dr_tme = '1' then
                        uv_start <= '1';
                     end if;
                     if dr_zon = '1' then
                        z_start <= '1';
                     end if;
                  end if;

                  tri_mode <= '1';
                  state    <= S_TRI_WAIT;

               when S_TRI_WAIT =>
                  e_start  <= '0';
                  c_start  <= '0';
                  uv_start <= '0';
                  z_start  <= '0';
                  if e_start = '0' and e_busy = "000"
                     and c_start = '0' and c_busy = "0000"
                     and uv_start = '0' and uv_busy = "00"
                     and z_start = '0' and z_busy = '0' then
                     if dr_empty = '1' then
                        tri_mode <= '0';
                        state    <= dr_ret;
                     else
                        state <= S_TRI_SCAN;
                     end if;
                  end if;

               when S_TRI_STEP =>
                  -- e_step was raised on the previous edge, so the edges update
                  -- at the end of *this* cycle.  Reading them in the same cycle
                  -- the step is raised gives the previous scanline's span, which
                  -- draws a triangle one pixel too wide on every line but the
                  -- first -- a shape that is still a triangle, and so the kind
                  -- of wrong that survives a look at the picture.
                  state <= S_TRI_SCAN;

               when S_TRI_SEED =>
                  c_sstart  <= '0';
                  uv_sstart <= '0';
                  z_sstart  <= '0';
                  if c_sstart = '0' and c_sbusy = "0000"
                     and uv_sstart = '0' and uv_sbusy = "00"
                     and z_sstart = '0' and z_sbusy = '0' then
                     state <= S_DRAW;
                  end if;

               -- Finding the span, clamping it to the scissor and deciding
               -- whether anything of it survived used to be one state.  That
               -- put the three edge DDAs' outputs through a three-way minimum,
               -- a three-way maximum, two clamps and three comparisons in one
               -- clock: twenty-nine logic levels, and the longest path in the
               -- part once the pixel path and the plane numerators had been
               -- split off.  It is three states now.  The cost is two extra
               -- clocks per scanline against a scanline hundreds of pixels
               -- long, which is the same trade the sprite setup took and the
               -- same reason: this is per primitive, not per pixel.
               when S_TRI_SCAN =>
                  -- Exactly two edges span any scanline, and the span runs
                  -- between their two ceil(x) values, half-open.
                  lft := 4095;
                  rgt := -4096;
                  for k in 0 to 2 loop
                     if e_yst(k) <= signed(resize(dr_y, 13))
                        and signed(resize(dr_y, 13)) < e_yen(k) then
                        if to_integer(e_x(k)) < lft then lft := to_integer(e_x(k)); end if;
                        if to_integer(e_x(k)) > rgt then rgt := to_integer(e_x(k)); end if;
                     end if;
                  end loop;
                  q_lft <= lft;
                  q_rgt <= rgt - 1;
                  q_sx0 <= to_integer(unsigned(reg(16#40# + ctxi)(10 downto 0)));
                  q_sx1 <= to_integer(unsigned(reg(16#40# + ctxi)(26 downto 16)));
                  state <= S_TRI_CLAMP;

               when S_TRI_CLAMP =>
                  if q_lft < q_sx0 then q_lft <= q_sx0; end if;
                  if q_rgt > q_sx1 then q_rgt <= q_sx1; end if;
                  state <= S_TRI_TEST;

               when S_TRI_TEST =>
                  if q_lft > q_rgt or q_lft < 0 or q_rgt < 0 then
                     e_step <= '1';
                     if dr_y >= dr_y1 then
                        tri_mode <= '0';
                        state    <= dr_ret;
                     else
                        dr_y  <= dr_y + 1;
                        state <= S_TRI_STEP;
                     end if;
                  else
                     dr_x  <= to_unsigned(q_lft, 11);
                     dr_x0 <= to_unsigned(q_lft, 11);
                     dr_x1 <= to_unsigned(q_rgt, 11);
                     if dr_iip = '1' or dr_zon = '1' or dr_tme = '1' then
                        -- Every span is seeded at its own first pixel, which is
                        -- also where the blocking starts: lane 0 of block 0 is
                        -- the leftmost pixel of this scanline, not of the
                        -- triangle and not of an aligned x.
                        --
                        -- **dr_tme belongs in this condition and not only in
                        -- the pulses below.** A flat, depth-less, textured
                        -- triangle sets neither of the other two, so without it
                        -- the whole seeding step is skipped: c_sx and c_sy are
                        -- never written, no seed pulse is issued, and the UV
                        -- interpolators sit at zero for the entire primitive.
                        -- The symptom is a triangle painted in one texel --
                        -- which reads as a texture-addressing fault rather than
                        -- as a missing state transition.
                        c_sx <= to_signed(q_lft, 13);
                        c_sy <= signed(resize(dr_y, 13));
                        if dr_iip = '1' then c_sstart <= '1'; end if;
                        if dr_tme = '1' then uv_sstart <= '1'; end if;
                        if dr_zon = '1' then z_sstart <= '1'; end if;
                        state <= S_TRI_SEED;
                     else
                        state <= S_DRAW;
                     end if;
                  end if;

               -- Clamp the sprite's corners against the scissor.  Four
               -- comparisons on registers, and nothing else on the edge.
               when S_SPR_CLAMP =>
                  if k_ax < k_sx0 then k_ax <= k_sx0; end if;
                  if k_ay < k_sy0 then k_ay <= k_sy0; end if;
                  if k_bx > k_sx1 then k_bx <= k_sx1; end if;
                  if k_by > k_sy1 then k_by <= k_sy1; end if;
                  state <= S_SPR_TEST;

               -- Did anything survive?  The test is on the clamped corners, so
               -- it has to wait for them.
               when S_SPR_TEST =>
                  dr_x0 <= to_unsigned(k_ax, 11);
                  dr_x  <= to_unsigned(k_ax, 11);
                  dr_x1 <= to_unsigned(k_bx, 11);
                  dr_y  <= to_unsigned(k_ay, 11);
                  dr_y1 <= to_unsigned(k_by, 11);
                  if k_ax > k_bx or k_ay > k_by or k_ax < 0 or k_ay < 0
                     or k_ok = '0' then
                     dr_empty <= '1';      -- nothing to draw, or a format this
                                           -- rasteriser cannot write
                  else
                     dr_empty <= '0';
                  end if;
                  state <= S_DRAW;

               when S_DRAW =>
                  -- Four consecutive pixels of a span share one 256-bit memory
                  -- word, and that is true of the depth buffer as much as of
                  -- the colour one, so both steps of a pixel can take four at a
                  -- time.  The restrictions are the same for both -- a flat
                  -- primitive and a 32-bit buffer -- plus, for depth, that the
                  -- test is one that needs no read: ZTST = ALWAYS writes every
                  -- pixel, so there is no per-lane pass mask to build.
                  -- GEQUAL and GREATER stay one at a time until there is.
                  -- and never for a textured primitive: each of the four
                  -- lanes needs its own texel, and this block fetches one at a
                  -- time. tri_mode already excludes every textured primitive
                  -- this rasteriser draws, so the term is belt and braces until
                  -- the sprite path gains UV -- at which point it stops being.
                  wide := dr_tme = '0' and tri_mode = '0' and dr_fb16 = '0'
                          and (dr_zon = '0'
                               or (dr_ztst = "01" and dr_z16 = '0'));
                  if wide then
                     nrun := 4 - to_integer(dr_x(1 downto 0));
                     if resize(dr_x, 13) + nrun > resize(dr_x1, 13) then
                        nrun := to_integer(dr_x1 - dr_x) + 1;
                     end if;
                  else
                     nrun := 1;
                  end if;
                  if dr_empty = '1' or dr_y > dr_y1 then
                     state <= dr_ret;
                  elsif dr_tme = '1' and dr_texdone = '0'
                        and (dr_zon = '0' or dr_zdone = '1') then
                     -- After the depth test and before anything is read or
                     -- blended. A pixel the test rejected never gets here, so
                     -- it costs no texel -- which is the same ordering rule the
                     -- depth test itself is under, one stage further on.
                     --
                     -- **Waiting for the palette is a branch of its own, not a
                     -- term in this condition.** The palette shares this
                     -- block's texture port and answers the sampler's index, so
                     -- a fetch started under a half-loaded CLUT would be wrong
                     -- rather than merely early -- but putting `kc_busy = '0'`
                     -- into the condition above makes the *elsif* fall through
                     -- to the colour write instead, which draws the pixel with
                     -- whatever texel the previous one happened to leave in
                     -- tex_colour. That is a textured primitive painted in one
                     -- stale colour, and it looks like a cache fault.
                     if kc_busy = '1' then
                        null;              -- hold here; the palette is loading
                     else
                        tx_req <= '1';
                        state  <= S_TEX;
                     end if;
                  elsif dr_zon = '1' and dr_zdone = '0' then
                     -- The depth test comes first, and a pixel it rejects is
                     -- never read, never blended and never written.  Doing it
                     -- after the colour would still produce the right picture
                     -- most of the time and the wrong one wherever FBMSK or the
                     -- blender touches a pixel that should not have survived.
                     if dr_z16 = '1' then
                        za   := pix_addr16_page(dr_zbp, dr_fbw, dr_x, dr_y,
                                                dr_zs, '1');
                        half := fb16_half(dr_x);
                     else
                        za   := pix_addr_page(dr_zbp, dr_fbw, dr_x, dr_y, '1');
                        half := 0;
                     end if;
                     lane := to_integer(za(2 downto 0));
                     dr_zaddr <= za;
                     dr_zhalf <= half;
                     if dr_ztst = "00" then
                        null;                 -- NEVER: px_step retires it
                     elsif dr_ztst = "01" then
                        -- ALWAYS passes without reading, but still writes.
                        dr_zdone <= '1';
                        if dr_zmsk = '0' then
                           wr_en   <= '1';
                           wr_addr <= std_logic_vector(za(19 downto 3));
                           if dr_z16 = '1' then
                              wr_data <= spread16(src_zc(15 downto 0));
                              wr_be   <= std_logic_vector(shift_left(
                                            resize(unsigned'("11"), 32),
                                            4 * lane + 2 * half));
                           elsif not wide then
                              wr_data <= spread32(src_zc);
                              wr_be   <= std_logic_vector(shift_left(
                                            resize(unsigned(zbe(dr_zmask)), 32), 4 * lane));
                           else
                              -- A sprite's depth is one number for the whole
                              -- primitive, so the four lanes of a word take the
                              -- same value and only the enables differ.
                              --
                              -- The depth block exclusive-or is passed here for
                              -- consistency with the address above, and makes no
                              -- difference: it flips bits 3 and 4 of the block
                              -- index and the lane is the low *three* bits, so
                              -- the two forms give the same lane for every
                              -- pixel.  Measured, not assumed -- passing '0'
                              -- instead is a mutation the directed test cannot
                              -- tell apart, and this is why.
                              wbe := (others => '0');
                              for i in 0 to 3 loop
                                 if i < nrun then
                                    ai := pix_addr_page(dr_zbp, dr_fbw,
                                                        dr_x + i, dr_y, '1');
                                    wbe := wbe or shift_left(
                                              resize(unsigned(zbe(dr_zmask)), 32),
                                              4 * to_integer(ai(2 downto 0)));
                                 end if;
                              end loop;
                              wr_data <= spread32(src_zc);
                              wr_be   <= std_logic_vector(wbe);
                           end if;
                        end if;
                     else
                        rd_en   <= '1';
                        rd_addr <= std_logic_vector(za(19 downto 3));
                        dr_srcz <= src_zc;
                        state   <= S_ZRD;
                     end if;
                  else
                     if dr_fb16 = '1' then
                        wa   := pix_addr16_page(dr_fbp, dr_fbw, dr_x, dr_y, dr_fbs);
                        half := fb16_half(dr_x);
                     else
                        wa   := pix_addr_page(dr_fbp, dr_fbw, dr_x, dr_y);
                        half := 0;
                     end if;
                     lane := to_integer(wa(2 downto 0));
                     if dr_fbmsk = x"00000000" and dr_abe = '0' then
                        -- nothing to preserve, so no read is needed: the common
                        -- case stays one pixel per clock.  At 16 bits the byte
                        -- enables protect the *other* pixel sharing the word,
                        -- so this path stays available rather than forcing a
                        -- read-modify-write on every 16-bit pixel.
                        wr_en   <= '1';
                        wr_addr <= std_logic_vector(wa(19 downto 3));
                        if dr_fb16 = '1' then
                           wr_data <= spread16(pack16(src_rgba));
                           wr_be   <= std_logic_vector(shift_left(
                                         resize(unsigned'("11"), 32),
                                         4 * lane + 2 * half));
                        elsif not wide then
                           wr_data <= spread32(src_rgba);
                           wr_be   <= std_logic_vector(shift_left(
                                         resize(unsigned'(x"F"), 32), 4 * lane));
                        else
                           -- ---- the wide write ------------------------------
                           --
                           -- A 256-bit memory word holds a 4 x 2 block of
                           -- PSMCT32 pixels, so four consecutive pixels of a
                           -- span share one word -- and writing them one at a
                           -- time spends four cycles where one would do.  The
                           -- byte enables already select which lanes are
                           -- written and the colour is already replicated into
                           -- all of them, so the only new work is deciding how
                           -- far the run reaches and or-ing four enables
                           -- together.
                           --
                           wbe := (others => '0');
                           for i in 0 to 3 loop
                              if i < nrun then
                                 ai := pix_addr_page(dr_fbp, dr_fbw,
                                                     dr_x + i, dr_y);
                                 wbe := wbe or shift_left(resize(unsigned'(x"F"), 32),
                                                          4 * to_integer(ai(2 downto 0)));
                              end if;
                           end loop;
                           wr_data <= spread32(src_rgba);
                           wr_be   <= std_logic_vector(wbe);
                           px_run  := nrun;
                        end if;
                        pixels  <= pixels + px_run;
                     else
                        rd_en   <= '1';
                        rd_addr <= std_logic_vector(wa(19 downto 3));
                        dr_addr <= wa;
                        dr_half <= half;
                        dr_src  <= src_rgba;
                        dr_run  <= nrun;
                        dr_wide <= '1' when wide else '0';
                        state   <= S_DRAWRD;
                     end if;
                  end if;

               -- The wide read-modify-write's write, a cycle after its blend.
               when S_TEX =>
                  tx_req <= '0';
                  if tx_done = '1' then
                     tex_colour <= tx_colour;
                     dr_texdone <= '1';
                  end if;
                  -- Back to S_DRAW either way: with the texel if it has
                  -- arrived, and to wait again if it has not. The state is not
                  -- left until tx_done, because tx_busy falls on the same edge
                  -- and a return that watched *that* would re-enter with the
                  -- colour already replaced by the next request's.
                  if tx_done = '1' then
                     state <= S_DRAW;
                  end if;

               when S_DRAWWR =>
                  wr_en   <= '1';
                  wr_addr <= std_logic_vector(dr_addr(19 downto 3));
                  wr_data <= dr_nw;
                  wr_be   <= dr_nbe;
                  pixels  <= pixels + dr_run;
                  px_run  := dr_run;
                  -- next_px sets the state, as it does for every other way a
                  -- pixel can end

               when S_ZRD =>
                  if rd_valid = '1' then
                     if z_pass = '1' then
                        dr_zdone <= '1';
                        if dr_zmsk = '0' then
                           lane := to_integer(dr_zaddr(2 downto 0));
                           wr_en   <= '1';
                           wr_addr <= std_logic_vector(dr_zaddr(19 downto 3));
                           if dr_z16 = '1' then
                              wr_data <= spread16(dr_srcz(15 downto 0));
                              wr_be   <= std_logic_vector(shift_left(
                                            resize(unsigned'("11"), 32),
                                            4 * lane + 2 * dr_zhalf));
                           else
                              wr_data <= spread32(dr_srcz);
                              wr_be   <= std_logic_vector(shift_left(
                                            resize(unsigned(zbe(dr_zmask)), 32), 4 * lane));
                           end if;
                        end if;
                        state <= S_DRAW;
                     end if;
                     -- a failing pixel is retired by px_step, below
                  end if;

               when S_DRAWRD =>
                  if rd_valid = '1' and dr_wide = '1' then
                     -- ---- the wide read-modify-write -----------------------
                     --
                     -- One read, up to four blends, one write.  This is where
                     -- the four-times matters most: a blended pixel costs a
                     -- read, two clocks of memory latency and a write, and
                     -- measured on the card that is four clocks per pixel
                     -- against one for a plain write.  Sharing the round trip
                     -- between the four pixels of a memory word turns that back
                     -- into one clock per pixel.
                     --
                     -- The blender is instantiated four times over rather than
                     -- reused, because the four pixels differ only in their
                     -- destination: the source colour is the same for all of
                     -- them, which is exactly why this is restricted to flat
                     -- primitives.
                     wbe := (others => '0');
                     -- Starting from the word that was read is belt and braces:
                     -- the byte enables below only enable the lanes this run
                     -- covers, so the rest are never written whatever they
                     -- hold.  Measured, not assumed -- zeroing them instead is
                     -- a mutation the directed test cannot tell apart.
                     nw  := rd_data;
                     for i in 0 to 3 loop
                        if i < dr_run then
                           ai := pix_addr_page(dr_fbp, dr_fbw, dr_x + i, dr_y);
                           li := to_integer(ai(2 downto 0));
                           opx := rd_data(32 * li + 31 downto 32 * li);
                           if dr_abe = '1' then
                              bl := blend_px(dr_src, opx, dr_alpha, dr_fix,
                                             dr_clamp);
                           else
                              bl := dr_src;
                           end if;
                           nw(32 * li + 31 downto 32 * li) :=
                              (opx and dr_fbmsk) or (bl and not dr_fbmsk);
                           wbe := wbe or shift_left(resize(unsigned'(x"F"), 32),
                                                    4 * li);
                        end if;
                     end loop;
                     dr_nw  <= nw;
                     dr_nbe <= std_logic_vector(wbe);
                     state  <= S_DRAWWR;
                  elsif rd_valid = '1' then
                     lane := to_integer(dr_addr(2 downto 0));
                     oldpx := std_logic_vector(
                                 shift_right(unsigned(rd_data), 32 * lane)(31 downto 0));
                     if dr_fb16 = '1' then
                        -- The destination is expanded before the blender sees
                        -- it, because the blender works in 8 bits per channel
                        -- whatever the buffer holds -- and because a 16-bit
                        -- buffer's alpha is 0x80 or 0x00, not 0 or 255.
                        old16 := std_logic_vector(
                                    shift_right(unsigned(oldpx), 16 * dr_half)(15 downto 0));
                        oldpx := expand16(old16);
                     end if;
                     -- PRIM.ABE decides whether the blender runs at all.  This
                     -- path is also taken for a plain masked write, where the
                     -- destination is read to preserve the masked bits and the
                     -- source must go through untouched.
                     if dr_abe = '1' then
                        blended := blend_px(dr_src, oldpx, dr_alpha, dr_fix, dr_clamp);
                     else
                        blended := dr_src;
                     end if;
                     wr_en   <= '1';
                     wr_addr <= std_logic_vector(dr_addr(19 downto 3));
                     if dr_fb16 = '1' then
                        -- FBMSK's bit positions are those of the pixel *before*
                        -- format conversion (3.9.5), and the bits that survive
                        -- the conversion are exactly the ones pack16 keeps -- so
                        -- the mask converts with the same function the colour
                        -- does rather than needing one of its own.
                        msk16 := pack16(dr_fbmsk);
                        new16 := (old16 and msk16) or (pack16(blended) and not msk16);
                        wr_data <= spread16(new16);
                        wr_be   <= std_logic_vector(shift_left(
                                      resize(unsigned'("11"), 32),
                                      4 * lane + 2 * dr_half));
                     else
                        newpx := (oldpx and dr_fbmsk) or (blended and not dr_fbmsk);
                        wr_data <= spread32(newpx);
                        wr_be   <= std_logic_vector(shift_left(
                                      resize(unsigned'(x"F"), 32), 4 * lane));
                     end if;
                     pixels  <= pixels + 1;
                     state   <= S_DRAW;
                  end if;

               when S_PIXELS =>
                  -- one pixel per clock into local memory
                  if px_n = 0 then
                     state <= px_ret;
                  else
                     if x_active = '1' and x_psm = 0 and x_left /= 0 then
                        wa   := pix_addr(x_bp, x_bw, x_cx, x_cy);
                        lane := to_integer(wa(2 downto 0));
                        wr_en   <= '1';
                        wr_addr <= std_logic_vector(wa(19 downto 3));
                        wr_data <= spread32(px_data(31 downto 0));
                        wr_be   <= std_logic_vector(shift_left(
                                      resize(unsigned'(x"F"), 32), 4 * lane));
                        if x_cx + 1 = x_x0 + x_w then
                           x_cx <= x_x0;
                           x_cy <= x_cy + 1;
                        else
                           x_cx <= x_cx + 1;
                        end if;
                        x_left <= x_left - 1;
                     end if;
                     px_data <= x"00000000" & px_data(127 downto 32);
                     px_n    <= px_n - 1;
                  end if;

            end case;

            -- One place decides a pixel is finished with, so the position, the
            -- interpolators and the depth handshake can never disagree about
            -- which pixel is current.
            if px_step = '1' then
               next_px;
            end if;
         end if;
      end if;
   end process;

end architecture;
