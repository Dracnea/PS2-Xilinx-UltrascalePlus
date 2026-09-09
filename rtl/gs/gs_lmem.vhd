-- gs_lmem.vhd -- the Graphics Synthesizer's 4 MB of local memory, in UltraRAM.
--
-- This is the memory only; nothing that understands it. The GS's page/block
-- swizzle, the pixel formats and the buffer-width arithmetic all belong to the
-- rasteriser and the texture unit, which decide *which* address to touch. What
-- is settled here is where those bytes physically live and how fast they can be
-- reached, because that is what decides whether a GS is possible on these parts
-- at all.
--
-- Why UltraRAM and not HBM. The real GS runs its local memory at 2048 bits and
-- 147.456 MHz, about 38 GB/s, and every drawn pixel is a read-modify-write of
-- it. One HBM pseudo-channel is 14.4 GB/s at best and carries a latency of
-- 100-150 ns, which a rasteriser cannot hide the way a CPU can; it would take
-- three or more channels *and* an access pattern HBM likes, which a swizzled
-- framebuffer is not. On-die memory is the right home for it and is affordable:
-- 4 MB is 128 URAM, 20 % of the C1100's 640 and 40 % of the FK33's 320
-- (docs/hbm.md). The EE's 32 MB main memory is the opposite case and belongs in
-- HBM -- at 1024 URAM it does not fit on either part.
--
-- Organisation follows iop_ram: a URAM288 is 4096 x 72, so a 32-bit-wide array
-- wastes 40 bits of every row.  At 256 bits and 131072 words, Vivado cascades
-- 4 URAMs across and 32 deep = 128 URAMs, which is the figure the budget
-- assumes.  It has to be a flat 2D array to infer at all -- see the note in the
-- architecture.
--
-- The port is 256 bits wide and dual: one write and one read per cycle. At the
-- 300 MHz this is expected to close at, that is 9.6 GB/s each way. It is a
-- quarter of the real GS's figure and deliberately so -- a wider port is a
-- matter of instantiating more of these in parallel over disjoint address
-- ranges, and the right width is the one the rasteriser turns out to need. It
-- is written as a parameter rather than a constant so that decision costs an
-- edit and not a rewrite.
--
-- NOTE (unverified): 300 MHz and the resulting bandwidth are targets, not
-- measurements; no rasteriser exists to close timing against. Verify by
-- fitting this alongside a real GS front end.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity gs_lmem is
   generic
   (
      ADDR_BITS  : integer := 17;   -- 2^17 words of DATA_WIDTH bits = 4 MB at 256
      DATA_WIDTH : integer := 256
   );
   port
   (
      clk        : in  std_logic;

      -- write port; addresses count DATA_WIDTH-bit words
      wr_en      : in  std_logic;
      wr_addr    : in  std_logic_vector(ADDR_BITS-1 downto 0);
      wr_data    : in  std_logic_vector(DATA_WIDTH-1 downto 0);
      wr_be      : in  std_logic_vector(DATA_WIDTH/8-1 downto 0);

      -- read port; rd_data is valid two clocks after rd_en, which is what lets
      -- the URAM output registers be used
      rd_en      : in  std_logic;
      rd_addr    : in  std_logic_vector(ADDR_BITS-1 downto 0);
      rd_data    : out std_logic_vector(DATA_WIDTH-1 downto 0) := (others => '0');
      rd_valid   : out std_logic := '0'
   );
end entity;

architecture arch of gs_lmem is

   -- A FLAT two-dimensional array, which is what iop_ram uses and what Vivado
   -- infers UltraRAM from.  An earlier version banked this as an array of
   -- arrays; out-of-context synthesis warned "Potential Runtime issue for
   -- 3D-RAM ... mem_reg with 33554432 registers" and then ground for eleven
   -- minutes without finishing, because it was building flip-flops rather than
   -- memory.  A 3D array is not a memory as far as inference is concerned.
   type t_mem is array (0 to 2**ADDR_BITS-1) of std_logic_vector(DATA_WIDTH-1 downto 0);
   signal mem : t_mem := (others => (others => '0'));
   attribute ram_style : string;
   attribute ram_style of mem : signal is "ultra";

   -- Two register stages on the read path, matching iop_ram's two-cycle URAM
   -- latency: one for the array output, one for the URAM output register.
   signal rd_q1 : std_logic_vector(DATA_WIDTH-1 downto 0) := (others => '0');
   signal rd_v1 : std_logic := '0';

begin

   process (clk)
   begin
      if rising_edge(clk) then
         if (wr_en = '1') then
            for b in 0 to DATA_WIDTH/8-1 loop
               if (wr_be(b) = '1') then
                  mem(to_integer(unsigned(wr_addr)))(b*8+7 downto b*8) <=
                     wr_data(b*8+7 downto b*8);
               end if;
            end loop;
         end if;

         if (rd_en = '1') then
            rd_q1 <= mem(to_integer(unsigned(rd_addr)));
         end if;
         rd_v1 <= rd_en;

         rd_data  <= rd_q1;
         rd_valid <= rd_v1;
      end if;
   end process;

end architecture;
