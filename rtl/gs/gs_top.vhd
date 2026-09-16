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
      dbg_pixels  : out unsigned(31 downto 0);

      -- ---- the display ----------------------------------------------------
      -- Privileged registers, by offset from 0x12000000: PMODE, DISPFB1/2,
      -- DISPLAY1/2, BGCOLOR. They are a separate space from the general
      -- registers the GIF writes, which is why they arrive on their own port
      -- rather than through gif_data.
      pr_we       : in  std_logic := '0';
      pr_addr     : in  std_logic_vector(7 downto 0) := (others => '0');
      pr_data     : in  std_logic_vector(63 downto 0) := (others => '0');
      -- Raster totals, until there is a sync generator to derive them.
      v_total     : in  unsigned(11 downto 0) := to_unsigned(480, 12);
      h_total     : in  unsigned(11 downto 0) := to_unsigned(640, 12);
      -- Held low, PCRTC idles with its counters at zero and never asks for the
      -- memory, which is what lets the rasteriser be tested as it was before
      -- this port existed.
      disp_enable : in  std_logic := '0';
      px_valid    : out std_logic := '0';
      px_rgb      : out std_logic_vector(23 downto 0) := (others => '0');
      px_x        : out unsigned(11 downto 0) := (others => '0');
      px_y        : out unsigned(11 downto 0) := (others => '0');
      px_sof      : out std_logic := '0';
      -- How hard the display and the rasteriser actually fought over the one
      -- read port. A contention test that does not check these can pass
      -- because nothing contended, which proves nothing at all.
      dbg_crtc_rd    : out unsigned(31 downto 0) := (others => '0');
      dbg_crtc_stall : out unsigned(31 downto 0) := (others => '0')
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

   -- PCRTC side
   signal p_rd_en   : std_logic;
   signal p_rd_addr : std_logic_vector(ADDR_BITS-1 downto 0);
   signal p_rd_valid: std_logic;
   signal p_grant   : std_logic;

   -- Who owns each read in flight.  Three customers now, so this is two bits
   -- wide per stage rather than one, and the valid bit beside it still says
   -- whether there is a read in that slot at all.
   constant OWN_HOST  : std_logic_vector(1 downto 0) := "00";
   constant OWN_RAST  : std_logic_vector(1 downto 0) := "01";
   constant OWN_PCRTC : std_logic_vector(1 downto 0) := "10";
   signal own0, own1 : std_logic_vector(1 downto 0) := OWN_HOST;
   signal own_nxt    : std_logic_vector(1 downto 0) := OWN_HOST;
   signal own_v      : std_logic_vector(1 downto 0) := "00";
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

   -- **The rasteriser still wins, and the order is forced rather than chosen.**
   --
   -- It asks from inside a pixel that is already half drawn, and its port has
   -- no way of being told to wait: rd_en out, rd_valid in, no ready. A refusal
   -- it cannot see is a dropped read, so it cannot be refused.
   --
   -- PCRTC is next, and it is second because it is the one that *can* wait --
   -- `rd_ready` was added to it for this. It tracks its outstanding reads with
   -- a need/got pair rather than assuming a fixed latency, so a grant deferred
   -- by a few cycles costs it nothing but a later pixel.
   --
   -- The host is last and may still be refused outright, which is what it was
   -- before this block gained a third customer: it reads a buffer that is
   -- finished, and the tools that drive it retry.
   p_grant   <= not r_rd_en;

   m_rd_en   <= r_rd_en or p_rd_en or h_rd_en;
   m_rd_addr <= r_rd_addr(ADDR_BITS-1 downto 0) when r_rd_en = '1'
                else p_rd_addr when p_rd_en = '1'
                else h_rd_addr;

   own_nxt   <= OWN_RAST  when r_rd_en = '1'
                else OWN_PCRTC when p_rd_en = '1'
                else OWN_HOST;

   count : process (clk)
   begin
      if rising_edge(clk) then
         if reset = '1' then
            dbg_crtc_rd    <= (others => '0');
            dbg_crtc_stall <= (others => '0');
         else
            if p_rd_en = '1' and p_grant = '1' then
               dbg_crtc_rd <= dbg_crtc_rd + 1;
            end if;
            if p_rd_en = '1' and p_grant = '0' then
               dbg_crtc_stall <= dbg_crtc_stall + 1;
            end if;
         end if;
      end if;
   end process;

   track : process (clk)
   begin
      if rising_edge(clk) then
         if reset = '1' then
            own0  <= OWN_HOST;
            own1  <= OWN_HOST;
            own_v <= "00";
         else
            own1     <= own0;
            own_v(1) <= own_v(0);
            own0     <= own_nxt;
            own_v(0) <= m_rd_en;
         end if;
      end if;
   end process;

   r_rd_data  <= m_rd_data;
   r_rd_valid <= m_rd_valid and own_v(1) when own1 = OWN_RAST else '0';
   h_rd_data  <= m_rd_data;
   h_rd_valid <= m_rd_valid and own_v(1) when own1 = OWN_HOST else '0';
   p_rd_valid <= m_rd_valid and own_v(1) when own1 = OWN_PCRTC else '0';

   crtc : entity work.gs_pcrtc
      generic map (ADDR_BITS => ADDR_BITS)
      port map (
         clk => clk, reset => reset,
         pr_we => pr_we, pr_addr => pr_addr, pr_data => pr_data,
         h_total => h_total, v_total => v_total,
         enable => disp_enable,
         rd_ready => p_grant,
         rd_en => p_rd_en, rd_addr => p_rd_addr,
         rd_data => m_rd_data, rd_valid => p_rd_valid,
         px_valid => px_valid, px_rgb => px_rgb,
         px_x => px_x, px_y => px_y, px_sof => px_sof);

end architecture;
