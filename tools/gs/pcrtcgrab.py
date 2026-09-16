#!/usr/bin/env python3
"""Set up PCRTC on the card, grab a frame, and save it as a PNG.

    tools/gs/pcrtcgrab.py --csr build/c1100_gs_disp/csr.csv -o frame.png
    tools/gs/pcrtcgrab.py --csr ... --raster 64 64 --fbp 0 --psm 0 -o frame.png

**This is PCRTC, and gsgrab.py is not.** gsgrab.py reads the frame buffer over
PCIe and de-swizzles it on the host: a faithful picture of what the rasteriser
drew, and no test at all of the video block. PCRTC is the part that reads two
display circuits out of local memory, magnifies them, merges them and blends
between them, and none of that is exercised by reading memory directly.

So this drives the privileged registers the way the Emotion Engine would --
PMODE, DISPFB1/2, DISPLAY1/2, BGCOLOR at their offsets from 0x12000000 -- lets
the raster run, and reads back the frame gs_pxcap caught. What comes out is a
picture the *card* composited, which can be put beside sim/gs/pcrtc_ref.py's.

The capture is one frame and the host reads it a pixel at a time. That is slow
and deliberately so: a bring-up picture is static, so being obviously correct
is worth more than being quick, and it keeps the fabric cost at four block RAMs
instead of a DMA ring.

SPDX-License-Identifier: BSD-2-Clause
"""
import argparse
import fcntl
import os
import struct
import sys
import time
import zlib

LITEPCIE_IOCTL_REG = (3 << 30) | (12 << 16) | (ord("S") << 8) | 0

# offsets from 0x12000000, as gs_pcrtc decodes them
PMODE, DISPFB1, DISPLAY1, DISPFB2, DISPLAY2, BGCOLOR = (
    0x00, 0x70, 0x80, 0x90, 0xA0, 0xE0)


def regs_from_csv(path):
    regs = {}
    with open(path) as f:
        for line in f:
            p = line.strip().split(",")
            if p and p[0] == "csr_register":
                regs[p[1]] = (int(p[2], 0), int(p[3]))
    return regs


class Card:
    def __init__(self, dev, csr):
        self.fd = os.open(dev, os.O_RDWR)
        self.regs = regs_from_csv(csr)

    def rd(self, name):
        addr, _ = self.regs[name]
        return struct.unpack("IIB3x", fcntl.ioctl(
            self.fd, LITEPCIE_IOCTL_REG, struct.pack("IIB3x", addr, 0, 0)))[1]

    def wr(self, name, val):
        addr, _ = self.regs[name]
        fcntl.ioctl(self.fd, LITEPCIE_IOCTL_REG,
                    struct.pack("IIB3x", addr, val & 0xFFFFFFFF, 1))

    def pr(self, off, val):
        """One privileged-register write, through the toggle handshake."""
        self.wr("gs_pr_addr", off)
        self.wr("gs_pr_d0", val & 0xFFFFFFFF)
        self.wr("gs_pr_d1", (val >> 32) & 0xFFFFFFFF)
        self.wr("gs_pr_push", 1)


def write_png(path, w, h, rgb):
    """A minimal PNG, the same one gsgrab.py writes: no filtering, one IDAT."""
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw += rgb[y * w * 3:(y + 1) * w * 3]

    def chunk(kind, data):
        c = struct.pack(">I", len(data)) + kind + data
        return c + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 6))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dev", default="/dev/litepcie0")
    ap.add_argument("--csr", required=True)
    ap.add_argument("--raster", nargs=2, type=int, default=[64, 64],
                    metavar=("W", "H"), help="h_total and v_total")
    ap.add_argument("--fbp", type=lambda x: int(x, 0), default=0,
                    help="frame buffer base, in 2048-word pages")
    ap.add_argument("--fbw", type=int, default=1, help="width in 64-pixel units")
    ap.add_argument("--psm", type=lambda x: int(x, 0), default=0,
                    help="0 PSMCT32, 1 PSMCT24, 2 PSMCT16, 10 PSMCT16S")
    ap.add_argument("--bgcolor", type=lambda x: int(x, 0), default=0)
    ap.add_argument("-o", "--out", default="pcrtc.png")
    a = ap.parse_args()

    w, h = a.raster
    card = Card(a.dev, a.csr)

    # Registers first, raster second: gs_pcrtc holds its counters at zero while
    # disabled, which is what lets the registers be put in place before any
    # pixel is produced from them.
    card.wr("gs_disp_en", 0)
    card.wr("gs_cap_arm", 0)
    card.wr("gs_h_total", w)
    card.wr("gs_v_total", h)
    card.pr(PMODE,    0x0000000000000001)               # circuit 1 only
    card.pr(DISPFB1,  a.fbp | (a.fbw << 9) | (a.psm << 15))
    card.pr(DISPLAY1, ((w - 1) << 32) | ((h - 1) << 44))
    card.pr(BGCOLOR,  a.bgcolor)

    card.wr("gs_cap_arm", 1)
    card.wr("gs_disp_en", 1)

    deadline = time.time() + 5.0
    while time.time() < deadline:
        if card.rd("gs_cap_stat") & 2:                  # done
            break
        time.sleep(0.01)
    else:
        raise SystemExit("FAIL  no frame was captured in 5 s.\n"
                         "  gs_cap_stat busy=%d done=%d, %d pixels.\n"
                         "  A raster whose circuits cover nothing emits no "
                         "start-of-frame and captures nothing."
                         % (card.rd("gs_cap_stat") & 1,
                            (card.rd("gs_cap_stat") >> 1) & 1,
                            card.rd("gs_cap_count")))

    card.wr("gs_disp_en", 0)
    n = card.rd("gs_cap_count")
    print(f"captured {n} pixels of a {w}x{h} raster "
          f"({card.rd('gs_crtc_rd')} display reads, "
          f"{card.rd('gs_crtc_stall')} refused by the arbiter)")

    rgb = bytearray(w * h * 3)
    for i in range(min(n, w * h)):
        card.wr("gs_cap_addr", i)
        time.sleep(0.0002)                              # the read crosses to cd_gs
        v = card.rd("gs_cap_data")
        rgb[i * 3 + 0] = v & 0xFF                       # 0xBBGGRR -> R,G,B
        rgb[i * 3 + 1] = (v >> 8) & 0xFF
        rgb[i * 3 + 2] = (v >> 16) & 0xFF
    write_png(a.out, w, h, rgb)
    print(f"wrote {a.out}")
    if n < w * h:
        print(f"note: {w * h - n} pixels short of a full raster, so the tail of "
              f"the picture is black rather than captured")
    return 0


if __name__ == "__main__":
    sys.exit(main())
