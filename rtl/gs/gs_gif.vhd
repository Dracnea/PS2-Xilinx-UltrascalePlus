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

      -- for the testbench: read any general register, and count writes to
      -- addresses the manual does not define rather than inventing behaviour
      dbg_sel     : in  unsigned(6 downto 0) := (others => '0');
      dbg_reg     : out std_logic_vector(63 downto 0) := (others => '0');
      dbg_unknown : out unsigned(15 downto 0) := (others => '0');
      -- pixels drawn, because a primitive that quietly draws nothing -- clipped
      -- away, wrong pixel format, empty rectangle -- otherwise looks exactly
      -- like a framebuffer that was never meant to change
      dbg_pixels  : out unsigned(31 downto 0) := (others => '0')
   );
end entity;

architecture arch of gs_gif is
   type regfile_t is array (0 to 127) of std_logic_vector(63 downto 0);
   signal reg : regfile_t := (others => (others => '0'));

   signal unknown : unsigned(15 downto 0) := (others => '0');
   signal pixels  : unsigned(31 downto 0) := (others => '0');

   type state_t is (S_TAG, S_PACKED, S_REGLIST, S_IMAGE, S_PIXELS,
                    S_DRAW, S_DRAWRD,
                    S_TRI_SET, S_TRI_WAIT, S_TRI_SCAN, S_TRI_STEP);
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
   signal dr_x, dr_y : unsigned(10 downto 0) := (others => '0');
   signal dr_x0      : unsigned(10 downto 0) := (others => '0');
   signal dr_x1      : unsigned(10 downto 0) := (others => '0');
   signal dr_y1      : unsigned(10 downto 0) := (others => '0');
   signal dr_rgba    : std_logic_vector(31 downto 0) := (others => '0');
   signal dr_fbp     : unsigned(8 downto 0) := (others => '0');
   signal dr_fbw     : unsigned(5 downto 0) := (others => '0');
   signal dr_fbmsk   : std_logic_vector(31 downto 0) := (others => '0');
   -- the blender's settings, latched with the rest of the primitive
   signal dr_abe     : std_logic := '0';
   signal dr_alpha   : std_logic_vector(7 downto 0) := (others => '0');  -- A B C D
   signal dr_fix     : unsigned(7 downto 0) := (others => '0');
   signal dr_clamp   : std_logic := '0';
   signal dr_empty   : std_logic := '0';
   signal dr_ret     : state_t := S_TAG;
   signal dr_addr    : unsigned(19 downto 0) := (others => '0');

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

   function pix_addr_page(pg : unsigned(8 downto 0); bw : unsigned(5 downto 0);
                          x, y : unsigned(10 downto 0)) return unsigned is
      variable page : unsigned(8 downto 0);
   begin
      page := resize(pg + resize(y(10 downto 5) * bw, 9)
                     + resize(x(10 downto 6), 9), 9);
      return page & x(5) & y(4) & x(4) & y(3) & x(3)
                  & y(2) & y(1) & x(2) & x(1) & y(0) & x(0);
   end function;

   function pix_addr(bp : unsigned(13 downto 0); bw : unsigned(5 downto 0);
                     x, y : unsigned(10 downto 0)) return unsigned is
   begin
      return pix_addr_page(bp(13 downto 5), bw, x, y);
   end function;
begin

   edges : for k in 0 to 2 generate
      u : entity work.gs_edge_dda
         port map (clk => clk, reset => reset, start => e_start,
                   x0 => e_x0(k), y0 => e_y0(k), x1 => e_x1(k), y1 => e_y1(k),
                   ytop => e_ytop, busy => e_busy(k), step => e_step,
                   x => e_x(k));
   end generate;

   -- Combinational, because valid/ready only means anything if both sides agree
   -- on which edge the transfer happened.  A registered ready lags the state it
   -- describes by a cycle, and the producer then advances on an edge where
   -- nothing was taken -- which loses a quadword exactly when the consumer
   -- stops to do some work, which is the one case that matters.
   gif_ready <= '0' when reset = '1' else
                '0' when state = S_PIXELS or state = S_DRAW or state = S_DRAWRD
                         or state = S_TRI_SET or state = S_TRI_WAIT
                         or state = S_TRI_SCAN or state = S_TRI_STEP
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
      variable ylo, yhi, tya, tyb          : integer range -65536 to 65535;
      variable lft, rgt                    : integer range -4096 to 4095;
      variable ka, kb                      : integer range 0 to 2;
   begin
      if rising_edge(clk) then
         wr_en     <= '0';
         rd_en     <= '0';
         e_step    <= '0';

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
                           elsif w_addr = 0 then
                              v_cnt <= (others => '0');   -- PRIM restarts it
                           elsif w_addr = 4 or w_addr = 5
                                 or w_addr = 16#0C# or w_addr = 16#0D# then
                              v0_x <= v1_x;  v0_y <= v1_y;
                              v1_x <= v2_x;  v1_y <= v2_y;
                              v2_x <= unsigned(w_data(15 downto 0));
                              v2_y <= unsigned(w_data(31 downto 16));
                              if v_cnt = 0 then          -- the fan's anchor
                                 vf_x <= unsigned(w_data(15 downto 0));
                                 vf_y <= unsigned(w_data(31 downto 16));
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
                        sx0 := to_integer(unsigned(reg(16#40# + ctxi)(10 downto 0)));
                        sx1 := to_integer(unsigned(reg(16#40# + ctxi)(26 downto 16)));
                        sy0 := to_integer(unsigned(reg(16#40# + ctxi)(42 downto 32)));
                        sy1 := to_integer(unsigned(reg(16#40# + ctxi)(58 downto 48)));
                        if ax < sx0 then ax := sx0; end if;
                        if ay < sy0 then ay := sy0; end if;
                        bx := bx - 1;  by := by - 1;
                        if bx > sx1 then bx := sx1; end if;
                        if by > sy1 then by := sy1; end if;

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
                        dr_rgba  <= reg(1)(31 downto 0);
                        dr_abe   <= reg(0)(6);
                        dr_alpha <= reg(16#42# + ctxi)(7 downto 0);
                        dr_fix   <= unsigned(reg(16#42# + ctxi)(39 downto 32));
                        dr_clamp <= reg(16#46#)(0);
                        dr_x0    <= to_unsigned(ax, 11);
                        dr_x     <= to_unsigned(ax, 11);
                        dr_x1    <= to_unsigned(bx, 11);
                        dr_y     <= to_unsigned(ay, 11);
                        dr_y1    <= to_unsigned(by, 11);
                        if ax > bx or ay > by or ax < 0 or ay < 0
                           or (reg(16#4C# + ctxi)(29 downto 24) /= "000000"
                               and reg(16#4C# + ctxi)(29 downto 24) /= "000001") then
                           dr_empty <= '1';       -- nothing to draw, or not PSMCT32
                        else
                           dr_empty <= '0';
                        end if;
                        v_cnt  <= (others => '0');
                        dr_ret <= S_PACKED;
                        if last then dr_ret <= S_TAG; end if;
                        state  <= S_DRAW;
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
                        else
                           t_x(0) <= to_signed(to_integer(v1_x) - ofx, 18);
                           t_y(0) <= to_signed(to_integer(v1_y) - ofy, 18);
                        end if;
                        t_x(1) <= to_signed(to_integer(v2_x) - ofx, 18);
                        t_y(1) <= to_signed(to_integer(v2_y) - ofy, 18);
                        t_x(2) <= to_signed(to_integer(unsigned(w_data(15 downto 0))) - ofx, 18);
                        t_y(2) <= to_signed(to_integer(unsigned(w_data(31 downto 16))) - ofy, 18);
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
                        dr_rgba  <= reg(1)(31 downto 0);
                        dr_abe   <= reg(0)(6);
                        dr_alpha <= reg(16#42# + ctxi)(7 downto 0);
                        dr_fix   <= unsigned(reg(16#42# + ctxi)(39 downto 32));
                        dr_clamp <= reg(16#46#)(0);
                        if reg(16#4C# + ctxi)(29 downto 24) /= "000000"
                           and reg(16#4C# + ctxi)(29 downto 24) /= "000001" then
                           dr_empty <= '1';            -- neither PSMCT32 nor 24
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
                  sy0 := to_integer(unsigned(reg(16#40# + ctxi)(42 downto 32)));
                  sy1 := to_integer(unsigned(reg(16#40# + ctxi)(58 downto 48)));
                  -- ceil(y/16) is floor((y+15)/16), and floor is an arithmetic
                  -- shift.  Integer division truncates toward zero instead,
                  -- which differs as soon as a coordinate is negative -- and a
                  -- vertex above or left of XYOFFSET is exactly that.
                  tya := to_integer(shift_right(to_signed(ylo + 15, 24), 4));
                  tyb := to_integer(shift_right(to_signed(yhi + 15, 24), 4)) - 1;
                  if tya < sy0 then tya := sy0; end if;
                  if tyb > sy1 then tyb := sy1; end if;
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
                  if tya > tyb or tya < 0 then
                     dr_empty <= '1';
                     dr_y  <= (others => '0');
                     dr_y1 <= (others => '0');
                  else
                     dr_y  <= to_unsigned(tya, 11);
                     dr_y1 <= to_unsigned(tyb, 11);
                  end if;
                  e_ytop   <= to_signed(tya, 14);
                  e_start  <= '1';
                  tri_mode <= '1';
                  state    <= S_TRI_WAIT;

               when S_TRI_WAIT =>
                  e_start <= '0';
                  if e_start = '0' and e_busy = "000" then
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
                  sx0 := to_integer(unsigned(reg(16#40# + ctxi)(10 downto 0)));
                  sx1 := to_integer(unsigned(reg(16#40# + ctxi)(26 downto 16)));
                  rgt := rgt - 1;
                  if lft < sx0 then lft := sx0; end if;
                  if rgt > sx1 then rgt := sx1; end if;
                  if lft > rgt or lft < 0 or rgt < 0 then
                     e_step <= '1';
                     if dr_y >= dr_y1 then
                        tri_mode <= '0';
                        state    <= dr_ret;
                     else
                        dr_y  <= dr_y + 1;
                        state <= S_TRI_STEP;
                     end if;
                  else
                     dr_x  <= to_unsigned(lft, 11);
                     dr_x0 <= to_unsigned(lft, 11);
                     dr_x1 <= to_unsigned(rgt, 11);
                     state <= S_DRAW;
                  end if;

               when S_DRAW =>
                  if dr_empty = '1' or dr_y > dr_y1 then
                     state <= dr_ret;
                  else
                     wa   := pix_addr_page(dr_fbp, dr_fbw, dr_x, dr_y);
                     lane := to_integer(wa(2 downto 0));
                     if dr_fbmsk = x"00000000" and dr_abe = '0' then
                        -- nothing to preserve, so no read is needed: the common
                        -- case stays one pixel per clock
                        wr_en   <= '1';
                        wr_addr <= std_logic_vector(wa(19 downto 3));
                        wr_data <= std_logic_vector(shift_left(
                                      resize(unsigned(dr_rgba), 256), 32 * lane));
                        wr_be   <= std_logic_vector(shift_left(
                                      resize(unsigned'(x"F"), 32), 4 * lane));
                        pixels  <= pixels + 1;
                        if dr_x = dr_x1 then
                           -- end of a scanline: a sprite goes back to the same
                           -- left edge, a triangle will ask its edges for the next
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
                              dr_x <= dr_x0;
                              dr_y <= dr_y + 1;
                           end if;
                        else
                           dr_x <= dr_x + 1;
                        end if;
                     else
                        rd_en   <= '1';
                        rd_addr <= std_logic_vector(wa(19 downto 3));
                        dr_addr <= wa;
                        state   <= S_DRAWRD;
                     end if;
                  end if;

               when S_DRAWRD =>
                  if rd_valid = '1' then
                     lane := to_integer(dr_addr(2 downto 0));
                     oldpx := std_logic_vector(
                                 shift_right(unsigned(rd_data), 32 * lane)(31 downto 0));
                     -- PRIM.ABE decides whether the blender runs at all.  This
                     -- path is also taken for a plain masked write, where the
                     -- destination is read to preserve the masked bits and the
                     -- source must go through untouched.
                     if dr_abe = '1' then
                        blended := blend_px(dr_rgba, oldpx, dr_alpha, dr_fix, dr_clamp);
                     else
                        blended := dr_rgba;
                     end if;
                     newpx := (oldpx and dr_fbmsk) or (blended and not dr_fbmsk);
                     wr_en   <= '1';
                     wr_addr <= std_logic_vector(dr_addr(19 downto 3));
                     wr_data <= std_logic_vector(shift_left(
                                   resize(unsigned(newpx), 256), 32 * lane));
                     wr_be   <= std_logic_vector(shift_left(
                                   resize(unsigned'(x"F"), 32), 4 * lane));
                     pixels  <= pixels + 1;
                     if dr_x = dr_x1 then
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
                           dr_x <= dr_x0;
                           dr_y <= dr_y + 1;
                           state <= S_DRAW;
                        end if;
                     else
                        dr_x <= dr_x + 1;
                        state <= S_DRAW;
                     end if;
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
                        wr_data <= std_logic_vector(shift_left(
                                      resize(unsigned(px_data(31 downto 0)), 256),
                                      32 * lane));
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
         end if;
      end if;
   end process;

end architecture;
