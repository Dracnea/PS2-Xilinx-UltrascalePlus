#!/usr/bin/env python3
"""Draw a GIF stream on the card and save the frame buffer as a PNG.

    tools/gs/gsgrab.py --csr build/c1100_gs/csr.csv --prog scene.hex \
                       --size 320 224 -o frame.png
    tools/gs/gsgrab.py --prog scene.hex --model-only -o model.png

This is not PCRTC.  The Graphics Synthesizer's video block reads the frame
buffer at a pixel clock and drives a display; a C1100 has no video connector, so
the picture leaves the card the way everything else does -- over PCIe -- and is
assembled here.  What this shares with PCRTC is the part that is PlayStation 2
rather than plumbing: taking a frame buffer's base, width and pixel format and
turning the swizzled contents into a raster.

`--model-only` renders the same stream through sim/gs/gs_ref.py instead, so the
two pictures can be put side by side.  A checksum says *whether* the card and
the model differ; two images say *how*, which is the only way some faults ever
get recognised -- a gradient that runs the wrong way, or a seam along a shared
edge, is invisible in a number.
"""
import argparse, fcntl, os, struct, sys, zlib

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "sim", "gs"))

LITEPCIE_IOCTL_REG = (3 << 30) | (12 << 16) | (ord("S") << 8) | 0


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

    def reset(self):
        self.wr("gs_reset", 1)
        self.wr("gs_reset", 0)

    def idle(self):
        while True:
            st = self.rd("gs_status")
            if (st & 1) == 0 and (st & 2) != 0:
                return

    def push(self, qw):
        while self.rd("gs_status") & 1:
            pass
        for i in range(4):
            self.wr(f"gs_gif_w{i}", (qw >> (32 * i)) & 0xFFFFFFFF)
        self.wr("gs_gif_push", 1)

    def read_word(self, addr):
        self.wr("gs_rd_addr", addr)
        while not (self.rd("gs_status") & 4):
            pass
        v = 0
        for i in range(8):
            v |= self.rd(f"gs_rd_d{i}") << (32 * i)
        return v

    def read_range(self, first, count):
        """`count` 256-bit words from `first`, as bytes."""
        out = bytearray()
        for w in range(first, first + count):
            out += self.read_word(w).to_bytes(32, "little")
        return bytes(out)


def write_png(path, w, h, rgb):
    """A minimal PNG: no filtering, one IDAT.  zlib is in the standard library
    and a dependency for one image is not worth adding."""
    raw = bytearray()
    for y in range(h):
        raw.append(0)                                   # filter type 0
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
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dev", default="/dev/litepcie0")
    ap.add_argument("--csr")
    ap.add_argument("--prog", required=True)
    ap.add_argument("--size", nargs=2, type=int, default=[320, 224],
                    metavar=("W", "H"))
    ap.add_argument("--fbp", type=lambda x: int(x, 0), default=0,
                    help="frame buffer base, in 8 KB pages")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--model-only", action="store_true",
                    help="render through gs_ref.py instead of the card")
    a = ap.parse_args()

    W, H = a.size
    qwords = [int(l.split("//")[0].strip(), 16)
              for l in open(a.prog) if l.split("//")[0].strip()]

    import gs_ref
    if a.model_only:
        gs = gs_ref.GS()
        at = 0
        while at < len(qwords):
            nxt = gs.gif_packet(qwords, at)
            if nxt <= at:
                break
            at = nxt
        vm = bytes(gs.vm)
    else:
        if not a.csr:
            sys.exit("--csr is needed unless --model-only")
        card = Card(a.dev, a.csr)
        card.reset()
        for qw in qwords:
            card.push(qw)
        card.idle()
        # Only the pages the frame buffer occupies, not all 4 MB.
        pages = ((H + 31) // 32) * max(1, W // 64)
        vm = card.read_range(a.fbp * 256, pages * 256)
        if a.fbp:
            vm = bytes(a.fbp * 8192) + vm

    # The swizzle, from the model -- the same arithmetic cross-checked against
    # PCSX2 exhaustively, so the picture cannot be wrong in a way the addressing
    # tests would have caught.
    rgb = bytearray(W * H * 3)
    for y in range(H):
        for x in range(W):
            addr = gs_ref.addr32p(a.fbp, max(1, W // 64), x, y) * 4
            px = int.from_bytes(vm[addr:addr + 4], "little")
            i = (y * W + x) * 3
            rgb[i]     = px & 0xFF
            rgb[i + 1] = (px >> 8) & 0xFF
            rgb[i + 2] = (px >> 16) & 0xFF
    write_png(a.out, W, H, bytes(rgb))
    print(f"wrote {a.out} ({W}x{H})")


if __name__ == "__main__":
    sys.exit(main())
