-- gs_pxcap.vhd -- catch a frame of PCRTC's output so the host can look at it.
--
-- The Graphics Synthesizer's video block drives a display at a pixel clock, and
-- a C1100 has no video connector. tools/gs/gsgrab.py already gets a picture off
-- the card by reading the frame buffer over PCIe and de-swizzling it on the
-- host -- but that is not PCRTC, and it says so. It reproduces the part of the
-- video block that is plumbing and skips the part that is a PlayStation 2:
-- two independent read circuits, their merge, the alpha blend between them, and
-- magnification.
--
-- This block is how that part becomes reviewable. It takes PCRTC's pixel stream
-- and writes it into a small RAM the host reads through CSRs, so a picture the
-- *card* composited can be compared against pcrtc_ref.py rather than assumed.
--
-- **It captures one frame, not a video.** `arm` waits for the next px_sof and
-- then stores pixels until the buffer is full or another frame begins, and
-- stops. A bring-up picture is static, the host reads at its leisure, and
-- nothing here has to keep up with 60 Hz -- which is the difference between a
-- few block RAMs and a DMA ring with a frame queue in HBM.
--
-- The default 64 x 64 is 4096 pixels: enough to hold a whole small raster, and
-- small enough to cost four block RAMs. The host reads a pixel at a time
-- because it reads once per frame and being obviously correct is worth more
-- here than being quick.
--
-- SPDX-License-Identifier: BSD-2-Clause
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity gs_pxcap is
   generic
   (
      -- 2^ADDR_BITS pixels. 12 is 4096: a 64 x 64 raster, four block RAMs.
      ADDR_BITS : integer := 12
   );
   port
   (
      clk       : in  std_logic;
      reset     : in  std_logic;

      -- the stream, straight from gs_pcrtc
      px_valid  : in  std_logic := '0';
      px_rgb    : in  std_logic_vector(23 downto 0) := (others => '0');
      px_sof    : in  std_logic := '0';

      -- control, from the host's clock domain via whatever crosses it
      arm       : in  std_logic := '0';   -- level: hold high to arm
      busy      : out std_logic := '0';   -- capturing right now
      done      : out std_logic := '0';   -- a frame is in the buffer
      count     : out unsigned(ADDR_BITS downto 0) := (others => '0');

      -- read it back
      rd_addr   : in  std_logic_vector(ADDR_BITS-1 downto 0) := (others => '0');
      rd_data   : out std_logic_vector(23 downto 0) := (others => '0')
   );
end entity;

architecture arch of gs_pxcap is
   type ram_t is array (0 to 2**ADDR_BITS - 1) of std_logic_vector(23 downto 0);
   signal ram   : ram_t := (others => (others => '0'));
   signal wptr  : unsigned(ADDR_BITS downto 0) := (others => '0');
   signal cap   : std_logic := '0';
   signal fin   : std_logic := '0';
   signal armed : std_logic := '0';
begin
   busy  <= cap;
   done  <= fin;
   count <= wptr;

   -- **One write statement, one write address.**
   --
   -- The first version of this block wrote `ram(0)` on the start-of-frame path
   -- and `ram(wptr)` on every other pixel. That reads naturally and is two
   -- write addresses into one array, which no block RAM has: synthesis gave up
   -- on inference and built the whole 4096 x 24 in fabric -- **30,725 LUTs and
   -- 98,428 flip-flops**, against the four block RAMs this block's comment
   -- claimed. It cost the Graphics Synthesizer its timing, and the failing
   -- paths were inside the rasteriser, where nothing had changed.
   --
   -- So the address is chosen first and written once. The lesson is the cheap
   -- one: a comment asserting a cost is not a measurement of it.
   process (clk)
      variable waddr : unsigned(ADDR_BITS-1 downto 0);
      variable wen   : std_logic;
   begin
      if rising_edge(clk) then
         rd_data <= ram(to_integer(unsigned(rd_addr)));

         waddr := wptr(ADDR_BITS-1 downto 0);
         wen   := '0';

         if reset = '1' then
            cap   <= '0';
            fin   <= '0';
            armed <= '0';
            wptr  <= (others => '0');
         else
            -- Arming is a level and clearing it disarms, so the host can
            -- abandon a capture that never started -- a raster whose circuits
            -- cover nothing emits no px_sof and would otherwise arm forever.
            if arm = '0' then
               armed <= '0';
               cap   <= '0';
               fin   <= '0';
            elsif armed = '0' and fin = '0' then
               armed <= '1';
               wptr  <= (others => '0');
            end if;

            if armed = '1' and cap = '0' and fin = '0' then
               -- Start on the first pixel of a frame, and store that pixel:
               -- px_sof arrives *with* a valid pixel, not before one.
               if px_valid = '1' and px_sof = '1' then
                  cap   <= '1';
                  waddr := (others => '0');
                  wen   := '1';
                  wptr  <= to_unsigned(1, wptr'length);
               end if;
            elsif cap = '1' then
               if px_valid = '1' and px_sof = '1' then
                  -- the next frame began: this one is whole, however short
                  cap <= '0';
                  fin <= '1';
               elsif px_valid = '1' then
                  if wptr < 2**ADDR_BITS then
                     wen  := '1';
                     wptr <= wptr + 1;
                  else
                     -- full. Stop rather than wrap: a torn picture that looks
                     -- plausible is worse than a short one that cannot.
                     cap <= '0';
                     fin <= '1';
                  end if;
               end if;
            end if;
         end if;

         -- the only write to `ram` anywhere in this block
         if wen = '1' then
            ram(to_integer(waddr)) <= px_rgb;
         end if;
      end if;
   end process;
end architecture;
