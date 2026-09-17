-- gs_clut.vhd -- the Graphics Synthesizer's palette, and the rules for when it reloads.
--
-- The CLUT is the second piece of the texture unit to become hardware, after
-- gs_texaddr. It is a good next piece for the same reason addressing was a good
-- first one: it is almost entirely structure, it is exhaustively checkable
-- against sim/gs/gs_ref.py, and it does not depend on the shape of the pixel
-- pipeline that the sampler is waiting for.
--
-- It is *not* a register file. The palette lives in local memory like everything
-- else and is copied into a 1 KB buffer on the chip when TEX0 says so. So this
-- block is two things that are easy to think of as one and must not be:
--
--   * **a buffer**, 256 entries of 32 bits, read by the sampler;
--   * **a cache with explicit invalidation**, whose rules decide when that
--     buffer is refilled from memory.
--
-- Getting the first wrong gives wrong colours, which is obvious. Getting the
-- second wrong gives *the previous primitive's* colours, several primitives
-- later, which is much harder to recognise and is why CLD is modelled here at
-- all rather than treated as "reload every time".
--
-- ## CSM1 is derived, not tabulated
--
-- Like the block and column maps, the swizzled CLUT layout looks like an
-- arbitrary permutation and is not. Two observations give all of it, and
-- sim/gs/gs_ref.py records how they were arrived at:
--
--   1. A 16-entry CLUT is exactly one PSMCT32 *column*, 8 wide by 2 high, read
--      in raster order.
--   2. A 256-entry CLUT is that pattern stepped over four consecutive blocks,
--      alternating between two blocks before advancing.
--
-- So `clut_csm1_32` below is one expression, and it reproduces PCSX2's
-- 128-entry clutTableT32I8 exactly. tools/gs/xcheck_clut.py is what makes that
-- a claim which can fail -- including the specific check that the derivation is
-- **not** the plausible wrong one. A 16 x 16 PSMCT32 image is also a bijection
-- over 256 entries, so it passes a bijectivity test, and it occupies blocks 0,
-- 1, 4 and 5 of a page rather than four consecutive blocks. Being a permutation
-- is not the same as being the right permutation.
--
-- ## What is deliberately not here
--
-- **16-bit CLUTs.** `CPSM` can name PSMCT16 or PSMCT16S, and that layout has
-- not been derived -- gs_ref.py leaves it unimplemented on purpose rather than
-- guessing, because a wrong palette layout looks like a wrong palette and not
-- like a wrong address. This block raises `unsupported` rather than producing
-- something plausible. A block that says "I do not know" is worth more than one
-- that is quietly wrong for a whole class of textures.
--
-- ## The cost, stated rather than hidden
--
-- A load reads **one entry per local-memory access**, so a 256-entry palette
-- costs 256 reads on a port that the rasteriser and the display already share.
-- That is slow and it is the honest first version: consecutive CSM1 entries do
-- often land in the same 256-bit line, and a later version can coalesce them,
-- but coalescing a swizzle is exactly the kind of optimisation that is wrong in
-- a way no colour test notices. Correct first, and CLD is what keeps it from
-- mattering -- a palette that reloads on every primitive is the case the
-- hardware's own designers refused to pay for.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library work;
use work.gs_addr_pkg.all;

package gs_clut_pkg is

   -- CLD, the load control: three bits of TEX0 saying whether this write should
   -- cause a reload. Two of the six compare against a remembered pointer.
   constant CLD_NONE      : unsigned(2 downto 0) := "000";
   constant CLD_LOAD      : unsigned(2 downto 0) := "001";
   constant CLD_LOAD_CBP0 : unsigned(2 downto 0) := "010";
   constant CLD_LOAD_CBP1 : unsigned(2 downto 0) := "011";
   constant CLD_IF_CBP0   : unsigned(2 downto 0) := "100";
   constant CLD_IF_CBP1   : unsigned(2 downto 0) := "101";

   -- Word index within a block, from a pixel's low three bits. This is the same
   -- interleave gs_addr_pkg builds into pix_addr_page; the CLUT needs it as a
   -- function of its own because it indexes a column directly rather than a
   -- pixel.
   function column32(y : unsigned(2 downto 0);
                     x : unsigned(2 downto 0)) return unsigned;   -- 6 bits

   -- Word offset, from the CLUT base, of 32-bit entry `c` in CSM1.
   function clut_csm1_32(c : unsigned(7 downto 0)) return unsigned;  -- 8 bits

end package;

package body gs_clut_pkg is

   function column32(y : unsigned(2 downto 0);
                     x : unsigned(2 downto 0)) return unsigned is
   begin
      return y(2) & y(1) & x(2) & x(1) & y(0) & x(0);
   end function;

   function clut_csm1_32(c : unsigned(7 downto 0)) return unsigned is
      variable j   : unsigned(3 downto 0);
      variable k   : unsigned(2 downto 0);
      variable hi  : std_logic;
      variable col : unsigned(5 downto 0);
   begin
      j  := c(3 downto 0);            -- position within one 8 x 2 column
      k  := c(6 downto 4);            -- which column, alternating between blocks
      hi := c(7);                     -- the second pair of blocks
      -- column32's y is one bit here and its x three, so the result is under 16
      -- and the four terms -- 128*hi, 64*k0, 16*(k >> 1), col -- occupy
      -- disjoint bits. A sum of disjoint terms is a concatenation, so that is
      -- how it is written: this is a wire permutation and not an adder, the
      -- same as every other swizzle in this design.
      col := column32("00" & j(3), j(2 downto 0));
      return hi & k(0) & k(2 downto 1) & col(3 downto 0);
   end function;

end package body;

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library work;
use work.gs_addr_pkg.all;
use work.gs_clut_pkg.all;

entity gs_clut is
   port
   (
      clk        : in  std_logic;
      reset      : in  std_logic;

      -- A TEX0 write. `we` is a pulse; tex0 and texclut must be stable with it.
      -- TEXCLUT only matters when CSM is 1 and is ignored otherwise.
      we         : in  std_logic;
      tex0       : in  std_logic_vector(63 downto 0);
      texclut    : in  std_logic_vector(63 downto 0);

      -- local memory, the same port shape gs_lmem presents: a read is accepted
      -- when rd_en is high and answered later with rd_valid.
      rd_en      : out std_logic;
      rd_addr    : out std_logic_vector(16 downto 0);
      rd_data    : in  std_logic_vector(255 downto 0);
      rd_valid   : in  std_logic;

      -- the sampler's port: an index in, its colour out one clock later
      idx        : in  unsigned(7 downto 0);
      entry      : out std_logic_vector(31 downto 0);

      busy       : out std_logic;
      -- Counted so a test can assert that a reload did **not** happen, which is
      -- the half of CLD that a colour comparison cannot see.
      loads      : out unsigned(15 downto 0);
      -- A CLUT format this block does not implement was asked for; nothing was
      -- loaded and the buffer still holds what it held.
      unsupported: out std_logic
   );
end entity;

architecture rtl of gs_clut is

   -- TEX0 fields. The positions are gs_ref.py's and are the manual's.
   alias t_psm  : std_logic_vector(5 downto 0)  is tex0(25 downto 20);
   alias t_cbp  : std_logic_vector(13 downto 0) is tex0(50 downto 37);
   alias t_cpsm : std_logic_vector(3 downto 0)  is tex0(54 downto 51);
   alias t_csm  : std_logic                     is tex0(55);
   alias t_csa  : std_logic_vector(4 downto 0)  is tex0(60 downto 56);
   alias t_cld  : std_logic_vector(2 downto 0)  is tex0(63 downto 61);

   -- TEXCLUT, for CSM2.
   alias x_cbw  : std_logic_vector(5 downto 0)  is texclut(5 downto 0);
   alias x_cou  : std_logic_vector(5 downto 0)  is texclut(11 downto 6);
   alias x_cov  : std_logic_vector(9 downto 0)  is texclut(21 downto 12);

   type t_entries is array (0 to 255) of std_logic_vector(31 downto 0);
   signal entries : t_entries := (others => (others => '0'));
   attribute ram_style : string;
   attribute ram_style of entries : signal is "block";

   type t_state is (IDLE, ISSUE, WAIT_D, FINISH);
   signal state : t_state := IDLE;

   -- The two remembered pointers CLD compares against, and whether they have
   -- ever been set. `null` in the model is a real state: before any CLD of 2 or
   -- 3 has been seen, a comparison form must reload rather than match zero.
   signal cbp0, cbp1       : unsigned(13 downto 0) := (others => '0');
   signal cbp0_v, cbp1_v   : std_logic := '0';

   signal r_base   : unsigned(19 downto 0) := (others => '0');  -- words
   signal r_csm    : std_logic := '0';
   signal r_dst    : unsigned(7 downto 0) := (others => '0');
   signal r_n      : unsigned(8 downto 0) := (others => '0');   -- 16 or 256
   signal r_cbw    : unsigned(5 downto 0) := (others => '0');
   signal r_cou    : unsigned(5 downto 0) := (others => '0');
   signal r_cov    : unsigned(9 downto 0) := (others => '0');
   signal c        : unsigned(8 downto 0) := (others => '0');
   signal lane     : unsigned(2 downto 0) := (others => '0');

   signal n_loads  : unsigned(15 downto 0) := (others => '0');
   signal r_unsup  : std_logic := '0';

   -- Is this PSM one of the three 4-bit indexed formats? Those take a 16-entry
   -- palette; everything else takes 256.
   function is_4bit(psm : std_logic_vector(5 downto 0)) return boolean is
   begin
      return psm = "010100"      -- PSMT4
          or psm = "100100"      -- PSMT4HL
          or psm = "101100";     -- PSMT4HH
   end function;

   -- Should this TEX0 write cause a reload? The two comparison forms are the
   -- reason CLD exists: the GS has no bandwidth to re-read a palette per
   -- primitive, so a game names a pointer and says "only if it changed".
   function should_load(cld    : std_logic_vector(2 downto 0);
                        cbp    : unsigned(13 downto 0);
                        p0, p1 : unsigned(13 downto 0);
                        v0, v1 : std_logic) return boolean is
   begin
      case unsigned(cld) is
         when CLD_NONE      => return false;
         when CLD_LOAD      => return true;
         when CLD_LOAD_CBP0 => return true;
         when CLD_LOAD_CBP1 => return true;
         when CLD_IF_CBP0   => return v0 = '0' or p0 /= cbp;
         when CLD_IF_CBP1   => return v1 = '0' or p1 /= cbp;
         -- 6 and 7 are reserved. Do nothing rather than guess: a reserved
         -- encoding that quietly reloads is indistinguishable from CLD_LOAD in
         -- every test that only looks at colours.
         when others        => return false;
      end case;
   end function;

   -- Word offset of entry `c` for the layout in force.
   function csm2_off(cbw  : unsigned(5 downto 0);
                     cou  : unsigned(5 downto 0);
                     cov  : unsigned(9 downto 0);
                     c    : unsigned(8 downto 0)) return unsigned is
      variable x  : unsigned(10 downto 0);
      variable bw : unsigned(5 downto 0);
   begin
      -- CSM2 is a one-pixel-high strip out of an ordinary PSMCT32 buffer, so
      -- there is no swizzle to undo -- it is addressed exactly as any other
      -- PSMCT32 read, which is why this calls pix_addr_page rather than having
      -- arithmetic of its own.
      x  := resize(cou & "0000", 11) + resize(c, 11);
      bw := cbw when cbw /= 0 else to_unsigned(1, 6);
      return pix_addr_page(to_unsigned(0, 9), bw, x, resize(cov, 11));
   end function;

   signal off      : unsigned(19 downto 0);
   signal word_adr : unsigned(19 downto 0);
begin

   busy        <= '0' when state = IDLE else '1';
   loads       <= n_loads;
   unsupported <= r_unsup;

   off <= resize(clut_csm1_32(resize(c + r_dst, 8)), 20) when r_csm = '0'
          else resize(csm2_off(r_cbw, r_cou, r_cov, c), 20);
   word_adr <= r_base + off;

   rd_addr <= std_logic_vector(word_adr(19 downto 3));
   rd_en   <= '1' when state = ISSUE else '0';

   process (clk)
      variable cbp : unsigned(13 downto 0);
      variable dst : unsigned(7 downto 0);
   begin
      if rising_edge(clk) then
         if reset = '1' then
            state   <= IDLE;
            cbp0_v  <= '0';
            cbp1_v  <= '0';
            n_loads <= (others => '0');
            r_unsup <= '0';
         else
            case state is

               when IDLE =>
                  if we = '1' then
                     r_unsup <= '0';
                     cbp := unsigned(t_cbp);

                     -- The remembered pointers are updated by the two settings
                     -- that say so, and that happens whether or not a
                     -- comparison form would have reloaded. They are a side
                     -- effect of the write, not of the load.
                     if unsigned(t_cld) = CLD_LOAD_CBP0 then
                        cbp0 <= cbp; cbp0_v <= '1';
                     elsif unsigned(t_cld) = CLD_LOAD_CBP1 then
                        cbp1 <= cbp; cbp1_v <= '1';
                     end if;

                     if should_load(t_cld, cbp, cbp0, cbp1, cbp0_v, cbp1_v) then
                        if t_cpsm /= "0000" then
                           -- Only PSMCT32 CLUTs are derived. Say so rather than
                           -- load something shaped like a palette.
                           r_unsup <= '1';
                        else
                           -- CBP counts 256-byte blocks and a block is 64
                           -- words. Writing this as (cbp << 5) * 4 -- reaching
                           -- for the blocks-to-pages shift pix_addr uses and
                           -- then scaling -- gives cbp * 128, out by exactly a
                           -- factor of two, and reads back a palette of zeros.
                           r_base <= resize(cbp & "000000", 20);   -- blocks -> words, 64 to a block
                           r_csm  <= t_csm;
                           r_cbw  <= unsigned(x_cbw);
                           r_cou  <= unsigned(x_cou);
                           r_cov  <= unsigned(x_cov);
                           if is_4bit(t_psm) then
                              r_n <= to_unsigned(16, 9);
                              -- CSA offsets the destination within the buffer
                              -- in 16-entry steps: how eight palettes share one
                              -- CLUT for 4-bit textures.
                              dst := unsigned(t_csa(3 downto 0)) & "0000";   -- 16-entry steps
                           else
                              r_n <= to_unsigned(256, 9);
                              dst := (others => '0');
                           end if;
                           r_dst <= dst;
                           c     <= (others => '0');
                           state <= ISSUE;
                        end if;
                     end if;
                  end if;

               when ISSUE =>
                  -- One entry per access. rd_en is combinational on this state,
                  -- so the address presented is word_adr for the current c.
                  lane  <= word_adr(2 downto 0);
                  state <= WAIT_D;

               when WAIT_D =>
                  if rd_valid = '1' then
                     entries(to_integer(resize(c + r_dst, 8))) <=
                        rd_data(to_integer(lane) * 32 + 31
                                downto to_integer(lane) * 32);
                     if c + 1 = r_n then
                        state <= FINISH;
                     else
                        c     <= c + 1;
                        state <= ISSUE;
                     end if;
                  end if;

               when FINISH =>
                  n_loads <= n_loads + 1;
                  state   <= IDLE;

            end case;
         end if;
      end if;
   end process;

   -- The sampler's read. One statement, so the array stays a true dual-port
   -- memory and infers block RAM -- the lesson gs_ram paid for twice.
   process (clk)
   begin
      if rising_edge(clk) then
         entry <= entries(to_integer(idx));
      end if;
   end process;

end architecture;
