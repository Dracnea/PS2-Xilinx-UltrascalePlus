-- gs_texaddr.vhd -- where a *texel* lives in the Graphics Synthesizer's memory.
--
-- This is the texture unit's addressing, and it is deliberately the first piece
-- of that unit to become RTL.  docs/gs-texture.md gives the reason: the texture
-- unit sits inside the pixel pipeline, that pipeline is being widened, and a
-- sampler written one pixel wide today would be rewritten when it changes
-- shape.  Addressing is the part that does not care.  A texel is at the same
-- address whether it is fetched one at a time or four at a time, so this can be
-- built and made *known* right while the shape of everything around it is still
-- open.
--
-- What it does, and nothing else: it takes a texel coordinate and the TEX0 and
-- CLAMP register state, applies the wrap, and produces the one place in local
-- memory where that texel's bits are.  It does not fetch, it does not look up a
-- CLUT, it does not filter and it does not combine with a fragment colour.
-- Those are the sampler's, and they are what waits for the pipeline.
--
-- ## The one interface decision here
--
-- Nine formats store texels at four different granularities -- a nibble, a
-- byte, a half word and a word -- and three of them hide an index in the spare
-- bits of somebody else's word.  Each could be reported in its own units, and
-- then every caller would carry the same four-way case.
--
-- So they are all normalised to the same three numbers instead:
--
--     lm_addr   which 256-bit local-memory word to read
--     bit_off   where in that word the texel starts, 0 to 255
--     width     how many bits it is: 4, 8, 16, 24 or 32
--
-- gs_lmem's port is 256 bits wide, so this is the form the fetch actually
-- needs, and the H formats stop being a special case entirely: PSMT8H is a
-- PSMCT32 address with 24 added to the bit offset and a width of 8.  The
-- awkward part of those formats moves into an adder that was there anyway.
--
-- ## What this shares with the frame buffer, and what it does not
--
-- PSMCT32/24/16/16S are addressed by gs_addr_pkg, unchanged -- the rasteriser
-- writes a frame buffer through those functions and a texture unit reads one
-- back through the same ones, which is exactly the sharing gs_addr_pkg exists
-- for.  Only the indexed formats are new here, and their pages are a different
-- shape: PSMCT32's page is 64 x 32 texels, PSMT8's is 128 x 64 and PSMT4's is
-- 128 x 128, the same 8 KB holding more of a smaller thing.
--
-- The trap that shape sets is TBW.  **TBW counts 64-texel units whatever the
-- format**, so for the indexed formats it does not count pages: a PSMT8 page is
-- 128 texels across, so a row of pages is TBW/2 of them.  Forget the halving
-- and every texture wider than one page is sheared -- while a texture exactly
-- one page wide, which is what a first test naturally uses, comes out perfect.
-- sim/gs/gen_texaddr.py therefore always includes a multi-page case.
--
-- ## The column maps are not tables
--
-- PCSX2 stores columnTable8 as a literal 16 x 16 array and columnTable4 as
-- 16 x 32, and the GS manual draws them as figures.  Both are linear over
-- GF(2) -- every output bit a fixed exclusive-or of input bits -- which
-- sim/gs/gs_ref.py established by testing v(y,x) == v(y,0) ^ v(0,x) ^ v(0,0)
-- over all 256 and 512 entries rather than by looking at them.  So in hardware
-- they are a wire permutation and one XOR3 gate, not a lookup, and that is what
-- is written below.  tools/gs/xcheck_swizzle.py checks the derivation against
-- PCSX2's tables exhaustively, which is what makes it a claim that can fail.
--
-- Note column4 is **nine** bits and not eight.  A 4-bit column is 32 x 16
-- texels and so holds 512 nibbles; the first version of the model stopped at
-- bit 7 and was right for the top half of every column and wrong by exactly 256
-- for the bottom.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

package gs_texaddr_pkg is

   -- PSM codes, named rather than written bare at each use: several differ by
   -- one bit and the indexed ones are easy to transpose.
   constant PSMCT32  : unsigned(5 downto 0) := "000000";   -- 0x00
   constant PSMCT24  : unsigned(5 downto 0) := "000001";   -- 0x01
   constant PSMCT16  : unsigned(5 downto 0) := "000010";   -- 0x02
   constant PSMCT16S : unsigned(5 downto 0) := "001010";   -- 0x0A
   constant PSMT8    : unsigned(5 downto 0) := "010011";   -- 0x13
   constant PSMT4    : unsigned(5 downto 0) := "010100";   -- 0x14
   constant PSMT8H   : unsigned(5 downto 0) := "011011";   -- 0x1B
   constant PSMT4HL  : unsigned(5 downto 0) := "100100";   -- 0x24
   constant PSMT4HH  : unsigned(5 downto 0) := "101100";   -- 0x2C

   -- CLAMP.WMS / WMT.  Three of the four do what their names say; the fourth
   -- does not, and that is handled in tex_wrap.
   constant WM_REPEAT        : unsigned(1 downto 0) := "00";
   constant WM_CLAMP         : unsigned(1 downto 0) := "01";
   constant WM_REGION_CLAMP  : unsigned(1 downto 0) := "10";
   constant WM_REGION_REPEAT : unsigned(1 downto 0) := "11";

   -- One axis of wrapping.  The coordinate arrives signed because CLAMP has to
   -- be able to see a negative one -- STQ with a Q that has taken a coordinate
   -- off the left of the texture produces them, and a model that took an
   -- unsigned coordinate here would clamp the wrong end of the texture.
   function tex_wrap(u       : signed(12 downto 0);
                     mode    : unsigned(1 downto 0);
                     lo, hi  : unsigned(9 downto 0);
                     sz_log2 : unsigned(3 downto 0)) return unsigned;

   -- Position within a column, for the two indexed granularities.
   function column8(y : unsigned(3 downto 0);
                    x : unsigned(3 downto 0)) return unsigned;  -- 8 bits
   function column4(y : unsigned(3 downto 0);
                    x : unsigned(4 downto 0)) return unsigned;  -- 9 bits

   -- Block index within a page.  PCSX2's _blockTable8 is byte-identical to
   -- _blockTable32, so an indexed page arranges its blocks exactly as a 32-bit
   -- page does -- only the block holds more texels.  _blockTable4 is the same
   -- permutation with the roles of x and y exchanged, which is why block4 below
   -- passes its arguments the other way round rather than having a table of its
   -- own.
   function block_idx(by : unsigned(2 downto 0);
                      bx : unsigned(2 downto 0)) return unsigned;  -- 5 bits

   function tex_addr8(pagebase : unsigned(8 downto 0);
                      bw       : unsigned(5 downto 0);
                      x, y     : unsigned(10 downto 0)) return unsigned; -- byte
   function tex_addr4(pagebase : unsigned(8 downto 0);
                      bw       : unsigned(5 downto 0);
                      x, y     : unsigned(10 downto 0)) return unsigned; -- nibble

end package;

package body gs_texaddr_pkg is

   function tex_wrap(u       : signed(12 downto 0);
                     mode    : unsigned(1 downto 0);
                     lo, hi  : unsigned(9 downto 0);
                     sz_log2 : unsigned(3 downto 0)) return unsigned is
      variable mask : unsigned(10 downto 0);
      variable top  : signed(12 downto 0);
      variable uu   : unsigned(10 downto 0);
   begin
      -- size is 2**TW, so size-1 is a mask of TW ones.  TW is at most 10.
      mask := shift_left(to_unsigned(1, 11), to_integer(sz_log2)) - 1;
      top  := signed(resize(mask, 13));

      case mode is
         when WM_REPEAT =>
            return unsigned(u(10 downto 0)) and mask;

         when WM_CLAMP =>
            if u < 0 then
               return to_unsigned(0, 11);
            elsif u > top then
               return mask;
            else
               return unsigned(u(10 downto 0));
            end if;

         when WM_REGION_CLAMP =>
            if u < signed(resize(lo, 13)) then
               return resize(lo, 11);
            elsif u > signed(resize(hi, 13)) then
               return resize(hi, 11);
            else
               return unsigned(u(10 downto 0));
            end if;

         when others =>
            -- REGION_REPEAT.  MINU and MAXU are not a range here: MINU is a
            -- mask of the bits kept from the coordinate and MAXU is ored in
            -- afterwards.  Same two register fields, a different operation
            -- wearing them -- which is why this is not written as a clamp with
            -- different bounds.
            uu := unsigned(u(10 downto 0));
            return (uu and resize(lo, 11)) or resize(hi, 11);
      end case;
   end function;

   function column8(y : unsigned(3 downto 0);
                    x : unsigned(3 downto 0)) return unsigned is
   begin
      return y(3) & y(2) & (y(1) xor y(2) xor x(2)) & x(1)
           & y(0) & x(0) & x(3) & y(1);
   end function;

   function column4(y : unsigned(3 downto 0);
                    x : unsigned(4 downto 0)) return unsigned is
   begin
      return y(3) & y(2) & (y(1) xor y(2) xor x(2)) & x(1)
           & y(0) & x(0) & x(4) & x(3) & y(1);
   end function;

   function block_idx(by : unsigned(2 downto 0);
                      bx : unsigned(2 downto 0)) return unsigned is
   begin
      return bx(2) & by(1) & bx(1) & by(0) & bx(0);
   end function;

   function tex_addr8(pagebase : unsigned(8 downto 0);
                      bw       : unsigned(5 downto 0);
                      x, y     : unsigned(10 downto 0)) return unsigned is
      variable page : unsigned(8 downto 0);
   begin
      -- bw/2, because TBW counts 64 texels and a PSMT8 page is 128 across.
      page := resize(pagebase + resize(y(10 downto 6) * ('0' & bw(5 downto 1)), 9)
                     + resize(x(10 downto 7), 9), 9);
      return page
           & block_idx(resize(y(5 downto 4), 3), x(6 downto 4))
           & column8(y(3 downto 0), x(3 downto 0));
   end function;

   function tex_addr4(pagebase : unsigned(8 downto 0);
                      bw       : unsigned(5 downto 0);
                      x, y     : unsigned(10 downto 0)) return unsigned is
      variable page : unsigned(8 downto 0);
   begin
      page := resize(pagebase + resize(y(10 downto 7) * ('0' & bw(5 downto 1)), 9)
                     + resize(x(10 downto 7), 9), 9);
      -- block4 is block32 with x and y exchanged, so the arguments cross here.
      return page
           & block_idx(resize(x(6 downto 5), 3), y(6 downto 4))
           & column4(y(3 downto 0), x(4 downto 0));
   end function;

end package body;

-- ---------------------------------------------------------------------------
-- The unit itself: combinational, one texel in, one place in memory out.
--
-- It is combinational on purpose.  Where the pipeline registers go is a
-- decision for the sampler that will wrap this, and putting them here would be
-- guessing at a shape that docs/gs-texture.md says is still open.  A register
-- stage added around a correct function is a much smaller change than one
-- removed from inside it.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library work;
use work.gs_addr_pkg.all;
use work.gs_texaddr_pkg.all;

entity gs_texaddr is
   port
   (
      -- the texel, as an integer coordinate, before wrapping.  Signed: see
      -- tex_wrap.
      u_in    : in  signed(12 downto 0);
      v_in    : in  signed(12 downto 0);

      -- TEX0
      tbp     : in  unsigned(13 downto 0);   -- in 64-word blocks
      tbw     : in  unsigned(5 downto 0);    -- in 64 texels, whatever the psm
      psm     : in  unsigned(5 downto 0);
      tw      : in  unsigned(3 downto 0);    -- log2 width
      th      : in  unsigned(3 downto 0);    -- log2 height

      -- CLAMP
      wms     : in  unsigned(1 downto 0);
      wmt     : in  unsigned(1 downto 0);
      minu    : in  unsigned(9 downto 0);
      maxu    : in  unsigned(9 downto 0);
      minv    : in  unsigned(9 downto 0);
      maxv    : in  unsigned(9 downto 0);

      -- where the texel is
      lm_addr : out unsigned(16 downto 0);   -- 256-bit word in local memory
      bit_off : out unsigned(7 downto 0);    -- bit within that word
      width   : out unsigned(5 downto 0);    -- 4, 8, 16, 24 or 32

      -- the wrapped coordinate, which the sampler needs anyway for bilinear
      -- and which makes the wrap independently observable in a test
      u_out   : out unsigned(10 downto 0);
      v_out   : out unsigned(10 downto 0)
   );
end entity;

architecture rtl of gs_texaddr is
   signal u, v     : unsigned(10 downto 0);
   signal a32      : unsigned(19 downto 0);   -- 32-bit word address
   signal a16      : unsigned(19 downto 0);   -- ditto, 16-bit block order
   signal h16      : integer range 0 to 1;
   signal a8       : unsigned(21 downto 0);   -- byte address
   signal a4       : unsigned(22 downto 0);   -- nibble address
   signal sform    : std_logic;
begin

   u <= tex_wrap(u_in, wms, minu, maxu, tw);
   v <= tex_wrap(v_in, wmt, minv, maxv, th);
   u_out <= u;
   v_out <= v;

   -- The colour formats go through the frame buffer's own addressing, which is
   -- already verified from the drawing side.  A texture unit reading a frame
   -- buffer back has to agree with the rasteriser that wrote it, and the only
   -- way to guarantee that is to call the same function.
   a32 <= pix_addr(tbp, tbw, u, v);
   -- PSMCT16 and PSMCT16S differ only in the order of blocks within a page.
   sform <= '1' when psm = PSMCT16S else '0';
   a16 <= pix_addr16_page(tbp(13 downto 5), tbw, u, v, sform => sform);
   h16 <= fb16_half(u);

   a8  <= tex_addr8(tbp(13 downto 5), tbw, u, v);
   a4  <= tex_addr4(tbp(13 downto 5), tbw, u, v);

   process (all)
      variable word : unsigned(19 downto 0);
      variable off  : unsigned(7 downto 0);
   begin
      case psm is
         when PSMT8 =>
            -- a byte address: 32 bytes to a 256-bit word.
            lm_addr <= a8(21 downto 5);
            bit_off <= resize(a8(4 downto 0) & "000", 8);
            width   <= to_unsigned(8, 6);

         when PSMT4 =>
            -- a nibble address: 64 nibbles to a word.
            lm_addr <= a4(22 downto 6);
            bit_off <= resize(a4(5 downto 0) & "00", 8);
            width   <= to_unsigned(4, 6);

         when PSMCT16 | PSMCT16S =>
            lm_addr <= a16(19 downto 3);
            bit_off <= resize(a16(2 downto 0) & "00000", 8)
                       + to_unsigned(16 * h16, 8);
            width   <= to_unsigned(16, 6);

         when others =>
            -- PSMCT32, PSMCT24 and the three H formats: one 32-bit word,
            -- eight to a 256-bit line.  The H formats differ from PSMCT32 only
            -- in where inside that word they start and how wide they are --
            -- which is the whole reason this unit reports a bit offset rather
            -- than a texel address.
            word := a32;
            off  := resize(word(2 downto 0) & "00000", 8);
            lm_addr <= word(19 downto 3);
            case psm is
               when PSMCT24 =>
                  bit_off <= off;
                  width   <= to_unsigned(24, 6);
               when PSMT8H =>
                  bit_off <= off + 24;         -- the whole spare byte
                  width   <= to_unsigned(8, 6);
               when PSMT4HL =>
                  bit_off <= off + 24;         -- its low nibble
                  width   <= to_unsigned(4, 6);
               when PSMT4HH =>
                  bit_off <= off + 28;         -- its high nibble
                  width   <= to_unsigned(4, 6);
               when others =>                  -- PSMCT32
                  bit_off <= off;
                  width   <= to_unsigned(32, 6);
            end case;
      end case;
   end process;

end architecture;
