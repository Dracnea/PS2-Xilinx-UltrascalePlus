#!/usr/bin/env python3
"""Where the console's disc comes from, on the host side.

    tools/ps2iop/discsource.py <source> info
    tools/ps2iop/discsource.py <source> read LBA [--count N] [--out FILE]
    tools/ps2iop/discsource.py <source> bench [--sectors N]

`<source>` is one of:

  * a **disc image** on disk -- `game.iso`, or any file of 2048-byte sectors
  * a **block device** holding one -- `/dev/sdb`, a USB drive with a raw image
  * a **DVD drive** with the disc in it -- `/dev/sr0`

The reason those are one class and not three: on Linux all of them are opened
and read the same way, and a PS2 disc is 2048-byte sectors in every case. The
console's CDVD block asks for "sector N"; nothing above this file needs to know
which of the three answered. That is what lets the eventual UI offer "play from
an image / play from a drive" without any of it reaching the gateware.

What differs, and is handled here:

  * A drive has to be *ready*. A tray that is open or still spinning up returns
    ENOMEDIUM or EIO, which is a state to report to the user, not a crash.
  * A drive is slow and seeks badly. Reads are cached, and the cache is sized
    so a directory walk does not re-seek for every record.
  * A drive can be shorter than the volume claims, and a truncated image
    certainly can. Reads past the end are reported rather than returned as
    zeros, because zeros look like a legitimately blank sector.

> **NOTE (unverified): no optical drive is attached to the machine this was
> written on**, so the `/dev/sr0` path is written to the same interface as the
> other two and exercised only against files and the loop path.
> *Verify by: putting a disc in a drive and running `info` against it.*
"""
import argparse, errno, os, sys, time

SECTOR = 2048

# The HBM disc cache, from docs/hbm.md. An image at or under this is entirely
# resident once staged and never misses; a larger one still works, with the
# cache holding its working set.
CACHE_BYTES = 6 * 1024**3
DVD5_BYTES  = 4_700_372_992          # single layer, nominal
DVD9_BYTES  = 8_543_666_176          # dual layer, nominal


def classify(size):
    """Where an image falls against the cache, per docs/disc-path.md."""
    if size <= CACHE_BYTES:
        layer = "single-layer" if size <= DVD5_BYTES else "dual-layer"
        return ("resident",
                f"{layer}, fits the {CACHE_BYTES//1024**3} GiB cache entirely: "
                "no misses once staged")
    if size <= DVD9_BYTES:
        return ("cached",
                "dual-layer, larger than the cache: works, with the working set "
                "resident and the occasional slow sector")
    return ("oversize",
            f"{size/1024**3:.2f} GiB is beyond a dual-layer disc. That usually means "
            "two discs merged into one image, which is not supported -- the "
            "filesystem layout is not what the game expects and its own disc-swap "
            "logic has nothing to swap to. Use the separate per-disc images.")


class DiscSource:
    """A PS2 disc, whatever it is physically stored on."""

    def __init__(self, path, cache_sectors=512):
        self.path = path
        self.kind = "image"
        try:
            st = os.stat(path)
        except OSError as e:
            raise SystemExit(f"{path}: {e.strerror}")
        if os.path.exists("/sys/class/block/" + os.path.basename(path)):
            self.kind = "block device"
        if os.path.basename(path).startswith("sr"):
            self.kind = "optical drive"

        try:
            self.f = open(path, "rb", buffering=0)
        except OSError as e:
            if e.errno == errno.ENOMEDIUM:
                raise SystemExit(f"{path}: no disc in the drive")
            raise SystemExit(f"{path}: {e.strerror}")

        self.size = self._size()
        self.sectors = self.size // SECTOR
        self._cache = {}
        self._cache_max = cache_sectors
        self.reads = 0
        self.cache_hits = 0

    def _size(self):
        try:
            return os.stat(self.path).st_size or self._seek_size()
        except OSError:
            return self._seek_size()

    def _seek_size(self):
        cur = self.f.seek(0, 2)
        return cur

    def read(self, lba, count=1):
        """`count` sectors from `lba`. Cached; raises on a short read."""
        out = bytearray()
        for n in range(count):
            s = lba + n
            if s in self._cache:
                self.cache_hits += 1
                out += self._cache[s]
                continue
            self.f.seek(s * SECTOR)
            try:
                d = self.f.read(SECTOR)
            except OSError as e:
                raise SystemExit(f"{self.path}: read of sector {s} failed: {e.strerror}")
            self.reads += 1
            if len(d) != SECTOR:
                raise SystemExit(f"{self.path}: sector {s} is past the end of the "
                                 f"{self.sectors}-sector source (got {len(d)} bytes)")
            if len(self._cache) >= self._cache_max:
                self._cache.clear()
            self._cache[s] = d
            out += d
        return bytes(out)

    def close(self):
        self.f.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("info")
    p = sub.add_parser("read"); p.add_argument("lba", type=lambda x: int(x, 0))
    p.add_argument("--count", type=int, default=1); p.add_argument("--out")
    p = sub.add_parser("bench"); p.add_argument("--sectors", type=int, default=2000)
    a = ap.parse_args()

    d = DiscSource(a.source)
    if a.cmd == "info":
        print(f"{d.path}")
        print(f"   kind      {d.kind}")
        print(f"   size      {d.size} bytes ({d.size/1024**3:.2f} GiB), "
              f"{d.sectors} sectors of {SECTOR}")
        verdict, why = classify(d.size)
        print(f"   cache     {verdict}: {why}")
        # is it a PS2 disc? ask the reader that already knows
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        try:
            from isoread import Iso
            iso = Iso(a.source)
            print(f"   label     {iso.label!r}")
            hit = iso.find("SYSTEM.CNF")
            if hit:
                txt = iso.read_file(hit[1], hit[2]).decode("latin-1")
                for line in txt.splitlines():
                    if line.strip():
                        print(f"   cnf       {line.strip()}")
            else:
                print("   cnf       no SYSTEM.CNF: readable, but not a PS2 disc")
        except SystemExit as e:
            print(f"   iso9660   {e}")
    elif a.cmd == "read":
        data = d.read(a.lba, a.count)
        if a.out:
            open(a.out, "wb").write(data)
            print(f"{len(data)} bytes from LBA {a.lba} -> {a.out}")
        else:
            for off in range(0, min(len(data), 256), 16):
                row = data[off:off + 16]
                print(f"   {a.lba*SECTOR+off:010x}  {row.hex(' ')}  "
                      f"{''.join(chr(c) if 32 <= c < 127 else '.' for c in row)}")
    elif a.cmd == "bench":
        # sequential, then the scattered pattern a directory walk makes
        t0 = time.time(); d.read(0, min(a.sectors, d.sectors))
        seq = time.time() - t0
        t0 = time.time()
        step = max(d.sectors // 200, 1)
        for i in range(200):
            d.read(min(i * step, d.sectors - 1))
        rnd = time.time() - t0
        print(f"   sequential {a.sectors} sectors: {seq:.3f} s "
              f"({a.sectors*SECTOR/seq/1e6:.1f} MB/s)")
        print(f"   200 scattered single sectors: {rnd:.3f} s ({rnd/200*1e3:.2f} ms each)")
        print(f"   {d.reads} source reads, {d.cache_hits} cache hits")
    d.close()


if __name__ == "__main__":
    main()
