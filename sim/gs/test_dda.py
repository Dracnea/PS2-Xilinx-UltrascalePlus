#!/usr/bin/env python3
"""Prove the integer DDA the RTL will use matches the reference exactly.

    sim/gs/test_dda.py [--n 2000] [--seed 1]

sim/gs/gs_ref.py computes each scanline's span with exact rational arithmetic,
which is the right shape for a specification and the wrong shape for hardware:
it divides once per scanline per edge, in unbounded precision.  Hardware divides
once per *edge* and steps.

Those are the same answer only if the stepping is done exactly, and "only if" is
the whole problem -- a DDA that accumulates in fixed point with the wrong
rounding is right in the middle of an edge and wrong at its ends, which is
precisely where a fill rule matters.  So the formulation is checked here, on
random triangles, before any of it is committed to RTL.  Finding this out from a
Python diff costs minutes; finding it out from a waveform costs a day.

The derivation, in pixel space with y an integer scanline:

    x(y) = [ x0*dy + dx*(16*y - y0) ] / (16*dy)          (all terms integers)

so with num stepping by 16*dx each scanline and den = 16*dy held constant, the
span edge is ceil(num/den).  Dividing once at setup to get the per-scanline
quotient and remainder steps turns that into an add and at most one correction
per scanline, which is what the RTL will do.
"""
import argparse, random, sys, os
from fractions import Fraction

sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
from gs_ref import _ceil


def exact_edge_x(x0, y0, x1, y1, yy):
    """The reference's arithmetic: an exact rational, ceil'd."""
    X0, Y0 = Fraction(x0, 16), Fraction(y0, 16)
    X1, Y1 = Fraction(x1, 16), Fraction(y1, 16)
    return _ceil(X0 + (X1 - X0) * (Fraction(yy) - Y0) / (Y1 - Y0))


def dda_edge_xs(x0, y0, x1, y1, ytop, ybot):
    """The hardware's arithmetic: integers only, one division at setup."""
    dx, dy = x1 - x0, y1 - y0
    den = 16 * dy                      # positive: the caller orders the edge
    # num at the first scanline
    num = x0 * dy + dx * (16 * ytop - y0)
    # ceil(num/den) split into quotient and remainder, with 0 <= r < den
    q = num // den
    r = num - q * den
    step = 16 * dx
    qstep = step // den
    rstep = step - qstep * den         # 0 <= rstep < den
    out = []
    for _ in range(ytop, ybot + 1):
        out.append(q + (1 if r > 0 else 0))     # ceil from floor plus remainder
        q += qstep
        r += rstep
        if r >= den:                   # at most one correction, since rstep < den
            q += 1
            r -= den
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--n", type=int, default=2000)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    rng = random.Random(a.seed)

    checked = skipped = 0
    for _ in range(a.n):
        # 12.4 fixed point, including sub-pixel positions on purpose: an edge
        # that only ever lands on pixel boundaries never exercises the rounding
        x0, y0 = rng.randrange(0, 640 * 16), rng.randrange(0, 448 * 16)
        x1, y1 = rng.randrange(0, 640 * 16), rng.randrange(0, 448 * 16)
        if y0 == y1:
            skipped += 1
            continue
        if y0 > y1:
            x0, y0, x1, y1 = x1, y1, x0, y0
        ytop = _ceil(Fraction(y0, 16))
        ybot = _ceil(Fraction(y1, 16)) - 1
        if ybot < ytop:
            skipped += 1
            continue
        want = [exact_edge_x(x0, y0, x1, y1, yy) for yy in range(ytop, ybot + 1)]
        got = dda_edge_xs(x0, y0, x1, y1, ytop, ybot)
        if got != want:
            for i, (g, w) in enumerate(zip(got, want)):
                if g != w:
                    print("FAIL  edge (%d,%d)-(%d,%d) at scanline %d: "
                          "DDA %d, exact %d" % (x0, y0, x1, y1, ytop + i, g, w))
                    return 1
        checked += len(want)

    print("PASS  %d scanlines over %d edges agree exactly (%d degenerate skipped)"
          % (checked, a.n - skipped, skipped))
    return 0


if __name__ == "__main__":
    sys.exit(main())
