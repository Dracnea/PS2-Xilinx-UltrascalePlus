-- gs_top.vhd -- the Graphics Synthesizer as one unit: the GIF and rasteriser
-- wired to their own local memory, with a host port to read the result back.
--
-- Until this existed, gs_gif and gs_lmem had never been connected.  Their ports
-- were shaped for each other from the start -- gs_gif's comment says "shaped for
-- gs_lmem" -- and each was verified against a testbench that modelled the other:
-- tb_gs.sv models a memory with two clocks of latency because that is what the
-- UltraRAM output registers give, and sim/mem/tb_mem.sv exercises the memory
-- with no rasteriser in sight.  Two halves proven separately and never joined is
-- a seam worth closing before either goes near a card.
--
-- The only thing here that is not wiring is the read arbiter.  gs_lmem has one
-- read port and two customers: the rasteriser, which reads for the
-- read-modify-write that FBMSK, blending and the depth test all need, and the
-- host, which reads the finished buffer back.  The rasteriser wins whenever it
-- asks, because it is inside a pixel and the host is not.
--
-- Returning the data to the right customer is the part that needs care.  A read
-- takes two clocks and rd_valid does not say whose read it was, so ownership
-- travels alongside the request in a two-stage shift register.  Getting this
-- wrong would hand the rasteriser the host's data in the middle of a blend,
-- which would look like a blender bug and not like an arbiter bug.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity gs_top is
   generic
   (
      -- 2^17 words of 256 bits is the GS's whole 4 MB.  A smaller memory is
      -- useful in simulation and on a part with less UltraRAM than the C1100.
      ADDR_BITS : integer := 17
   );
   port
   (
      clk        : in  std_logic;
      reset      : in  std_logic;

      -- GIF input: one quadword at a time
      gif_valid  : in  std_logic;
      gif_data   : in  std_logic_vector(127 downto 0);
      gif_ready  : out std_logic;

      -- host read port into local memory, for reading a drawn buffer back
      h_rd_en    : in  std_logic := '0';
      h_rd_addr  : in  std_logic_vector(ADDR_BITS-1 downto 0) := (others => '0');
      h_rd_data  : out std_logic_vector(255 downto 0) := (others => '0');
      h_rd_valid : out std_logic := '0';

      -- the same observation points gs_gif offers on its own
      dbg_sel     : in  unsigned(6 downto 0) := (others => '0');
      dbg_reg     : out std_logic_vector(63 downto 0);
      dbg_unknown : out unsigned(15 downto 0);
      dbg_pixels  : out unsigned(31 downto 0)
   );
end entity;

architecture arch of gs_top is
   -- rasteriser side
   signal r_wr_en   : std_logic;
   signal r_wr_addr : std_logic_vector(16 downto 0);
   signal r_wr_data : std_logic_vector(255 downto 0);
   signal r_wr_be   : std_logic_vector(31 downto 0);
   signal r_rd_en   : std_logic;
   signal r_rd_addr : std_logic_vector(16 downto 0);
   signal r_rd_data : std_logic_vector(255 downto 0);
   signal r_rd_valid: std_logic;

   -- memory side
   signal m_rd_en   : std_logic;
   signal m_rd_addr : std_logic_vector(ADDR_BITS-1 downto 0);
   signal m_rd_data : std_logic_vector(255 downto 0);
   signal m_rd_valid: std_logic;

   -- who owns each read in flight.  '1' is the rasteriser, '0' the host; the
   -- valid bit beside it says whether there is a read in that slot at all.
   signal own       : std_logic_vector(1 downto 0) := "00";
   signal own_v     : std_logic_vector(1 downto 0) := "00";
begin

   gif : entity work.gs_gif
      port map (
         clk => clk, reset => reset,
         gif_valid => gif_valid, gif_data => gif_data, gif_ready => gif_ready,
         wr_en => r_wr_en, wr_addr => r_wr_addr,
         wr_data => r_wr_data, wr_be => r_wr_be,
         rd_en => r_rd_en, rd_addr => r_rd_addr,
         rd_data => r_rd_data, rd_valid => r_rd_valid,
         dbg_sel => dbg_sel, dbg_reg => dbg_reg,
         dbg_unknown => dbg_unknown, dbg_pixels => dbg_pixels);

   mem : entity work.gs_lmem
      generic map (ADDR_BITS => ADDR_BITS, DATA_WIDTH => 256)
      port map (
         clk => clk,
         wr_en => r_wr_en,
         wr_addr => r_wr_addr(ADDR_BITS-1 downto 0),
         wr_data => r_wr_data, wr_be => r_wr_be,
         rd_en => m_rd_en, rd_addr => m_rd_addr,
         rd_data => m_rd_data, rd_valid => m_rd_valid);

   -- The rasteriser wins.  It asks from inside a pixel that is already half
   -- drawn; the host is reading a buffer that is finished and can wait.
   m_rd_en   <= r_rd_en or h_rd_en;
   m_rd_addr <= r_rd_addr(ADDR_BITS-1 downto 0) when r_rd_en = '1'
                else h_rd_addr;

   track : process (clk)
   begin
      if rising_edge(clk) then
         if reset = '1' then
            own   <= "00";
            own_v <= "00";
         else
            own(1)   <= own(0);
            own_v(1) <= own_v(0);
            own(0)   <= r_rd_en;                  -- '1' rasteriser, '0' host
            own_v(0) <= r_rd_en or h_rd_en;
         end if;
      end if;
   end process;

   r_rd_data  <= m_rd_data;
   r_rd_valid <= m_rd_valid and own_v(1) and own(1);
   h_rd_data  <= m_rd_data;
   h_rd_valid <= m_rd_valid and own_v(1) and not own(1);

end architecture;
