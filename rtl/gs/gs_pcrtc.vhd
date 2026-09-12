-- gs_pcrtc.vhd -- the Graphics Synthesizer's video block: the read circuit.
--
-- PCRTC is the half of the GS that the drawing pipeline never touches.  It
-- walks a raster, reads whatever frame buffer DISPFB points at, and produces a
-- colour per video clock.  Almost none of that is arithmetic; it is addressing,
-- and the addressing is the swizzle the rasteriser writes through, read in the
-- opposite direction -- which is why both blocks take it from gs_addr_pkg
-- rather than each keeping a copy.  Two copies that drifted would scramble the
-- picture in a way no differential test of either block alone could find: each
-- would still agree with its own model.
--
-- What is here
-- ------------
-- Two read circuits, each with its own DISPFB and DISPLAY, and the merge that
-- combines them.  Source formats PSMCT32, PSMCT24, PSMCT16 and PSMCT16S, which
-- is every format a frame buffer can be in.
--
-- What is not here, and why it is missing rather than guessed
-- -----------------------------------------------------------
-- The sync generator.  SMODE1, SMODE2, SYNCH1, SYNCH2 and SYNCV hold a PLL
-- setting and a set of counter reloads whose field positions this project has
-- no verified source for.  Writing them from memory would produce a block that
-- looked finished and could not be shown wrong until a console was attached, so
-- the raster totals arrive here as ports instead, and reading the real
-- registers off hardware is a probe entry.  Everything below is checkable
-- today against sim/gs/pcrtc_ref.py; a sync generator written from memory would
-- not have been.
--
-- The merge arithmetic is flagged the same way: its shape is the drawing side's
-- ALPHA fixed point, which is the argument for it, but it is not a measurement.
-- A picture that uses one read circuit -- the ordinary case, and every scene
-- this project has drawn -- never reaches it.
--
-- Magnification without a divider
-- -------------------------------
-- MAGH and MAGV stretch each source pixel over several video clocks.  Written
-- as arithmetic that is a division of the offset into the display area, and a
-- divider per circuit per axis would be absurd for a value that only counts up.
-- So it counts: a source position and a small repeat counter that advances it,
-- both starting from zero at the top-left of the raster and advancing only
-- while the raster is inside the display area.  At the area's first pixel they
-- are therefore still zero, which is the answer the division gives.  That is
-- what the hardware does and it costs four counters.
--
-- The shape of the interface
-- --------------------------
-- One pixel at a time, with reads arbitrated outside this block.  A pixel needs
-- one memory read per enabled circuit and the raster waits for them, so this is
-- slower than one pixel per clock when both circuits are on.  The real PCRTC
-- reads whole columns into a line buffer; this reads a word per pixel.  That is
-- the same fill-rate gap the rasteriser has, and it is recorded, not hidden.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.gs_addr_pkg.all;

entity gs_pcrtc is
   generic
   (
      ADDR_BITS : integer := 17
   );
   port
   (
      clk       : in  std_logic;
      reset     : in  std_logic;

      -- privileged-register writes, by offset from 0x12000000
      pr_we     : in  std_logic := '0';
      pr_addr   : in  std_logic_vector(7 downto 0) := (others => '0');
      pr_data   : in  std_logic_vector(63 downto 0) := (others => '0');

      -- raster totals, standing in for the sync generator (see the header)
      h_total   : in  unsigned(11 downto 0) := to_unsigned(640, 12);
      v_total   : in  unsigned(11 downto 0) := to_unsigned(480, 12);

      -- run the raster.  Held low the block idles with its counters at zero,
      -- which is what lets a testbench put the registers in place first.
      enable    : in  std_logic := '0';

      -- local-memory read port, arbitrated outside this block
      rd_en     : out std_logic := '0';
      rd_addr   : out std_logic_vector(ADDR_BITS-1 downto 0) := (others => '0');
      rd_data   : in  std_logic_vector(255 downto 0) := (others => '0');
      rd_valid  : in  std_logic := '0';

      -- the picture.  24 bits, because a display has no alpha.
      px_valid  : out std_logic := '0';
      px_rgb    : out std_logic_vector(23 downto 0) := (others => '0');
      px_x      : out unsigned(11 downto 0) := (others => '0');
      px_y      : out unsigned(11 downto 0) := (others => '0');
      px_sof    : out std_logic := '0'     -- this pixel starts a frame
   );
end entity;

architecture arch of gs_pcrtc is

   -- ---- the privileged registers ------------------------------------------
   type reg2_t is array (0 to 1) of std_logic_vector(63 downto 0);
   signal pmode     : std_logic_vector(63 downto 0) := (others => '0');
   signal bgcolor   : std_logic_vector(63 downto 0) := (others => '0');
   signal dispfb_r  : reg2_t := (others => (others => '0'));
   signal display_r : reg2_t := (others => (others => '0'));

   -- ---- one circuit's decoded registers -----------------------------------
   --
   -- The two registers divide the work in a way that is easy to get backwards.
   -- DISPFB says where in *memory*: the buffer's page, its width, its format,
   -- and an offset into it.  DISPLAY says where on *screen*: the first video
   -- clock and raster line the area occupies, how big it is, and how far each
   -- source pixel is stretched.  So DW is measured in output clocks and the
   -- source rectangle is DW/(MAGH+1) wide; reading DW as a source width would
   -- give a picture that is right only at magnification one.
   type circ_t is record
      en   : std_logic;
      fbp  : unsigned(8 downto 0);       -- 8 KB pages, as FRAME's FBP is
      fbw  : unsigned(5 downto 0);       -- 64-pixel units, as FRAME's FBW is
      psm  : unsigned(4 downto 0);
      dbx  : unsigned(10 downto 0);
      dby  : unsigned(10 downto 0);
      dx   : unsigned(11 downto 0);
      dy   : unsigned(11 downto 0);
      magh : unsigned(4 downto 0);       -- MAGH + 1, so 1 to 16
      magv : unsigned(2 downto 0);       -- MAGV + 1, so 1 to 4
      dw   : unsigned(12 downto 0);      -- DW + 1
      dh   : unsigned(12 downto 0);      -- DH + 1
   end record;
   type circ_a is array (0 to 1) of circ_t;

   function decode(fb, dp : std_logic_vector(63 downto 0);
                   en : std_logic) return circ_t is
      variable c : circ_t;
   begin
      c.en   := en;
      c.fbp  := unsigned(fb(8 downto 0));
      c.fbw  := unsigned(fb(14 downto 9));
      c.psm  := unsigned(fb(19 downto 15));
      c.dbx  := unsigned(fb(42 downto 32));
      c.dby  := unsigned(fb(53 downto 43));
      c.dx   := unsigned(dp(11 downto 0));
      c.dy   := resize(unsigned(dp(22 downto 12)), 12);
      -- MAGH, MAGV, DW and DH are all stored as "minus one": no field here can
      -- name a zero-sized or zero-magnified area, which is the reason for the
      -- encoding and the reason for these adds.
      c.magh := resize(unsigned(dp(26 downto 23)), 5) + 1;
      c.magv := resize(unsigned(dp(28 downto 27)), 3) + 1;
      c.dw   := resize(unsigned(dp(43 downto 32)), 13) + 1;
      c.dh   := resize(unsigned(dp(54 downto 44)), 13) + 1;
      return c;
   end function;

   signal circ : circ_a;

   -- ---- the raster --------------------------------------------------------
   signal hx, vy : unsigned(11 downto 0) := (others => '0');

   -- per-circuit source position and its repeat counters
   type upos_a is array (0 to 1) of unsigned(10 downto 0);
   type uh_a   is array (0 to 1) of unsigned(4 downto 0);
   type uv_a   is array (0 to 1) of unsigned(2 downto 0);
   signal sxp, syp : upos_a := (others => (others => '0'));
   signal sxc      : uh_a   := (others => (others => '0'));
   signal syc      : uv_a   := (others => (others => '0'));

   -- ---- the per-pixel read sequence ---------------------------------------
   type state_t is (S_ISS0, S_ISS1, S_WAIT);
   signal state : state_t := S_ISS0;

   -- What this pixel asked for, what has come back, and where in the 256-bit
   -- line each answer sits.  Reads are issued circuit 0 first and return in
   -- order, so the next return always belongs to the lowest circuit that is
   -- still waiting -- which is why there is no tag queue here.
   signal need, got : std_logic_vector(1 downto 0) := "00";
   signal hlf       : std_logic_vector(1 downto 0) := "00";
   type off_a is array (0 to 1) of unsigned(2 downto 0);
   signal off       : off_a := (others => (others => '0'));
   type w32_a is array (0 to 1) of std_logic_vector(31 downto 0);
   signal pxw       : w32_a := (others => (others => '0'));

   -- ---- the merge ---------------------------------------------------------
   --
   -- out = under + (over - under) * a / 128, per channel, clamped.
   --
   -- UNVERIFIED.  The shape is the drawing side's ALPHA arithmetic, where 0x80
   -- is one and a larger alpha overshoots; the clamp is what keeps an ALP above
   -- 0x80 from wrapping a channel round.  It is not a measurement.
   function blend(under, over : std_logic_vector(23 downto 0);
                  a : unsigned(7 downto 0)) return std_logic_vector is
      variable r    : std_logic_vector(23 downto 0);
      variable u, o : signed(17 downto 0);
      variable t    : signed(17 downto 0);
   begin
      for n in 0 to 2 loop
         u := signed(resize(unsigned(under(8 * n + 7 downto 8 * n)), 18));
         o := signed(resize(unsigned(over (8 * n + 7 downto 8 * n)), 18));
         t := u + resize(shift_right((o - u) * signed('0' & a), 7), 18);
         if t < 0 then
            r(8 * n + 7 downto 8 * n) := x"00";
         elsif t > 255 then
            r(8 * n + 7 downto 8 * n) := x"FF";
         else
            r(8 * n + 7 downto 8 * n) := std_logic_vector(t(7 downto 0));
         end if;
      end loop;
      return r;
   end function;

   -- Is the raster inside this circuit's display area?
   function covers(c : circ_t; x, y : unsigned(11 downto 0)) return boolean is
   begin
      return c.en = '1'
             and x >= c.dx and resize(x, 13) < resize(c.dx, 13) + c.dw
             and y >= c.dy and resize(y, 13) < resize(c.dy, 13) + c.dh;
   end function;

begin

   circ(0) <= decode(dispfb_r(0), display_r(0), pmode(0));
   circ(1) <= decode(dispfb_r(1), display_r(1), pmode(1));

   process (clk)
      variable c     : circ_t;
      variable i     : integer range 0 to 1;
      variable a     : unsigned(19 downto 0);
      variable sx, sy : unsigned(10 downto 0);
      variable w     : std_logic_vector(31 downto 0);
      variable e     : std_logic_vector(31 downto 0);
      variable rgb   : std_logic_vector(23 downto 0);
      variable alpha : unsigned(7 downto 0);
      variable rgb0, rgb1, und, res : std_logic_vector(23 downto 0);
      variable a0    : unsigned(7 downto 0);
      variable alp   : unsigned(7 downto 0);
      variable mmod, slbg : std_logic;
      variable bg    : std_logic_vector(23 downto 0);
      variable eol, eof : boolean;
   begin
      if rising_edge(clk) then
         rd_en    <= '0';
         px_valid <= '0';

         if reset = '1' then
            hx    <= (others => '0');
            vy    <= (others => '0');
            state <= S_ISS0;
            need  <= "00";
            got   <= "00";
            sxp   <= (others => (others => '0'));
            syp   <= (others => (others => '0'));
            sxc   <= (others => (others => '0'));
            syc   <= (others => (others => '0'));
         else
            if pr_we = '1' then
               case pr_addr is
                  when x"00"  => pmode        <= pr_data;
                  when x"70"  => dispfb_r(0)  <= pr_data;
                  when x"80"  => display_r(0) <= pr_data;
                  when x"90"  => dispfb_r(1)  <= pr_data;
                  when x"A0"  => display_r(1) <= pr_data;
                  when x"E0"  => bgcolor      <= pr_data;
                  when others => null;
               end case;
            end if;

            -- A return belongs to the lowest circuit still outstanding.
            if rd_valid = '1' and (need and not got) /= "00" then
               if need(0) = '1' and got(0) = '0' then i := 0; else i := 1; end if;
               pxw(i) <= rd_data(32 * to_integer(off(i)) + 31
                                 downto 32 * to_integer(off(i)));
               got(i) <= '1';
            end if;

            case state is

               when S_ISS0 | S_ISS1 =>
                  if state = S_ISS0 then i := 0; else i := 1; end if;
                  c := circ(i);
                  if enable = '1' then
                     if covers(c, hx, vy) then
                        sx := c.dbx + sxp(i);
                        sy := c.dby + syp(i);
                        if c.psm = 2 or c.psm = 10 then      -- PSMCT16, PSMCT16S
                           a := pix_addr16_page(c.fbp, c.fbw, sx, sy,
                                                '1' when c.psm = 10 else '0');
                           hlf(i) <= '1' when fb16_half(sx) = 1 else '0';
                        else                                 -- PSMCT32, PSMCT24
                           a := pix_addr_page(c.fbp, c.fbw, sx, sy);
                           hlf(i) <= '0';
                        end if;
                        rd_en   <= '1';
                        rd_addr <= std_logic_vector(a(ADDR_BITS + 2 downto 3));
                        off(i)  <= a(2 downto 0);
                        need(i) <= '1';
                     else
                        need(i) <= '0';
                     end if;
                     if state = S_ISS0 then
                        state <= S_ISS1;
                     else
                        state <= S_WAIT;
                     end if;
                  end if;

               when S_WAIT =>
                  -- Nothing outstanding: every read this pixel asked for has
                  -- come back, or it asked for none.
                  if (need and not got) = "00" then
                     mmod := pmode(5);
                     slbg := pmode(7);
                     alp  := unsigned(pmode(15 downto 8));
                     -- BGCOLOR is 0xBBGGRR and a frame-buffer pixel is
                     -- 0xAABBGGRR, so the two agree in their low 24 bits and
                     -- nothing needs reordering.
                     bg   := bgcolor(23 downto 0);

                     for n in 0 to 1 loop
                        c := circ(n);
                        w := pxw(n);
                        if c.psm = 2 or c.psm = 10 then
                           if hlf(n) = '1' then
                              e := expand16(w(31 downto 16));
                           else
                              e := expand16(w(15 downto 0));
                           end if;
                        elsif c.psm = 1 then
                           -- PSMCT24 is the same memory with the alpha byte not
                           -- read back.  The manual gives the unread byte as
                           -- zero rather than as whatever the rasteriser last
                           -- left there.
                           e := x"00" & w(23 downto 0);
                        else
                           e := w;
                        end if;
                        if n = 0 then
                           rgb0 := e(23 downto 0);
                           a0   := unsigned(e(31 downto 24));
                        else
                           rgb1 := e(23 downto 0);
                        end if;
                     end loop;

                     if need = "01" then
                        res := rgb0;
                     elsif need = "10" then
                        -- SLBG puts the background under circuit 2 even where
                        -- circuit 1 is not covering, which is what makes a
                        -- small circuit 2 over a coloured field work.
                        if slbg = '1' then
                           res := blend(bg, rgb1,
                                        alp when mmod = '1' else x"80");
                        else
                           res := rgb1;
                        end if;
                     elsif need = "11" then
                        und := bg when slbg = '1' else rgb0;
                        res := blend(und, rgb1, alp when mmod = '1' else a0);
                     else
                        res := bg;
                     end if;

                     px_rgb   <= res;
                     px_x     <= hx;
                     px_y     <= vy;
                     px_sof   <= '1' when hx = 0 and vy = 0 else '0';
                     px_valid <= '1';

                     -- ---- advance the raster and the source counters -------
                     eol := hx + 1 = h_total;
                     eof := eol and (vy + 1 = v_total);

                     for n in 0 to 1 loop
                        c := circ(n);
                        if eof then
                           sxp(n) <= (others => '0'); sxc(n) <= (others => '0');
                           syp(n) <= (others => '0'); syc(n) <= (others => '0');
                        elsif eol then
                           -- A new line restarts the horizontal counters and
                           -- steps the vertical ones, but only if the line just
                           -- finished was inside the area: outside it the
                           -- source position must not move.
                           sxp(n) <= (others => '0');
                           sxc(n) <= (others => '0');
                           if c.en = '1' and vy >= c.dy
                              and resize(vy, 13) < resize(c.dy, 13) + c.dh then
                              if syc(n) + 1 = c.magv then
                                 syc(n) <= (others => '0');
                                 syp(n) <= syp(n) + 1;
                              else
                                 syc(n) <= syc(n) + 1;
                              end if;
                           end if;
                        else
                           if c.en = '1' and hx >= c.dx
                              and resize(hx, 13) < resize(c.dx, 13) + c.dw then
                              if sxc(n) + 1 = c.magh then
                                 sxc(n) <= (others => '0');
                                 sxp(n) <= sxp(n) + 1;
                              else
                                 sxc(n) <= sxc(n) + 1;
                              end if;
                           end if;
                        end if;
                     end loop;

                     if eof then
                        hx <= (others => '0');
                        vy <= (others => '0');
                     elsif eol then
                        hx <= (others => '0');
                        vy <= vy + 1;
                     else
                        hx <= hx + 1;
                     end if;

                     need  <= "00";
                     got   <= "00";
                     state <= S_ISS0;
                  end if;

            end case;
         end if;
      end if;
   end process;

end architecture;
