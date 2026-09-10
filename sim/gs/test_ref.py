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

# ---- a sprite fills the rectangle it names ------------------------------
def ad(addr, data):
    return (data & ((1 << 64) - 1)) | (addr << 64)

def sprite_prog(x0, y0, x1, y1, colour, scissor=(0, 639, 0, 447), ofx=0, ofy=0):
    setup = [ad(0x4C, 0 | (1 << 16) | (0 << 24)),            # FRAME_1: FBP 0, FBW 1
             ad(0x18, (ofx << 0) | (ofy << 32)),             # XYOFFSET_1
             ad(0x40, scissor[0] | (scissor[1] << 16)
                      | (scissor[2] << 32) | (scissor[3] << 48)),
             ad(0x00, 6),                                    # PRIM: sprite
             ad(0x01, colour)]                               # RGBAQ
    verts = [ad(0x05, (x0 << 4) | ((y0 << 4) << 16)),
             ad(0x05, (x1 << 4) | ((y1 << 4) << 16))]
    return ([giftag(len(setup), 0, 0xEEEEEEEEEEEEEEEE & ((1 << (4 * len(setup))) - 1),
                    len(setup))] + setup
            + [giftag(2, 1, 0xEE, 2)] + verts)

def run(pkts):
    g = GS()
    at = 0
    while at < len(pkts):
        nxt = g.gif_packet(pkts, at)
        if nxt == at:
            break
        at = nxt
    return g

g = run(sprite_prog(2, 1, 6, 3, 0x11223344))
check("sprite pixel count", g.pixels, (6 - 2) * (3 - 1))
for y in range(1, 3):
    for x in range(2, 6):
        a = gs_ref.addr32p(0, 1, x, y)
        got = int.from_bytes(g.vm[a * 4:a * 4 + 4], "little")
        if got != 0x11223344:
            fails.append("sprite (%d,%d): got %08x" % (x, y, got))
# the edges are exclusive at the far corner and inclusive at the near one
a = gs_ref.addr32p(0, 1, 6, 3)
if int.from_bytes(g.vm[a * 4:a * 4 + 4], "little") != 0:
    fails.append("sprite wrote its exclusive corner")

# the scissor clips it
g = run(sprite_prog(0, 0, 8, 8, 0xAABBCCDD, scissor=(2, 4, 3, 5)))
check("scissored pixel count", g.pixels, 3 * 3)

# XYOFFSET shifts it: the same vertices with an offset of 2 px land 2 px lower
g = run(sprite_prog(4, 4, 8, 8, 0x01020304, ofx=2 << 4, ofy=2 << 4))
a = gs_ref.addr32p(0, 1, 2, 2)
if int.from_bytes(g.vm[a * 4:a * 4 + 4], "little") != 0x01020304:
    fails.append("XYOFFSET was not subtracted")

# ---- a triangle covers its interior, and tiles with its neighbour --------
def tri_prog(verts, colour, prim=3, scissor=(0, 639, 0, 447)):
    setup = [ad(0x4C, 0 | (1 << 16)),
             ad(0x18, 0),
             ad(0x40, scissor[0] | (scissor[1] << 16)
                      | (scissor[2] << 32) | (scissor[3] << 48)),
             ad(0x00, prim),
             ad(0x01, colour)]
    regs = 0
    for i in range(len(setup)):
        regs |= 0xE << (4 * i)
    out = [giftag(1, 0, regs, len(setup))] + setup
    vregs = 0
    for i in range(len(verts)):
        vregs |= 0xE << (4 * i)
    out += [giftag(1, 1, vregs, len(verts))]
    out += [ad(0x05, (x << 4) | ((y << 4) << 16)) for x, y in verts]
    return out

# a right triangle with legs of 8: the interior is about half the bounding box,
# and every covered pixel must lie inside it
g = run(tri_prog([(0, 0), (8, 0), (0, 8)], 0x0000FF00))
check("triangle drew something", g.pixels > 0, True)
for y in range(0, 9):
    for x in range(0, 9):
        a = gs_ref.addr32p(0, 1, x, y)
        painted = int.from_bytes(g.vm[a * 4:a * 4 + 4], "little") != 0
        if painted and x + y > 8:
            fails.append("triangle painted (%d,%d), outside its own hypotenuse" % (x, y))

# Two triangles sharing the diagonal must tile the square exactly: every pixel
# covered once, none twice and none missed.  That is what a fill rule is for,
# and it holds whether or not this particular rule is the GS's.
gA = run(tri_prog([(0, 0), (8, 0), (0, 8)], 0x11111111))
gB = run(tri_prog([(8, 0), (8, 8), (0, 8)], 0x22222222))
both = missed = 0
for y in range(0, 8):
    for x in range(0, 8):
        a = gs_ref.addr32p(0, 1, x, y)
        pa = int.from_bytes(gA.vm[a * 4:a * 4 + 4], "little") != 0
        pb = int.from_bytes(gB.vm[a * 4:a * 4 + 4], "little") != 0
        if pa and pb: both += 1
        if not pa and not pb: missed += 1
check("shared edge drawn twice", both, 0)
check("shared edge left a gap", missed, 0)

# a degenerate triangle has no area and must draw nothing
g = run(tri_prog([(2, 2), (6, 2), (4, 2)], 0x33333333))
check("degenerate triangle", g.pixels, 0)

# a strip reuses the last two vertices, so four vertices make two triangles
g4 = run(tri_prog([(0, 0), (8, 0), (0, 8), (8, 8)], 0x44444444, prim=4))
check("strip drew two triangles", g4.pixels > gA.pixels, True)

# ---- the swizzle is a bijection over a page ------------------------------
seen = {addr32(0, 1, x, y) for y in range(32) for x in range(64)}
check("page is a bijection", len(seen), 32 * 64)

if fails:
    print("FAIL")
    for f in fails:
        print("  " + f)
    sys.exit(1)
print("PASS  all reference-model checks")
