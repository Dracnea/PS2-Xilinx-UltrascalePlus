-- iop_spu2.vhd -- the SPU2 as two instances of PSX_MiSTer's SPU (Robert Peip,
-- GPL-2.0) behind the IOP's 0x1F900000 window, each with 512 KB of on-chip
-- work RAM.
--
-- What this is and is not.  The PS2's SPU2 is two PS1-style SPU cores (24
-- ADPCM voices, ADSR, reverb) sharing 2 MB of RAM, but its REGISTER MAP is
-- not the PS1's: voice registers are 16 bytes per voice with the address
-- registers (SSA/LSAX/NAX) in a separate block at +0x1C0, the core control
-- block is at +0x180 with different bit layouts, and core 1 sits at +0x400.
-- This block places a PSX SPU, with the PSX register layout, at each of
-- 0x1F900000 (core 0) and 0x1F900400 (core 1).  It gives the right fabric
-- cost and exercises the bus, RAM, FIFO and IRQ plumbing; IOP code written
-- for the SPU2 (libspu2, the BIOS's sound modules) will NOT drive it
-- correctly until an SPU2 register decode is written in front of the cores.
--
-- Bus: the memory mux hands this block 32-bit accesses with byte lanes as
-- the CPU produced them (a `sh` to +2 arrives word-aligned with bits 31:16
-- valid and write mask "1100"; a load carries its byte address).  SPU registers are 16-bit, so the addressed halfword is passed
-- to the core and a read returns the core's halfword in both halves; the mux
-- rotates the right one into place for lh/lhu.  A 32-bit `sw` reaches only
-- the low halfword (unverified against real SPU2 behaviour for `sw`).
--
-- RAM: PSX_MiSTer's spu_ram in its "useSDRAM" mode issues one halfword
-- request at a time on the SDRAM-style spuram port; that port is answered
-- here by on-chip RAM in 128-bit rows (32 K rows = 512 KB per core; the URAM
-- is 72 bits wide, so a halfword-wide array would waste 56 bits of every
-- row).  512 KB per core is the PS1's size; the SPU2 addresses 2 MB shared,
-- which is a change to the cores' 19-bit address, not to this wrapper.
--
-- Not connected: DMA (the SPU's dma_* ports are tied off; the IOP DMAC does
-- not exist yet), CD audio input (zero), savestates (tied off).  The two
-- IRQ lines are exported for INTC bit 9 (SPU).

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity iop_spu2 is
   port
   (
      clk1x         : in  std_logic;
      clk2x         : in  std_logic;
      clk2xIndex    : in  std_logic;
      reset         : in  std_logic;
      -- 32-bit internal bus from the memory mux (byte address within the 2 KB window)
      bus_addr      : in  unsigned(10 downto 0);
      bus_writeMask : in  std_logic_vector(3 downto 0);
      bus_dataWrite : in  std_logic_vector(31 downto 0);
      bus_read      : in  std_logic;
      bus_write     : in  std_logic;
      bus_dataRead  : out std_logic_vector(31 downto 0) := (others => '0');
      -- interrupts (one per core)
      irq           : out std_logic_vector(1 downto 0);
      -- audio
      sound_l0      : out std_logic_vector(15 downto 0);
      sound_r0      : out std_logic_vector(15 downto 0);
      sound_l1      : out std_logic_vector(15 downto 0);
      sound_r1      : out std_logic_vector(15 downto 0)
   );
end entity;

architecture arch of iop_spu2 is

   constant ZERO32 : std_logic_vector(31 downto 0) := (others => '0');

   type t_slv16 is array (0 to 1) of std_logic_vector(15 downto 0);
   signal core_read, core_write : std_logic_vector(1 downto 0) := (others => '0');
   signal core_dataRead         : t_slv16;
   signal halfword              : std_logic_vector(15 downto 0);
   signal spu_addr              : unsigned(9 downto 0);
   signal rd_pending            : std_logic := '0';
   signal rd_core               : std_logic := '0';

   -- spu <-> backing ram, per core
   type t_slv32 is array (0 to 1) of std_logic_vector(31 downto 0);
   type t_slv19 is array (0 to 1) of std_logic_vector(18 downto 0);
   type t_slv4  is array (0 to 1) of std_logic_vector(3 downto 0);
   signal ram_dataWrite : t_slv32;
   signal ram_Adr       : t_slv19;
   signal ram_be        : t_slv4;
   signal ram_rnw, ram_ena, ram_done : std_logic_vector(1 downto 0);
   signal ram_dataRead  : t_slv32;

   signal sound_l, sound_r : t_slv16;

begin

   -- ---------------------------------------------------------------- bus split
   -- stores arrive word-aligned with the lanes in the mask (the CPU aligns
   -- store addresses); loads carry their byte address
   spu_addr <= bus_addr(9 downto 2) & bus_writeMask(2) & '0' when bus_write = '1' else bus_addr(9 downto 0);
   halfword <= bus_dataWrite(31 downto 16) when bus_writeMask(2) = '1' else bus_dataWrite(15 downto 0);

   core_write(0) <= bus_write and not bus_addr(10);
   core_write(1) <= bus_write and     bus_addr(10);
   core_read(0)  <= bus_read  and not bus_addr(10);
   core_read(1)  <= bus_read  and     bus_addr(10);

   -- read data must be valid in the cycle after the strobe and zero otherwise
   -- (the mux ORs every peripheral's read data together and samples it one
   -- cycle after the strobe).  The SPU registers its bus_dataRead at the
   -- strobe, so it is passed through here, gated by a one-cycle flag.
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         rd_pending <= bus_read;
         rd_core    <= bus_addr(10);
      end if;
   end process;
   bus_dataRead <= core_dataRead(1) & core_dataRead(1) when (rd_pending = '1' and rd_core = '1') else
                   core_dataRead(0) & core_dataRead(0) when (rd_pending = '1') else
                   (others => '0');

   sound_l0 <= sound_l(0); sound_r0 <= sound_r(0);
   sound_l1 <= sound_l(1); sound_r1 <= sound_r(1);

   -- ---------------------------------------------------------------- the cores
   gcores : for i in 0 to 1 generate
   begin
      ispu : entity work.spu
      port map
      (
         clk1x                => clk1x,
         clk2x                => clk2x,
         clk2xIndex           => clk2xIndex,
         ce                   => '1',
         reset                => reset,
         SPUon                => '1',
         SPUIRQTrigger        => '0',
         useSDRAM             => '1',
         REPRODUCIBLESPUIRQ   => '1',
         REPRODUCIBLESPUDMA   => '0',
         REVERBOFF            => '0',
         cpuPaused            => '0',
         spu_tick             => open,
         cd_left              => (others => '0'),
         cd_right             => (others => '0'),
         irqOut               => irq(i),
         sound_timeout        => open,
         sound_out_left       => sound_l(i),
         sound_out_right      => sound_r(i),
         bus_addr             => spu_addr,
         bus_dataWrite        => halfword,
         bus_read             => core_read(i),
         bus_write            => core_write(i),
         bus_dataRead         => core_dataRead(i),
         spu_dmaRequest       => open,
         dma_read             => '0',
         dma_readdata         => open,
         dma_write            => '0',
         dma_writedata        => (others => '0'),
         sdram_dataWrite      => ram_dataWrite(i),
         sdram_Adr            => ram_Adr(i),
         sdram_be             => ram_be(i),
         sdram_rnw            => ram_rnw(i),
         sdram_ena            => ram_ena(i),
         sdram_dataRead       => ram_dataRead(i),
         sdram_done           => ram_done(i),
         mem_request          => open,
         mem_BURSTCNT         => open,
         mem_ADDR             => open,
         mem_DIN              => open,
         mem_BE               => open,
         mem_WE               => open,
         mem_RD               => open,
         mem_ack              => '0',
         mem_DOUT             => (others => '0'),
         mem_DOUT_READY       => '0',
         SS_reset             => '0',
         loading_savestate    => '0',
         SS_DataWrite         => ZERO32,
         SS_Adr               => (others => '0'),
         SS_wren              => '0',
         SS_rden              => '0',
         SS_DataRead          => open,
         SS_idle              => open,
         SS_RAM_dataWrite     => (others => '0'),
         SS_RAM_Adr           => (others => '0'),
         SS_RAM_request       => '0',
         SS_RAM_rnw           => '1',
         SS_RAM_dataRead      => open,
         SS_RAM_done          => open
      );

      iram : entity work.iop_spuram
      port map
      (
         clk1x         => clk1x,
         reset         => reset,
         ram_ena       => ram_ena(i),
         ram_rnw       => ram_rnw(i),
         ram_Adr       => ram_Adr(i),
         ram_be        => ram_be(i),
         ram_dataWrite => ram_dataWrite(i),
         ram_done      => ram_done(i),
         ram_dataRead  => ram_dataRead(i)
      );
   end generate;

end architecture;
