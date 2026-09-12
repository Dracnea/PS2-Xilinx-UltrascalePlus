#!/usr/bin/env python3
"""Measure the Graphics Synthesizer's actual fill rate on the card.

    tools/gs/gsfill.py --csr build/c1100_gs/csr.csv

The rasteriser is "one pixel per clock" the way a car is "40 miles per gallon":
true of the steady state and not of the journey. A sprite spends cycles on setup
before it draws anything, a blended or depth-tested pixel goes through a
read-modify-write that the plain case skips, and a triangle pays for a division
per edge per channel before its first pixel exists. What a frame actually costs
is the number this measures.

It works by reading the two counters the card already carries -- pixels drawn
and GS-domain clocks elapsed -- around a known workload. Both are read over
PCIe, so each read costs microseconds; the workloads below are therefore sized
to take milliseconds, which makes the measurement overhead a rounding error
rather than the thing being measured.
"""
import argparse, fcntl, os, struct, sys, time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "sim", "gs"))
LITEPCIE_IOCTL_REG = (3 << 30) | (12 << 16) | (ord("S") << 8) | 0

GS_HZ = 147.456e6


def regs_from_csv(path):
    regs = {}
    with open(path) as f:
        for line in f:
            p = line.strip().split(",")
            if p and p[0] == "csr_register":
                regs[p[1]] = (int(p[2], 0), int(p[3]))
    return regs


def tag(nloop, eop, regs, nreg):
    """A PACKED-mode GIFtag, exactly as tools/gs/gsrun.py builds one.

    Written out again here rather than imported because gsrun.py builds its
    stream inside a function that also talks to the card -- but it is the *same*
    construction, and the first version of this file proved why that matters by
    inventing its own and drawing nothing: a PRE bit that should not have been
    set, PACKED's register descriptor for a pair of A+D writes given as 0x55
    where A+D is 0xE so a pair is 0xEE, and no XYOFFSET at all.  The card
    accepted every quadword and rendered none of them.
    """
    return nloop | (eop << 15) | ((nreg & 15) << 60) | (regs << 64)


def sprite_stream(w, h, n=1, blend=False, ztest=False):
    """`n` sprites of w x h at the origin, into PSMCT32 at page 0.

    `blend` sets PRIM's ABE bit, which is what forces the rasteriser down its
    read-modify-write path -- the blend function itself is left as a no-op, so
    what this measures is the cost of the memory round trip and not of the
    arithmetic.  `ztest` does the same for the depth path.
    """
    items = [
        (0x4C, 0 | (16 << 16) | (0 << 24)),                   # FRAME_1: page 0, 1024 wide
        (0x18, 0),                                            # XYOFFSET_1
        (0x40, 0 | (1023 << 16) | (0 << 32) | (1023 << 48)),  # SCISSOR_1
        (0x42, 0), (0x46, 1),                                 # ALPHA_1 (no-op), COLCLAMP
        (0x4E, 0 | ((0 if ztest else 1) << 32)),              # ZBUF_1, ZMSK
        (0x47, (1 << 16) | (1 << 17)),                        # TEST_1: ZTST ALWAYS
        (0x01, 0x0000_0000_0080_4020),                        # RGBAQ
        (0x00, 6 | ((1 << 6) if blend else 0)),               # PRIM: sprite, ABE
    ]
    regs = 0
    for i in range(len(items)):
        regs |= 0xE << (4 * i)
    out = [tag(1, 0, regs, len(items))]
    for a_, d in items:
        out.append((d & ((1 << 64) - 1)) | (a_ << 64))
    # Each sprite is two A+D writes of XYZ2, so one tag of NLOOP = n and
    # NREG = 2 carries all of them.
    out.append(tag(n, 1, 0xEE, 2))
    for _ in range(n):
        out.append((0 | (0 << 16)) | (0x05 << 64))
        out.append((w << 4) | ((h << 4) << 16) | (0x05 << 64))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dev", default="/dev/litepcie0")
    ap.add_argument("--csr", required=True)
    a = ap.parse_args()
    regs = regs_from_csv(a.csr)
    fd = os.open(a.dev, os.O_RDWR)

    def rd(n):
        addr, _ = regs[n]
        return struct.unpack("IIB3x", fcntl.ioctl(
            fd, LITEPCIE_IOCTL_REG, struct.pack("IIB3x", addr, 0, 0)))[1]

    def wr(n, v):
        addr, _ = regs[n]
        fcntl.ioctl(fd, LITEPCIE_IOCTL_REG,
                    struct.pack("IIB3x", addr, v & 0xFFFFFFFF, 1))

    for probe in (0xA5A55A5A, 0x0F0FF0F0):
        wr("ctrl_scratch", probe)
        if rd("ctrl_scratch") != probe:
            print("FAIL  the PCIe link is not answering; run "
                  "sudo tools/pcie-bringup.sh c1100_gs")
            return 1
    wr("ctrl_scratch", 0x12345678)

    def push(q):
        wr("gs_gif_w0", q & 0xFFFFFFFF)
        wr("gs_gif_w1", (q >> 32) & 0xFFFFFFFF)
        wr("gs_gif_w2", (q >> 64) & 0xFFFFFFFF)
        wr("gs_gif_w3", (q >> 96) & 0xFFFFFFFF)
        wr("gs_gif_push", 1)
        while rd("gs_status") & 1:
            pass

    def run(name, stream, expect):
        wr("gs_reset", 1); wr("gs_reset", 0)
        for q in stream[:-1]:
            push(q)
        t0 = rd("gs_clk_ticks"); p0 = rd("gs_pixels")
        push(stream[-1])
        # wait for the GIF to go idle and the pixel count to stop moving
        prev = -1
        while True:
            if (rd("gs_status") & 3) == 2:
                cur = rd("gs_pixels")
                if cur == prev:
                    break
                prev = cur
        t1 = rd("gs_clk_ticks"); p1 = rd("gs_pixels")
        px = (p1 - p0) & 0xFFFFFFFF
        tk = (t1 - t0) & 0xFFFFFFFF
        ppc = px / tk if tk else 0
        print(f"  {name:14s} {px:>9d} px in {tk:>9d} clk   {ppc:5.3f} px/clk")
        if px != expect:
            print(f"      MISMATCH: expected {expect} pixels, got {px}")
        return px, tk

    print("Graphics Synthesizer fill rate, measured on the card")
    print(f"  GS clock {GS_HZ/1e6:.3f} MHz")
    print()
    print("  Each row is ONE sprite, measured from just before the host pushes")
    print("  its last vertex to the rasteriser going idle.  That window contains")
    print("  a PCIe round trip -- about 4000 GS clocks of it -- so the intercept")
    print("  below is host latency and NOT the GS's setup cost.  The *slope* is")
    print("  clean, because the same constant sits in both measurements and")
    print("  subtracts out, and the slope is what a fill rate is.")
    print()

    def sweep(title, **kw):
        print(f"  {title}")
        pts = []
        for side in (8, 16, 32, 64, 128, 256, 512):
            px, tk = run(f"    {side}x{side}", sprite_stream(side, side, **kw),
                         side * side)
            pts.append((side * side, tk))
        # two well-separated points are enough for a straight line, and the
        # small one is where setup dominates
        (n0, t0), (n1, t1) = pts[0], pts[-1]
        per = (t1 - t0) / (n1 - n0)
        setup = t0 - per * n0
        rate = GS_HZ / per
        print(f"    -> {per:5.2f} clk/pixel = {rate/1e6:7.1f} Mpixel/s"
              f"   ({setup:5.0f} clk fixed, mostly the PCIe round trip)")
        print()
        return rate

    r_plain = sweep("plain, no blend and no depth test:")
    r_blend = sweep("alpha blending on (a read-modify-write per pixel):",
                    blend=True)
    r_z     = sweep("depth test on:", ztest=True)

    FRAME = 640 * 448
    print("  What that is worth per frame, against 640x448 at 60 Hz")
    print("  (one 'pass' is the whole screen covered once):")
    for name, rate in (("plain", r_plain), ("blended", r_blend),
                       ("depth-tested", r_z)):
        print(f"    {name:14s} {rate/1e6:7.1f} Mpixel/s = "
              f"{rate/(FRAME*60):5.2f} passes per frame")
    print(f"    {'a real GS':14s} {2360.0:7.1f} Mpixel/s = "
          f"{2360e6/(FRAME*60):5.2f} passes per frame  (16 pixels per clock)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
