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
            CSRField("state", size=4, description="FSM state: 0 IDLE, then AW/W/B/AR/R/FIN"),
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
        # Which state, not just "not idle".  A stuck AXI master is always busy;
        # the only useful question is which handshake it is waiting on.
        # Migen's FSM has no `.state` until it is finalised, so the encoding is
        # built here from ongoing() -- which also means the numbers are ours and
        # stay stable if the FSM ever gains a state.
        pst = Signal(4)
        self.comb += [
            If(fsm.ongoing("AW"), pst.eq(1)).Elif(fsm.ongoing("W"), pst.eq(2))
            .Elif(fsm.ongoing("B"), pst.eq(3)).Elif(fsm.ongoing("AR"), pst.eq(4))
            .Elif(fsm.ongoing("R"), pst.eq(5)).Elif(fsm.ongoing("FIN"), pst.eq(6)),
        ]
        self.specials += MultiReg(pst, self.stat.fields.state, "sys")


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
            CSRField("state",  size=4,  description="FSM state: 0 IDLE, AR, R, EMIT, DRAIN, DONE, WAIT"),
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
        self.comb += [
            If(fsm.ongoing("AR"),      self.stat.fields.state.eq(1))
            .Elif(fsm.ongoing("R"),     self.stat.fields.state.eq(2))
            .Elif(fsm.ongoing("EMIT"),  self.stat.fields.state.eq(3))
            .Elif(fsm.ongoing("DRAIN"), self.stat.fields.state.eq(4))
            .Elif(fsm.ongoing("DONE"),  self.stat.fields.state.eq(5))
            .Elif(fsm.ongoing("WAIT"),  self.stat.fields.state.eq(6)),
        ]


class HBMDMAWriter(LiteXModule, AutoCSR):
    """Write a stream straight into HBM, at PCIe speed.

    The staging problem in one line: the HBM probe moves a 32-byte beat per ten
    CSR round trips, so a 4 GiB disc image would take most of a day.  This takes
    LitePCIe's host-to-card DMA stream and puts it in HBM with no CSR in the
    path at all, which is the difference between "stage a few sectors to prove
    the wiring" and "load a game".

    Rate: the DMA stream is `data_width` bits at the sys clock -- 128 bits at
    125 MHz is 2 GB/s -- against 8 GB/s on the 256-bit HBM port, so PCIe and the
    sys clock are the limit and HBM is not.  A 4.35 GiB image should land in
    roughly two seconds.  That number is arithmetic until the card confirms it.

    Two 128-bit words are packed into each 256-bit beat and written in bursts of
    `burst` beats, so one address phase covers 512 bytes rather than 32.  The
    engine runs in the sys domain and reaches HBM through
    AXIClockDomainCrossing, for the same reason the disc source does: a library
    crossing rather than a hand-written one on a path that carries data.
    """
    def __init__(self, axi_port, dma_source, data_width=128, burst=16):
        assert 256 % data_width == 0 and data_width <= 256
        packing = 256 // data_width          # source words per HBM beat

        self.base   = CSRStorage(33, reset=HBM_DISC_BASE,
                                 description="HBM byte address to start writing at")
        self.length = CSRStorage(32, description="bytes to write; the transfer ends when this many have landed")
        self.ctrl   = CSRStorage(fields=[
            CSRField("start", size=1, pulse=True, description="arm the engine; the host then runs the DMA"),
            CSRField("abort", size=1, pulse=True, description="give up on a transfer that is not completing"),
        ])
        self.stat   = CSRStatus(fields=[
            CSRField("busy", size=1),
            CSRField("done", size=1, description="set when `length` bytes have been written"),
            CSRField("resp", size=2, description="AXI response of the last burst; 0 is OK"),
            CSRField("state", size=4, description="FSM state: 0 IDLE, 1 AW, 2 W, 3 B"),
            CSRField("stalled", size=1, description="in W with no packed beat: waiting on the host, not on HBM"),
        ])
        self.written = CSRStatus(32, description="bytes written so far; the honest progress indicator")
        self.bursts  = CSRStatus(32, description="AW handshakes HBM accepted; 0 means HBM never answered")

        port = axi.AXIInterface(data_width=256, address_width=33, id_width=6)
        self.submodules.axi_cdc = axi.AXIClockDomainCrossing(port, axi_port, "sys", "axi")

        addr    = Signal(33)
        remain  = Signal(32)
        written = Signal(32)
        resp    = Signal(2)
        done    = Signal()
        beat    = Signal(max=burst + 1)
        bursts  = Signal(32)

        # --- pack `packing` source words into one 256-bit beat ---------------
        acc   = Signal(256)
        half  = Signal(max=packing)
        full  = Signal()
        taken = Signal()
        self.comb += taken.eq(port.w.valid & port.w.ready)
        # Accept a source word whenever the accumulator has room, including the
        # cycle the packed beat is being taken.  With `ready = ~full` alone the
        # pattern is accept, accept, stall: `full` is only cleared at the end of
        # the cycle the beat is taken, so the source sees backpressure for that
        # cycle and the engine settles at two words per three cycles -- two
        # thirds of line rate, 1.3 GB/s instead of 2.  Adding `| taken` closes
        # the gap for a single OR gate.
        # The packer must not carry state across transfers, and must not collect
        # anything while the engine is idle.  Both were true before, and the
        # result was that a beat left packed by one run became the *first* beat
        # of the next: every byte correct and the whole image 32 bytes late.
        # The data being right is what makes this kind of fault easy to pass --
        # it reads as a working transfer until something checks alignment.
        armed = Signal()
        flush = Signal()
        self.comb += dma_source.ready.eq(armed & (~full | taken))
        self.sync += [
            If(flush,
                full.eq(0),
                half.eq(0),
            ).Else(
                If(taken, full.eq(0)),
                If(dma_source.valid & dma_source.ready,
                    Case(half, {i: acc[data_width*i:data_width*(i+1)].eq(dma_source.data)
                                for i in range(packing)}),
                    If(half == packing - 1,
                        half.eq(0),
                        full.eq(1),
                    ).Else(
                        half.eq(half + 1),
                    ),
                ),
            ),
        ]

        self.comb += [
            port.aw.addr.eq(addr), port.aw.len.eq(burst - 1), port.aw.size.eq(5),
            port.aw.burst.eq(1), port.aw.id.eq(0),
            port.w.data.eq(acc), port.w.strb.eq(2**32 - 1),
            self.stat.fields.resp.eq(resp),
            self.stat.fields.done.eq(done),
            self.written.status.eq(written),
        ]

        fsm = FSM(reset_state="IDLE")
        self.submodules += fsm
        self.comb += armed.eq(~fsm.ongoing("IDLE"))
        fsm.act("IDLE",
            If(self.ctrl.fields.start,
                flush.eq(1),
                NextValue(addr, self.base.storage),
                NextValue(remain, self.length.storage),
                NextValue(written, 0),
                NextValue(done, 0),
                NextState("AW"),
            ),
        )
        # Abort is latched rather than acted on where it lands.  AXI says that
        # once an AW is accepted, every W beat of that burst and its B response
        # must follow; jumping to IDLE from the middle of a burst leaves the
        # slave waiting for beats that never come and wedges the port.  So abort
        # stops the engine only where stopping is legal: before the next address
        # goes out.
        aborting = Signal()
        self.sync += If(self.ctrl.fields.abort, aborting.eq(1)).Elif(fsm.ongoing("IDLE"), aborting.eq(0))

        fsm.act("AW",
            If(aborting, NextState("IDLE")).
            Elif(remain == 0,
                NextValue(done, 1),
                NextState("IDLE"),
            ).Else(
                port.aw.valid.eq(1),
                If(port.aw.ready,
                   NextValue(beat, 0),
                   NextValue(bursts, bursts + 1),
                   NextState("W")),
            ),
        )
        fsm.act("W",
            port.w.valid.eq(full),
            port.w.last.eq(beat == burst - 1),
            If(taken,
                NextValue(written, written + 32),
                # remain is a byte count and saturates at 0 rather than wrapping,
                # so a length that is not a whole number of bursts still ends.
                If(remain > 32, NextValue(remain, remain - 32)).Else(NextValue(remain, 0)),
                If(beat == burst - 1, NextState("B")).Else(NextValue(beat, beat + 1)),
            ),
        )
        fsm.act("B",
            port.b.ready.eq(1),
            If(port.b.valid,
                NextValue(resp, port.b.resp),
                NextValue(addr, addr + burst * 32),
                NextState("AW"),
            ),
        )
        self.comb += [
            self.stat.fields.busy.eq(~fsm.ongoing("IDLE")),
            If(fsm.ongoing("AW"), self.stat.fields.state.eq(1))
            .Elif(fsm.ongoing("W"), self.stat.fields.state.eq(2))
            .Elif(fsm.ongoing("B"), self.stat.fields.state.eq(3)),
            self.stat.fields.stalled.eq(fsm.ongoing("W") & ~full),
            self.bursts.status.eq(bursts),
        ]
