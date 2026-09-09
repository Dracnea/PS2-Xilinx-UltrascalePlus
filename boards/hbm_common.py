#!/usr/bin/env python3
#
# The HBM pieces, shared by every target that uses the memory.
#
# Factored out of boards/c1100_hbm_test.py once a second target needed them, so
# that the two fixes it took to get HBM working on the card live in one place:
# the AXI reset domain and the debug hub's clock.  Both are easy to get wrong
# and neither is obvious from the LiteX wrapper.

import os
from os.path import join, dirname, abspath, normpath

from migen import *
from migen.genlib.cdc import MultiReg, PulseSynchronizer

from litex.gen.fhdl.module import LiteXModule
from litex.soc.cores.ram.xilinx_usp_hbm2 import USPHBM2
from litex.soc.interconnect import axi
from litex.soc.interconnect.csr import CSRStorage, CSRStatus, CSRField, AutoCSR

REPO_ROOT = normpath(join(dirname(abspath(__file__)), ".."))
HBM_XCI   = join(REPO_ROOT, "ip", "hbm", "hbm_0", "hbm_0.xci")
HBM_TCL   = join(REPO_ROOT, "boards", "hbm_dbghub.tcl")

# Where things live in HBM.  docs/hbm.md is the authority; these are the two
# regions gateware needs to know about by name.
HBM_DISC_BASE = 0x0_0000_0000      # 6 GiB disc sector cache
HBM_EE_BASE   = 0x1_8000_0000      # EE main memory, 32 MB


class HBM(USPHBM2):
    """USPHBM2 with the three things the stock wrapper leaves to the board.

    1. The .xci path.  The wrapper looks for ip/hbm/<name>.xci relative to the
       working directory; Vivado's create_ip puts it in ip/hbm/<name>/<name>.xci
       and the build may run from anywhere, so the real path is passed in.

    2. CATTRIP.  The wrapper ties both stacks' DRAM_x_STAT_CATTRIP to Open().
       On this board that is a real pin (BE45) feeding the satellite controller,
       and platforms/xilinx_c1100.py warns it must never float.  Targets without
       HBM drive it low; this one has the actual over-temperature output and
       reports it.  Tying it low would make an overheating card look healthy.

    3. The AXI reset.  The wrapper drives every AXI_xx_ARESET_N from
       ResetSignal("apb"), but those ports are clocked by the AXI clock, so the
       recovery check ran from the 100 MHz APB domain into the 250 MHz AXI one
       and failed by 1.077 ns.  A reset must be released synchronously to the
       clock that uses it; LiteX's create_clkout has already put an
       AsyncResetSynchronizer on the AXI domain, so that is the correct one.
    """
    def __init__(self, platform, cattrip_pad, xci=HBM_XCI, **kwargs):
        self.xci = xci
        USPHBM2.__init__(self, platform, **kwargs)

        cattrip = Signal(2)
        for i in range(2):
            self.hbm_params[f"o_DRAM_{i:1d}_STAT_CATTRIP"] = cattrip[i]
        self.comb += cattrip_pad.eq(cattrip != 0)

        for i in range(32):
            self.hbm_params[f"i_AXI_{i:02d}_ARESET_N"] = ~ResetSignal("axi")

        # The IP brings its own debug hub whose clock Vivado leaves unconnected,
        # which stops opt_design.  See boards/hbm_dbghub.tcl.
        platform.toolchain.pre_optimize_commands.append("source " + HBM_TCL)

    def add_sources(self, platform):
        platform.add_ip(self.xci)


class HBMProbe(LiteXModule, AutoCSR):
    """One 256-bit AXI beat at a time, driven from the host.

    Slow and meant to be: this is how the host proves the memory works, and how
    it stages a modest amount of data into it before there is a DMA path.  A
    beat costs about ten CSR round trips, so it is fine for a sector and wrong
    for a disc.

    The engine lives entirely in the AXI domain and only three things cross: a
    go pulse in, a done pulse out, and the address/data registers.  Those are
    written long before `go` and never move while a transfer is in flight, so a
    MultiReg on them is sound -- the failure to avoid is crossing a value that
    is still changing, which is what put a disc sector one word out of place
    (docs/disc-path.md).
    """
    def __init__(self, axi_port):
        self.addr  = CSRStorage(33, description="byte address, 32-byte aligned; 33 bits reaches both stacks")
        self.wdata = CSRStorage(32, description="write port: each write pushes one 32-bit lane, 8 to a beat")
        self.ctrl  = CSRStorage(fields=[
            CSRField("write", size=1, pulse=True, description="issue a write beat"),
            CSRField("read",  size=1, pulse=True, description="issue a read beat"),
            CSRField("clear", size=1, pulse=True, description="reset the lane pointer"),
        ])
        self.stat  = CSRStatus(fields=[
            CSRField("busy", size=1),
            CSRField("done", size=1, description="set when a beat completes, cleared by the next"),
            CSRField("resp", size=2, description="AXI response of the last beat; 0 is OK"),
            CSRField("lane", size=4, description="current write-lane pointer"),
        ])
        self.rdata = CSRStatus(32, description="read port: lane selected by rlane")
        self.rlane = CSRStorage(3, description="which 32-bit lane of the last read beat rdata shows")

        wbuf = Signal(256)
        lane = Signal(4)
        self.sync += [
            If(self.ctrl.fields.clear,
                lane.eq(0),
            ).Elif(self.wdata.re,
                Case(lane, {i: wbuf[32*i:32*(i+1)].eq(self.wdata.storage) for i in range(8)}),
                If(lane == 7, lane.eq(0)).Else(lane.eq(lane + 1)),
            ),
        ]
        self.comb += self.stat.fields.lane.eq(lane)

        go_wr = PulseSynchronizer("sys", "axi"); self.submodules += go_wr
        go_rd = PulseSynchronizer("sys", "axi"); self.submodules += go_rd
        fin   = PulseSynchronizer("axi", "sys"); self.submodules += fin
        self.comb += go_wr.i.eq(self.ctrl.fields.write), go_rd.i.eq(self.ctrl.fields.read)

        addr_axi = Signal(33); wbuf_axi = Signal(256)
        self.specials += MultiReg(self.addr.storage, addr_axi, "axi")
        self.specials += MultiReg(wbuf, wbuf_axi, "axi")

        rbuf_axi = Signal(256); resp_axi = Signal(2)
        rbuf = Signal(256);     resp = Signal(2)
        self.specials += MultiReg(rbuf_axi, rbuf, "sys")
        self.specials += MultiReg(resp_axi, resp, "sys")
        self.comb += [
            self.stat.fields.resp.eq(resp),
            Case(self.rlane.storage, {i: self.rdata.status.eq(rbuf[32*i:32*(i+1)]) for i in range(8)}),
        ]

        busy = Signal(); done = Signal()
        self.specials += MultiReg(busy, self.stat.fields.busy, "sys")
        self.sync += If(fin.o, done.eq(1)).Elif(self.ctrl.fields.write | self.ctrl.fields.read, done.eq(0))
        self.comb += self.stat.fields.done.eq(done)

        fsm = ClockDomainsRenamer("axi")(FSM(reset_state="IDLE"))
        self.submodules += fsm
        self.comb += [
            axi_port.aw.addr.eq(addr_axi), axi_port.aw.len.eq(0), axi_port.aw.size.eq(5),
            axi_port.aw.burst.eq(1), axi_port.aw.id.eq(0),
            axi_port.ar.addr.eq(addr_axi), axi_port.ar.len.eq(0), axi_port.ar.size.eq(5),
            axi_port.ar.burst.eq(1), axi_port.ar.id.eq(0),
            axi_port.w.data.eq(wbuf_axi), axi_port.w.strb.eq(2**32 - 1), axi_port.w.last.eq(1),
        ]
        fsm.act("IDLE", If(go_wr.o, NextState("AW")).Elif(go_rd.o, NextState("AR")))
        fsm.act("AW", axi_port.aw.valid.eq(1), If(axi_port.aw.ready, NextState("W")))
        fsm.act("W",  axi_port.w.valid.eq(1),  If(axi_port.w.ready,  NextState("B")))
        fsm.act("B",  axi_port.b.ready.eq(1),
                If(axi_port.b.valid, NextValue(resp_axi, axi_port.b.resp), NextState("FIN")))
        fsm.act("AR", axi_port.ar.valid.eq(1), If(axi_port.ar.ready, NextState("R")))
        fsm.act("R",  axi_port.r.ready.eq(1),
                If(axi_port.r.valid,
                   NextValue(rbuf_axi, axi_port.r.data),
                   NextValue(resp_axi, axi_port.r.resp),
                   NextState("FIN")))
        fsm.act("FIN", fin.i.eq(1), NextState("IDLE"))
        self.comb += busy.eq(~fsm.ongoing("IDLE"))


class HBMDiscSource(LiteXModule, AutoCSR):
    """Answer the CDVD's sector requests from HBM instead of from the host.

    The CDVD block does not know or care where a sector comes from: it raises
    sec_req with an LBA and waits for 512 words and a done.  `discserve.py`
    answers that over PCIe today, one sector per round trip; this answers it out
    of HBM, with no host in the loop and a seek time that is a memory latency.
    Which of the two is in charge is a CSR, so the host path stays available and
    the two can be compared directly on the same disc.

    It runs in the `sys` domain and reaches HBM through
    axi.AXIClockDomainCrossing, rather than living in the AXI domain and
    hand-crossing the sector data.  A library crossing is the right trade here:
    the hand-written one on this exact path is what shifted a sector by a word
    on the first hardware run (docs/disc-path.md).

    A 2048-byte sector is 64 beats of 256 bits, which is one AXI burst; each
    beat becomes eight 32-bit writes into the CDVD's sector buffer.
    """
    def __init__(self, axi_port, sector_bytes=2048, throttle=8):
        beats = sector_bytes // 32
        words = sector_bytes // 4

        self.base   = CSRStorage(33, reset=HBM_DISC_BASE,
                                 description="HBM byte address of LBA 0")
        self.enable = CSRStorage(1, description="1: serve sectors from HBM; 0: leave them to the host")
        self.stat   = CSRStatus(fields=[
            CSRField("busy",   size=1),
            CSRField("served", size=16, description="sectors served from HBM since reset"),
            CSRField("resp",   size=2,  description="AXI response of the last burst; 0 is OK"),
        ])

        # from the CDVD (already in sys), and the fill path back to it
        self.req       = Signal()
        self.lba       = Signal(32)
        self.fill_we   = Signal()
        self.fill_addr = Signal(max=words)
        self.fill_data = Signal(32)
        self.fill_done = Signal()

        # sys-side AXI master; the crossing to the AXI domain is a library part
        port = axi.AXIInterface(data_width=256, address_width=33, id_width=6)
        self.submodules.cdc = axi.AXIClockDomainCrossing(port, axi_port, "sys", "axi")

        served = Signal(16)
        resp   = Signal(2)
        beat   = Signal(max=beats + 1)
        word   = Signal(max=words + 1)
        shift  = Signal(256)
        self.comb += [
            self.stat.fields.served.eq(served),
            self.stat.fields.resp.eq(resp),
        ]

        fsm = FSM(reset_state="IDLE")
        self.submodules += fsm
        self.comb += [
            port.ar.addr.eq(self.base.storage + (self.lba * sector_bytes)),
            port.ar.len.eq(beats - 1),
            port.ar.size.eq(5),          # 32 bytes per beat
            port.ar.burst.eq(1),         # INCR
            port.ar.id.eq(0),
        ]
        fsm.act("IDLE",
            If(self.enable.storage & self.req,
                NextValue(beat, 0), NextValue(word, 0), NextState("AR")),
        )
        fsm.act("AR",
            port.ar.valid.eq(1),
            If(port.ar.ready, NextState("R")),
        )
        fsm.act("R",
            port.r.ready.eq(1),
            If(port.r.valid,
                NextValue(shift, port.r.data),
                NextValue(resp, port.r.resp),
                NextValue(beat, beat + 1),
                NextState("EMIT"),
            ),
        )
        # Eight 32-bit words out of each beat, into the CDVD's sector buffer.
        # r.ready is low throughout, which stops the next beat arriving before
        # this one has been spent.
        #
        # One word every `throttle` sys cycles, not one per cycle.  The fill path
        # crosses into the IOP's 36.864 MHz domain through a PulseSynchronizer,
        # which needs its input pulses spaced by a few destination clocks; at
        # 125 MHz sys that is a ratio of 3.4, so a word per cycle would silently
        # drop most of the sector.  Eight leaves margin and still delivers 2 KB
        # in about 33 us, against the ~100 us a real drive takes for a sector.
        # The host path never hit this because CSR writes arrive microseconds
        # apart on their own.
        emit = Signal(max=8)
        gap  = Signal(max=throttle)
        fsm.act("EMIT",
            self.fill_we.eq(gap == 0),
            self.fill_addr.eq(word),
            self.fill_data.eq(shift[:32]),
            If(gap != throttle - 1,
                NextValue(gap, gap + 1),
            ).Else(
                NextValue(gap, 0),
                NextValue(shift, Cat(shift[32:], Signal(32))),
                NextValue(word, word + 1),
                If(emit == 7,
                    NextValue(emit, 0),
                    If(beat == beats, NextState("DRAIN")).Else(NextState("R")),
                ).Else(
                    NextValue(emit, emit + 1),
                ),
            ),
        )
        # Let the last word's pulse land in the IOP domain before saying done,
        # or the sector is announced complete while its final write is still in
        # flight across the crossing.
        drain = Signal(max=64)
        fsm.act("DRAIN",
            NextValue(drain, drain + 1),
            If(drain == 63, NextValue(drain, 0), NextState("DONE")),
        )
        fsm.act("DONE",
            self.fill_done.eq(1),
            NextValue(served, served + 1),
            NextState("WAIT"),
        )
        # Hold until the CDVD drops its request, so one press of sec_req serves
        # exactly one sector.
        fsm.act("WAIT", If(~self.req, NextState("IDLE")))
        self.comb += self.stat.fields.busy.eq(~fsm.ongoing("IDLE"))
