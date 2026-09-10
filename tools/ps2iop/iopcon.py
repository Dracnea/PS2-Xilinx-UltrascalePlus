#!/usr/bin/env python3
"""Read what the IOP printed to its serial console.

    tools/ps2iop/iopcon.py                 # drain whatever is waiting
    tools/ps2iop/iopcon.py --follow 10     # keep reading for 10 seconds

Every BIOS module prints as it initialises, so this is the record of how far the
boot got and in what order.  It answers questions like "did FILEIO reach its RPC
registration" directly, in the BIOS's own words, instead of by inference from
the structures it would have written.

The FIFO is 4096 bytes and `overflow` latches if a byte was ever dropped, which
matters: a gap in this log would otherwise be indistinguishable from a module
that printed nothing.
"""
import argparse, fcntl, os, struct, sys, time

LITEPCIE_IOCTL_REG = (3 << 30) | (12 << 16) | (ord("S") << 8) | 0


class Con:
    def __init__(self, csr, dev):
        self.regs = {}
        for line in open(csr):
            p = line.strip().split(",")
            if p and p[0] == "csr_register":
                self.regs[p[1]] = int(p[2], 0)
        if "zcon_data" not in self.regs:
            sys.exit("this bitstream has no IOP console; rebuild boards/c1100_ps2_iop.py")
        self.fd = os.open(dev, os.O_RDWR)

    def rd(self, n):
        return struct.unpack("IIB3x", fcntl.ioctl(
            self.fd, LITEPCIE_IOCTL_REG, struct.pack("IIB3x", self.regs[n], 0, 0)))[1]

    def wr(self, n, v):
        fcntl.ioctl(self.fd, LITEPCIE_IOCTL_REG,
                    struct.pack("IIB3x", self.regs[n], v & 0xFFFFFFFF, 1))

    def drain(self, limit=1 << 20):
        out = bytearray()
        while self.rd("zcon_level") and len(out) < limit:
            out.append(self.rd("zcon_data") & 0xFF)
            self.wr("zcon_pop", 1)
        return bytes(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--csr", default="build/c1100_ps2_iop/csr.csv")
    ap.add_argument("--dev", default="/dev/litepcie0")
    ap.add_argument("--follow", type=float, default=0.0,
                    help="keep reading for this many seconds")
    ap.add_argument("--raw", action="store_true", help="no line numbering")
    a = ap.parse_args()
    c = Con(a.csr, a.dev)

    buf = c.drain()
    t0 = time.time()
    while a.follow and time.time() - t0 < a.follow:
        time.sleep(0.05)
        buf += c.drain()

    if c.rd("zcon_overflow"):
        print("WARNING: the console FIFO overflowed; bytes were dropped", file=sys.stderr)
    if not buf:
        print("(nothing printed)")
        return 0
    text = buf.decode("latin-1")
    if a.raw:
        sys.stdout.write(text)
    else:
        for i, line in enumerate(text.splitlines(), 1):
            print("%3d  %s" % (i, line))
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
