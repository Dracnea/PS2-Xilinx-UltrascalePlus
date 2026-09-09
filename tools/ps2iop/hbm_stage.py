#!/usr/bin/env python3
"""Stage disc sectors into the card's HBM, and hand the CDVD over to it.

    tools/ps2iop/hbm_stage.py <disc> --sectors 16,17,18 [--csr ...]
    tools/ps2iop/hbm_stage.py <disc> --from 0 --count 4096
    tools/ps2iop/hbm_stage.py --status
    tools/ps2iop/hbm_stage.py --host          # give the disc back to discserve.py

Once sectors are in HBM and `iop_hbm_disc_enable` is set, the gateware answers
the CDVD's requests directly and no host program needs to be running at all --
which is the point. `discserve.py` answers one sector per PCIe round trip; this
answers out of memory, and the IOP cannot tell the difference except in timing.

**This is not the way to stage a whole disc.** Writing goes through the HBM
probe, which spends about ten CSR round trips per 32-byte beat, so a 2 KB sector
costs ~640 of them and a 4 GiB image would take the better part of a day. It is
the right tool for the first megabytes -- enough to prove the path and to boot --
and the wrong one for a game. Bulk staging wants the LitePCIe DMA engine writing
HBM directly, which does not exist yet; see docs/disc-path.md.
"""
import argparse, os, struct, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import iop_post
from discsource import DiscSource, SECTOR

BEAT = 32                      # bytes per 256-bit HBM beat


def write_beat(dev, addr, data32):
    """One 256-bit beat: eight 32-bit lanes, then a write."""
    dev.wr("hbm_probe_addr", addr)
    dev.wr("hbm_probe_ctrl", 0x4)                 # clear the lane pointer
    for w in data32:
        dev.wr("hbm_probe_wdata", w)
    dev.wr("hbm_probe_ctrl", 0x1)                 # write
    for _ in range(10000):
        s = dev.rd("hbm_probe_stat")
        if (s >> 1) & 1:
            return (s >> 2) & 3
    raise SystemExit("HBM probe never reported done")


def stage_sector(dev, base, lba, data):
    assert len(data) == SECTOR
    words = struct.unpack("<%dI" % (SECTOR // 4), data)
    for b in range(SECTOR // BEAT):
        resp = write_beat(dev, base + lba * SECTOR + b * BEAT, words[b*8:(b+1)*8])
        if resp:
            sys.exit(f"AXI response {resp} writing LBA {lba} beat {b}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", nargs="?", help="ISO, block device or drive")
    ap.add_argument("--csr", default="bitstreams/c1100_ps2_iop.csr.csv")
    ap.add_argument("--dev", default="/dev/litepcie0")
    ap.add_argument("--sectors", help="comma-separated LBAs to stage")
    ap.add_argument("--from", dest="first", type=int, default=None, help="first LBA of a range")
    ap.add_argument("--count", type=int, default=1, help="how many sectors from --from")
    ap.add_argument("--base", type=lambda x: int(x, 0), default=None,
                    help="HBM byte address of LBA 0 (default: leave the CSR alone)")
    ap.add_argument("--host", action="store_true", help="hand the disc back to the host path")
    ap.add_argument("--status", action="store_true", help="just report")
    a = ap.parse_args()

    dev = iop_post.Dev(a.dev, a.csr)
    dev.check_link()
    if "iop_hbm_disc_enable" not in dev.regs:
        sys.exit("this bitstream has no HBM disc source; rebuild boards/c1100_ps2_iop.py")

    if a.status:
        st = dev.rd("iop_hbm_disc_stat")
        print(f"  enable  = {dev.rd('iop_hbm_disc_enable') & 1}")
        print(f"  base    = 0x{dev.rd('iop_hbm_disc_base'):09x}")
        print(f"  busy    = {st & 1}   served = {(st >> 1) & 0xFFFF}   last AXI resp = {(st >> 17) & 3}")
        return 0

    if a.host:
        dev.wr("iop_hbm_disc_enable", 0)
        print("disc source: the host (run discserve.py)")
        return 0

    if a.base is not None:
        dev.wr("iop_hbm_disc_base", a.base)
    base = dev.rd("iop_hbm_disc_base")

    if not a.source:
        sys.exit("give a disc image to stage, or use --status / --host")
    lbas = []
    if a.sectors:
        lbas += [int(x, 0) for x in a.sectors.split(",")]
    if a.first is not None:
        lbas += list(range(a.first, a.first + a.count))
    if not lbas:
        sys.exit("nothing to stage: pass --sectors or --from/--count")

    disc = DiscSource(a.source)
    print(f"staging {len(lbas)} sector(s) of {disc.path} into HBM at 0x{base:09x}")
    t0 = time.time()
    for n, lba in enumerate(lbas):
        stage_sector(dev, base, lba, disc.read(lba))
        if len(lbas) > 8 and n % 8 == 0:
            el = time.time() - t0
            print(f"   {n+1}/{len(lbas)}  {(n+1)*SECTOR/1024/max(el,1e-9):.0f} KiB/s", end="\r")
    el = time.time() - t0
    print(f"staged {len(lbas)} sector(s) in {el:.1f} s "
          f"({len(lbas)*SECTOR/1024/max(el,1e-9):.0f} KiB/s)")

    dev.wr("iop_hbm_disc_enable", 1)
    print("disc source: HBM (the gateware answers; no host program needed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
