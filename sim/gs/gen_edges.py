#!/usr/bin/env python3
"""Generate random triangle edges and the ceil(x) the reference gives for each.

    sim/gs/gen_edges.py --seed 1 --n 60 --out edges.txt   > expected.txt

The edges deliberately include sub-pixel endpoints: an edge that only ever lands
on pixel boundaries never exercises the rounding, and rounding is the whole
difficulty -- a DDA that accumulates wrongly is right in the middle of an edge
and wrong at its ends.
"""
import argparse, random, sys, os
from fractions import Fraction

sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
from gs_ref import _ceil


def exact_x(x0, y0, x1, y1, yy):
    X0, Y0 = Fraction(x0, 16), Fraction(y0, 16)
    X1, Y1 = Fraction(x1, 16), Fraction(y1, 16)
    return _ceil(X0 + (X1 - X0) * (Fraction(yy) - Y0) / (Y1 - Y0))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--n", type=int, default=60)
    ap.add_argument("--out", default="edges.txt")
    ap.add_argument("--maxscan", type=int, default=24)
    a = ap.parse_args()
    rng = random.Random(a.seed)

    edges = []
    while len(edges) < a.n:
        x0, y0 = rng.randrange(0, 640 * 16), rng.randrange(0, 400 * 16)
        x1, y1 = rng.randrange(0, 640 * 16), rng.randrange(0, 400 * 16)
        if y0 == y1:
            continue
        if y0 > y1:
            x0, y0, x1, y1 = x1, y1, x0, y0
        ytop = _ceil(Fraction(y0, 16))
        ybot = _ceil(Fraction(y1, 16)) - 1
        if ybot < ytop:
            continue
        ns = min(ybot - ytop + 1, a.maxscan)
        edges.append((x0, y0, x1, y1, ytop, ns))

    with open(a.out, "w") as fh:
        for e in edges:
            fh.write("%d %d %d %d %d %d\n" % e)
    for i, (x0, y0, x1, y1, ytop, ns) in enumerate(edges):
        for k in range(ns):
            print("E %d %d %d" % (i, k, exact_x(x0, y0, x1, y1, ytop + k)))


if __name__ == "__main__":
    main()
