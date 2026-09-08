-- iop_top.vhd -- the PS2 I/O processor subsystem, stage 1: CPU, memory mux,
-- on-chip RAM/ROM, SSBUS config, interrupt controller, the six timers, the
-- POST register, the SPU2 (two PSX SPU cores), SIO2 with a digital pad, and
-- the CDVD register block with no disc.  Everything else on the IOP bus (DMA,
-- SIF, SSBUS config 2) is a register stub (iop_regstub) so boot code can
-- program it without hanging; see README.md.
--
-- Reused from PSX_MiSTer (GPL-2.0, Robert Peip), unmodified: cpu (the R3000A
-- with its instruction cache, the IOP is the same CPU), memctrl (SSBUS
-- timing registers at 0x1F801000), timer (root counters 0-2).  Everything
-- PSX-specific those blocks expose (GTE, exe loading, savestates, DMA stall,
-- turbo modes) is tied off here.
--
-- Clocks: clk1x is the IOP clock, 36.864 MHz on real hardware; clk2x/clk3x
-- are the PSX core's phase-aligned multiples (its register file and mux run
-- on them).  Nothing here has been on hardware.
--
-- Simulated: sim/run_sim.sh boots sim/boot_test.s through RAM, byte/halfword
-- access, cached execution, timer 3 polled and by interrupt (see README.md).

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity iop_top is
   port
   (
      clk1x      : in  std_logic;
      clk2x      : in  std_logic;
      clk3x      : in  std_logic;
      reset      : in  std_logic;
      -- video timing from the GS side (vblank feeds INTC bits 0/11 and timer 1; hblank feeds timers 0/3)
      hblank     : in  std_logic;
      vblank     : in  std_logic;
      -- external interrupt sources OR'ed into the INTC (SBUS, SIF, ... when they exist)
      ext_irq    : in  std_logic_vector(31 downto 0);
      -- digital pad on SIO2 port 0, active low, PS1 bit order (the host feeds this)
      pad0_buttons : in std_logic_vector(15 downto 0);
      -- ROM load port (word addressed, 4 MB)
      rom_wr     : in  std_logic;
      rom_addr   : in  std_logic_vector(19 downto 0);
      rom_data   : in  std_logic_vector(31 downto 0);
      -- Memory peek port: reads a word of IOP RAM or ROM for the host while
      -- the CPU is held in reset.  A real console has no such port; this is
      -- how a post-mortem is taken, because the interesting evidence about a
      -- BIOS boot is in RAM (LOADCORE's module list, the modules themselves)
      -- and there is no serial console on a retail BIOS to print it.
      -- peek_req for one cycle with peek_addr (byte address, bit 23 selects
      -- the ROM) answers with peek_valid for one cycle and peek_data.
      -- Ignored unless the CPU is in reset, so it can never race the CPU.
      peek_req   : in  std_logic := '0';
      peek_addr  : in  std_logic_vector(24 downto 0) := (others => '0');
      peek_data  : out std_logic_vector(31 downto 0) := (others => '0');
      peek_valid : out std_logic := '0';
      -- POST register (0x1F802070): what the boot code says about its progress
      post_code  : out std_logic_vector(7 downto 0) := (others => '0');
      post_wr    : out std_logic := '0';
      -- SPU2 audio (core 0 and core 1, signed 16-bit)
      spu_l0     : out std_logic_vector(15 downto 0);
      spu_r0     : out std_logic_vector(15 downto 0);
      spu_l1     : out std_logic_vector(15 downto 0);
      spu_r1     : out std_logic_vector(15 downto 0);
      -- diagnostics
      cpu_error  : out std_logic;
      mem_idle   : out std_logic;
      -- trace: the CPU's memory bus as the memory mux sees it, for an on-chip
      -- analyzer (left open in builds that do not use it)
      dbg_req        : out std_logic;
      dbg_rnw        : out std_logic;
      dbg_isdata     : out std_logic;
      dbg_addr_instr : out std_logic_vector(31 downto 0);
      dbg_addr_data  : out std_logic_vector(31 downto 0);
      dbg_wdata      : out std_logic_vector(31 downto 0);
      dbg_rdata      : out std_logic_vector(31 downto 0);
      dbg_done       : out std_logic;
      dbg_wmask      : out std_logic_vector(3 downto 0);
      -- console: bytes the IOP writes to its serial port (SIO1, 0x1F801050), i.e. Kprintf
      con_wr         : out std_logic;
      con_data       : out std_logic_vector(7 downto 0)
   );
end entity;

architecture arch of iop_top is

   constant ZERO32 : std_logic_vector(31 downto 0) := (others => '0');

   -- cpu <-> memory mux
   signal irqRequest        : std_logic;
   signal mem_request       : std_logic;
   signal mem_rnw           : std_logic;
   signal mem_isData        : std_logic;
   signal mem_isCache       : std_logic;
   signal mem_oldtagvalids  : std_logic_vector(3 downto 0);
   signal mem_addressInstr  : unsigned(31 downto 0);
   signal mem_addressData   : unsigned(31 downto 0);
   signal mem_reqsize       : unsigned(1 downto 0);
   signal mem_writeMask     : std_logic_vector(3 downto 0);
   signal mem_dataWrite     : std_logic_vector(31 downto 0);
   signal mem_dataRead      : std_logic_vector(31 downto 0);
   signal mem_done          : std_logic;
   signal mem_fifofull      : std_logic;
   signal mem_tagvalids     : std_logic_vector(3 downto 0);
   signal errorCPU, errorCPU2 : std_logic;

   -- mux <-> ram
   signal ram_dataWrite     : std_logic_vector(31 downto 0);
   signal ram_dataRead      : std_logic_vector(31 downto 0);
   signal ram_Adr           : std_logic_vector(24 downto 0);
   signal ram_be            : std_logic_vector(3 downto 0);
   signal ram_rnw           : std_logic;
   signal ram_ena           : std_logic;
   signal ram_cache         : std_logic;
   signal ram_done          : std_logic;
   signal cache_wr          : std_logic_vector(3 downto 0);
   signal cache_data        : std_logic_vector(31 downto 0);
   signal cache_addr        : std_logic_vector(7 downto 0);

   -- ssbus timing
   signal bios_memctrl, ex1_memctrl, ex2_memctrl, ex3_memctrl, spu_memctrl, cd_memctrl : unsigned(13 downto 0);
   signal com0_delay, com1_delay, com2_delay, com3_delay : unsigned(3 downto 0);

   -- internal buses
   signal bus_memc_addr     : unsigned(5 downto 0);
   signal bus_memc_dataWrite: std_logic_vector(31 downto 0);
   signal bus_memc_read, bus_memc_write : std_logic;
   signal bus_memc_dataRead : std_logic_vector(31 downto 0);
   signal bus_memc2_addr    : unsigned(3 downto 0);
   signal bus_memc2_dataWrite : std_logic_vector(31 downto 0);
   signal bus_memc2_read, bus_memc2_write : std_logic;
   signal bus_memc2_dataRead : std_logic_vector(31 downto 0);
   signal bus_irq_addr      : unsigned(3 downto 0);
   signal bus_irq_dataWrite : std_logic_vector(31 downto 0);
   signal bus_irq_read, bus_irq_write : std_logic;
   signal bus_irq_dataRead  : std_logic_vector(31 downto 0);
   signal bus_tmr_addr      : unsigned(5 downto 0);
   signal bus_tmr_dataWrite : std_logic_vector(31 downto 0);
   signal bus_tmr_read, bus_tmr_write : std_logic;
   signal bus_tmr_dataRead  : std_logic_vector(31 downto 0);
   signal bus_tmr2_addr     : unsigned(5 downto 0);
   signal bus_tmr2_dataWrite: std_logic_vector(31 downto 0);
   signal bus_tmr2_read, bus_tmr2_write : std_logic;
   signal bus_tmr2_dataRead : std_logic_vector(31 downto 0);
   signal bus_dma_addr      : unsigned(6 downto 0);
   signal bus_dma_dataWrite : std_logic_vector(31 downto 0);
   signal bus_dma_read, bus_dma_write : std_logic;
   signal bus_dma_dataRead  : std_logic_vector(31 downto 0);
   signal bus_dma2_addr     : unsigned(6 downto 0);
   signal bus_dma2_dataWrite: std_logic_vector(31 downto 0);
   signal bus_dma2_read, bus_dma2_write : std_logic;
   signal bus_dma2_dataRead : std_logic_vector(31 downto 0);
   signal bus_ssb2_addr     : unsigned(6 downto 0);
   signal bus_ssb2_dataWrite: std_logic_vector(31 downto 0);
   signal bus_ssb2_read, bus_ssb2_write : std_logic;
   signal bus_ssb2_dataRead : std_logic_vector(31 downto 0);
   signal bus_sif_addr      : unsigned(6 downto 0);
   signal bus_sif_dataWrite : std_logic_vector(31 downto 0);
   signal bus_sif_read, bus_sif_write : std_logic;
   signal bus_sif_dataRead  : std_logic_vector(31 downto 0);
   signal bus_cdvd_addr     : unsigned(5 downto 0);
   signal bus_cdvd_writeMask, bus_sio2_writeMask, bus_spu2_writeMask : std_logic_vector(3 downto 0);
   signal bus_cdvd_dataWrite: std_logic_vector(31 downto 0);
   signal bus_cdvd_read, bus_cdvd_write : std_logic;
   signal bus_cdvd_dataRead : std_logic_vector(31 downto 0);
   signal bus_sio2_addr     : unsigned(7 downto 0);
   signal bus_sio2_dataWrite: std_logic_vector(31 downto 0);
   signal bus_sio2_read, bus_sio2_write : std_logic;
   signal bus_sio2_dataRead : std_logic_vector(31 downto 0);
   signal bus_spu2_addr     : unsigned(10 downto 0);
   signal bus_spu2_dataWrite: std_logic_vector(31 downto 0);
   signal bus_spu2_read, bus_spu2_write : std_logic;
   signal bus_spu2_dataRead : std_logic_vector(31 downto 0);
   signal bus_exp2_addr     : unsigned(12 downto 0);
   signal bus_exp2_dataWrite: std_logic_vector(7 downto 0);
   signal bus_exp2_read, bus_exp2_write : std_logic;
   signal bus_exp2_dataRead : std_logic_vector(7 downto 0);

   -- interrupts
   signal irq_src           : std_logic_vector(31 downto 0);
   signal irq_local         : std_logic_vector(31 downto 0);
   signal irqTimer0, irqTimer1, irqTimer2, irqTimer3, irqTimer4, irqTimer5 : std_logic;
   signal post_reg          : std_logic_vector(7 downto 0) := (others => '0');

   -- clock phase index for the SPU (psx_top's clk2xIndex: '1' on the clk2x
   -- edge that coincides with a clk1x edge)
   signal clk1xToggle       : std_logic := '0';
   signal clk1xToggle2x     : std_logic := '0';
   signal clk2xIndex        : std_logic := '0';
   signal irq_spu           : std_logic_vector(1 downto 0);
   signal irq_sio2, irq_cdvd : std_logic;
   -- SIO1 (0x1F801050): the IOP's serial console
   signal bus_sio_addr      : unsigned(3 downto 0);
   signal bus_sio_dataWrite : std_logic_vector(31 downto 0);
   signal bus_sio_read, bus_sio_write : std_logic;
   signal bus_sio_dataRead  : std_logic_vector(31 downto 0);

   -- memory peek (see the port comment): the RAM port is muxed away from the
   -- memory mux while the CPU is in reset, and iop_ram's own reset is released
   -- for the duration so its request FSM can serve the read.
   signal peek_mode         : std_logic := '0';
   signal peek_busy         : std_logic := '0';
   signal ram_reset         : std_logic := '1';
   signal ram_ena_m         : std_logic;
   signal ram_rnw_m         : std_logic;
   signal ram_Adr_m         : std_logic_vector(24 downto 0);
   signal ram_be_m          : std_logic_vector(3 downto 0);
   signal ram_cache_m       : std_logic;

   -- reset sequencing (see below)
   signal reset_int         : std_logic := '1';
   signal ss_reset          : std_logic := '0';
   signal reset_cnt         : unsigned(6 downto 0) := (others => '0');
   -- PRId (COP0 register 15) the CPU reports.  The PSX core's reset default is
   -- 0x00000002, a PS1 R3000A, and the PS2 BIOS branches on it: below 0x10 it
   -- takes its PS1-compatibility path (init table A, then it looks for a "TBIN"
   -- module and halts at POST FA when there is none, which is what a real BIOS
   -- did in xsim on 2026-09-08); 0x10..0x58 is the IOP path that runs IOPBOOT.
   -- Every PRId test in the 0220A ROM compares against 0x10, 0x23 or 0x59.
   -- 0x1F is below 0x23 like the original CXD97xx IOPs.  Loaded through the
   -- CPU's savestate port during reset, so the upstream CPU is untouched.
   constant IOP_PRID        : std_logic_vector(31 downto 0) := x"0000001F";
   signal ss_wren           : std_logic := '0';

begin

   -- The PSX CPU takes its reset state (PC = 0xBFC00000, PRID, zeroed
   -- registers) from its savestate-load port: SS_reset loads the defaults and
   -- then streams zeros into the register file for 32 cycles.  psx_top drives
   -- that from its savestate block; there is none here, so: pulse SS_reset on
   -- the first cycle of reset and hold the internal reset for 64 cycles after
   -- the external one drops, so the register-file load is over before the
   -- first instruction.  Without this the CPU comes up at PC 0 (found in
   -- simulation, 2026-09-06).
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         ss_reset <= '0';
         ss_wren  <= '0';
         if (reset = '1') then
            if (reset_cnt = 0) then
               ss_reset <= '1';
            end if;
            -- after the SS_reset pulse, overwrite slot 13 (PRId); the CPU copies
            -- the slots into COP0 on every cycle its reset is asserted
            if (reset_cnt = 1 and ss_reset = '0') then
               ss_wren <= '1';
            end if;
            reset_cnt <= to_unsigned(1, 7);
            reset_int <= '1';
         elsif (reset_cnt /= 0) then
            reset_cnt <= reset_cnt + 1;
            if (reset_cnt = 64) then
               reset_cnt <= (others => '0');
               reset_int <= '0';
            end if;
         end if;
      end if;
   end process;

   cpu_error <= errorCPU or errorCPU2;

   -- ------------------------------------------------------------ memory peek
   -- Only while the CPU is held in reset, so the mux never has a request in
   -- flight and no arbitration is needed: the RAM port is simply switched over.
   peek_mode   <= reset_int;
   ram_ena_m   <= peek_req  when peek_mode = '1' else ram_ena;
   ram_rnw_m   <= '1'       when peek_mode = '1' else ram_rnw;
   ram_Adr_m   <= peek_addr when peek_mode = '1' else ram_Adr;
   ram_be_m    <= "1111"    when peek_mode = '1' else ram_be;
   ram_cache_m <= '0'       when peek_mode = '1' else ram_cache;
   -- iop_ram's reset only forces its FSM to IDLE; release it whenever a peek
   -- is in flight so the read can complete with the CPU still in reset.
   ram_reset   <= reset_int and not (peek_busy or peek_req);

   process (clk1x)
   begin
      if rising_edge(clk1x) then
         peek_valid <= '0';
         -- No reset branch on purpose: a peek only ever happens while the IOP
         -- is held in reset, so clearing this on `reset` would kill every
         -- request before it started.  peek_busy powers up at '0'.
         if (peek_req = '1' and peek_mode = '1') then
            peek_busy <= '1';
         elsif (peek_busy = '1' and ram_done = '1') then
            peek_busy  <= '0';
            peek_data  <= ram_dataRead;
            peek_valid <= '1';
         end if;
      end if;
   end process;

   dbg_req        <= mem_request;
   dbg_rnw        <= mem_rnw;
   dbg_isdata     <= mem_isData;
   dbg_addr_instr <= std_logic_vector(mem_addressInstr);
   dbg_addr_data  <= std_logic_vector(mem_addressData);
   dbg_wdata      <= mem_dataWrite;
   dbg_rdata      <= mem_dataRead;
   dbg_done       <= mem_done;
   dbg_wmask      <= mem_writeMask;

   iconsole : entity work.iop_console
   port map
   (
      clk1x         => clk1x,
      reset         => reset_int,
      bus_addr      => bus_sio_addr,
      bus_dataWrite => bus_sio_dataWrite,
      bus_read      => bus_sio_read,
      bus_write     => bus_sio_write,
      bus_dataRead  => bus_sio_dataRead,
      con_wr        => con_wr,
      con_data      => con_data
   );

   icpu : entity work.cpu
   port map
   (
      clk1x             => clk1x,
      clk2x             => clk2x,
      clk3x             => clk3x,
      ce                => '1',
      reset             => reset_int,
      TURBO             => '0',
      TURBO_CACHE       => '0',
      TURBO_CACHE50     => '0',
      irqRequest        => irqRequest,
      dmaStallCPU       => '0',
      cpuPaused         => '0',
      error             => errorCPU,
      error2            => errorCPU2,
      mem_request       => mem_request,
      mem_rnw           => mem_rnw,
      mem_isData        => mem_isData,
      mem_isCache       => mem_isCache,
      mem_oldtagvalids  => mem_oldtagvalids,
      mem_addressInstr  => mem_addressInstr,
      mem_addressData   => mem_addressData,
      mem_reqsize       => mem_reqsize,
      mem_writeMask     => mem_writeMask,
      mem_dataWrite     => mem_dataWrite,
      mem_dataRead      => mem_dataRead,
      mem_done          => mem_done,
      mem_fifofull      => mem_fifofull,
      mem_tagvalids     => mem_tagvalids,
      cache_wr          => cache_wr,
      cache_data        => cache_data,
      cache_addr        => cache_addr,
      stallNext         => open,
      dma_cache_Adr     => (others => '0'),
      dma_cache_data    => ZERO32,
      dma_cache_write   => '0',
      ram_dataRead      => ram_dataRead,
      ram_rnw           => ram_rnw,
      ram_done          => ram_done,
      gte_busy          => '0',
      gte_readEna       => open,
      gte_readAddr      => open,
      gte_readData      => (others => '0'),
      gte_writeAddr     => open,
      gte_writeData     => open,
      gte_writeEna      => open,
      gte_cmdData       => open,
      gte_cmdEna        => open,
      SS_reset          => ss_reset,
      SS_DataWrite      => IOP_PRID,
      SS_Adr            => to_unsigned(13, 8),
      SS_wren_CPU       => ss_wren,
      SS_wren_SCP       => '0',
      SS_rden_CPU       => '0',
      SS_rden_SCP       => '0',
      SS_DataRead_CPU   => open,
      SS_DataRead_SCP   => open,
      SS_idle           => open,
      debug_firstGTE    => '0'
   );

   imux : entity work.iop_memorymux
   port map
   (
      clk1x                => clk1x,
      clk2x                => clk2x,
      ce                   => '1',
      reset                => reset_int,
      pauseNext            => '0',
      isIdle               => mem_idle,
      loadExe              => '0',
      exe_initial_pc       => (others => '0'),
      exe_initial_gp       => (others => '0'),
      exe_load_address     => (others => '0'),
      exe_file_size        => (others => '0'),
      exe_stackpointer     => (others => '0'),
      reset_exe            => open,
      fastboot             => '0',
      PATCHSERIAL          => '0',
      TURBO                => '0',
      region_in            => "00",
      ram_dataWrite        => ram_dataWrite,
      ram_dataRead         => ram_dataRead,
      ram_Adr              => ram_Adr,
      ram_be               => ram_be,
      ram_rnw              => ram_rnw,
      ram_ena              => ram_ena,
      ram_cache            => ram_cache,
      ram_done             => ram_done,
      mem_in_request       => mem_request,
      mem_in_rnw           => mem_rnw,
      mem_in_isData        => mem_isData,
      mem_in_isCache       => mem_isCache,
      mem_in_oldtagvalids  => mem_oldtagvalids,
      mem_in_addressInstr  => mem_addressInstr,
      mem_in_addressData   => mem_addressData,
      mem_in_reqsize       => mem_reqsize,
      mem_in_writeMask     => mem_writeMask,
      mem_in_dataWrite     => mem_dataWrite,
      mem_dataRead         => mem_dataRead,
      mem_done             => mem_done,
      mem_fifofull         => mem_fifofull,
      mem_tagvalids        => mem_tagvalids,
      bios_memctrl         => bios_memctrl,
      ex1_memctrl          => ex1_memctrl,
      bus_exp1_read        => open,
      bus_exp1_dataRead    => x"00",
      bus_memc_addr        => bus_memc_addr,
      bus_memc_dataWrite   => bus_memc_dataWrite,
      bus_memc_read        => bus_memc_read,
      bus_memc_write       => bus_memc_write,
      bus_memc_dataRead    => bus_memc_dataRead,
      bus_pad_addr         => open,
      bus_pad_dataWrite    => open,
      bus_pad_read         => open,
      bus_pad_write        => open,
      bus_pad_writeMask    => open,
      bus_pad_dataRead     => ZERO32,
      bus_sio_addr         => bus_sio_addr,
      bus_sio_dataWrite    => bus_sio_dataWrite,
      bus_sio_read         => bus_sio_read,
      bus_sio_write        => bus_sio_write,
      bus_sio_writeMask    => open,
      bus_sio_dataRead     => bus_sio_dataRead,
      bus_memc2_addr       => bus_memc2_addr,
      bus_memc2_dataWrite  => bus_memc2_dataWrite,
      bus_memc2_read       => bus_memc2_read,
      bus_memc2_write      => bus_memc2_write,
      bus_memc2_dataRead   => bus_memc2_dataRead,
      bus_irq_addr         => bus_irq_addr,
      bus_irq_dataWrite    => bus_irq_dataWrite,
      bus_irq_read         => bus_irq_read,
      bus_irq_write        => bus_irq_write,
      bus_irq_dataRead     => bus_irq_dataRead,
      bus_dma_addr         => bus_dma_addr,
      bus_dma_dataWrite    => bus_dma_dataWrite,
      bus_dma_read         => bus_dma_read,
      bus_dma_write        => bus_dma_write,
      bus_dma_dataRead     => bus_dma_dataRead,
      bus_tmr_addr         => bus_tmr_addr,
      bus_tmr_dataWrite    => bus_tmr_dataWrite,
      bus_tmr_read         => bus_tmr_read,
      bus_tmr_write        => bus_tmr_write,
      bus_tmr_dataRead     => bus_tmr_dataRead,
      cd_memctrl           => cd_memctrl,
      bus_cd_addr          => open,
      bus_cd_dataWrite     => open,
      bus_cd_read          => open,
      bus_cd_write         => open,
      bus_cd_dataRead      => x"00",
      bus_gpu_addr         => open,
      bus_gpu_dataWrite    => open,
      bus_gpu_read         => open,
      bus_gpu_write        => open,
      bus_gpu_dataRead     => ZERO32,
      bus_gpu_stall        => '0',
      bus_mdec_addr        => open,
      bus_mdec_dataWrite   => open,
      bus_mdec_read        => open,
      bus_mdec_write       => open,
      bus_mdec_dataRead    => ZERO32,
      bus_tmr2_addr        => bus_tmr2_addr,
      bus_tmr2_dataWrite   => bus_tmr2_dataWrite,
      bus_tmr2_read        => bus_tmr2_read,
      bus_tmr2_write       => bus_tmr2_write,
      bus_tmr2_dataRead    => bus_tmr2_dataRead,
      bus_dma2_addr        => bus_dma2_addr,
      bus_dma2_dataWrite   => bus_dma2_dataWrite,
      bus_dma2_read        => bus_dma2_read,
      bus_dma2_write       => bus_dma2_write,
      bus_dma2_dataRead    => bus_dma2_dataRead,
      bus_ssb2_addr        => bus_ssb2_addr,
      bus_ssb2_dataWrite   => bus_ssb2_dataWrite,
      bus_ssb2_read        => bus_ssb2_read,
      bus_ssb2_write       => bus_ssb2_write,
      bus_ssb2_dataRead    => bus_ssb2_dataRead,
      bus_sif_addr         => bus_sif_addr,
      bus_sif_dataWrite    => bus_sif_dataWrite,
      bus_sif_read         => bus_sif_read,
      bus_sif_write        => bus_sif_write,
      bus_sif_dataRead     => bus_sif_dataRead,
      bus_cdvd_addr        => bus_cdvd_addr,
      bus_cdvd_writeMask   => bus_cdvd_writeMask,
      bus_cdvd_dataWrite   => bus_cdvd_dataWrite,
      bus_cdvd_read        => bus_cdvd_read,
      bus_cdvd_write       => bus_cdvd_write,
      bus_cdvd_dataRead    => bus_cdvd_dataRead,
      bus_sio2_addr        => bus_sio2_addr,
      bus_sio2_writeMask   => bus_sio2_writeMask,
      bus_sio2_dataWrite   => bus_sio2_dataWrite,
      bus_sio2_read        => bus_sio2_read,
      bus_sio2_write       => bus_sio2_write,
      bus_sio2_dataRead    => bus_sio2_dataRead,
      bus_spu2_addr        => bus_spu2_addr,
      bus_spu2_writeMask   => bus_spu2_writeMask,
      bus_spu2_dataWrite   => bus_spu2_dataWrite,
      bus_spu2_read        => bus_spu2_read,
      bus_spu2_write       => bus_spu2_write,
      bus_spu2_dataRead    => bus_spu2_dataRead,
      spu_memctrl          => spu_memctrl,
      bus_spu_addr         => open,
      bus_spu_dataWrite    => open,
      bus_spu_read         => open,
      bus_spu_write        => open,
      bus_spu_dataRead     => x"0000",
      ex2_memctrl          => ex2_memctrl,
      bus_exp2_addr        => bus_exp2_addr,
      bus_exp2_dataWrite   => bus_exp2_dataWrite,
      bus_exp2_read        => bus_exp2_read,
      bus_exp2_write       => bus_exp2_write,
      bus_exp2_dataRead    => bus_exp2_dataRead,
      ex3_memctrl          => ex3_memctrl,
      bus_exp3_read        => open,
      bus_exp3_dataRead    => x"0000",
      com0_delay           => com0_delay,
      com1_delay           => com1_delay,
      com2_delay           => com2_delay,
      com3_delay           => com3_delay,
      loading_savestate    => '0',
      SS_reset             => '0',
      SS_DataWrite         => ZERO32,
      SS_Adr               => (others => '0'),
      SS_wren_SDRam        => '0',
      SS_rden_SDRam        => '0'
   );

   iram : entity work.iop_ram
   port map
   (
      clk1x         => clk1x,
      reset         => ram_reset,
      ram_ena       => ram_ena_m,
      ram_rnw       => ram_rnw_m,
      ram_Adr       => ram_Adr_m,
      ram_be        => ram_be_m,
      ram_dataWrite => ram_dataWrite,
      ram_cache     => ram_cache_m,
      ram_done      => ram_done,
      ram_dataRead  => ram_dataRead,
      cache_wr      => cache_wr,
      cache_data    => cache_data,
      cache_addr    => cache_addr,
      rom_wr        => rom_wr,
      rom_addr      => rom_addr,
      rom_data      => rom_data
   );

   imemctrl : entity work.memctrl
   port map
   (
      clk1x                => clk1x,
      ce                   => '1',
      reset                => reset_int,
      bus_addr             => bus_memc_addr,
      bus_dataWrite        => bus_memc_dataWrite,
      bus_read             => bus_memc_read,
      bus_write            => bus_memc_write,
      bus_dataRead         => bus_memc_dataRead,
      bus2_addr            => bus_memc2_addr,
      bus2_dataWrite       => bus_memc2_dataWrite,
      bus2_read            => bus_memc2_read,
      bus2_write           => bus_memc2_write,
      bus2_dataRead        => bus_memc2_dataRead,
      errorBuswidth        => open,
      spu_memctrl          => spu_memctrl,
      cd_memctrl           => cd_memctrl,
      bios_memctrl         => bios_memctrl,
      ex1_memctrl          => ex1_memctrl,
      ex2_memctrl          => ex2_memctrl,
      ex3_memctrl          => ex3_memctrl,
      com0_delay           => com0_delay,
      com1_delay           => com1_delay,
      com2_delay           => com2_delay,
      com3_delay           => com3_delay,
      dma_spu_timing_on    => open,
      dma_spu_timing_value => open,
      loading_savestate    => '0',
      SS_reset             => '0',
      SS_DataWrite         => ZERO32,
      SS_Adr               => (others => '0'),
      SS_wren              => '0',
      SS_rden              => '0',
      SS_DataRead          => open
   );

   itimer : entity work.timer
   port map
   (
      clk1x                => clk1x,
      ce                   => '1',
      reset                => reset_int,
      error                => open,
      dotclock             => '0',
      hblank               => hblank,
      vblank               => vblank,
      irqRequest0          => irqTimer0,
      irqRequest1          => irqTimer1,
      irqRequest2          => irqTimer2,
      bus_addr             => bus_tmr_addr,
      bus_dataWrite        => bus_tmr_dataWrite,
      bus_read             => bus_tmr_read,
      bus_write            => bus_tmr_write,
      bus_dataRead         => bus_tmr_dataRead,
      loading_savestate    => '0',
      SS_reset             => '0',
      SS_DataWrite         => ZERO32,
      SS_Adr               => (others => '0'),
      SS_wren              => '0',
      SS_rden              => '0',
      SS_DataRead          => open
   );

   itimer32 : entity work.iop_timer32
   port map
   (
      clk1x         => clk1x,
      ce            => '1',
      reset         => reset_int,
      hblank        => hblank,
      irqRequest3   => irqTimer3,
      irqRequest4   => irqTimer4,
      irqRequest5   => irqTimer5,
      bus_addr      => bus_tmr2_addr,
      bus_dataWrite => bus_tmr2_dataWrite,
      bus_read      => bus_tmr2_read,
      bus_write     => bus_tmr2_write,
      bus_dataRead  => bus_tmr2_dataRead
   );

   -- clock phase index, as psx_top generates it
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         clk1xToggle <= not clk1xToggle;
      end if;
   end process;
   process (clk2x)
   begin
      if rising_edge(clk2x) then
         clk1xToggle2x <= clk1xToggle;
         clk2xIndex    <= '0';
         if (clk1xToggle2x = clk1xToggle) then
            clk2xIndex <= '1';
         end if;
      end if;
   end process;

   -- interrupt sources, PS2SDK intrman numbering
   process (vblank, irqTimer0, irqTimer1, irqTimer2, irqTimer3, irqTimer4, irqTimer5, irq_spu, irq_sio2, irq_cdvd)
   begin
      irq_local     <= (others => '0');
      irq_local(0)  <= vblank;
      irq_local(2)  <= irq_cdvd;
      irq_local(9)  <= irq_spu(0) or irq_spu(1);
      irq_local(17) <= irq_sio2;
      irq_local(4)  <= irqTimer0;
      irq_local(5)  <= irqTimer1;
      irq_local(6)  <= irqTimer2;
      irq_local(11) <= not vblank;
      irq_local(14) <= irqTimer3;
      irq_local(15) <= irqTimer4;
      irq_local(16) <= irqTimer5;
   end process;
   irq_src <= ext_irq or irq_local;

   iintc : entity work.iop_intc
   port map
   (
      clk1x         => clk1x,
      ce            => '1',
      reset         => reset_int,
      irq_in        => irq_src,
      bus_addr      => bus_irq_addr,
      bus_dataWrite => bus_irq_dataWrite,
      bus_read      => bus_irq_read,
      bus_write     => bus_irq_write,
      bus_dataRead  => bus_irq_dataRead,
      irqRequest    => irqRequest
   );

   -- stubs: programmed and read back, nothing behind them yet
   idma  : entity work.iop_regstub generic map (ADDR_BITS => 7)  port map (clk1x, reset_int, bus_dma_addr,  bus_dma_dataWrite,  bus_dma_read,  bus_dma_write,  bus_dma_dataRead);
   idma2 : entity work.iop_regstub generic map (ADDR_BITS => 7)  port map (clk1x, reset_int, bus_dma2_addr, bus_dma2_dataWrite, bus_dma2_read, bus_dma2_write, bus_dma2_dataRead);
   issb2 : entity work.iop_regstub generic map (ADDR_BITS => 7)  port map (clk1x, reset_int, bus_ssb2_addr, bus_ssb2_dataWrite, bus_ssb2_read, bus_ssb2_write, bus_ssb2_dataRead);
   isif  : entity work.iop_regstub generic map (ADDR_BITS => 7)  port map (clk1x, reset_int, bus_sif_addr,  bus_sif_dataWrite,  bus_sif_read,  bus_sif_write,  bus_sif_dataRead);

   -- CDVD register block, no disc (see iop_cdvd.vhd)
   icdvd : entity work.iop_cdvd
   port map
   (
      clk1x         => clk1x,
      reset         => reset_int,
      bus_addr      => bus_cdvd_addr,
      bus_writeMask => bus_cdvd_writeMask,
      bus_dataWrite => bus_cdvd_dataWrite,
      bus_read      => bus_cdvd_read,
      bus_write     => bus_cdvd_write,
      bus_dataRead  => bus_cdvd_dataRead,
      irq           => irq_cdvd
   );

   -- SIO2 with a digital pad on port 0 (see iop_sio2.vhd)
   isio2 : entity work.iop_sio2
   port map
   (
      clk1x         => clk1x,
      reset         => reset_int,
      pad0_buttons  => pad0_buttons,
      bus_addr      => bus_sio2_addr,
      bus_writeMask => bus_sio2_writeMask,
      bus_dataWrite => bus_sio2_dataWrite,
      bus_read      => bus_sio2_read,
      bus_write     => bus_sio2_write,
      bus_dataRead  => bus_sio2_dataRead,
      irq           => irq_sio2
   );

   -- SPU2: two PSX SPU cores with 512 KB each (see iop_spu2.vhd for what is
   -- and is not SPU2-accurate about this)
   ispu2 : entity work.iop_spu2
   port map
   (
      clk1x         => clk1x,
      clk2x         => clk2x,
      clk2xIndex    => clk2xIndex,
      reset         => reset_int,
      bus_addr      => bus_spu2_addr,
      bus_writeMask => bus_spu2_writeMask,
      bus_dataWrite => bus_spu2_dataWrite,
      bus_read      => bus_spu2_read,
      bus_write     => bus_spu2_write,
      bus_dataRead  => bus_spu2_dataRead,
      irq           => irq_spu,
      sound_l0      => spu_l0,
      sound_r0      => spu_r0,
      sound_l1      => spu_l1,
      sound_r1      => spu_r1
   );

   -- POST register at 0x1F802070 on the 8-bit expansion-2 bus
   bus_exp2_dataRead <= post_reg when (bus_exp2_addr = to_unsigned(16#70#, 13)) else x"00";
   post_code <= post_reg;
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         post_wr <= '0';
         if (reset_int = '1') then
            post_reg <= (others => '0');
         elsif (bus_exp2_write = '1' and bus_exp2_addr = to_unsigned(16#70#, 13)) then
            post_reg <= bus_exp2_dataWrite;
            post_wr  <= '1';
         end if;
      end if;
   end process;

end architecture;
