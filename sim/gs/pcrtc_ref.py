#!/usr/bin/env python3
"""The PCRTC's read circuit, in Python -- the reference the RTL is diffed against.

The Graphics Synthesizer's video block, PCRTC, is the half of the chip that
never touches the drawing pipeline: it walks a raster, reads the frame buffer
that DISPFB points at, and hands out a pixel per video clock.  Nothing it does
is arithmetic on colours except the merge; the work is addressing.

## What is here and what is not

This models the **read circuit** -- everything from a raster position to a
colour -- and the **merge** that combines the two read circuits.  It does not
model the sync generator.  That is deliberate, and the reason is worth stating
plainly rather than leaving as an omission:

* The read circuit's registers (DISPFB and DISPLAY) use field layouts that this
  repository has already verified from the drawing side.  DISPFB's FBP counts
  8 KB pages and FBW counts 64-pixel units, exactly as FRAME's do, and its PSM
  takes the same format codes -- all three are checked every time the rasteriser
  is diffed.  Building on them is building on tested ground.

* The sync generator's registers -- SMODE1, SMODE2, SYNCH1, SYNCH2, SYNCV --
  are a PLL and a pile of counter reload values whose field positions this
  project has no verified source for.  Writing them from memory would produce
  code that looks finished and is unfalsifiable until a console is attached.
  So the raster's totals are taken as explicit parameters here, and reading the
  real values off a console is a probe entry, not a guess.  See
  `hw/ps2probe/README.md`.

What that costs is real: a PCRTC that cannot yet be told "NTSC" and work out
its own timings.  What it buys is that every line below is checkable today.

## The merge, and what about it is not yet verified

PMODE selects one or both read circuits and how they combine.  The selection
(EN1, EN2), the background (SLBG, BGCOLOR) and the constant alpha (ALP) are
plain enough.  The **arithmetic** of the blend is the part taken from the
manual's description rather than from measurement, and it is flagged:

    out = c1 + ((c2 - c1) * a) / 128

with `a` the alpha from circuit 1 (MMOD = 0) or ALP (MMOD = 1), and 128 meaning
one.  That is the same fixed point the drawing-side ALPHA register uses, which
is the argument for it; it is not a measurement, and until a console confirms
it, a scene that uses both read circuits at once is not verified.  Scenes that
use one -- which is the ordinary case, including every scene this project has
drawn so far -- do not reach this code at all.
"""

import sys

from gs_ref import addr32p, addr16p, expand16, PAGE_WORDS

M32 = 0xFFFFFFFF


def bits(v, hi, lo):
    return (v >> lo) & ((1 << (hi - lo + 1)) - 1)


class Circuit:
    """One read circuit: a DISPFB and a DISPLAY, decoded.

    The two registers divide the work in a way that is easy to get backwards.
    DISPFB says *where in memory* -- the buffer's page, its width, its format,
    and an offset into it (DBX, DBY).  DISPLAY says *where on screen* -- the
    first video clock and raster line the area occupies (DX, DY), how big it is
    (DW, DH), and how many video clocks and lines each source pixel is stretched
    over (MAGH, MAGV).  So DW is measured in output clocks and the source
    rectangle is DW/(MAGH+1) wide; reading DW as a source width would give a
    picture that is right only at magnification one.
    """

    def __init__(self, dispfb=0, display=0, enabled=False):
        self.enabled = enabled
        self.fbp = bits(dispfb, 8, 0)             # in 8 KB pages
        self.fbw = bits(dispfb, 14, 9)            # in 64-pixel units
        self.psm = bits(dispfb, 19, 15)
        self.dbx = bits(dispfb, 42, 32)
        self.dby = bits(dispfb, 53, 43)
        self.dx = bits(display, 11, 0)
        self.dy = bits(display, 22, 12)
        self.magh = bits(display, 26, 23) + 1
        self.magv = bits(display, 28, 27) + 1
        # DW and DH are stored as "minus one", so the area is never zero-sized.
        self.dw = bits(display, 43, 32) + 1
        self.dh = bits(display, 54, 44) + 1

    def covers(self, hx, vy):
        return (self.enabled
                and self.dx <= hx < self.dx + self.dw
                and self.dy <= vy < self.dy + self.dh)

    def fetch(self, mem, hx, vy):
        """The RGBA at raster position (hx, vy), or None outside the area.

        Magnification is a divide, and it is a divide of the *offset into the
        area*, not of the raster position: a display area that does not start at
        zero would otherwise sample from the wrong place by DX/MAGH pixels.
        """
        if not self.covers(hx, vy):
            return None
        sx = self.dbx + (hx - self.dx) // self.magh
        sy = self.dby + (vy - self.dy) // self.magv
        if self.psm in (0x00, 0x01):              # PSMCT32, PSMCT24
            w = mem[addr32p(self.fbp, self.fbw, sx, sy)] & M32
            # PSMCT24 is the same memory with the alpha byte not read back; the
            # manual gives the unread byte as zero rather than as whatever the
            # rasteriser last left there.
            return w if self.psm == 0x00 else w & 0x00FFFFFF
        if self.psm in (0x02, 0x0A):              # PSMCT16, PSMCT16S
            a, half = addr16p(self.fbp, self.fbw, sx, sy, sform=(self.psm == 0x0A))
            return expand16((mem[a] >> (16 * half)) & 0xFFFF)
        raise ValueError("PCRTC cannot read PSM 0x%02X" % self.psm)


class PCRTC:
    """The privileged registers this block reads, and the raster it walks.

    `htotal` and `vtotal` are the video clocks per line and lines per frame.
    On hardware they come out of SYNCH1/SYNCH2/SYNCV; here they are given,
    for the reason in the module docstring.
    """

    def __init__(self, htotal, vtotal):
        self.htotal = htotal
        self.vtotal = vtotal
        self.pmode = 0
        self.dispfb = [0, 0]
        self.display = [0, 0]
        self.bgcolor = 0

    def write(self, addr, value):
        """A privileged-register write, by its offset from 0x12000000."""
        if addr == 0x00: self.pmode = value
        elif addr == 0x70: self.dispfb[0] = value
        elif addr == 0x80: self.display[0] = value
        elif addr == 0x90: self.dispfb[1] = value
        elif addr == 0xA0: self.display[1] = value
        elif addr == 0xE0: self.bgcolor = value
        else: raise ValueError("PCRTC has no register at 0x%02X" % addr)

    def circuits(self):
        return (Circuit(self.dispfb[0], self.display[0], bits(self.pmode, 0, 0) == 1),
                Circuit(self.dispfb[1], self.display[1], bits(self.pmode, 1, 1) == 1))

    def pixel(self, mem, hx, vy):
        """One output pixel, as 0xBBGGRR.

        The output is 24 bits: PCRTC drives a display and a display has no
        alpha.  Alpha still matters on the way here, because it is what the
        merge blends with when MMOD says to use circuit 1's.
        """
        c1, c2 = self.circuits()
        mmod = bits(self.pmode, 5, 5)
        slbg = bits(self.pmode, 7, 7)
        alp = bits(self.pmode, 15, 8)

        p1 = c1.fetch(mem, hx, vy)
        p2 = c2.fetch(mem, hx, vy)

        # Background where nothing is displayed.  BGCOLOR is 0xBBGGRR and the
        # frame buffer is 0xAABBGGRR, so the two agree in their low 24 bits and
        # nothing needs reordering.
        bg = self.bgcolor & 0xFFFFFF

        # One circuit on, which is the ordinary case: it is output as it is.
        if p1 is not None and p2 is None:
            return p1 & 0xFFFFFF
        if p2 is not None and p1 is None:
            # SLBG puts the background under circuit 2 even when circuit 1 is
            # not covering this pixel, which is what makes a small circuit 2
            # over a coloured field work.
            if slbg:
                a = alp if mmod else 0x80
                return _blend(bg, p2 & 0xFFFFFF, a)
            return p2 & 0xFFFFFF
        if p1 is None and p2 is None:
            return bg

        # Both: circuit 2 over circuit 1 -- or over the background if SLBG.
        under = bg if slbg else (p1 & 0xFFFFFF)
        a = alp if mmod else ((p1 >> 24) & 0xFF)
        return _blend(under, p2 & 0xFFFFFF, a)

    def frame(self, mem):
        """The whole raster, as a list of rows of 0xBBGGRR."""
        return [[self.pixel(mem, x, y) for x in range(self.htotal)]
                for y in range(self.vtotal)]


def _blend(under, over, a):
    """out = under + (over - under) * a / 128, per channel, clamped.

    UNVERIFIED -- see the module docstring.  The shape is the drawing side's
    ALPHA arithmetic, where 0x80 is one and values above it overshoot, and the
    clamp is what keeps an ALP above 0x80 from wrapping a channel round.
    """
    out = 0
    for sh in (0, 8, 16):
        u = (under >> sh) & 0xFF
        o = (over >> sh) & 0xFF
        v = u + ((o - u) * a) // 128
        v = 0 if v < 0 else (255 if v > 255 else v)
        out |= v << sh
    return out


if __name__ == "__main__":
    print(__doc__)
