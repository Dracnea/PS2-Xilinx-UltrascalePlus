#!/usr/bin/env python3
"""Walk a PS2 disc image the way the BIOS does, from the host.

    tools/ps2iop/isoread.py disc.iso [--list] [--cat SYSTEM.CNF] [--sector N]

This is the reference implementation of the read path the IOP will have to
perform once the CDVD sector path exists: find the Primary Volume Descriptor at
sector 16, follow its root directory record, walk the root directory, find
SYSTEM.CNF, and read the name of the boot executable out of it. When the
hardware can do this against the same disc and produce the same answer, the
disc path works.

It reads only the filesystem metadata and SYSTEM.CNF -- the few dozen bytes of
configuration that name the executable. It is not an extractor and deliberately
will not dump a game's contents.

Sector size is 2048 for both CD and DVD PS2 discs; nothing here needs to know
which it is.
"""
import argparse, struct, sys

SECTOR = 2048


class Iso:
    def __init__(self, path):
        self.f = open(path, "rb")
        self.path = path
        self.f.seek(0, 2)
        self.size = self.f.tell()
        self.pvd = None
        for lba in range(16, 32):                 # descriptors start at 16
            d = self.sector(lba)
            if d[1:6] != b"CD001":
                break
            if d[0] == 1:
                self.pvd = d
            if d[0] == 255:                       # terminator
                break
        if self.pvd is None:
            raise SystemExit(f"{path}: no ISO9660 Primary Volume Descriptor")

    def sector(self, lba, n=1):
        self.f.seek(lba * SECTOR)
        return self.f.read(SECTOR * n)

    @property
    def label(self):
        return self.pvd[40:72].decode("latin-1").rstrip()

    @property
    def volume_sectors(self):
        return struct.unpack_from("<I", self.pvd, 80)[0]

    @property
    def root_record(self):
        return self.pvd[156:190]

    def records(self, blob):
        """Walk the directory records in a directory extent."""
        i = 0
        while i < len(blob):
            ln = blob[i]
            if ln == 0:                            # rest of the sector is padding
                i = (i // SECTOR + 1) * SECTOR
                if i >= len(blob):
                    break
                continue
            rec = blob[i:i + ln]
            extent = struct.unpack_from("<I", rec, 2)[0]
            length = struct.unpack_from("<I", rec, 10)[0]
            flags  = rec[25]
            nlen   = rec[32]
            name   = rec[33:33 + nlen]
            if nlen == 1 and name in (b"\x00", b"\x01"):
                nm = "." if name == b"\x00" else ".."
            else:
                nm = name.decode("latin-1")
            yield nm, extent, length, flags
            i += ln

    def root(self):
        r = self.root_record
        extent = struct.unpack_from("<I", r, 2)[0]
        length = struct.unpack_from("<I", r, 10)[0]
        n = (length + SECTOR - 1) // SECTOR
        return list(self.records(self.sector(extent, n)))

    def find(self, want):
        want = want.upper()
        for nm, ext, ln, fl in self.root():
            if nm.upper().split(";")[0] == want.split(";")[0]:
                return nm, ext, ln, fl
        return None

    def read_file(self, extent, length, limit=64 * 1024):
        n = (min(length, limit) + SECTOR - 1) // SECTOR
        return self.sector(extent, n)[:min(length, limit)]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("iso")
    ap.add_argument("--list", action="store_true", help="the root directory")
    ap.add_argument("--cat", metavar="NAME", help="print a small text file from the root (e.g. SYSTEM.CNF)")
    ap.add_argument("--sector", type=int, help="hexdump one sector, for comparing against what the hardware read")
    a = ap.parse_args()

    iso = Iso(a.iso)
    print(f"{a.iso}")
    print(f"   {iso.size} bytes, {iso.size // SECTOR} sectors on disc; volume says {iso.volume_sectors}")
    print(f"   label {iso.label!r}")
    r = iso.root_record
    print(f"   root directory at LBA {struct.unpack_from('<I', r, 2)[0]}, "
          f"{struct.unpack_from('<I', r, 10)[0]} bytes")

    if a.sector is not None:
        d = iso.sector(a.sector)
        for off in range(0, 256, 16):
            row = d[off:off + 16]
            print(f"   {a.sector*SECTOR+off:08x}  {row.hex(' ')}  "
                  f"{''.join(chr(c) if 32 <= c < 127 else '.' for c in row)}")
        return

    entries = iso.root()
    if a.list:
        print(f"\n   root directory, {len(entries)} entries:")
        for nm, ext, ln, fl in entries:
            print(f"      {'d' if fl & 2 else '-'} {nm:<24} LBA {ext:8d}  {ln:11d}")

    if a.cat:
        hit = iso.find(a.cat)
        if not hit:
            sys.exit(f"{a.cat} not found in the root directory")
        nm, ext, ln, fl = hit
        print(f"\n   {nm}  LBA {ext}  {ln} bytes:")
        for line in iso.read_file(ext, ln).decode("latin-1").splitlines():
            print(f"      | {line}")
        return

    # default: the thing that matters -- what does the BIOS boot?
    hit = iso.find("SYSTEM.CNF")
    if not hit:
        print("\n   no SYSTEM.CNF in the root: not a PS2 disc, or not the boot layer")
        return
    nm, ext, ln, fl = hit
    text = iso.read_file(ext, ln).decode("latin-1")
    print(f"\n   SYSTEM.CNF at LBA {ext}, {ln} bytes:")
    for line in text.splitlines():
        if line.strip():
            print(f"      | {line.strip()}")
    for line in text.splitlines():
        if line.upper().startswith("BOOT2"):
            boot = line.split("=", 1)[1].strip()
            name = boot.split("\\")[-1].split(";")[0]
            e = iso.find(name)
            print(f"\n   boot executable: {boot}")
            if e:
                print(f"   found in the root: {e[0]}  LBA {e[1]}  {e[2]} bytes")
                hdr = iso.read_file(e[1], 64)
                print(f"   first bytes: {hdr[:16].hex(' ')}"
                      + ("   (ELF)" if hdr[:4] == b"\x7fELF" else ""))
            else:
                print(f"   NOT found in the root directory -- it may be in a subdirectory")


if __name__ == "__main__":
    main()
