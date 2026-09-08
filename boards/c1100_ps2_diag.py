#!/usr/bin/env python3
#
# C1100 PS2 IOP, diagnostic build: c1100_ps2_iop unchanged, plus what is
# needed to watch a real BIOS boot on silicon and see where it stops.
#
#   * UARTbone on the card's FPGA UART 0 (BJ41/BK41 -> FT4232H channel C,
#     /dev/ttyUSB2): the CSR bus without PCIe.
#   * A ring of the last 64 POST writes (code + IOP cycle count), so a fast
#     sequence is not lost between host polls.
#   * A stall detector: cycles since the CPU last issued a bus request; the
#     flag rises after 2^22 IOP cycles (114 ms) with no request.
#   * A LiteScope analyzer in the iop clock domain on the CPU's memory bus
#     (address, data, write mask, request/done), the POST write, cpu_error
#     and the stall flag, run-length encoded so idle cycles do not fill it.
#     Armed with the stall flag as trigger and almost all samples pre-trigger,
#     it holds the last few thousand bus transactions before a hang.
#
# SPDX-License-Identifier: BSD-2-Clause

import sys
from os.path import join, dirname, abspath

sys.path.insert(0, dirname(abspath(__file__)))
sys.path.insert(0, join(dirname(abspath(__file__)), "..", "platforms"))

from migen import *
from migen.genlib.cdc import MultiReg, PulseSynchronizer
from migen.genlib.fifo import AsyncFIFO
from litex.gen.fhdl.module import LiteXModule
from litex.build.generic_platform import Subsignal, Pins, IOStandard
from litex.soc.integration.builder import Builder
from litex.soc.interconnect.csr import CSRStorage, CSRStatus, AutoCSR
from litescope import LiteScopeAnalyzer
from litepcie.software import generate_litepcie_software

import xilinx_c1100
from c1100_ps2_iop import PS2IOPSoC

_serial = [
    ("serial", 0,
        Subsignal("tx", Pins("BJ41")),
        Subsignal("rx", Pins("BK41")),
        IOStandard("LVCMOS18"),
    ),
]


class PostRing(LiteXModule, AutoCSR):
    """Last 64 POST writes with the IOP cycle count at which they happened."""
    def __init__(self, post_code, post_wr, reset_iop, depth=64):
        self.count = CSRStatus(16, description="POST writes since the IOP last left reset (saturating)")
        self.addr  = CSRStorage(6, description="entry to read: 0 = oldest of the last 64")
        self.code  = CSRStatus(8,  description="POST code of the selected entry")
        self.time  = CSRStatus(32, description="IOP cycle count of the selected entry")
        self.cycles = CSRStatus(32, description="IOP cycles since the IOP last left reset")

        mem = Memory(40, depth)
        self.specials += mem
        wp = mem.get_port(write_capable=True, clock_domain="iop")
        rp = mem.get_port(clock_domain="sys")
        self.specials += wp, rp

        cycles = Signal(32); wr_ptr = Signal(6); count = Signal(16)
        self.sync.iop += [
            If(reset_iop,
                cycles.eq(0), wr_ptr.eq(0), count.eq(0),
            ).Else(
                cycles.eq(cycles + 1),
                If(post_wr,
                    wr_ptr.eq(wr_ptr + 1),
                    If(count != 0xFFFF, count.eq(count + 1)),
                ),
            ),
        ]
        self.comb += [
            wp.adr.eq(wr_ptr), wp.dat_w.eq(Cat(post_code, cycles)), wp.we.eq(post_wr & ~reset_iop),
        ]
        # read side: entry 0 = oldest -> address wr_ptr + addr (mod 64) when the ring has wrapped
        wr_ptr_sys = Signal(6); count_sys = Signal(16); cycles_sys = Signal(32)
        self.specials += MultiReg(wr_ptr, wr_ptr_sys, "sys"), MultiReg(count, count_sys, "sys"), MultiReg(cycles, cycles_sys, "sys")
        self.comb += [
            rp.adr.eq(Mux(count_sys >= depth, wr_ptr_sys + self.addr.storage, self.addr.storage)),
            self.code.status.eq(rp.dat_r[0:8]),
            self.time.status.eq(rp.dat_r[8:40]),
            self.count.status.eq(count_sys),
            self.cycles.status.eq(cycles_sys),
        ]


class ConsoleFifo(LiteXModule, AutoCSR):
    """Bytes the IOP writes to its serial console, iop -> sys, read by the host."""
    def __init__(self, con_wr, con_data, depth=4096):
        self.level = CSRStatus(16, description="bytes waiting (saturating at the FIFO depth)")
        self.data  = CSRStatus(8,  description="next byte; reading `pop` advances")
        self.pop   = CSRStorage(1, description="write 1 to drop the byte in `data`")
        self.overflow = CSRStatus(1, description="1 once a byte was lost to a full FIFO")
        fifo = AsyncFIFO(8, depth)
        self.fifo = ClockDomainsRenamer({"write": "iop", "read": "sys"})(fifo)
        ovf = Signal()
        self.comb += fifo.din.eq(con_data), fifo.we.eq(con_wr & fifo.writable)
        self.sync.iop += If(con_wr & ~fifo.writable, ovf.eq(1))
        self.comb += [
            self.data.status.eq(fifo.dout),
            self.level.status.eq(Mux(fifo.readable, 1, 0)),      # AsyncFIFO has no level: 1 = at least one byte
            fifo.re.eq(self.pop.re),
        ]
        self.specials += MultiReg(ovf, self.overflow.status, "sys")


class StallDetector(LiteXModule, AutoCSR):
    """Cycles since the CPU's last bus request; `stall` after 2^22 of them."""
    def __init__(self, req, reset_iop):
        self.idle_cycles = CSRStatus(24, description="IOP cycles since the last CPU bus request (saturating)")
        self.stalled     = CSRStatus(1,  description="1 once 2^22 cycles passed with no request")
        self.stall = Signal()
        cnt = Signal(24)
        self.sync.iop += [
            If(reset_iop | req, cnt.eq(0)).Elif(cnt != 0xFFFFFF, cnt.eq(cnt + 1)),
        ]
        self.comb += self.stall.eq(cnt[22])
        self.specials += MultiReg(cnt, self.idle_cycles.status, "sys"), MultiReg(self.stall, self.stalled.status, "sys")


class PS2DiagSoC(PS2IOPSoC):
    def __init__(self, platform, baudrate=115200, depth=4096, **kwargs):
        platform.add_extension(_serial)
        PS2IOPSoC.__init__(self, platform, **kwargs)
        self.add_uartbone("serial", baudrate=baudrate)

        iop = self.iop                      # IOPBringup: post_code/post_wr/dbg in the iop domain
        reset_iop = Signal()
        self.specials += MultiReg(iop.reset.storage, reset_iop, "iop")

        self.zpost  = PostRing(iop.post_code, iop.post_wr, reset_iop)
        self.zstall = StallDetector(iop.dbg["req"], reset_iop)
        self.zcon   = ConsoleFifo(iop.con_wr, iop.con_data)

        d = iop.dbg
        sigs = [d["req"], d["rnw"], d["isdata"], d["done"], d["wmask"], d["addr_instr"], d["addr_data"],
                d["wdata"], d["rdata"], iop.post_wr, iop.post_code, iop.cpu_error_iop, self.zstall.stall, reset_iop,
                iop.con_wr, iop.con_data]
        self.zanalyzer_iop = LiteScopeAnalyzer(sigs, depth=depth, clock_domain="iop", with_rle=True,
                                               csr_csv="zanalyzer_iop.csv")


def build(do_build=False, build_dir="build/c1100_ps2_diag"):
    platform = xilinx_c1100.Platform(toolchain="vivado")
    soc      = PS2DiagSoC(platform)
    builder  = Builder(soc, output_dir=build_dir, compile_software=False,
                       csr_csv=join(build_dir, "csr.csv"))
    builder.build(run=do_build)
    try:
        generate_litepcie_software(soc, join(build_dir, "software"))
    except Exception as e:
        print(f"note: litepcie software generation skipped: {e}")
    return builder


if __name__ == "__main__":
    build(do_build="--build" in sys.argv)
