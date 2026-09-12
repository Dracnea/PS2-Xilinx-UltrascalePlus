-- gs_addr_pkg.vhd -- where a pixel lives in the Graphics Synthesizer's memory.
--
-- The swizzle is the one piece of the GS that more than one block needs to get
-- exactly right.  The rasteriser writes through it and PCRTC reads back through
-- it, and if the two ever disagreed the picture would be scrambled in a way
-- that no differential test of either block on its own could find -- each would
-- still match its own model.  So it is written once, here.
--
-- In hardware this is not arithmetic at all:
--
--     word address = page(8:0) & x5 & y4 & x4 & y3 & x3 & y2 & y1 & x2 & x1 & y0 & x0
--
-- The low eleven bits are the low bits of x and y interleaved in a fixed order.
-- The manual presents it as three tables and PCSX2 stores two of them as literal
-- arrays, but it is a wire permutation and costs nothing.  Only the page number
-- needs an adder.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

package gs_addr_pkg is

   -- The five bits after the page are the block index within it, and the six
   -- after that the word within the block.  The depth formats use the same
   -- tables with the block index exclusive-ored by 24 -- bits 3 and 4, which
   -- are y(4) and x(5) here.  The GS User's Manual gives the PSMZ32 and PSMZ16
   -- block figures as their colour figures with every entry xor 24, and PCSX2
   -- says the same thing as `swizzle32Z {swizzleTables32, 0x18}`.
   --
   -- Getting this wrong is invisible in a differential test, because the
   -- reference and the RTL are wrong together: it shows up only against silicon
   -- or wherever a Z buffer shares memory with something addressed as colour --
   -- which is exactly what reading the Z buffer back through Local->Host does.
   function pix_addr_page(pg : unsigned(8 downto 0); bw : unsigned(5 downto 0);
                          x, y : unsigned(10 downto 0);
                          zblk : std_logic := '0') return unsigned;

   function pix_addr(bp : unsigned(13 downto 0); bw : unsigned(5 downto 0);
                     x, y : unsigned(10 downto 0)) return unsigned;

   -- The 16-bit formats.  A page is 64x64 pixels, a block 16x8, a column 16x2,
   -- and two pixels share a word.  The six bits naming the word within a block
   -- are the *same* interleave as at 32 bits -- a column holds sixteen words
   -- either way, and the extra eight pixels of width go into the upper half of
   -- those same words -- so only the block index changes, and which half, which
   -- is x(3) and is returned by fb16_half rather than folded in here.
   --
   -- PSMCT16 and PSMCT16S differ only in the order of blocks within a page.
   -- Both orders are wire permutations here, as the 32-bit one is.
   function pix_addr16_page(pg : unsigned(8 downto 0); bw : unsigned(5 downto 0);
                            x, y : unsigned(10 downto 0);
                            sform : std_logic;
                            zblk  : std_logic := '0') return unsigned;

   function fb16_half(x : unsigned(10 downto 0)) return integer;

   -- RGBA5551 <-> RGBA8888.  These are not inverses of each other and the
   -- manual is explicit about both directions: writing truncates the low three
   -- bits of each channel, and reading shifts up with zeros rather than
   -- replicating the top bits.  Alpha read back from a 16-bit buffer is 0x80 or
   -- 0x00, never 0xFF.
   function pack16(v : std_logic_vector(31 downto 0)) return std_logic_vector;
   function expand16(v : std_logic_vector(15 downto 0)) return std_logic_vector;

end package;

package body gs_addr_pkg is

   function pix_addr_page(pg : unsigned(8 downto 0); bw : unsigned(5 downto 0);
                          x, y : unsigned(10 downto 0);
                          zblk : std_logic := '0') return unsigned is
      variable page : unsigned(8 downto 0);
   begin
      page := resize(pg + resize(y(10 downto 5) * bw, 9)
                     + resize(x(10 downto 6), 9), 9);
      return page & (x(5) xor zblk) & (y(4) xor zblk) & x(4) & y(3) & x(3)
                  & y(2) & y(1) & x(2) & x(1) & y(0) & x(0);
   end function;

   function pix_addr(bp : unsigned(13 downto 0); bw : unsigned(5 downto 0);
                     x, y : unsigned(10 downto 0)) return unsigned is
   begin
      return pix_addr_page(bp(13 downto 5), bw, x, y);
   end function;

   function pix_addr16_page(pg : unsigned(8 downto 0); bw : unsigned(5 downto 0);
                            x, y : unsigned(10 downto 0);
                            sform : std_logic;
                            zblk  : std_logic := '0') return unsigned is
      variable page : unsigned(8 downto 0);
      variable blk  : unsigned(4 downto 0);
   begin
      page := resize(pg + resize(y(10 downto 6) * bw, 9)
                     + resize(x(10 downto 6), 9), 9);
      if sform = '0' then
         blk := y(5) & x(5) & y(4) & x(4) & y(3);
      else
         blk := x(5) & y(4) & y(5) & x(4) & y(3);
      end if;
      blk := blk xor ("11" & "000" and (4 downto 0 => zblk));
      return page & blk & y(2) & y(1) & x(2) & x(1) & y(0) & x(0);
   end function;

   function fb16_half(x : unsigned(10 downto 0)) return integer is
   begin
      if x(3) = '1' then
         return 1;
      else
         return 0;
      end if;
   end function;

   function pack16(v : std_logic_vector(31 downto 0)) return std_logic_vector is
   begin
      return v(31) & v(23 downto 19) & v(15 downto 11) & v(7 downto 3);
   end function;

   function expand16(v : std_logic_vector(15 downto 0)) return std_logic_vector is
      variable a : std_logic_vector(7 downto 0);
   begin
      if v(15) = '1' then
         a := x"80";
      else
         a := x"00";
      end if;
      return a & v(14 downto 10) & "000" & v(9 downto 5) & "000"
               & v(4 downto 0) & "000";
   end function;

end package body;
