#!/usr/bin/env python3
#
# C1100 PS2 IOP bring-up target.
#
# The PS2 I/O processor subsystem (cores/PS2/rtl/iop, "stage 1a": R3000A,
# memory mux, 2 MB RAM + 4 MB ROM in URAM, SSBUS config, INTC, six timers,
# POST register) behind the PCIe endpoint proven in c1100_pcie_video.py, so
# that the host can load a ROM image into it, release reset and watch the POST
# register -- the same boot test cores/PS2/sim/run_sim.sh runs in xsim, on
# silicon.  Host side: tools/ps2iop/iop_post.py.
#
# What is in the design:
#   * the c1100_pcie_video.py PCIe endpoint, unchanged (gen3 x4, DMA0 kept so
#     the same litepcie driver binds; nothing feeds the DMA yet);
#   * a second MMCM making the IOP clock and its phase-aligned 2x / 3x (see
#     _IOPClocks for why it is not LiteX's USPMMCM);
#   * iop_top, with its ROM load port, reset and status on CSRs; every crossing
#     between the 125 MHz sys domain and the IOP domain is explicit.
#
# Build, from the root of this repository:
#   venv/bin/python boards/c1100_ps2_iop.py --build
# Output: build/c1100_ps2_iop/gateware/xilinx_c1100.bit, csr.csv, software/.
#
# STATUS: see docs/ps2-iop-bringup.md for what has been built and measured.
#
# SPDX-License-Identifier: BSD-2-Clause

import os
import sys
from os.path import join, dirname, abspath, normpath

sys.path.insert(0, join(dirname(abspath(__file__)), "..", "platforms"))

from migen import *
from migen.genlib.cdc import MultiReg, PulseSynchronizer
from migen.genlib.resetsync import AsyncResetSynchronizer

from litex.gen.fhdl.module import LiteXModule
from litex.soc.cores.clock import USPMMCM
from litex.soc.integration.soc_core import SoCMini
from litex.soc.integration.builder import Builder
from litex.soc.interconnect.csr import CSRStorage, CSRStatus, CSRField, AutoCSR

from litepcie.phy.usppciephy import USPHBMPCIEPHY
from litepcie.software import generate_litepcie_software

import xilinx_c1100
from hbm_common import HBM, HBMProbe, HBMDiscSource, HBMDMAWriter

REPO_ROOT = normpath(join(dirname(abspath(__file__)), ".."))    # this repository


# IOP sources --------------------------------------------------------------------------------------

def add_iop_sources(platform, root=REPO_ROOT):
    """The same file list as fit/fit_iop.tcl and sim/run_sim.sh.

    Everything VHDL goes into library `mem` (PSX_MiSTer writes `entity mem.X`
    and `entity work.X` interchangeably; Quartus folds all libraries into one
    and this reproduces that), the Intel component declarations into
    `altera_mf`, and the Verilog stand-ins for the Intel megafunctions are
    moved into `mem` after being read so the component binding finds them.
    """
    # PSX_MiSTer is a pinned submodule, not vendored: its RTL stays under its
    # own GPL-2.0 licence and its exact commit is recorded by git.
    up   = join(root, "third_party", "PSX_MiSTer", "rtl")
    rtl  = join(root, "rtl")
    if not os.path.isfile(join(up, "cpu.vhd")):
        raise SystemExit(f"no PSX_MiSTer sources at {up}\n"
                         "run: git submodule update --init third_party/PSX_MiSTer")
    platform.add_source(join(rtl, "altera_compat", "altera_mf_components.vhd"),
                        language="vhdl", library="altera_mf")
    compat_v = [join(rtl, "altera_compat", f) for f in ("altsyncram.v", "altdpram.v")]
    for f in compat_v:
        platform.add_source(f, language="verilog")
    # (LiteX passes these strings through str.format, so Tcl braces are doubled)
    platform.toolchain.pre_synthesis_commands.append(
        "set_property library mem [get_files {{" + " ".join(compat_v) + "}}]")
    vhdl = [
        join(up, "RamMLAB.vhd"), join(up, "SyncFifoFallThroughMLAB.vhd"), join(up, "SyncFifo.vhd"),
        join(up, "SyncFifoFallThrough.vhd"), join(up, "SyncRam.vhd"),
        join(rtl, "psx", "SyncRamDual.vhd"),
        join(rtl, "psx", "SyncRamDualNotPow2.vhd"),
        join(up, "SyncRamDualByteEnable.vhd"), join(up, "dpram.vhd"), join(up, "export.vhd"),
        join(up, "divider.vhd"), join(up, "datacache.vhd"), join(up, "cpu.vhd"), join(up, "timer.vhd"),
        join(up, "memctrl.vhd"),
        join(rtl, "iop", "iop_regstub.vhd"), join(rtl, "iop", "iop_sif.vhd"), join(rtl, "iop", "iop_dma.vhd"), join(rtl, "iop", "iop_console.vhd"), join(rtl, "iop", "iop_intc.vhd"),
        join(rtl, "iop", "iop_timer32.vhd"), join(rtl, "iop", "iop_ram.vhd"),
        join(up, "spu.vhd"), join(up, "spu_ram.vhd"), join(up, "spu_gauss.vhd"),
        join(rtl, "iop", "iop_spuram.vhd"), join(rtl, "iop", "iop_spu2.vhd"),
        join(rtl, "iop", "iop_sio2.vhd"), join(rtl, "iop", "iop_cdvd.vhd"),
        join(rtl, "iop", "iop_memorymux.vhd"), join(rtl, "iop", "iop_top.vhd"),
    ]
    for f in vhdl:
        platform.add_source(f, language="vhdl", library="mem")


# Clocking -----------------------------------------------------------------------------------------

class _CRG(LiteXModule):
    """100 MHz reference (BK43/BK44) -> 125 MHz sys clock, as c1100_pcie_video.py.

    The reference is buffered once here (IBUFDS + BUFG) and handed to both
    MMCMs; margin=0 forces integer dividers so the sys clock is exact.
    """
    def __init__(self, platform, sys_clk_freq):
        self.rst    = Signal()
        self.cd_sys = ClockDomain()
        # The three clocks the HBM IP wants: a 100 MHz reference for its internal
        # PLL, 100 MHz for APB, and 250 MHz on the AXI ports -- above the IP's
        # 225 MHz floor and matching USER_AXI_CLK_FREQ in ip/hbm/gen_hbm.tcl.
        self.cd_hbm_ref = ClockDomain()
        self.cd_apb     = ClockDomain()
        self.cd_axi     = ClockDomain()
        self.clk100 = Signal()          # buffered single-ended reference for the IOP MMCM

        pads   = platform.request("clk100")
        clk_se = Signal()
        self.specials += Instance("IBUFDS", i_I=pads.p, i_IB=pads.n, o_O=clk_se)
        self.specials += Instance("BUFG",   i_I=clk_se, o_O=self.clk100)

        self.mmcm = mmcm = USPMMCM(speedgrade=-2, name="sys_mmcm")   # named so constraints can find its pins
        self.comb += mmcm.reset.eq(self.rst)
        mmcm.register_clkin(self.clk100, 100e6)
        mmcm.create_clkout(self.cd_sys,     sys_clk_freq, margin=0)
        mmcm.create_clkout(self.cd_hbm_ref, 100e6,        margin=0)
        mmcm.create_clkout(self.cd_apb,     100e6,        margin=0)
        mmcm.create_clkout(self.cd_axi,     250e6,        margin=0)

        platform.add_period_constraint(pads.p, 1e9/100e6)


class _IOPClocks(LiteXModule):
    """The IOP clock and its phase-aligned 2x and 3x from the 100 MHz reference.

    The PSX CPU core runs its register file and memory mux on clk2x/clk3x and
    samples clk1x-domain signals in them directly, so the three must come from
    ONE MMCM with integer output dividers; LiteX's USPMMCM solver may pick a
    fractional divider for one output and lose the alignment, so the MMCM is
    instantiated by hand here.

    36.864 MHz (= 2 x 18.432, the PS2's IOP clock) is not reachable from
    100 MHz with integer ratios: 100 x 11 / 30 = 36.667 MHz, 0.5 % slow.
    A VCO of 1106.25 MHz and /30, /15, /10 give 36.875 / 73.75 / 110.625 MHz,
    0.03 % fast, which is closer than a PSX's own crystal tolerance matters
    for a bring-up ROM.  That VCO is 100 x 11.0625, but the generated Verilog
    prints the multiplier as 11.062 and bitgen's DRC AVAL-168 rejects it as
    off the 0.125 grid (first build of this file); 100 / 2 x 22.125 is the
    same VCO with a value that survives three-decimal formatting.

    > **NOTE (unverified):** the fractional feedback multiplier has not been
    > confirmed on this card. *Verify by:* status.locked reading 1 after the
    > bitstream loads; if it does not, fall back to DIVCLK 1 / MULT 11.0.
    """
    def __init__(self, platform, clkref, rst, clkin_period=10.0, divclk_divide=2,
                 ref_clk_name="clk100_p"):
        """`clkref` is the buffered single-ended board reference.

        The VCO is always 1106.25 MHz, so the three outputs are the same on
        every card; only the way of getting there changes.  From the C1100's
        100 MHz that is DIVCLK 2 / MULT 22.125; from the FK33's 200 MHz it is
        DIVCLK 4 with the same multiplier, which keeps the value that survives
        the three-decimal formatting bitgen's DRC checks.
        """
        self.cd_iop   = ClockDomain()
        self.cd_iop2x = ClockDomain()
        self.cd_iop3x = ClockDomain()
        self.locked   = Signal()

        fb = Signal()
        c  = [Signal(name=f"iop_mmcm_clkout{i}") for i in range(3)]
        self.specials += Instance("MMCME4_ADV", name="iop_mmcm",
            p_BANDWIDTH       = "OPTIMIZED",
            p_COMPENSATION    = "AUTO",
            p_REF_JITTER1     = 0.01,
            p_CLKIN1_PERIOD   = clkin_period,
            p_DIVCLK_DIVIDE   = divclk_divide,
            p_CLKFBOUT_MULT_F = 22.125,
            p_CLKOUT0_DIVIDE_F = 30.0,
            p_CLKOUT1_DIVIDE  = 15,
            p_CLKOUT2_DIVIDE  = 10,
            p_CLKOUT0_PHASE   = 0.0, p_CLKOUT1_PHASE = 0.0, p_CLKOUT2_PHASE = 0.0,
            i_CLKIN1   = clkref, i_CLKIN2 = 0, i_CLKINSEL = 1,
            i_CLKFBIN  = fb,     o_CLKFBOUT = fb,
            i_RST      = rst,    i_PWRDWN = 0,
            i_DADDR = 0, i_DCLK = 0, i_DEN = 0, i_DI = 0, i_DWE = 0,
            i_PSCLK = 0, i_PSEN = 0, i_PSINCDEC = 0, i_CDDCREQ = 0,
            o_CLKOUT0 = c[0], o_CLKOUT1 = c[1], o_CLKOUT2 = c[2],
            o_LOCKED  = self.locked,
        )
        for cd, clk in ((self.cd_iop, c[0]), (self.cd_iop2x, c[1]), (self.cd_iop3x, c[2])):
            self.specials += Instance("BUFG", i_I=clk, o_O=cd.clk)
            self.specials += AsyncResetSynchronizer(cd, ~self.locked | rst)

        # The IOP clocks are related to sys only through the shared 100 MHz
        # reference, which makes Vivado time every sys <-> iop crossing at the
        # tightest edge alignment of two unrelated MMCM outputs.  All of those
        # crossings are MultiReg / PulseSynchronizer chains (below), so declare
        # the groups asynchronous, together with the sys <-> clk100 reset
        # crossing c1100_pcie_video.py declares.  This goes in the pre-placement
        # commands, because the generated clocks only exist after synthesis,
        # and it names clocks BY MMCM PIN, not by net name: the first build of
        # this file used "clkout" for the sys clock, as c1100_pcie_video.py
        # does, and that name no longer existed once the reference was buffered
        # here -- "No clocks matched 'clkout'", and the constraint did nothing
        # (docs/c1100-pcie-transport.md, the same trap a third time).  After
        # building, grep the log for "No clocks matched" and 12-4739.
        platform.toolchain.pre_placement_commands.append(
            "set_clock_groups -asynchronous "
            "-group [get_clocks -of_objects [get_pins {{iop_mmcm/CLKOUT0 iop_mmcm/CLKOUT1 iop_mmcm/CLKOUT2}}]] "
            "-group [get_clocks -of_objects [get_pins sys_mmcm/CLKOUT0]] "
            f"-group [get_clocks {ref_clk_name}]")


# IOP with host control ----------------------------------------------------------------------------

class IOPBringup(LiteXModule, AutoCSR):
    """iop_top on CSRs.

    reset      1 (the power-up value) holds the IOP in reset.
    rom_addr   word address for the next rom_data write.
    rom_data   writing it stores the word at rom_addr and increments rom_addr,
               so a ROM image is one rom_addr write followed by N rom_data writes.
    status     POST register, cpu_error, mem_idle, MMCM lock, a heartbeat bit.
    post_count POST writes since the IOP last left reset.
    rom_count  rom_data writes since power-up.
    peek_addr  byte address in IOP memory (bit 23 selects the 4 MB ROM over the
               2 MB RAM); writing it fetches that word.
    peek_data  the fetched word.  READING IT ALSO ADVANCES: the address steps
               on by four and the next word is fetched, so dumping memory is
               one address write and then one read per word.  Only works while
               `reset` holds the IOP, which is the only time the RAM port is
               free; a real console has no such port, and it exists because
               the evidence about a BIOS boot is in RAM (LOADCORE's module
               list) and a retail BIOS prints nothing to the serial port.
    peek_count fetches completed since power-up, so a dump can check that it
               read as many distinct words as it asked for.
    sif_data   value for the next SIF host write.
    sif_go     writing it performs that write, the value selecting what:
               0 MSCOM, 1 MSFLAG set, 2 MSFLAG clear, 3 SMFLAG clear, 4 CTRL,
               5 BD6.  This is the Emotion Engine's half of the SIF mailbox,
               and the host plays the EE because there is no EE: the BIOS's
               SIFMAN spins on MSFLAG bit 16 until it is answered
               (docs/ps2-bios-boot.md).
    sif_mscom / sif_smcom / sif_msflag / sif_smflag / sif_regctrl
               the mailbox as it stands, readable at any time.
    """
    def __init__(self, platform, locked, hbm_axi=None):
        # hbm_axi: one HBM pseudo-channel.  Given one, the CDVD's sectors can be
        # served out of HBM instead of over PCIe; without one (the FK33 target
        # has no HBM wired yet) the host stays the only source and the mux below
        # collapses to it.
        self.reset      = CSRStorage(1, reset=1, description="1 holds the IOP in reset")
        self.rom_addr   = CSRStorage(20, description="word address for the next rom_data write")
        self.rom_data   = CSRStorage(32, description="write: store at rom_addr, then rom_addr += 1")
        self.status     = CSRStatus(fields=[
            CSRField("post",      size=8, offset=0,  description="last value written to 0x1F802070"),
            CSRField("cpu_error", size=1, offset=8,  description="PSX CPU core error flag"),
            CSRField("mem_idle",  size=1, offset=9,  description="memory mux idle"),
            CSRField("locked",    size=1, offset=10, description="IOP MMCM locked"),
            CSRField("heartbeat", size=1, offset=11, description="toggles every 2^24 IOP cycles"),
        ])
        self.post_count = CSRStatus(32, description="POST writes since the IOP left reset")
        self.rom_count  = CSRStatus(32, description="rom_data writes since power-up")
        self.pad0       = CSRStorage(16, reset=0xFFFF, description="digital pad on SIO2 port 0: PS1 bit order, active low (0xFFFF = nothing pressed)")
        self.peek_addr  = CSRStorage(25, description="IOP byte address to read (bit 23 selects ROM); writing fetches it")
        self.peek_data  = CSRStatus(32,  description="the word at peek_addr; reading advances peek_addr by 4 and fetches the next")
        self.peek_count = CSRStatus(32,  description="peek fetches completed since power-up")
        self.sif_data   = CSRStorage(32, description="value for the next SIF host write")
        self.sif_go     = CSRStorage(3,  description="write to perform it: 0 MSCOM, 1 MSFLAG set, 2 MSFLAG clear, 3 SMFLAG clear, 4 CTRL, 5 BD6")
        self.sif_mscom  = CSRStatus(32,  description="SIF MSCOM (EE -> IOP mailbox word)")
        self.sif_smcom  = CSRStatus(32,  description="SIF SMCOM (IOP -> EE mailbox word)")
        self.sif_msflag = CSRStatus(32,  description="SIF MSFLAG: the EE sets, the IOP clears. The BIOS waits here for bit 16")
        self.sif_smflag = CSRStatus(32,  description="SIF SMFLAG: the IOP sets, the EE clears")
        self.sif_regctrl = CSRStatus(32, description="SIF CTRL as the IOP last wrote it")

        # A window onto one DMA channel's registers.  SIF0 is channel 9 and
        # SIF1 is channel 10; what the BIOS's SIFCMD programs there -- and
        # whether it uses chain mode, which shows up as CHCR bit 10 and a TADR
        # -- decides how much of the DMA controller the SIF path needs.  That
        # is a question to read off the hardware, not to guess at.
        self.dma_dbg_sel  = CSRStorage(4, description="which DMA channel the registers below show (9 = SIF0, 10 = SIF1)")
        self.dma_dbg_madr = CSRStatus(32, description="MADR of the selected channel")
        self.dma_dbg_bcr  = CSRStatus(32, description="BCR of the selected channel")
        self.dma_dbg_chcr = CSRStatus(32, description="CHCR of the selected channel; bit 24 start/busy, bit 10 chain mode")
        self.dma_dbg_tadr = CSRStatus(32, description="TADR of the selected channel, the chain-mode tag list")
        self.cdvd_disc  = CSRStorage(fields=[
            CSRField("present", size=1, offset=0, description="1 tells the driver a disc is in the tray"),
            CSRField("type",    size=8, offset=8, reset=0x14, description="disc type byte (0x14 = PS2 DVD)"),
        ])
        self.cdvd_log_addr  = CSRStorage(8,  description="word to read from the CDVD command log (8 words per entry)")
        self.cdvd_log_data  = CSRStatus(32,  description="that word: entry+0 is kind<<31 | opcode<<16 | nparams, +1..+4 the parameter bytes")
        self.cdvd_log_count = CSRStatus(16,  description="commands logged since reset")
        self.cdvd_sec_req  = CSRStatus(fields=[
            CSRField("want", size=1,  offset=0,  description="1 when the drive is waiting for a sector"),
        ])
        self.cdvd_sec_lba  = CSRStatus(32, description="which sector it is waiting for")
        self.cdvd_sec_data = CSRStorage(32, description="write 512 words to fill the sector; the write pointer advances on each")
        self.cdvd_sec_done = CSRStorage(1,  description="write 1 when the 512 words are in: the read continues and the pointer resets")

        # --- sys -> iop -------------------------------------------------------
        reset_iop = Signal()
        self.specials += MultiReg(self.reset.storage, reset_iop, "iop")
        pad0_iop = Signal(16)
        self.specials += MultiReg(self.pad0.storage, pad0_iop, "iop")
        spu_out = [Signal(16, name=f"spu_{n}") for n in ("l0", "r0", "l1", "r1")]   # no audio sink yet

        self.rom_wr_sync   = rom_wr_sync   = PulseSynchronizer("sys", "iop")
        self.rom_addr_sync = rom_addr_sync = PulseSynchronizer("sys", "iop")
        self.comb += [
            rom_wr_sync.i.eq(self.rom_data.re),
            rom_addr_sync.i.eq(self.rom_addr.re),
        ]
        rom_ptr  = Signal(20)
        rom_wr   = Signal()
        rom_word = Signal(32)
        self.sync.iop += [
            rom_wr.eq(0),
            If(rom_wr, rom_ptr.eq(rom_ptr + 1)),
            If(rom_addr_sync.o, rom_ptr.eq(self.rom_addr.storage)),
            If(rom_wr_sync.o, rom_wr.eq(1), rom_word.eq(self.rom_data.storage)),
        ]
        self.sync += If(self.rom_data.re, self.rom_count.status.eq(self.rom_count.status + 1))

        # --- memory peek ------------------------------------------------------
        # The pointer moves in the sys domain; the request crosses as a pulse
        # one cycle later, so the address MultiReg has already settled when the
        # pulse arrives on the other side.
        peek_ptr = Signal(25)
        peek_arm = Signal()
        peek_go  = Signal()
        self.sync += [
            peek_arm.eq(0),
            peek_go.eq(peek_arm),
            If(self.peek_addr.re,
                peek_ptr.eq(self.peek_addr.storage),
                peek_arm.eq(1),
            ).Elif(self.peek_data.we,          # rd_stb: the host has taken this word
                peek_ptr.eq(peek_ptr + 4),
                peek_arm.eq(1),
            ),
        ]
        self.peek_req_sync = peek_req_sync = PulseSynchronizer("sys", "iop")
        self.comb += peek_req_sync.i.eq(peek_go)
        peek_addr_iop  = Signal(25)
        peek_data_iop  = Signal(32)
        peek_valid_iop = Signal()
        self.specials += MultiReg(peek_ptr, peek_addr_iop, "iop")
        self.peek_done_sync = peek_done_sync = PulseSynchronizer("iop", "sys")
        self.comb += peek_done_sync.i.eq(peek_valid_iop)
        self.specials += MultiReg(peek_data_iop, self.peek_data.status, "sys")
        self.sync += If(peek_done_sync.o, self.peek_count.status.eq(self.peek_count.status + 1))
        self.peek_iop = (peek_req_sync.o, peek_addr_iop, peek_data_iop, peek_valid_iop)

        # --- CDVD: the sector source -------------------------------------------
        # The host answers "give me sector N" by writing 512 words and then
        # pulsing done. The write pointer lives here rather than costing a CSR
        # write per word to maintain; docs/disc-path.md explains why the source
        # is behind an interface at all -- HBM replaces the host later without
        # the IOP or the CDVD block noticing.
        sec_ptr = Signal(9)
        self.sync += [
            If(self.cdvd_sec_done.re, sec_ptr.eq(0)
            ).Elif(self.cdvd_sec_data.re, sec_ptr.eq(sec_ptr + 1)),
        ]
        # The address has to be the pointer *at the time of the write*, not the
        # live one.  sec_ptr increments on the CSR strobe, but the write pulse
        # only reaches the IOP domain a few cycles later through sec_arm/sec_go
        # and the PulseSynchronizer -- by which time the live pointer is already
        # N+1, so word N lands at N+1 and the whole sector arrives shifted by one
        # word.  Latching it here keeps address and data together across the
        # crossing.  The testbench drives sec_waddr directly, so no simulation
        # can catch this; the card found it on the first real sector read.
        sec_ptr_q = Signal(9)
        self.sync += If(self.cdvd_sec_data.re, sec_ptr_q.eq(sec_ptr))
        sec_arm, sec_go = Signal(), Signal()
        self.sync += [sec_arm.eq(self.cdvd_sec_data.re), sec_go.eq(sec_arm)]

        # Two possible fillers, one crossing.  The host writing CSRs and the HBM
        # source both produce the same four signals in the sys domain, and which
        # one is in charge is a CSR.  Everything below the mux -- the pointer
        # latch, the MultiRegs, the PulseSynchronizers -- is the plumbing the
        # card has already proved, so the HBM path inherits it rather than
        # getting a second copy to get wrong.
        fill_we   = Signal()
        fill_addr = Signal(9)
        fill_data = Signal(32)
        fill_done = Signal()
        if hbm_axi is not None:
            self.hbm_disc = HBMDiscSource(hbm_axi)
            self.comb += [
                If(self.hbm_disc.enable.storage,
                    fill_we.eq(self.hbm_disc.fill_we),
                    fill_addr.eq(self.hbm_disc.fill_addr),
                    fill_data.eq(self.hbm_disc.fill_data),
                    fill_done.eq(self.hbm_disc.fill_done),
                ).Else(
                    fill_we.eq(sec_go),
                    fill_addr.eq(sec_ptr_q),
                    fill_data.eq(self.cdvd_sec_data.storage),
                    fill_done.eq(self.cdvd_sec_done.re),
                ),
            ]
        else:
            self.hbm_disc = None
            self.comb += [
                fill_we.eq(sec_go),
                fill_addr.eq(sec_ptr_q),
                fill_data.eq(self.cdvd_sec_data.storage),
                fill_done.eq(self.cdvd_sec_done.re),
            ]

        sec_waddr_iop = Signal(9)
        sec_wdata_iop = Signal(32)
        self.specials += MultiReg(fill_addr, sec_waddr_iop, "iop")
        self.specials += MultiReg(fill_data, sec_wdata_iop, "iop")
        self.sec_we_sync   = sec_we_sync   = PulseSynchronizer("sys", "iop")
        self.sec_done_sync = sec_done_sync = PulseSynchronizer("sys", "iop")
        self.comb += sec_we_sync.i.eq(fill_we), sec_done_sync.i.eq(fill_done)
        sec_req_iop = Signal()
        sec_lba_iop = Signal(32)
        self.specials += MultiReg(sec_req_iop, self.cdvd_sec_req.fields.want, "sys")
        self.specials += MultiReg(sec_lba_iop, self.cdvd_sec_lba.status, "sys")
        if self.hbm_disc is not None:
            self.comb += [
                self.hbm_disc.req.eq(self.cdvd_sec_req.fields.want),
                self.hbm_disc.lba.eq(self.cdvd_sec_lba.status),
            ]
        self.sec_iop = (sec_req_iop, sec_lba_iop, sec_waddr_iop, sec_wdata_iop,
                        sec_we_sync.o, sec_done_sync.o)

        # --- CDVD: disc presence and the command log ---------------------------
        cdvd_present_iop = Signal()
        cdvd_type_iop    = Signal(8)
        cdvd_logaddr_iop = Signal(8)
        cdvd_logdata_iop = Signal(32)
        cdvd_logcnt_iop  = Signal(16)
        self.specials += MultiReg(self.cdvd_disc.fields.present, cdvd_present_iop, "iop")
        self.specials += MultiReg(self.cdvd_disc.fields.type, cdvd_type_iop, "iop")
        self.specials += MultiReg(self.cdvd_log_addr.storage, cdvd_logaddr_iop, "iop")
        self.specials += MultiReg(cdvd_logdata_iop, self.cdvd_log_data.status, "sys")
        self.specials += MultiReg(cdvd_logcnt_iop, self.cdvd_log_count.status, "sys")
        self.cdvd_iop = (cdvd_present_iop, cdvd_type_iop, cdvd_logaddr_iop,
                         cdvd_logdata_iop, cdvd_logcnt_iop)

        # --- SIF host side: the host is the EE ---------------------------------
        # Same shape as the peek port: the value settles through a MultiReg and
        # the strobe crosses a cycle later as a pulse, so the data is stable in
        # the iop domain before the write happens.
        sif_sel_iop  = Signal(3)
        sif_data_iop = Signal(32)
        self.specials += MultiReg(self.sif_go.storage, sif_sel_iop, "iop")
        self.specials += MultiReg(self.sif_data.storage, sif_data_iop, "iop")
        sif_arm, sif_go = Signal(), Signal()
        self.sync += [sif_arm.eq(self.sif_go.re), sif_go.eq(sif_arm)]
        self.sif_we_sync = sif_we_sync = PulseSynchronizer("sys", "iop")
        self.comb += sif_we_sync.i.eq(sif_go)
        sif_out = {n: Signal(32, name="sif_" + n) for n in
                   ("mscom", "smcom", "msflag", "smflag", "ctrl")}
        for n, csr in (("mscom", self.sif_mscom), ("smcom", self.sif_smcom),
                       ("msflag", self.sif_msflag), ("smflag", self.sif_smflag),
                       ("ctrl", self.sif_regctrl)):
            self.specials += MultiReg(sif_out[n], csr.status, "sys")
        self.sif_iop = (sif_we_sync.o, sif_sel_iop, sif_data_iop, sif_out)

        dma_dbg_sel_iop = Signal(4)
        self.specials += MultiReg(self.dma_dbg_sel.storage, dma_dbg_sel_iop, "iop")
        dma_dbg = {n: Signal(32, name="iop_dmadbg_" + n) for n in ("madr", "bcr", "chcr", "tadr")}
        for n, csr in (("madr", self.dma_dbg_madr), ("bcr", self.dma_dbg_bcr),
                       ("chcr", self.dma_dbg_chcr), ("tadr", self.dma_dbg_tadr)):
            self.specials += MultiReg(dma_dbg[n], csr.status, "sys")
        self.dma_dbg_iop = (dma_dbg_sel_iop, dma_dbg)

        # --- iop -> sys -------------------------------------------------------
        post_code = Signal(8)
        post_wr   = Signal()
        cpu_error = Signal()
        mem_idle  = Signal()
        self.post_code, self.post_wr, self.cpu_error_iop = post_code, post_wr, cpu_error   # iop domain
        self.con_wr, self.con_data = Signal(name="iop_con_wr"), Signal(8, name="iop_con_data")   # serial console bytes, iop domain
        # the CPU bus, iop domain, for the diagnostic build's analyzer
        self.dbg = {n: Signal(w, name="iop_dbg_" + n) for n, w in (
            ("req", 1), ("rnw", 1), ("isdata", 1), ("addr_instr", 32), ("addr_data", 32),
            ("wdata", 32), ("rdata", 32), ("done", 1), ("wmask", 4))}
        heartbeat = Signal(25)
        self.sync.iop += heartbeat.eq(heartbeat + 1)

        self.post_wr_sync = post_wr_sync = PulseSynchronizer("iop", "sys")
        self.comb += post_wr_sync.i.eq(post_wr)
        self.sync += [
            If(self.reset.storage,
                self.post_count.status.eq(0)
            ).Elif(post_wr_sync.o,
                self.post_count.status.eq(self.post_count.status + 1)
            ),
        ]
        self.specials += [
            MultiReg(post_code, self.status.fields.post, "sys"),
            MultiReg(cpu_error, self.status.fields.cpu_error, "sys"),
            MultiReg(mem_idle,  self.status.fields.mem_idle, "sys"),
            MultiReg(locked,    self.status.fields.locked, "sys"),
            MultiReg(heartbeat[24], self.status.fields.heartbeat, "sys"),
        ]

        # --- video timing stand-in --------------------------------------------
        # There is no GS yet; the timers and INTC still want hblank/vblank, so
        # generate NTSC-shaped ones: 2343 IOP cycles per line (36.864 MHz /
        # 15.734 kHz), 262 lines per field, blanking on the last 200 cycles
        # and the last 20 lines.
        hcnt   = Signal(12)
        line   = Signal(9)
        hblank = Signal()
        vblank = Signal()
        self.sync.iop += [
            If(hcnt == 2342,
                hcnt.eq(0),
                If(line == 261, line.eq(0)).Else(line.eq(line + 1)),
            ).Else(
                hcnt.eq(hcnt + 1),
            ),
        ]
        self.comb += [
            hblank.eq(hcnt >= 2143),
            vblank.eq(line >= 242),
        ]

        # --- the IOP -----------------------------------------------------------
        self.specials += Instance("iop_top",
            i_clk1x     = ClockSignal("iop"),
            i_clk2x     = ClockSignal("iop2x"),
            i_clk3x     = ClockSignal("iop3x"),
            i_reset     = reset_iop | ResetSignal("iop"),
            i_hblank    = hblank,
            i_vblank    = vblank,
            i_ext_irq   = Constant(0, 32),
            i_pad0_buttons = pad0_iop,
            o_spu_l0 = spu_out[0], o_spu_r0 = spu_out[1], o_spu_l1 = spu_out[2], o_spu_r1 = spu_out[3],
            i_rom_wr    = rom_wr,
            i_rom_addr  = rom_ptr,
            i_rom_data  = rom_word,
            i_cdvd_disc_present = self.cdvd_iop[0],
            i_cdvd_disc_type    = self.cdvd_iop[1],
            i_cdvd_log_addr     = self.cdvd_iop[2],
            o_cdvd_log_data     = self.cdvd_iop[3],
            o_cdvd_log_count    = self.cdvd_iop[4],
            o_cdvd_sec_req      = self.sec_iop[0],
            o_cdvd_sec_lba      = self.sec_iop[1],
            i_cdvd_sec_waddr    = self.sec_iop[2],
            i_cdvd_sec_wdata    = self.sec_iop[3],
            i_cdvd_sec_we       = self.sec_iop[4],
            i_cdvd_sec_done     = self.sec_iop[5],
            i_sif_host_sel   = self.sif_iop[1],
            i_sif_host_data  = self.sif_iop[2],
            i_sif_host_we    = self.sif_iop[0],
            o_sif_mscom      = self.sif_iop[3]["mscom"],
            o_sif_smcom      = self.sif_iop[3]["smcom"],
            o_sif_msflag     = self.sif_iop[3]["msflag"],
            o_sif_smflag     = self.sif_iop[3]["smflag"],
            o_sif_ctrl       = self.sif_iop[3]["ctrl"],
            i_dma_dbg_sel    = self.dma_dbg_iop[0],
            o_dma_dbg_madr   = self.dma_dbg_iop[1]["madr"],
            o_dma_dbg_bcr    = self.dma_dbg_iop[1]["bcr"],
            o_dma_dbg_chcr   = self.dma_dbg_iop[1]["chcr"],
            o_dma_dbg_tadr   = self.dma_dbg_iop[1]["tadr"],
            i_peek_req       = self.peek_iop[0],
            i_peek_addr      = self.peek_iop[1],
            o_peek_data      = self.peek_iop[2],
            o_peek_valid     = self.peek_iop[3],
            o_post_code = post_code,
            o_post_wr   = post_wr,
            o_dbg_req        = self.dbg["req"],
            o_dbg_rnw        = self.dbg["rnw"],
            o_dbg_isdata     = self.dbg["isdata"],
            o_dbg_addr_instr = self.dbg["addr_instr"],
            o_dbg_addr_data  = self.dbg["addr_data"],
            o_dbg_wdata      = self.dbg["wdata"],
            o_dbg_rdata      = self.dbg["rdata"],
            o_dbg_done       = self.dbg["done"],
            o_dbg_wmask      = self.dbg["wmask"],
            o_con_wr         = self.con_wr,
            o_con_data       = self.con_data,
            o_cpu_error = cpu_error,
            o_mem_idle  = mem_idle,
        )
        add_iop_sources(platform)


# SoC ----------------------------------------------------------------------------------------------

class PS2IOPSoC(SoCMini):
    def __init__(self, platform, speed="gen3", nlanes=4, sys_clk_freq=125e6):
        SoCMini.__init__(self, platform, sys_clk_freq,
                         ident=f"C1100 PS2 IOP bring-up x{nlanes} {speed}")

        self.crg = _CRG(platform, sys_clk_freq)

        # HBM.  Unlike the targets without it, hbm_cattrip is driven by the IP's
        # real over-temperature output rather than tied low
        # (platforms/xilinx_c1100.py, and the note in hbm_common.HBM).
        self.hbm = HBM(platform, platform.request("hbm_cattrip"))
        # Channel 0 is the host's way in -- staging sectors, and proving the
        # memory.  Channel 1 belongs to the CDVD's sector source.  HBM has 32
        # ports, so the two never contend and nothing needs arbitrating.
        self.hbm_probe = HBMProbe(self.hbm.axi[0])

        # PCIe, exactly as c1100_pcie_video.py (verified on hardware 2026-09-05).
        pcie_pads = platform.request(f"pcie_x{nlanes}")
        self.pcie_phy = USPHBMPCIEPHY(platform, pcie_pads,
                                      speed      = speed,
                                      data_width = {1:64, 4:128, 8:256, 16:512}[nlanes],
                                      bar0_size  = 0x20000)

        # BAR0 must be 64-bit prefetchable on this card. With a 32-bit BAR the
        # host places it in a 32-bit window that the firmware never routed
        # (assigned by Linux at rescan), and every access returns 0xffffffff
        # with no error on either end; in the 64-bit prefetchable window the
        # firmware set up at boot the same design works. Measured 2026-09-07,
        # docs/c1100-pcie-transport.md ("BAR0 reads return 0xFFFFFFFF").
        self.pcie_phy.update_config({
            "pf0_bar0_64bit":        "true",
            "pf0_bar0_prefetchable": "true",
        })
        self.add_pcie(phy=self.pcie_phy, ndmas=1,
                      with_dma_buffering = True, dma_buffering_depth=1024,
                      with_dma_loopback  = False)

        # Channel 2: the host-to-card DMA stream, straight into HBM.  This is
        # what makes staging a disc a couple of seconds rather than a day; the
        # probe on channel 0 stays for proving the memory and for a handful of
        # sectors.
        self.hbm_dma = HBMDMAWriter(self.hbm.axi[2], self.pcie_dma0.source,
                                    data_width=self.pcie_phy.data_width)

        # IOP clocks and the IOP.
        self.iop_clocks = _IOPClocks(platform, self.crg.clk100, self.crg.rst)
        self.iop        = IOPBringup(platform, self.iop_clocks.locked,
                                     hbm_axi=self.hbm.axi[1])

        platform.add_false_path_constraints(self.crg.cd_sys.clk, self.crg.cd_axi.clk)
        platform.add_false_path_constraints(self.crg.cd_sys.clk, self.crg.cd_apb.clk)
        platform.add_false_path_constraints(self.crg.cd_apb.clk, self.crg.cd_axi.clk)

        # The sys <-> clk100 reset crossing of c1100_pcie_video.py is covered by
        # the pin-named clock groups in _IOPClocks; its by-name form
        # (add_false_path_constraints_by_name("clkout", "clk100_p")) no longer
        # matches anything here.


def build(nlanes=4, speed="gen3", do_build=False, build_dir="build/c1100_ps2_iop"):
    platform = xilinx_c1100.Platform(toolchain="vivado")
    soc      = PS2IOPSoC(platform, speed=speed, nlanes=nlanes)
    builder  = Builder(soc, output_dir=build_dir, compile_software=False,
                       csr_csv=join(build_dir, "csr.csv"))
    builder.build(run=do_build)
    try:
        generate_litepcie_software(soc, join(build_dir, "software"))
    except Exception as e:
        print(f"note: litepcie software generation skipped: {e}")
    return builder


if __name__ == "__main__":
    build(nlanes = 16 if "--x16" in sys.argv else 4,
          do_build = "--build" in sys.argv)
