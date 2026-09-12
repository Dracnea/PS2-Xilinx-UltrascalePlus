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
_HALF = Fraction(1, 2 * _GRID)      # half a grid step: the depth bias


def _zbias(k, dzdy):
    """How far interpolated depth runs short of its own plane.

    This is the least-verified rule in this file and the first thing to ask a
    real console.  What the probes found is that depth -- and only depth, not
    colour -- lands half a grid step below the plane, and that the two axes
    carry the shortfall differently: along x it is there from the span's first
    pixel and does not follow the gradient's sign, while along y it accumulates
    one half-step per scanline, follows the sign of dz/dy, and is exempt on the
    primitive's first scanline.  A flat triangle is exact in 896 of 896
    readings, which is what puts the bias in the walk rather than in the seed.

    Everything above is a fact about somebody else's measurements, restated.
    hw/ps2probe exists to turn it into a fact about a console on this desk; if
    it ever disagrees, this function is the only place that has to change.
    """
    b = -_HALF                              # the x term: always, always down
    if k > 0 and dzdy != 0:
        b -= _HALF * k * (1 if dzdy > 0 else -1)
    return b


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

    def __init__(self, seed, dvdx, bias=0):
        # The bias is added *after* the snap, because it is half a grid step:
        # snapping first would round it straight back out of existence, which
        # is the whole reason it took purpose-built probes to see at all.
        self.seed = _grid(seed) + bias
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


# The Z formats use the *same* block table as their colour counterparts with
# the block address exclusive-ored by 24.  This is not a detail: it is the
# difference between a depth buffer that lands where silicon puts it and one
# that is permuted in blocks of 8x8 pixels.  Both the GS User's Manual (8.3.1,
# 8.3.2 -- the PSMZ32 and PSMZ16 figures are their colour figures with every
# entry xor 24) and PCSX2 say so, the latter as `swizzle32Z {swizzleTables32,
# 0x18}` against `swizzle32 {swizzleTables32, 0x00}`.
#
# PCSX2 applies the xor to the *final* block number rather than to the index
# within the page.  The two agree here because ZBUF's ZBP counts pages, so the
# base is always a multiple of 32 blocks and the xor cannot carry into it.
BLK_Z = 24


def addr32p(pagebase, bw, x, y, blkxor=0):
    """Word address of pixel (x, y), from a base given in *pages*.

    The two register fields that point at a buffer do not agree on units --
    BITBLTBUF's DBP counts 256-byte blocks and FRAME's FBP counts 8 KB pages --
    so the conversion belongs at the two call sites rather than inside here,
    where a single "bp" argument would silently mean different things.

    `blkxor` is BLK_Z for the depth formats and 0 for the colour ones.
    """
    page = pagebase + (y >> 5) * bw + (x >> 6)
    return (page * PAGE_WORDS
            + (block32((y >> 3) & 3, (x >> 3) & 7) ^ blkxor) * BLOCK_WORDS
            + column32(y & 7, x & 7))


def addr32(bp, bw, x, y):
    """The same, from a BITBLTBUF-style pointer in 256-byte blocks."""
    return addr32p(bp >> 5, bw, x, y)


# ---- the 16-bit formats ----------------------------------------------------
#
# A 16-bit page is 64 x 64 pixels, a block 16 x 8, a column 16 x 2, and two
# pixels share a 32-bit word.  Three things change from PSMCT32 and one does
# not, which is the part worth stating: **the word within a block is the same
# interleave**, column32(y & 7, x & 7), because a column holds sixteen words
# either way and the extra eight pixels of width go into the *upper half* of
# those same words rather than into more of them.  So the only new arithmetic
# is which block, and which half.
#
# PSMCT16 and PSMCT16S differ only in the order blocks are laid out in a page;
# the manual draws both (8.3.2) and PCSX2 stores both.  The S form exists so
# that a 16-bit buffer and a 32-bit one can share a page boundary usefully.

def block16(by, bx):
    """Block index within a page for PSMCT16/PSMZ16, blocks being 16x8 pixels."""
    return ((by & 1)) | ((bx & 1) << 1) | ((by & 2) << 1) | \
           ((bx & 2) << 2) | ((by & 4) << 2)


def block16s(by, bx):
    """The same for PSMCT16S/PSMZ16S, which permutes the middle bits."""
    return ((by & 1)) | ((bx & 1) << 1) | ((by & 4)) | \
           ((by & 2) << 2) | ((bx & 2) << 3)


def addr16p(pagebase, bw, x, y, sform=False, blkxor=0):
    """(word address, which 16-bit half) of pixel (x, y), base in *pages*.

    The half is returned rather than folded into the address because every
    caller needs both: the word is what local memory is addressed by, and the
    half is which sixteen bits of it the pixel occupies.  A function that
    returned a half-word address would push that split onto every call site.
    """
    page = pagebase + (y >> 6) * bw + (x >> 6)
    blk = (block16s(( y >> 3) & 7, (x >> 4) & 3) if sform
           else block16((y >> 3) & 7, (x >> 4) & 3)) ^ blkxor
    return (page * PAGE_WORDS + blk * BLOCK_WORDS + column32(y & 7, x & 7),
            (x >> 3) & 1)


# ---- the indexed formats, PSMT8 and PSMT4 -----------------------------------
#
# These are the texture formats that store a palette index rather than a colour,
# and their layout looks at first like the one part of the GS that really is a
# table: PCSX2 stores columnTable8 as a literal 16 x 16 array of bytes and
# columnTable4 as 16 x 32, with no evident pattern.
#
# They are not tables.  Both are **linear over GF(2)** -- every output bit is a
# fixed exclusive-or of input bits -- which was established by testing it rather
# than by looking at them: for all 256 and 512 entries,
#
#     v(y, x) == v(y, 0) ^ v(0, x) ^ v(0, 0)
#
# holds, which is exactly the condition for a bit-linear map.  Solving for the
# basis gives the closed forms below.  So, as with the colour formats, this is a
# wire permutation and one exclusive-or gate, not a lookup.
#
# The *block* index is not new at all: PCSX2's _blockTable8 is byte-identical to
# _blockTable32, so an 8-bit page arranges its blocks exactly as a 32-bit page
# does -- only the block is 16 x 16 pixels instead of 8 x 8.  _blockTable4 is
# the same permutation with the roles of x and y exchanged, its blocks being
# 32 x 16.
#
# tools/gs/xcheck_swizzle.py checks all of this against PCSX2's tables
# exhaustively, which is what makes the derivation above a claim that can fail.

def column8(y, x):
    """Byte offset of pixel (x, y) within a PSMT8 column, x < 16, y < 16."""
    y0, y1, y2, y3 = (y >> 0) & 1, (y >> 1) & 1, (y >> 2) & 1, (y >> 3) & 1
    x0, x1, x2, x3 = (x >> 0) & 1, (x >> 1) & 1, (x >> 2) & 1, (x >> 3) & 1
    return (y1 << 0 | x3 << 1 | x0 << 2 | y0 << 3 | x1 << 4
            | (y1 ^ y2 ^ x2) << 5 | y2 << 6 | y3 << 7)


def column4(y, x):
    """Nibble offset of pixel (x, y) within a PSMT4 column, x < 32, y < 16.

    Nine bits, not eight: a 4-bit column is 32 x 16 pixels and so holds 512
    nibbles.  The first version of this stopped at bit 7 because the basis was
    extracted over a byte, and it was right for the top half of every column and
    wrong by exactly 256 for the bottom -- which the cross-check caught on its
    first run.
    """
    y0, y1, y2, y3 = ((y >> b) & 1 for b in range(4))
    x0, x1, x2, x3, x4 = ((x >> b) & 1 for b in range(5))
    return (y1 << 0 | x3 << 1 | x4 << 2 | x0 << 3 | y0 << 4 | x1 << 5
            | (y1 ^ y2 ^ x2) << 6 | y2 << 7 | y3 << 8)


def block8(by, bx):
    """PSMT8 blocks are laid out in a page exactly as PSMCT32's are."""
    return block32(by, bx)


def block4(by, bx):
    """PSMT4's block order is PSMCT32's with x and y exchanged."""
    return block32(bx, by)


# ---- RGBA16 -----------------------------------------------------------------
#
# The 16-bit pixel is A1 B5 G5 R5, alpha in bit 15 and red in bits 4:0, and the
# two conversions are not inverses of each other.  Both are taken from the
# manual rather than assumed, because the obvious guess is wrong in the same
# direction each time.
#
#   * Writing **truncates**: the diagram in 3.9.5 lines the frame buffer's five
#     bits up against bits 7:3 of the 8-bit channel, so the low three are
#     dropped.  (Dither is what is meant to make that acceptable, and dither is
#     a later block.)
#   * Reading **shifts up with zeros**, not by replicating the top bits: the
#     manual draws the 5-to-8 expansion explicitly as `E D C B A 0 0 0`.  The
#     replicating form -- which spreads the value over the full 0..255 range and
#     is what a graphics programmer reaches for -- is a different function, and
#     white would come back as 0xFF from it and 0xF8 from this one.
#   * Alpha read back from a 16-bit buffer is **0x80 or 0x00**, never 0xFF.

def pack16(rgba):
    """RGBA8888 -> RGBA5551, as the GS writes it."""
    return (((rgba >> 3) & 0x1F)
            | (((rgba >> 11) & 0x1F) << 5)
            | (((rgba >> 19) & 0x1F) << 10)
            | (((rgba >> 31) & 0x01) << 15))


def expand16(px):
    """RGBA5551 -> RGBA8888, as the GS expands it for processing."""
    return (((px & 0x1F) << 3)
            | ((((px >> 5) & 0x1F) << 3) << 8)
            | ((((px >> 10) & 0x1F) << 3) << 16)
            | ((0x80 if (px >> 15) & 1 else 0x00) << 24))


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

    # -- the depth test ------------------------------------------------------
    def zsetup(self, ctx):
        """Everything the depth test needs, or None when it is not in play.

        The manual is unambiguous about the corner cases and they are worth
        honouring exactly.  ZTE = 0 is "prohibited since it may cause a
        malfunction", so it is not a documented mode and nothing here pretends
        to model one.  The *supported* way to draw without a depth test is ZTE=1
        with ZTST=ALWAYS and ZMSK=1, which the manual says leaves the Z buffer
        "neither accessed nor updated" -- so that combination returns None and
        the buffer is not even addressed, rather than being read and discarded.

        The Z buffer has no width of its own: the manual states it is the same
        size as the frame buffer, so FBW is what addresses it.
        """
        test = self.reg[0x47 + ctx]
        zbuf = self.reg[0x4E + ctx]
        if bits(test, 16, 16) == 0:                 # ZTE: prohibited, so off
            return None
        ztst = bits(test, 18, 17)
        zmsk = bits(zbuf, 32, 32)
        if ztst == 1 and zmsk == 1:                 # ALWAYS + masked: no access
            return None
        zpsm = bits(zbuf, 27, 24)
        if zpsm not in (0, 1, 2, 10):   # PSMZ32, PSMZ24, PSMZ16, PSMZ16S
            return None
        return {"zbp":  bits(zbuf, 8, 0),
                "fbw":  bits(self.reg[0x4C + ctx], 21, 16),
                "ztst": ztst,
                "zmsk": zmsk,
                "bits":  16 if zpsm in (2, 10) else 32,
                "sform": zpsm == 10,
                # The widest value the format can hold.  It is both the field
                # mask and the value an out-of-range depth **clamps** to -- see
                # zcheck.  PSMZ24 is 24 bits inside a 32-bit word, addressed
                # exactly as PSMZ32 is, and its top byte is neither compared nor
                # written.
                "zmax": {0: 0xFFFFFFFF, 1: 0x00FFFFFF,
                         2: 0x0000FFFF, 10: 0x0000FFFF}[zpsm]}

    def fbsetup(self, c):
        """What the FRAME register says about the frame buffer, or None if this
        model cannot draw to it.

        Collecting this in one place is what lets the sprite and the triangle
        share a pixel write.  They had the same dozen lines twice, and the
        16-bit formats would have made it the same thirty lines twice.
        """
        frame = self.reg[0x4C + c]
        psm = bits(frame, 29, 24)
        if psm not in (0, 1, 2, 10):    # PSMCT32, PSMCT24, PSMCT16, PSMCT16S
            return None
        fbmsk = bits(frame, 63, 32)
        if psm == 1:
            # PSMCT24 is 24 bits inside a 32-bit word, addressed exactly as
            # PSMCT32 is.  The top byte is not part of the pixel, so it survives
            # the write -- which is the same thing FBMSK does, and is therefore
            # expressed as one.
            fbmsk |= 0xFF000000
        return {"bits":  16 if psm in (2, 10) else 32,
                "sform": psm == 10,
                "fbp":   bits(frame, 8, 0),      # in 8 KB pages
                "fbw":   bits(frame, 21, 16),    # in 64-pixel units
                "fbmsk": fbmsk}

    def fbaddr(self, fb, x, y):
        """(word, half) for a pixel, or None if it falls outside local memory.

        Kept separate from the write because the caller has to know a pixel is
        addressable *before* the depth test runs: a pixel that is off the end of
        memory must not update the Z buffer either, and folding the bounds check
        into the write would silently reverse that order.
        """
        if fb["bits"] == 32:
            a, half = addr32p(fb["fbp"], fb["fbw"], x, y), 0
        else:
            a, half = addr16p(fb["fbp"], fb["fbw"], x, y, fb["sform"])
        return None if a >= VM_WORDS else (a, half)

    def putpixel(self, fb, loc, src, c):
        """Blend one pixel against what is there and write it back under FBMSK."""
        a, half = loc
        word = int.from_bytes(self.vm[a * 4:a * 4 + 4], "little")
        if fb["bits"] == 32:
            m = fb["fbmsk"]
            px = self.blend(src, word, c)
            word = (word & m) | (px & ~m & 0xFFFFFFFF)
        else:
            # The destination is read back *expanded*, because the blender works
            # in 8 bits per channel whatever the buffer holds -- and because a
            # 16-bit buffer's alpha is 0x80 or 0x00 rather than the 0 or 255 a
            # one-bit value would suggest.
            old16 = (word >> (16 * half)) & 0xFFFF
            px = self.blend(src, expand16(old16), c)
            # FBMSK's bit positions are those of the pixel *before* format
            # conversion (3.9.5), and the bits that survive that conversion are
            # exactly the ones pack16 keeps.  So the mask converts with the same
            # function the colour does, rather than needing one of its own.
            m16 = pack16(fb["fbmsk"])
            new16 = (old16 & m16) | (pack16(px) & ~m16 & 0xFFFF)
            word = (word & ~(0xFFFF << (16 * half))) | (new16 << (16 * half))
        self.vm[a * 4:a * 4 + 4] = word.to_bytes(4, "little")
        self.pixels += 1

    def zcheck(self, zs, x, y, z):
        """The depth test at one pixel, and the Z write that goes with it.

        Returns whether the pixel survives.  The Z buffer is updated here rather
        than by the caller because a pixel that passes updates Z even when the
        frame buffer write is entirely masked out -- the two masks are
        independent, and treating the Z write as a consequence of the colour
        write is a bug waiting for the first FBMSK that matters.
        """
        if zs is None:
            return True
        if zs["ztst"] == 0:                         # NEVER: nothing survives
            return False
        if zs["bits"] == 32:
            a, half = addr32p(zs["zbp"], zs["fbw"], x, y, BLK_Z), 0
        else:
            a, half = addr16p(zs["zbp"], zs["fbw"], x, y, zs["sform"], BLK_Z)
        if a >= VM_WORDS:
            return False
        m = zs["zmax"]

        # A depth wider than the buffer format **clamps**; it does not wrap.
        # This model masked it until 2026-09-11, which is the same thing for
        # every value that fits and the opposite for every value that does not:
        # a Z of 0x01000000 against PSMZ24 compares as 0 after a mask and as
        # 0xFFFFFF after a clamp, so a GREATER test flips from failing
        # everything to passing everything.
        #
        # It could not be seen before because the generator's deepest vertex was
        # 24 bits and the only narrow format was PSMZ24, so masking and clamping
        # agreed on every value ever generated.  PSMZ16 makes it central rather
        # than latent: nearly every Z a vertex carries exceeds 16 bits.
        #
        # > **NOTE (unverified):** clamping is taken from PCSX2, which does it
        # > twice over -- `min_u32(z_max)` on the vertex and `zclamp` in the
        # > scanline -- and gates the second on whether the primitive's maximum
        # > Z exceeds the format, which is the shape of something modelled from
        # > hardware rather than a convenience.  The GS User's Manual gives the
        # > three Z formats (2.3.2) and never says what happens to a value too
        # > wide for one.  *Verify by:* hw/ps2probe asks the console directly.
        zc = m if z > m else z

        if zs["ztst"] == 1:                         # ALWAYS: no read needed
            ok = True
        else:
            word = int.from_bytes(self.vm[a * 4:a * 4 + 4], "little")
            old = (word >> (16 * half)) & m if zs["bits"] == 16 else word & m
            ok = zc >= old if zs["ztst"] == 2 else zc > old
        if ok and zs["zmsk"] == 0:
            word = int.from_bytes(self.vm[a * 4:a * 4 + 4], "little")
            if zs["bits"] == 16:
                word = (word & ~(0xFFFF << (16 * half))) | (zc << (16 * half))
            else:
                word = (word & ~m & 0xFFFFFFFF) | zc
            self.vm[a * 4:a * 4 + 4] = word.to_bytes(4, "little")
        return ok

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
        xyoff = self.reg[0x18 + c]
        sciss = self.reg[0x40 + c]
        fb = self.fbsetup(c)
        if fb is None:
            return
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
        # Depth.  A triangle interpolates it on the same blocked, grid-snapped
        # DDA the colour channels use, with the bias above on top.
        zs = self.zsetup(c)
        zgrad = None
        if zs is not None:
            zgrad = _plane(P, [Fraction(v[2] & 0xFFFFFFFF) for v in (v0, v1, v2)])
            if zgrad is None:
                return

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
            zwalk = None
            if zs is not None:
                dzdx, dzdy = zgrad
                zseed = (Fraction(v0[2] & 0xFFFFFFFF)
                         + dzdx * (Fraction(left) - P[0][0])
                         + dzdy * (y - P[0][1]))
                zwalk = _Walk(zseed, dzdx, _zbias(yy - ytop, dzdy))

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
                loc = self.fbaddr(fb, xx, yy)
                if loc is None:
                    continue
                if zwalk is not None:
                    zv = _floor(zwalk.at(xx - left))
                    zv = 0 if zv < 0 else min(zv, 0xFFFFFFFF)
                    if not self.zcheck(zs, xx, yy, zv):
                        continue
                if iip:
                    src = 0
                    for n in range(4):
                        q = _floor(walk[n].at(xx - left))
                        src |= (0 if q < 0 else (255 if q > 255 else q)) << (8 * n)
                else:
                    src = rgba
                self.putpixel(fb, loc, src, c)

    def draw_sprite(self, v0, v1):
        """A flat-coloured, axis-aligned rectangle in PSMCT32.

        The colour is the one attached to the *second* vertex, which is what
        the manual specifies for a sprite -- and so is the depth, which a sprite
        carries as a plain integer and never interpolates.  That agrees with
        what the console probes found: sprites are the one primitive where
        depth has no DDA behind it at all.

        No texture and no dither: those are later blocks.
        """
        c = self.ctx()
        xyoff  = self.reg[0x18 + c]
        sciss  = self.reg[0x40 + c]
        fb = self.fbsetup(c)
        if fb is None:
            return
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
        z    = v1[2] & 0xFFFFFFFF
        zs   = self.zsetup(c)
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                loc = self.fbaddr(fb, x, y)
                if loc is None:
                    continue
                if not self.zcheck(zs, x, y, z):
                    continue
                self.putpixel(fb, loc, rgba, c)

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
