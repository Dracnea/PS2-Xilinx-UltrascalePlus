#!/usr/bin/env python3
"""Diff a console's answer against the reference model.

    ps2client -h <ip> execee host:gsprobe.elf | tee run.txt
    hw/ps2probe/compare.py run.txt

gsprobe.c draws a small number of primitives with attributes chosen so that one
readback answers a question, and prints the buffer a row at a time.  This builds
the *same* primitives as a GIF packet stream, runs them through
sim/gs/gs_ref.py, and prints where the two disagree.

The point is not that the model is checked -- it is that the model is checked
against silicon rather than against itself.  Two rules in this project were
established from reading rather than measuring and one of them turned out to be
systematically wrong, so a disagreement here is expected to be informative
rather than embarrassing.

Keep this file and gsprobe.c in step.  They describe the same primitives twice,
in C and in Python, and there is no mechanism that forces them to agree: if the
probe is changed and this is not, the diff will be of two different pictures and
will look like a hardware discovery.
"""
import os, sys, argparse
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "sim", "gs"))
from gs_ref import GS, addr32p                       # noqa: E402

FB_W, FB_H = 64, 32
ZB_PAGE = 4


def tag(nreg, regs):
    return 1 | (1 << 15) | ((nreg & 15) << 60) | (regs << 64)


def ad(items):
    """A PACKED A+D packet: one GIFtag, then (data, address) quadwords."""
    regs = 0
    for i in range(len(items)):
        regs |= 0xE << (4 * i)
    out = [tag(len(items), regs)]
    for a, d in items:
        out.append((d & ((1 << 64) - 1)) | (a << 64))
    return out


def xyz(x, y, z):
    return ((x << 4) | ((y << 4) << 16) | (z << 32))


def rgbaq(r, g, b, a):
    return r | (g << 8) | (b << 16) | (a << 24)


def stream_gouraud():
    """Mirrors draw_gouraud() in gsprobe.c."""
    return ad([(0x4C, 0 | (FB_W // 64) << 16),
               (0x18, 0),
               (0x40, 0 | ((FB_W - 1) << 16) | (0 << 32) | ((FB_H - 1) << 48)),
               (0x47, (1 << 16) | (1 << 17)),          # ZTE=1, ZTST=ALWAYS
               (0x4E, ZB_PAGE | (1 << 32)),            # ZMSK=1: buffer untouched
               (0x00, 3 | (1 << 3))]) \
         + ad([(0x01, rgbaq(255, 0, 0, 128)), (0x05, xyz(0, 0, 0)),
               (0x01, rgbaq(0, 255, 0, 128)), (0x05, xyz(FB_W - 1, 0, 0)),
               (0x01, rgbaq(0, 0, 255, 128)), (0x05, xyz(0, FB_H - 1, 0))])


def stream_zgrad(along_y):
    """Mirrors draw_zgrad() in gsprobe.c."""
    z0 = 0x00100000
    z1 = z0 + (0 if along_y else 0x2000)
    z2 = z0 + (0x2000 if along_y else 0)
    return ad([(0x4C, 0 | (FB_W // 64) << 16),
               (0x18, 0),
               (0x40, 0 | ((FB_W - 1) << 16) | (0 << 32) | ((FB_H - 1) << 48)),
               (0x47, (1 << 16) | (1 << 17)),
               (0x4E, ZB_PAGE | (0 << 24) | (0 << 32)),   # PSMZ32, ZMSK=0
               (0x00, 3)]) \
         + ad([(0x01, rgbaq(64, 64, 64, 128)),
               (0x05, xyz(0, 0, z0)),
               (0x05, xyz(FB_W - 1, 0, z1)),
               (0x05, xyz(0, FB_H - 1, z2))])


def model(packets, page):
    gs = GS()
    # gif_packet consumes one packet and returns where it stopped, so a stream
    # of several has to be walked; handing it the whole list runs only the
    # first, which presents as a rasteriser that draws nothing.
    at = 0
    while at < len(packets):
        nxt = gs.gif_packet(packets, at)
        if nxt <= at:
            break
        at = nxt
    rows = []
    for y in range(FB_H):
        rows.append([int.from_bytes(
            gs.vm[addr32p(page, FB_W // 64, x, y) * 4:][:4], "little")
            for x in range(FB_W)])
    return rows


def parse(text, marker, rowtag):
    """The rows the console printed for one probe, in order."""
    rows, inside = [], False
    for line in text.splitlines():
        if line.startswith(marker) and not line.endswith("end"):
            inside, rows = True, []
        elif line.startswith(marker) and line.endswith("end"):
            inside = False
        elif inside and line.startswith(rowtag):
            rows.append([int(v, 16) for v in line.split()[2:]])
    return rows


def report(name, want, got):
    if not got:
        print("%-8s console printed nothing -- probe did not run this pass"
              % name)
        return 1
    bad = 0
    for y in range(min(len(want), len(got))):
        for x in range(min(len(want[y]), len(got[y]))):
            if want[y][x] != got[y][x]:
                if bad < 12:
                    print("%-8s (%2d,%2d) model=%08x console=%08x  delta=%d"
                          % (name, x, y, want[y][x], got[y][x],
                             got[y][x] - want[y][x]))
                bad += 1
    if bad:
        print("%-8s %d pixels differ" % (name, bad))
    else:
        print("%-8s identical over %dx%d" % (name, FB_W, FB_H))
    return bad


def pairing(rows):
    """The open question: does silicon read rows k and k+2 identically?

    Nobody has published an answer and no emulator models the vertical structure
    it would imply, so it is worth printing whether or not anything else in the
    run disagrees.
    """
    if len(rows) < 3:
        return
    pairs = sum(1 for k in range(len(rows) - 2) if rows[k] == rows[k + 2])
    print("row pairing: %d of %d rows equal their k+2 neighbour%s"
          % (pairs, len(rows) - 2,
             "  <-- silicon pairs rows" if pairs > (len(rows) - 2) * 3 // 4
             else ""))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("logfile", help="what ps2client printed")
    a = ap.parse_args()
    text = open(a.logfile).read()

    bad = 0
    bad += report("gouraud", model(stream_gouraud(), 0),
                  parse(text, "PROBE gouraud", "ROW"))
    zy = parse(text, "ZPROBE ygrad", "ZROW")
    bad += report("z-ygrad", model(stream_zgrad(True), ZB_PAGE), zy)
    bad += report("z-xgrad", model(stream_zgrad(False), ZB_PAGE),
                  parse(text, "ZPROBE xgrad", "ZROW"))
    if zy:
        pairing(zy)
    print("\n%s" % ("everything the console drew matches the model"
                    if bad == 0 else
                    "the console disagrees -- it is the one that is right"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
