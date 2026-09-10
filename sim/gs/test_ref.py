#!/usr/bin/env python3
"""Hand-computed checks on sim/gs/gs_ref.py.

    sim/gs/test_ref.py

The cross-check against PCSX2 covers the addressing arithmetic.  These cover
the parts that have no second implementation to lean on: GIFtag decode, the
A+D path, REGLIST packing, and whether a host-to-local transfer puts pixels
where the addressing says it should.
"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
import gs_ref
from gs_ref import GS, addr32, bits

fails = []


def check(name, got, want):
    if got != want:
        fails.append("%s: got %r, want %r" % (name, got, want))


def giftag(nloop, eop, regs, nreg, flg=0, pre=0, prim=0):
    return (nloop | (eop << 15) | (pre << 46) | (prim << 47) |
            (flg << 58) | ((nreg & 15) << 60) | (regs << 64))


# ---- GIFtag fields decode where the manual puts them ----------------------
t = giftag(nloop=3, eop=1, regs=0xE, nreg=1)
check("NLOOP", bits(t, 14, 0), 3)
check("EOP",   bits(t, 15, 15), 1)
check("NREG",  bits(t, 63, 60), 1)
check("REGS",  bits(t, 127, 64), 0xE)

# ---- A+D writes the register its payload names ---------------------------
gs = GS()
# one PACKED loop of one A+D quadword: write 0x1234 to SCISSOR_1 (0x40)
qw = 0x1234 | (0x40 << 64)
gs.gif_packet([giftag(1, 1, 0xE, 1), qw])
check("A+D SCISSOR_1", gs.reg[0x40], 0x1234)

# ---- PRE loads PRIM before the data, and only when FLG is not IMAGE ------
gs = GS()
gs.gif_packet([giftag(1, 1, 0xF, 1, pre=1, prim=0x123), 0])
check("PRE loads PRIM", gs.reg[0x00], 0x123)

gs = GS()
gs.gif_packet([giftag(0, 1, 0xF, 1, pre=1, prim=0x123, flg=2)])
check("PRE ignored for IMAGE", gs.reg[0x00], 0)

# ---- REGLIST packs two registers per quadword ----------------------------
gs = GS()
# NREG=2, descriptors FOG(0xA) then PRIM(0x0); one loop => two writes
gs.gif_packet([giftag(1, 1, 0x0A, 2, flg=1), 0x0000_0111 | (0x222 << 64)])
check("REGLIST FOG",  gs.reg[0x0A], 0x111)
check("REGLIST PRIM", gs.reg[0x00], 0x222)

# ---- a host-to-local transfer lands where addr32 says --------------------
# A 4x2 rectangle of PSMCT32 at buffer pointer 0, one page wide, from (0,0).
# One PACKED loop of four A+D quadwords sets the transfer up; NLOOP counts
# loops and NREG the registers in each, so four registers is NLOOP=1, NREG=4 --
# NLOOP=4 would ask for sixteen quadwords.
W, H = 4, 2
pkts = [giftag(1, 0, 0xEEEE, 4),
        (0 | (1 << 48))       | (0x50 << 64),   # BITBLTBUF: DBP 0, DBW 1 page
        0                     | (0x51 << 64),   # TRXPOS:    DSAX 0, DSAY 0
        (W | (H << 32))       | (0x52 << 64),   # TRXREG:    RRW, RRH
        0                     | (0x53 << 64)]   # TRXDIR:    host-to-local
# then an IMAGE packet: each quadword carries four PSMCT32 pixels, so eight
# pixels is two quadwords
vals = [0x11111111, 0x22222222, 0x33333333, 0x44444444,
        0x55555555, 0x66666666, 0x77777777, 0x88888888]
pkts.append(giftag(2, 1, 0, 1, flg=2))
for i in range(0, 8, 4):
    pkts.append(vals[i] | (vals[i + 1] << 32) |
                (vals[i + 2] << 64) | (vals[i + 3] << 96))

gs2 = GS()
at = 0
while at < len(pkts):
    nxt = gs2.gif_packet(pkts, at)
    if nxt == at:
        break
    at = nxt
check("transfer set up BITBLTBUF", bits(gs2.reg[0x50], 53, 48), 1)
check("transfer set up TRXREG", bits(gs2.reg[0x52], 11, 0), W)
n = 0
for y in range(H):
    for x in range(W):
        a = addr32(0, 1, x, y)
        got = int.from_bytes(gs2.vm[a * 4:a * 4 + 4], "little")
        if got != vals[n]:
            fails.append("pixel (%d,%d) at word %d: got %08x want %08x"
                         % (x, y, a, got, vals[n]))
        n += 1

# ---- the swizzle is a bijection over a page ------------------------------
seen = {addr32(0, 1, x, y) for y in range(32) for x in range(64)}
check("page is a bijection", len(seen), 32 * 64)

if fails:
    print("FAIL")
    for f in fails:
        print("  " + f)
    sys.exit(1)
print("PASS  all reference-model checks")
