#!/usr/bin/env python3
"""A reference model of the Graphics Synthesizer, for differential testing.

    sim/gs/gs_ref.py packets.hex [--dump-mem BASE LEN]

Written to the GS User's Manual, and modelling no timing whatever -- the same
choice the R5900 reference makes, and for the same reason: the RTL and this can
then be compared on architectural state alone, and a disagreement is a diff
rather than an investigation.

This slice covers what can be checked without drawing anything:

  * GIFtag decode, in PACKED, REGLIST and IMAGE modes
  * the 64 general registers, including the A+D path
  * local memory addressing -- the page/block/column swizzle
  * host-to-local transfers, which are the first thing that puts pixels in
    memory and need no rasteriser at all

The swizzle is written as arithmetic rather than as tables.  Both tables turn
out to be bit interleaves, which is not a coincidence -- it is how the hardware
decodes an address -- and writing the interleave means the layout is derived
here rather than transcribed from somebody else's source.
tools/gs/xcheck_swizzle.py checks it against PCSX2's tables exhaustively.
"""
import argparse

VM_WORDS   = 4 * 1024 * 1024 // 4     # 4 MB of local memory, in 32-bit words
PAGE_WORDS = 8192 // 4                # a page is 8 KB
BLOCK_WORDS = 256 // 4                # a block is 256 B


# ---- the swizzle -----------------------------------------------------------
#
# PSMCT32: a page is 64 x 32 pixels, a block 8 x 8, a column 8 x 2.  A pixel's
# word address is page * 2048 + block * 64 + word-within-block, and both the
# block index within the page and the word index within the block are bit
# interleaves of the low bits of x and y.

def block32(by, bx):
    """Block index within a page, from the block's (x, y) in units of 8 px."""
    return ((bx & 1)) | ((by & 1) << 1) | ((bx & 2) << 1) | \
           ((by & 2) << 2) | ((bx & 4) << 2)


def column32(y, x):
    """Word index within a block, from a pixel's low three bits of x and y."""
    return ((x & 1)) | ((y & 1) << 1) | ((x & 6) << 1) | ((y & 6) << 3)


def addr32(bp, bw, x, y):
    """Word address of pixel (x, y) in a PSMCT32 buffer.

    bp is the buffer pointer in 256-byte blocks, as BITBLTBUF and FRAME carry
    it; bw is the buffer width in units of 64 pixels.
    """
    page = (bp >> 5) + (y >> 5) * bw + (x >> 6)
    return (page * PAGE_WORDS
            + block32((y >> 3) & 3, (x >> 3) & 7) * BLOCK_WORDS
            + column32(y & 7, x & 7))


# ---- GIF -------------------------------------------------------------------

# PACKED-mode register descriptors.  0x0-0xA and 0xC-0xF are defined; 0xB is
# reserved and the manual does not say what hardware does with it, so it is
# counted rather than guessed at.
PACKED_NAMES = {
    0x0: "PRIM", 0x1: "RGBAQ", 0x2: "ST", 0x3: "UV", 0x4: "XYZF2", 0x5: "XYZ2",
    0x6: "TEX0_1", 0x7: "TEX0_2", 0x8: "CLAMP_1", 0x9: "CLAMP_2", 0xA: "FOG",
    0xC: "XYZF3", 0xD: "XYZ3", 0xE: "A+D", 0xF: "NOP",
}

# General register addresses, as written through A+D or REGLIST.
REG_ADDR = {
    0x00: "PRIM",     0x01: "RGBAQ",   0x02: "ST",       0x03: "UV",
    0x04: "XYZF2",    0x05: "XYZ2",    0x06: "TEX0_1",   0x07: "TEX0_2",
    0x08: "CLAMP_1",  0x09: "CLAMP_2", 0x0A: "FOG",      0x0C: "XYZF3",
    0x0D: "XYZ3",     0x14: "TEX1_1",  0x15: "TEX1_2",   0x16: "TEX2_1",
    0x17: "TEX2_2",   0x18: "XYOFFSET_1", 0x19: "XYOFFSET_2",
    0x1A: "PRMODECONT", 0x1B: "PRMODE", 0x1C: "TEXCLUT", 0x22: "SCANMSK",
    0x34: "MIPTBP1_1", 0x35: "MIPTBP1_2", 0x36: "MIPTBP2_1", 0x37: "MIPTBP2_2",
    0x3B: "TEXA",     0x3D: "FOGCOL",  0x3F: "TEXFLUSH",
    0x40: "SCISSOR_1", 0x41: "SCISSOR_2", 0x42: "ALPHA_1", 0x43: "ALPHA_2",
    0x44: "DIMX",     0x45: "DTHE",    0x46: "COLCLAMP", 0x47: "TEST_1",
    0x48: "TEST_2",   0x49: "PABE",    0x4A: "FBA_1",    0x4B: "FBA_2",
    0x4C: "FRAME_1",  0x4D: "FRAME_2", 0x4E: "ZBUF_1",   0x4F: "ZBUF_2",
    0x50: "BITBLTBUF", 0x51: "TRXPOS", 0x52: "TRXREG",   0x53: "TRXDIR",
    0x54: "HWREG",    0x60: "SIGNAL",  0x61: "FINISH",   0x62: "LABEL",
}


def bits(v, hi, lo):
    return (v >> lo) & ((1 << (hi - lo + 1)) - 1)


class GS:
    def __init__(self):
        self.reg = {a: 0 for a in REG_ADDR}
        self.vm = bytearray(4 * 1024 * 1024)
        self.unknown = 0          # writes to addresses the manual does not define
        self.xfer = None          # a host-to-local transfer in progress

    # -- register writes ----------------------------------------------------
    def write(self, addr, data):
        if addr not in REG_ADDR:
            self.unknown += 1
            return
        self.reg[addr] = data & ((1 << 64) - 1)
        if addr == 0x53:                      # TRXDIR starts the transfer
            self.start_transfer()
        elif addr == 0x54:                    # HWREG carries transfer data
            self.hwreg(data)

    # -- host-to-local ------------------------------------------------------
    def start_transfer(self):
        if bits(self.reg[0x53], 1, 0) != 0:   # only host-to-local for now
            self.xfer = None
            return
        bitbltbuf = self.reg[0x50]
        trxpos    = self.reg[0x51]
        trxreg    = self.reg[0x52]
        self.xfer = {
            "bp":  bits(bitbltbuf, 45, 32) ,      # DBP, in 256-byte blocks
            "bw":  bits(bitbltbuf, 53, 48),       # DBW, in 64-pixel units
            "psm": bits(bitbltbuf, 61, 56),       # DPSM
            "dx":  bits(trxpos, 42, 32),          # DSAX
            "dy":  bits(trxpos, 58, 48),          # DSAY
            "w":   bits(trxreg, 11, 0),           # RRW
            "h":   bits(trxreg, 43, 32),          # RRH
            "n":   0,                             # pixels written so far
        }

    def hwreg(self, data):
        """One 64-bit word of transfer data: two PSMCT32 pixels."""
        t = self.xfer
        if t is None or t["psm"] != 0 or t["w"] == 0:
            return
        for half in (0, 1):
            if t["n"] >= t["w"] * t["h"]:
                break
            px = data >> (32 * half) & 0xFFFFFFFF
            x = t["dx"] + t["n"] % t["w"]
            y = t["dy"] + t["n"] // t["w"]
            a = addr32(t["bp"], t["bw"], x, y)
            if a < VM_WORDS:
                self.vm[a * 4:a * 4 + 4] = px.to_bytes(4, "little")
            t["n"] += 1

    # -- GIF ----------------------------------------------------------------
    def gif_packet(self, qwords, at=0):
        """Consume GIF data starting at quadword index `at`; return the next index."""
        while at < len(qwords):
            tag = qwords[at]
            at += 1
            nloop = bits(tag, 14, 0)
            eop   = bits(tag, 15, 15)
            pre   = bits(tag, 46, 46)
            prim  = bits(tag, 57, 47)
            flg   = bits(tag, 59, 58)
            nreg  = bits(tag, 63, 60) or 16
            regs  = bits(tag, 127, 64)

            if pre and flg != 2:
                self.write(0x00, prim)          # PRE loads PRIM before the data

            if flg == 0:                         # PACKED
                for i in range(nloop):
                    for r in range(nreg):
                        if at >= len(qwords):
                            return at
                        self.packed(bits(regs, 4 * r + 3, 4 * r), qwords[at])
                        at += 1
            elif flg == 1:                       # REGLIST: two registers per qword
                total = nloop * nreg
                i = 0
                while i < total:
                    if at >= len(qwords):
                        return at
                    qw = qwords[at]
                    at += 1
                    for half in (0, 1):
                        if i >= total:
                            break
                        d = bits(regs, 4 * (i % nreg) + 3, 4 * (i % nreg))
                        self.reglist(d, bits(qw, 64 * half + 63, 64 * half))
                        i += 1
            elif flg == 2:                       # IMAGE: straight to HWREG
                for i in range(nloop):
                    if at >= len(qwords):
                        return at
                    qw = qwords[at]
                    at += 1
                    self.hwreg(bits(qw, 63, 0))
                    self.hwreg(bits(qw, 127, 64))
            # flg == 3 is "disable" and transfers nothing

            if eop:
                return at
        return at

    def packed(self, desc, qw):
        name = PACKED_NAMES.get(desc)
        if name is None:                         # 0xB, reserved
            self.unknown += 1
        elif name == "NOP":
            pass
        elif name == "A+D":
            self.write(bits(qw, 71, 64), bits(qw, 63, 0))
        elif name == "PRIM":
            self.write(0x00, bits(qw, 10, 0))
        elif name == "RGBAQ":
            self.write(0x01, bits(qw, 7, 0) | (bits(qw, 39, 32) << 8) |
                             (bits(qw, 71, 64) << 16) | (bits(qw, 103, 96) << 24))
        elif name == "ST":
            self.write(0x02, bits(qw, 63, 0))
        elif name == "UV":
            self.write(0x03, bits(qw, 13, 0) | (bits(qw, 45, 32) << 16))
        elif name in ("XYZF2", "XYZF3"):
            v = (bits(qw, 15, 0) | (bits(qw, 47, 32) << 16) |
                 (bits(qw, 91, 68) << 32) | (bits(qw, 107, 100) << 56))
            self.write(0x04 if name == "XYZF2" else 0x0C, v)
        elif name in ("XYZ2", "XYZ3"):
            v = bits(qw, 15, 0) | (bits(qw, 47, 32) << 16) | (bits(qw, 95, 64) << 32)
            self.write(0x05 if name == "XYZ2" else 0x0D, v)
        else:
            addr = {v: k for k, v in REG_ADDR.items()}[name]
            self.write(addr, bits(qw, 63, 0))

    def reglist(self, desc, data):
        name = PACKED_NAMES.get(desc)
        if name is None or name == "NOP":
            return
        if name == "A+D":                        # not meaningful in REGLIST
            self.unknown += 1
            return
        addr = {v: k for k, v in REG_ADDR.items()}.get(name)
        if addr is not None:
            self.write(addr, data)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("packets")
    ap.add_argument("--dump-mem", nargs=2, type=lambda s: int(s, 0), default=None)
    ap.add_argument("--raw", action="store_true",
                    help="print every address 0x00-0x7f without names, for diffing "
                         "against the RTL -- the undefined ones are part of the test, "
                         "since a write to one must leave it alone")
    a = ap.parse_args()

    qwords = []
    for line in open(a.packets):
        t = line.split("//")[0].strip()
        if t:
            qwords.append(int(t, 16))

    gs = GS()
    at = 0
    while at < len(qwords):
        nxt = gs.gif_packet(qwords, at)
        if nxt == at:
            break
        at = nxt

    if a.raw:
        for addr in range(0x80):
            print("REG %02x %016x" % (addr, gs.reg.get(addr, 0)))
    else:
        for addr in sorted(REG_ADDR):
            print("REG %02x %-11s %016x" % (addr, REG_ADDR[addr], gs.reg[addr]))
    if a.dump_mem:
        base, ln = a.dump_mem
        for off in range(0, ln, 16):
            row = gs.vm[base + off:base + off + 16]
            print("VM %08x %s" % (base + off, row[::-1].hex()))
    if gs.unknown:
        print("# unknown register writes: %d" % gs.unknown)


if __name__ == "__main__":
    main()
