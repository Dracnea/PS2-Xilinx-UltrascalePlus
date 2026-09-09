#!/usr/bin/env python3
"""Serve disc sectors to the card, from an image, a block device or a drive.

    tools/ps2iop/discserve.py <source> [--csr bitstreams/c1100_ps2_diag.csr.csv]
                              [--seconds 30] [--once] [--quiet]

The CDVD block asks for one sector at a time -- `iop_cdvd_sec_req` goes high
with the wanted LBA in `iop_cdvd_sec_lba` -- and this answers by writing the
512 words and pulsing done. That is the whole protocol.

It is deliberately the *only* thing that knows where a sector comes from. The
gateware asks for "sector N"; `DiscSource` decides whether that is an ISO file,
a USB drive or a disc in a DVD drive; and when the card's HBM becomes the
backing store, this program stops being in the path without the IOP or the
CDVD block noticing (docs/disc-path.md).

Sectors are served one per request rather than streamed, because that is what
a drive does and because it keeps the interface honest: a miss costs a round
trip, which is exactly the cost HBM is meant to remove later.
"""
import argparse, os, struct, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import iop_post
from discsource import DiscSource, SECTOR


def serve(dev, disc, seconds=30.0, once=False, verbose=True):
    served = 0
    t0 = time.time()
    last_lba = None
    while time.time() - t0 < seconds:
        if not (dev.rd("iop_cdvd_sec_req") & 1):
            time.sleep(0.0002)
            continue
        lba = dev.rd("iop_cdvd_sec_lba")
        try:
            data = disc.read(lba)
        except SystemExit as e:
            print(f"   sector {lba}: {e}", file=sys.stderr)
            data = b"\0" * SECTOR
        words = struct.unpack("<512I", data)
        for w in words:
            dev.wr("iop_cdvd_sec_data", w)
        dev.wr("iop_cdvd_sec_done", 1)
        served += 1
        if verbose and lba != last_lba:
            head = data[:8]
            note = ""
            if data[1:6] == b"CD001":
                note = f"   ISO9660 descriptor type {data[0]}"
            print(f"   served LBA {lba:8d}  {head.hex(' ')}{note}")
            last_lba = lba
        if once:
            break
    return served


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source")
    ap.add_argument("--csr", default="bitstreams/c1100_ps2_diag.csr.csv")
    ap.add_argument("--dev", default="/dev/litepcie0")
    ap.add_argument("--seconds", type=float, default=30.0)
    ap.add_argument("--once", action="store_true", help="serve a single sector and stop")
    ap.add_argument("--quiet", action="store_true",
                    help="only the summary line: for repeat runs where per-sector output is noise")
    a = ap.parse_args()

    dev = iop_post.Dev(a.dev, a.csr)
    if "iop_cdvd_sec_req" not in dev.regs:
        sys.exit("this bitstream has no CDVD sector source; rebuild with it")
    disc = DiscSource(a.source)
    if not a.quiet:
        print(f"serving {disc.path} ({disc.kind}, {disc.sectors} sectors) for {a.seconds:g} s")
    n = serve(dev, disc, a.seconds, a.once, verbose=not a.quiet)
    print(f"{n} sectors served; {disc.reads} source reads, {disc.cache_hits} cache hits")


if __name__ == "__main__":
    main()
