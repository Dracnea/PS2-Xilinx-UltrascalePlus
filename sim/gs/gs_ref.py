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
from fractions import Fraction

def _ceil(q):
    """ceil for an exact rational, without going through float."""
    return -((-q.numerator) // q.denominator)


def _floor(q):
    """floor for an exact rational, without going through float."""
    return q.numerator // q.denominator


# ---- the interpolator ------------------------------------------------------
#
# The GS does not evaluate an interpolated component per pixel, and it does not
# evaluate it exactly.  Both facts were measured on a real console rather than
# read out of a manual -- Sony's GS User's Manual documents the fill rule to the
# letter and says nothing at all about interpolation precision -- and they are
# the difference between agreeing with hardware and being systematically wrong:
#
#   * One DDA step spans EIGHT pixels.  A span is seeded at its first pixel;
#     within a block of eight, each lane carries a fixed offset; and one step is
#     added per block.  Eight is a measurement, from a width curve that peaks on
#     powers of two and globally at eight.
#   * Both the lane offsets and the block step land on a 2**-10 GRID.  A
#     gradient of 1/4 is the identity under that truncation, which is what let
#     the effect be isolated in the first place.
#
# So an "exact" interpolator -- the obvious thing to write, and what this file
# nearly got -- would disagree with silicon on most gradients, in a way no
# self-consistency test could ever find.  Snapping to a fixed grid is also the
# cheaper thing to build: it is what a DDA does naturally, and it removes any
# need for an exact division per component per pixel.

_GRID = 1024                        # the DDA's fractional grid, 2**-10
_BLOCK = 8                          # pixels per DDA step


def _grid(q):
    """Snap a rational onto the DDA's grid.

    Hardware gets there with an arithmetic shift, so this is floor and not
    truncation toward zero -- the two differ for negative gradients, which is
    exactly where a plausible-looking model goes quietly wrong.
    """
    return Fraction(_floor(q * _GRID), _GRID)


class _Walk:
    """One interpolated component along one span.

    Built once per scanline from the span's seed value and the component's
    dv/dx, and then asked for the value at pixel i of the span.  The blocking is
    relative to the span's first pixel, not to an absolute x, because that is
    where the DDA is seeded.

    The seed is snapped to the same grid as the offsets.  That is a modelling
    choice rather than a measurement: the probes that established the grid used
    flat triangles for the seed, and a flat triangle's seed is an integer, so
    nothing in the evidence distinguishes a snapped seed from an exact one.  It
    is chosen because it puts the entire DDA on one grid -- every quantity here
    is then an integer count of 2**-10 -- which is what the register holding it
    would be in hardware, and which lets the RTL agree with this model bit for
    bit using integer arithmetic instead of chasing an exact rational.
    """
    __slots__ = ("seed", "lane", "step")

    def __init__(self, seed, dvdx):
        self.seed = _grid(seed)
        self.lane = [_grid(dvdx * j) for j in range(_BLOCK)]
        self.step = _grid(dvdx * _BLOCK)

    def at(self, i):
        b, j = divmod(i, _BLOCK)
        return self.seed + self.step * b + self.lane[j]


def _plane(P, vals):
    """dv/dx and dv/dy for the plane through three (x, y) points carrying vals.

    Returns None for a degenerate triangle, which has no plane and also covers
    no pixels, so the caller never gets that far.
    """
    (x0, y0), (x1, y1), (x2, y2) = P
    v0, v1, v2 = vals
    det = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
    if det == 0:
        return None
    return (((v1 - v0) * (y2 - y0) - (v2 - v0) * (y1 - y0)) / det,
            ((v2 - v0) * (x1 - x0) - (v1 - v0) * (x2 - x0)) / det)


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


def addr32p(pagebase, bw, x, y):
    """Word address of pixel (x, y), from a base given in *pages*.

    The two register fields that point at a buffer do not agree on units --
    BITBLTBUF's DBP counts 256-byte blocks and FRAME's FBP counts 8 KB pages --
    so the conversion belongs at the two call sites rather than inside here,
    where a single "bp" argument would silently mean different things.
    """
    page = pagebase + (y >> 5) * bw + (x >> 6)
    return (page * PAGE_WORDS
            + block32((y >> 3) & 3, (x >> 3) & 7) * BLOCK_WORDS
            + column32(y & 7, x & 7))


def addr32(bp, bw, x, y):
    """The same, from a BITBLTBUF-style pointer in 256-byte blocks."""
    return addr32p(bp >> 5, bw, x, y)


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
        self.vq = []              # vertices queued for the current primitive
        self.pixels = 0           # drawn, so a silently-empty test is visible

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
        elif addr == 0x00:                    # PRIM restarts the vertex queue
            self.vq = []
        elif addr in (0x04, 0x05):            # XYZF2 / XYZ2: queue and draw
            self.vertex(data, kick=True)
        elif addr in (0x0C, 0x0D):            # XYZF3 / XYZ3: queue only
            self.vertex(data, kick=False)

    # -- the pixel back end --------------------------------------------------
    def blend(self, src, dst, ctx):
        """One pixel through the alpha blender, if PRIM.ABE says so.

        Cv = ((A - B) * C >> 7) + D, per component, where A, B and D each select
        the source colour, the destination colour or zero, and C selects the
        source alpha, the destination alpha or a fixed value.  The subtraction
        is signed and the product can leave the byte range in both directions,
        so COLCLAMP decides between clamping and wrapping -- and wrapping is not
        a degenerate case to skip: content uses it deliberately for effects that
        rely on the overflow.

        Only RGB is blended.  The alpha written is the source's, which is why
        the blender cannot simply be run over four components.
        """
        if bits(self.reg[0x00], 6, 6) == 0:          # PRIM.ABE
            return src
        al = self.reg[0x42 + ctx]
        sel_a, sel_b, sel_c, sel_d = (bits(al, 1, 0), bits(al, 3, 2),
                                      bits(al, 5, 4), bits(al, 7, 6))
        fix = bits(al, 39, 32)
        clamp = bits(self.reg[0x46], 0, 0)

        def comp(v, n):
            return (v >> (8 * n)) & 0xFF

        if   sel_c == 0: c = comp(src, 3)
        elif sel_c == 1: c = comp(dst, 3)
        else:            c = fix

        out = 0
        for n in range(3):
            def pick(sel):
                if sel == 0: return comp(src, n)
                if sel == 1: return comp(dst, n)
                return 0
            v = (((pick(sel_a) - pick(sel_b)) * c) >> 7) + pick(sel_d)
            if clamp:
                v = 0 if v < 0 else (255 if v > 255 else v)
            else:
                v &= 0xFF
            out |= v << (8 * n)
        return out | (comp(src, 3) << 24)            # alpha comes from the source

    # -- primitives ---------------------------------------------------------
    def ctx(self):
        """0 or 1: which of the two register contexts this primitive uses."""
        return bits(self.reg[0x00], 9, 9)

    def vertex(self, data, kick):
        # X and Y are 12.4 fixed point; the fraction is dropped here because
        # a sprite has no interpolation to need it.  A triangle will.
        self.vq.append((bits(data, 15, 0), bits(data, 31, 16), bits(data, 63, 32),
                        self.reg[0x01]))
        if not kick:
            return
        prim = bits(self.reg[0x00], 2, 0)
        if prim == 6 and len(self.vq) >= 2:            # SPRITE
            self.draw_sprite(self.vq[-2], self.vq[-1])
            self.vq = []
        elif prim in (3, 4, 5) and len(self.vq) >= 3:  # TRIANGLE / STRIP / FAN
            self.draw_triangle(self.vq[-3], self.vq[-2], self.vq[-1])
            if prim == 3:
                self.vq = []              # a list restarts every three vertices
            elif prim == 4:
                self.vq = self.vq[-2:]    # a strip keeps the last two
            else:
                self.vq = [self.vq[0], self.vq[-1]]   # a fan keeps the first
        elif len(self.vq) > 8:
            self.vq = self.vq[-2:]

    def draw_triangle(self, v0, v1, v2):
        """A flat-shaded triangle in PSMCT32.

        The fill rule matters more than the geometry does.  Which pixels a
        triangle covers along a shared edge is decided by a convention, and
        getting it wrong shows up as seams between adjacent triangles, which is
        the kind of fault that looks like a texture problem for a week.

        **Sample points are at pixel origins, not pixel centres.**  That was
        settled by reading PCSX2's software rasteriser rather than by guessing:
        it takes `ceil` of the scanline bounds and `ceil` of each scanline's x
        span, and evaluates the edges *at* the integer scanline -- so a pixel
        (x, y) is covered when ceil(left) <= x < ceil(right) and
        ceil(top) <= y < ceil(bottom).  A half-open interval on ceil is exactly
        sampling the point (x, y) itself, with the left and top edges inclusive
        and the right and bottom edges exclusive.  The first version of this
        function sampled at (x + 0.5, y + 0.5) and was therefore shifted half a
        pixel against the hardware everywhere -- an error no self-consistency
        test can find, because a shifted rule still tiles perfectly.

        Frame-by-frame comparison against PCSX2 is still the stronger check and
        is still owed; this settles the convention, not every corner of it.

        Flat shading takes the colour of the *last* vertex, which is what the
        manual specifies when IIP is 0.  With PRIM.IIP set the four channels are
        each interpolated across the triangle by the blocked, grid-snapped DDA
        described above -- not by evaluating the plane per pixel, which is both
        what hardware does not do and what an obvious implementation would.

        Z, texture and dither are still later blocks.

        """
        c = self.ctx()
        frame = self.reg[0x4C + c]
        xyoff = self.reg[0x18 + c]
        sciss = self.reg[0x40 + c]
        psm = bits(frame, 29, 24)
        if psm not in (0, 1):
            return
        fbp   = bits(frame, 8, 0)
        fbw   = bits(frame, 21, 16)
        fbmsk = bits(frame, 63, 32)
        if psm == 1:
            fbmsk |= 0xFF000000
        ofx, ofy = bits(xyoff, 15, 0), bits(xyoff, 47, 32)

        # Pixel space, as exact rationals.  The hardware coordinates are 12.4
        # fixed point and the rule below is stated in terms of ceil, so doing
        # the arithmetic in floating point would put the answer at the mercy of
        # rounding in exactly the cases the rule exists to settle.
        P = [(Fraction(v[0] - ofx, 16), Fraction(v[1] - ofy, 16))
             for v in (v0, v1, v2)]
        ys = [q[1] for q in P]
        if min(ys) == max(ys):
            return                      # zero height: no scanline can be inside

        sx0, sx1 = bits(sciss, 10, 0), bits(sciss, 26, 16)
        sy0, sy1 = bits(sciss, 42, 32), bits(sciss, 58, 48)
        ytop = max(_ceil(min(ys)), sy0)
        ybot = min(_ceil(max(ys)) - 1, sy1)
        rgba = v2[3] & 0xFFFFFFFF

        # Gouraud: one plane per channel.  The gradients are computed once for
        # the whole triangle and the per-scanline seed is the plane evaluated at
        # the span's first pixel; only the walk along x is blocked and snapped,
        # which is where the measurements put the departure from exactness.
        iip = bits(self.reg[0x00], 3, 3)
        grad = None
        if iip:
            chan = [[(v[3] >> (8 * n)) & 0xFF for v in (v0, v1, v2)]
                    for n in range(4)]
            grad = [_plane(P, [Fraction(c) for c in ch]) for ch in chan]
            if any(g is None for g in grad):
                return                  # degenerate: no plane, and no coverage

        for yy in range(ytop, ybot + 1):
            y = Fraction(yy)
            # An edge spans this scanline on a half-open interval, so a vertex
            # belongs to exactly one of the two edges meeting there and the
            # count below is always zero or two.
            xs = []
            for a, b in ((P[0], P[1]), (P[1], P[2]), (P[0], P[2])):
                lo, hi = (a, b) if a[1] < b[1] else (b, a)
                if lo[1] <= y < hi[1]:
                    xs.append(lo[0] + (hi[0] - lo[0]) * (y - lo[1])
                              / (hi[1] - lo[1]))
            if len(xs) < 2:
                continue
            left  = max(_ceil(min(xs)), sx0)
            right = min(_ceil(max(xs)) - 1, sx1)
            walk = None
            if iip:
                walk = []
                for n in range(4):
                    dvdx, dvdy = grad[n]
                    base = Fraction(chan[n][0])
                    seed = (base + dvdx * (Fraction(left) - P[0][0])
                                 + dvdy * (y - P[0][1]))
                    walk.append(_Walk(seed, dvdx))

            for xx in range(left, right + 1):
                a = addr32p(fbp, fbw, xx, yy)
                if a >= VM_WORDS:
                    continue
                if iip:
                    src = 0
                    for n in range(4):
                        q = _floor(walk[n].at(xx - left))
                        src |= (0 if q < 0 else (255 if q > 255 else q)) << (8 * n)
                else:
                    src = rgba
                old = int.from_bytes(self.vm[a * 4:a * 4 + 4], "little")
                px = self.blend(src, old, c)
                v = (old & fbmsk) | (px & ~fbmsk & 0xFFFFFFFF)
                self.vm[a * 4:a * 4 + 4] = v.to_bytes(4, "little")
                self.pixels += 1

    def draw_sprite(self, v0, v1):
        """A flat-coloured, axis-aligned rectangle in PSMCT32.

        No Z test, no alpha blending, no texture and no dither: those are later
        blocks, and drawing them wrong now would be worse than not drawing them.
        The colour is the one attached to the *second* vertex, which is what the
        manual specifies for a sprite.
        """
        c = self.ctx()
        frame  = self.reg[0x4C + c]
        xyoff  = self.reg[0x18 + c]
        sciss  = self.reg[0x40 + c]
        psm = bits(frame, 29, 24)
        if psm not in (0, 1):                      # PSMCT32 and PSMCT24
            return
        fbp  = bits(frame, 8, 0)                   # in 8 KB pages
        fbw  = bits(frame, 21, 16)                 # in 64-pixel units
        fbmsk = bits(frame, 63, 32)
        if psm == 1:
            # PSMCT24 is 24 bits inside a 32-bit word, addressed exactly as
            # PSMCT32 is.  The top byte is not part of the pixel, so it survives
            # the write -- which is the same thing FBMSK does, and is therefore
            # expressed as one.
            fbmsk |= 0xFF000000
        ofx, ofy = bits(xyoff, 15, 0), bits(xyoff, 47, 32)

        x0 = (v0[0] - ofx) >> 4
        y0 = (v0[1] - ofy) >> 4
        x1 = (v1[0] - ofx) >> 4
        y1 = (v1[1] - ofy) >> 4
        if x0 > x1: x0, x1 = x1, x0
        if y0 > y1: y0, y1 = y1, y0

        # the scissor bounds are inclusive
        sx0, sx1 = bits(sciss, 10, 0), bits(sciss, 26, 16)
        sy0, sy1 = bits(sciss, 42, 32), bits(sciss, 58, 48)
        x0, y0 = max(x0, sx0), max(y0, sy0)
        x1, y1 = min(x1 - 1, sx1), min(y1 - 1, sy1)

        rgba = v1[3] & 0xFFFFFFFF
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                a = addr32p(fbp, fbw, x, y)
                if a >= VM_WORDS:
                    continue
                old = int.from_bytes(self.vm[a * 4:a * 4 + 4], "little")
                px = self.blend(rgba, old, c)
                v = (old & fbmsk) | (px & ~fbmsk & 0xFFFFFFFF)
                self.vm[a * 4:a * 4 + 4] = v.to_bytes(4, "little")
                self.pixels += 1

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
    # A checksum over the *whole* of local memory, because a dump window is a
    # test that only looks where it was told to.  A large primitive draws mostly
    # outside any window worth printing, so "the framebuffer matches" and "one
    # side drew twenty times as many pixels" were both true at once -- which is
    # a hole in the comparison, not a subtlety of the hardware.
    h = 0x811C9DC5
    for b in gs.vm:
        h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF
    print("VMSUM %08x" % h)
    if gs.unknown:
        print("# unknown register writes: %d" % gs.unknown)
    print("# pixels drawn: %d" % gs.pixels)


if __name__ == "__main__":
    main()
