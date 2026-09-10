#!/usr/bin/env python3
"""Emit a directed MFC0/MTC0 program.

    sim/ee/gen_cop0.py > cop0.hex

COP0 is only observable through a GPR, so every check here is MTC0 followed by
MFC0 -- which makes the distance between them the thing that matters, exactly as
it does for HI and LO: at distance 1 the value is forwarded from A2, at 2 from
WB, and at 3 or more it has reached the register file.  A COP0 file without
forwarding passes any test that spaces the pair apart.

PRId is read-only and identifies the core; a write to it must not take.
"""

def sp(rs, rt, rd, sa, fn): return (rs << 21) | (rt << 16) | (rd << 11) | (sa << 6) | fn
def lui(rt, imm):     return (15 << 26) | (rt << 16) | (imm & 0xFFFF)
def ori(rt, rs, imm): return (13 << 26) | (rs << 21) | (rt << 16) | (imm & 0xFFFF)
def addu(rd, rs, rt): return sp(rs, rt, rd, 0, 33)
def mtc0(rt, rd):     return (16 << 26) | (4 << 21) | (rt << 16) | (rd << 11)
def mfc0(rt, rd):     return (16 << 26) | (0 << 21) | (rt << 16) | (rd << 11)
NOP = 0


def main():
    o = []
    # a distinctive value per COP0 register, written then read back at each of
    # the three forwarding distances
    for gap in range(3):
        for cr in (0, 9, 11, 12, 13, 14, 16, 30):
            o += [lui(2, 0xC0DE), ori(2, 2, 0x1000 + cr + (gap << 8))]
            o += [mtc0(2, cr)]
            o += [NOP] * gap
            o += [mfc0(3 + (cr % 8), cr)]

    # every register in turn, so an index that is decoded wrongly shows up as a
    # value landing in the wrong place rather than not landing at all
    for cr in range(32):
        o += [lui(2, 0xBEEF), ori(2, 2, cr), mtc0(2, cr)]
    for cr in range(32):
        o += [mfc0(4 + (cr % 4), cr), addu(20 + (cr % 4), 4 + (cr % 4), 0)]

    # PRId is read-only: the write must not take, and the read must still
    # identify the core
    o += [mfc0(11, 15)]
    o += [lui(2, 0x1234), ori(2, 2, 0x5678), mtc0(2, 15), mfc0(12, 15)]
    o += [addu(13, 11, 0), addu(14, 12, 0)]

    for w in o:
        print("%08x" % (w & 0xFFFFFFFF))
    for _ in range(4096 - len(o)):
        print("00000000")
    return len(o)


if __name__ == "__main__":
    main()
