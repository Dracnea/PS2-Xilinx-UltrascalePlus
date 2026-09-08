#!/usr/bin/env python3
"""Build a minimal PS2-shaped ISO9660 image, so the disc path can be tested
without a game disc.

    tools/ps2iop/mkiso.py out.iso [--boot SLUS_900.00] [--elf FILE] [--label TEST]
                                 [--sectors N]

A PS2 disc is an ordinary ISO9660 filesystem. What makes it a PS2 disc is a
file called SYSTEM.CNF in the root naming the executable to run:

    BOOT2 = cdrom0:\\SLUS_900.00;1
    VER = 1.00
    VMODE = NTSC

and that is exactly the file the BIOS reads first. The BIOS's own CDVDMAN and
IOMAN walk the volume descriptor, the path table and the root directory to find
it, so an image built here exercises the identical driver path a retail disc
does -- with none of the waiting, and nothing of anyone else's in it.

The output is a few kilobytes rather than several gigabytes, which also means
it fits in the IOP's RAM for the first experiments, before the disc is served
from the host over PCIe.

`--sectors N` matters more than it looks. A real PS2 disc puts SYSTEM.CNF and
the boot executable at the *far end*: on the Star Wars Battlefront II disc
checked here, the volume is 2,278,160 sectors and SYSTEM.CNF is at LBA
2,265,115. A test image that puts everything at LBA 21 never exercises a large
sector number, so it would not catch a read path that truncated an LBA to 16 or
20 bits -- and that is exactly the sort of bug this is meant to find. With
`--sectors` the files are placed near the end of a volume of that size, and the
image is written sparse, so a disc-sized layout costs kilobytes on disk.

Written from scratch because this machine has no genisoimage/xorriso, and
because the pieces that matter here (the 2048-byte sectors, the little- and
big-endian pairs, the directory records) are the very things the driver under
test parses. ISO9660 level 1, no Joliet, no Rock Ridge.
"""
import argparse, struct, sys
from datetime import datetime, timezone

SECTOR = 2048


def both16(v):   return struct.pack("<H", v) + struct.pack(">H", v)
def both32(v):   return struct.pack("<I", v) + struct.pack(">I", v)


def dec_datetime(dt):
    """The 17-byte 'digits' form used by the volume descriptor."""
    return ("%04d%02d%02d%02d%02d%02d00" % (dt.year, dt.month, dt.day,
                                            dt.hour, dt.minute, dt.second)).encode() + bytes([0])


def dir_datetime(dt):
    """The 7-byte form used inside a directory record."""
    return bytes([dt.year - 1900, dt.month, dt.day, dt.hour, dt.minute, dt.second, 0])


def dir_record(name, extent, length, dt, is_dir=False, special=None):
    """One ISO9660 directory record. `special` is 0 for '.' and 1 for '..'."""
    if special is None:
        ident = name.encode("ascii")
    else:
        ident = bytes([special])
    ln = 33 + len(ident)
    pad = ln % 2                       # records are even-length
    rec = bytes([ln + pad, 0])
    rec += both32(extent)
    rec += both32(length)
    rec += dir_datetime(dt)
    rec += bytes([0x02 if is_dir else 0x00])   # flags
    rec += bytes([0, 0])                       # unit size, gap size
    rec += both16(1)                           # volume sequence number
    rec += bytes([len(ident)]) + ident
    rec += bytes(pad)
    return rec


def build(path, boot_name, elf_bytes, label, extra, volume_sectors=None):
    now = datetime.now(timezone.utc)
    files = [(boot_name.upper() + ";1", elf_bytes)]
    for n, b in extra:
        files.append((n.upper() + ";1", b))
    cnf = (f"BOOT2 = cdrom0:\\{boot_name.upper()};1\r\n"
           f"VER = 1.00\r\n"
           f"VMODE = NTSC\r\n").encode("ascii")
    files.insert(0, ("SYSTEM.CNF;1", cnf))

    # layout: 16 blank sectors, PVD, terminator, path tables (L and M), root
    # directory, then the file data
    lba_pvd, lba_term = 16, 17
    lba_pathl, lba_pathm, lba_root = 18, 19, 20

    # File data goes right after the root directory, unless a volume size is
    # given -- then it goes near the end, where a real disc keeps it.
    need = sum((len(d) + SECTOR - 1) // SECTOR for _, d in files)
    if volume_sectors:
        if volume_sectors < lba_root + 1 + need + 1:
            sys.exit(f"--sectors {volume_sectors} is too small for {need} sectors of files")
        lba = volume_sectors - need - 1
    else:
        lba = lba_root + 1
    placed = []
    for name, data in files:
        placed.append((name, lba, len(data), data))
        lba += (len(data) + SECTOR - 1) // SECTOR
    total = volume_sectors or lba

    # root directory: '.', '..', then the files
    root = dir_record("", lba_root, SECTOR, now, is_dir=True, special=0)
    root += dir_record("", lba_root, SECTOR, now, is_dir=True, special=1)
    for name, ext, ln, _ in placed:
        root += dir_record(name, ext, ln, now)
    if len(root) > SECTOR:
        sys.exit("root directory does not fit in one sector; this tool is deliberately minimal")
    root_sector = root.ljust(SECTOR, b"\0")

    # path tables: one entry, the root
    pt_l = bytes([1, 0]) + struct.pack("<I", lba_root) + struct.pack("<H", 1) + b"\0\0"
    pt_m = bytes([1, 0]) + struct.pack(">I", lba_root) + struct.pack(">H", 1) + b"\0\0"

    def pvd():
        v = bytes([1]) + b"CD001" + bytes([1])
        v += bytes([0])                                   # unused
        v += b" " * 32                                    # system identifier
        v += label.upper().ljust(32)[:32].encode("ascii") # volume identifier
        v += bytes(8)
        v += both32(total)                                # volume space size
        v += bytes(32)
        v += both16(1) + both16(1)                        # set size, sequence number
        v += both16(SECTOR)
        v += both32(len(pt_l))                            # path table size
        v += struct.pack("<I", lba_pathl) + struct.pack("<I", 0)
        v += struct.pack(">I", lba_pathm) + struct.pack(">I", 0)
        v += dir_record("", lba_root, SECTOR, now, is_dir=True, special=0)   # root record, 34 bytes
        v += b" " * 128                                   # volume set
        v += b" " * 128                                   # publisher
        v += b" " * 128                                   # data preparer
        v += b" " * 128                                   # application
        v += b" " * 37 + b" " * 37 + b" " * 37            # copyright, abstract, bibliographic
        v += dec_datetime(now) + dec_datetime(now)        # creation, modification
        v += b"0" * 16 + bytes([0])                       # expiration
        v += b"0" * 16 + bytes([0])                       # effective
        v += bytes([1]) + bytes([0])
        v += bytes(512) + bytes(653)
        return v.ljust(SECTOR, b"\0")[:SECTOR]

    with open(path, "wb") as f:
        f.write(bytes(SECTOR * 16))                       # system area
        f.write(pvd())
        term = (bytes([255]) + b"CD001" + bytes([1])).ljust(SECTOR, b"\0")
        f.write(term)
        f.write(pt_l.ljust(SECTOR, b"\0"))
        f.write(pt_m.ljust(SECTOR, b"\0"))
        f.write(root_sector)
        for name, ext, ln, data in placed:
            f.seek(ext * SECTOR)
            f.write(data)
        f.seek(total * SECTOR - 1)
        f.write(b"\0")
    return total, placed


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out")
    ap.add_argument("--boot", default="SLUS_900.00", help="name of the boot executable in SYSTEM.CNF")
    ap.add_argument("--elf", help="file to use as that executable (default: a recognisable stub)")
    ap.add_argument("--label", default="PS2TEST")
    ap.add_argument("--sectors", type=int, default=None,
                    help="declare a volume of this many 2048-byte sectors and put the files near "
                         "its end, as a real disc does (the image is written sparse). A real "
                         "PS2 DVD is around 2,278,160 sectors.")
    a = ap.parse_args()

    if a.elf:
        elf = open(a.elf, "rb").read()
    else:
        # not a runnable ELF, just something with an ELF magic and a known
        # pattern, so a read of it can be checked byte for byte
        elf = bytearray(b"\x7fELF\x01\x01\x01\x00" + bytes(8))
        elf += b"PS2-Xilinx-UltrascalePlus disc-path test payload\n"
        while len(elf) < 4096:
            elf += bytes([len(elf) & 0xFF])
        elf = bytes(elf)

    total, placed = build(a.out, a.boot, elf, a.label, [], a.sectors)
    import os
    print(f"{a.out}: {total} sectors, {total * SECTOR} bytes declared, "
          f"{os.stat(a.out).st_blocks * 512} bytes on disk, label {a.label.upper()}")
    for name, ext, ln, _ in placed:
        print(f"   {name:<16} LBA {ext:5d}  {ln:7d} bytes")


if __name__ == "__main__":
    main()
