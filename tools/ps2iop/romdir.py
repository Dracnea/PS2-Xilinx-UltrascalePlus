#!/usr/bin/env python3
"""Read a PS2 rom0 image the way IOPBOOT does: ROMDIR, EXTINFO, IOPBTCONF.

    tools/ps2iop/romdir.py <rom0.bin> [--list] [--extract NAME [--out DIR]]
    tools/ps2iop/romdir.py <rom0.bin> --boot        # what IOPBOOT will load, in order
    tools/ps2iop/romdir.py <rom0.bin> --hw NAME     # registers a module touches
    tools/ps2iop/romdir.py <rom0.bin> --irx NAME    # a module's IRX header and sections
    tools/ps2iop/romdir.py <dir-of-roms> --compare  # ROMVER / module set across dumps

A rom0 image is a flat archive. The directory is a run of 16-byte entries -
10 bytes of name, a u16 EXTINFO length, a u32 file length - starting at the
entry named RESET and ending at an entry with an empty name. File data is
packed in directory order from offset 0, each file padded up to 16 bytes.
Every entry's EXTINFO bytes are concatenated in the same order inside the
EXTINFO file, and carry the date, version and description strings.

The point of this for the FPGA work is --boot and --hw. IOPBOOT reads the
IOPBTCONF file, which names the modules it loads into IOP RAM and starts, in
order; --hw disassembles a module's lui/ori and lui/load-store pairs to list
the hardware addresses it actually touches. Together they say which
peripherals the IOP core must implement before the kernel can get past a
given module, which is the whole question after the ELF relocation pass.
"""
import argparse, os, re, struct, sys

ENTRY = struct.Struct("<10sHI")


class Rom:
    def __init__(self, path):
        self.path = path
        self.data = open(path, "rb").read()
        base = self.data.find(b"RESET\0\0\0\0\0")
        if base < 0:
            raise SystemExit(f"{path}: no ROMDIR (no RESET entry)")
        self.dir_offset = base
        self.files = []          # (name, offset, size, extinfo_offset, extinfo_size)
        off = 0                  # file data starts at 0 and runs in directory order
        ext = 0
        p = base
        while p + 16 <= len(self.data):
            name, esz, sz = ENTRY.unpack_from(self.data, p)
            name = name.split(b"\0")[0].decode("latin-1")
            if not name:
                break
            self.files.append((name, off, sz, ext, esz))
            off += (sz + 15) & ~15
            ext += esz
            p += 16
        self.by_name = {f[0]: f for f in self.files}

    def read(self, name):
        f = self.by_name.get(name)
        if not f:
            return None
        return self.data[f[1]:f[1] + f[2]]

    def extinfo(self, name):
        """The EXTINFO slice for one entry, decoded into date / version / comment.

        Each record is a 4-byte header - u16 value, u8 length, u8 id - followed
        by `length` bytes of data. id 1 is the build date as four BCD bytes
        (day, month, year low, year high), id 2 carries the version in the
        value field and has no data, id 3 is a NUL-padded description, and
        0x7f is a one-byte filler that ends the record run.
        """
        f = self.by_name.get(name)
        blob = self.read("EXTINFO")
        if not f or blob is None:
            return {}
        e = blob[f[3]:f[3] + f[4]]
        out, i = {}, 0
        while i + 4 <= len(e):
            if e[i] == 0x7F:
                break
            value, elen, eid = struct.unpack_from("<HBB", e, i)
            data = e[i + 4:i + 4 + elen]
            if eid == 1 and elen >= 4:
                out["date"] = f"{data[3]:02x}{data[2]:02x}-{data[1]:02x}-{data[0]:02x}"
            elif eid == 2:
                out["version"] = value
            elif eid == 3:
                out["comment"] = data.split(b"\0")[0].decode("latin-1")
            elif eid == 0:
                pass
            else:
                break
            i += 4 + elen
        return out

    def romver(self):
        v = self.read("ROMVER")
        return "".join(c for c in v.decode("latin-1") if c.isprintable()).strip() if v else "?"


def cmd_list(rom, args):
    print(f"{rom.path}   ROMVER {rom.romver()}   ROMDIR at 0x{rom.dir_offset:x}   {len(rom.files)} entries")
    print(f"{'name':<12} {'offset':>9} {'size':>9}  {'ver':>5}  {'date':<10} comment")
    for name, off, sz, _eo, _es in rom.files:
        x = rom.extinfo(name)
        v = x.get("version")
        print(f"{name:<12} 0x{off:07x} {sz:9d}  {('%03x' % v) if v is not None else '':>5}  "
              f"{x.get('date', ''):<10} {x.get('comment', '')}")


def cmd_boot(rom, args):
    """IOPBTCONF is the module list IOPBOOT loads; report each against the ROM."""
    conf = rom.read("IOPBTCONF")
    if conf is None:
        raise SystemExit("no IOPBTCONF in this ROM")
    mods = []
    for line in conf.decode("latin-1").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or line.startswith("@"):
            if line.startswith("@"):
                mods.append(("@" + line[1:], None))
            continue
        mods.append((line, None))
    iopboot = rom.by_name.get("IOPBOOT")
    print(f"{rom.path}  ROMVER {rom.romver()}")
    if iopboot:
        print(f"IOPBOOT at rom0+0x{iopboot[1]:x} = 0x{0xBFC00000 + iopboot[1]:08X}, {iopboot[2]} bytes")
    print(f"IOPBTCONF lists {len([m for m in mods if not m[0].startswith('@')])} modules:\n")
    print(f"{'#':>3}  {'module':<12} {'in ROM':>8} {'size':>8}  {'ver':>5}  comment")
    n = 0
    for name, _ in mods:
        if name.startswith("@"):
            print(f"     {name}")
            continue
        n += 1
        f = rom.by_name.get(name)
        if not f:
            print(f"{n:>3}  {name:<12} {'MISSING':>8}")
            continue
        x = rom.extinfo(name)
        v = x.get("version")
        print(f"{n:>3}  {name:<12} 0x{f[1]:06x} {f[2]:8d}  {('%03x' % v) if v is not None else '':>5}  {x.get('comment', '')}")


# --- what hardware a module touches -----------------------------------------
#
# IOP modules are IRX (ELF) files. Every peripheral access is a lui of the
# high half of the address followed by a load or store with the low half as
# the offset, so tracking the last lui per register recovers the address.

REGIONS = [
    (0x1F801000, 0x1F801040, "SSBUS"),      (0x1F801040, 0x1F801060, "SIO"),
    (0x1F801060, 0x1F801070, "RAMSIZE"),    (0x1F801070, 0x1F801080, "INTC"),
    (0x1F801080, 0x1F801100, "DMA"),        (0x1F801100, 0x1F801140, "TIMER"),
    (0x1F801400, 0x1F801480, "SSBUS2"),     (0x1F801480, 0x1F8014B0, "TIMER32"),
    (0x1F801500, 0x1F801580, "DMA2"),       (0x1F801800, 0x1F801810, "CDROM"),
    (0x1F802000, 0x1F802080, "EXP2/POST"),  (0x1F808200, 0x1F808300, "SIO2"),
    (0x1F900000, 0x1F900800, "SPU2"),       (0x1F402000, 0x1F402020, "CDVD"),
    (0x1F80146E, 0x1F801470, "DEV9"),       (0x1F80147C, 0x1F801480, "DEV9"),
    (0x1D000000, 0x1D000070, "SIF"),        (0x1F400000, 0x1F400100, "DEV9"),
    (0xFFFE0000, 0xFFFF0000, "CACHECTL"),
]


def region(a):
    m = a & 0x1FFFFFFF if a < 0xFFFE0000 else a
    for lo, hi, name in REGIONS:
        if lo <= m < hi:
            return name
    if m < 0x00200000:
        return "RAM"
    if 0x1FC00000 <= m < 0x20000000:
        return "ROM"
    return None


LOADSTORE = {0x20: "lb", 0x21: "lh", 0x23: "lw", 0x24: "lbu", 0x25: "lhu",
             0x28: "sb", 0x29: "sh", 0x2B: "sw"}


def scan_hw(blob):
    """Return {address: set(mnemonics)} for every peripheral access found.

    A constant-propagation pass over the module's words. IOP modules are
    relocatable IRX files, so a normal data address is a `lui 0` that the
    loader patches; a hardware address is not relocated and appears literally,
    built either as `lui reg, 0xbf80` + a signed offset in the load, or as
    `lui` + `ori`/`addiu` into a full pointer that the load then uses with
    offset 0. Both forms are followed here, and any other write to a tracked
    register drops it, so a stale high half cannot invent an address.
    """
    val = {}
    hits = {}

    def kill(r):
        val.pop(r, None)

    for i in range(0, len(blob) - 3, 4):
        w = struct.unpack_from("<I", blob, i)[0]
        op = w >> 26
        rs, rt = (w >> 21) & 0x1F, (w >> 16) & 0x1F
        imm = w & 0xFFFF
        simm = imm - 0x10000 if imm & 0x8000 else imm
        if op == 0x0F:                                   # lui rt, imm
            val[rt] = (imm << 16) if rt else 0
        elif op in (0x0D, 0x09, 0x0C):                   # ori / addiu / andi
            if rs in val:
                v = val[rs]
                val[rt] = (v | imm) if op == 0x0D else ((v + simm) & 0xFFFFFFFF) if op == 0x09 else (v & imm)
            else:
                kill(rt)
        elif op in LOADSTORE:
            if rs in val:
                a = (val[rs] + simm) & 0xFFFFFFFF
                if region(a) not in (None, "RAM", "ROM"):
                    hits.setdefault(a, set()).add(LOADSTORE[op])
            if op < 0x28:                                # a load writes rt
                kill(rt)
        elif op == 0:                                    # R-type: writes rd
            funct = w & 0x3F
            if funct in (0x08, 0x09):                    # jr / jalr ends the run
                val.clear()
            else:
                kill((w >> 11) & 0x1F)
        elif op in (0x02, 0x03):                         # j / jal
            val.clear()
        elif op in (0x04, 0x05, 0x06, 0x07, 0x01):       # branches: keep, the target may use it
            pass
        elif op == 0x10:                                 # cop0: mfc0 writes rt
            if not (w & (1 << 25)) and rs in (0, 4):
                kill(rt)
        else:
            kill(rt)
    return hits


def cmd_hw(rom, args):
    names = args.hw if args.hw != ["*"] else [f[0] for f in rom.files]
    for name in names:
        blob = rom.read(name)
        if blob is None:
            print(f"{name}: not in this ROM")
            continue
        hits = scan_hw(blob)
        by_region = {}
        for a, ops in hits.items():
            by_region.setdefault(region(a), []).append((a, ops))
        print(f"\n== {name}  ({len(blob)} bytes)  {rom.extinfo(name).get('comment', '')}")
        if not hits:
            print("   no peripheral access found")
        for r in sorted(by_region, key=lambda r: min(a for a, _ in by_region[r])):
            addrs = sorted(by_region[r])
            print(f"   {r:<10} {len(addrs):3d} addresses")
            for a, ops in addrs:
                print(f"      0x{a:08X}  {' '.join(sorted(ops))}")



# --- IRX modules -------------------------------------------------------------

def irx_sections(blob):
    """{section name: (offset, size, addr)} for an IRX (ELF) module."""
    if blob[:4] != b"\x7fELF":
        return {}
    e_shoff, = struct.unpack_from("<I", blob, 0x20)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", blob, 0x2E)
    strtab = struct.unpack_from("<10I", blob, e_shoff + e_shstrndx * e_shentsize)[4]
    out = {}
    for i in range(e_shnum):
        f = struct.unpack_from("<10I", blob, e_shoff + i * e_shentsize)
        end = blob.index(b"\0", strtab + f[0])
        out[blob[strtab + f[0]:end].decode("latin-1")] = (f[4], f[5], f[3])
    return out


def irx_info(blob):
    """The .iopmod header: the module's own name, entry, gp and segment sizes.

    This is the name the IOP kernel knows a module by, and it is also the
    string LOADCORE leaves in the module's .rodata once the module is in RAM,
    which is what iop_ram_map.py looks for in a memory dump.
    """
    secs = irx_sections(blob)
    if ".iopmod" not in secs:
        return None
    off = secs[".iopmod"][0]
    mi, entry, gp, text, data, bss = struct.unpack_from("<6I", blob, off)
    version, = struct.unpack_from("<H", blob, off + 24)
    name = blob[off + 26:].split(b"\0")[0].decode("latin-1")
    return {"name": name, "entry": entry, "gp": gp, "text": text, "data": data,
            "bss": bss, "version": version, "moduleinfo": mi, "sections": secs}


def cmd_irx(rom, args):
    for name in args.irx:
        blob = rom.read(name)
        if blob is None:
            print(f"{name}: not in this ROM")
            continue
        info = irx_info(blob)
        if info is None:
            print(f"{name}: not an IRX module ({len(blob)} bytes)")
            continue
        print(f"\n== {name}  ->  {info['name']}  v{info['version'] >> 8}.{info['version'] & 0xFF:02x}")
        print(f"   entry 0x{info['entry']:x}  gp 0x{info['gp']:x}  "
              f"text {info['text']}  data {info['data']}  bss {info['bss']}  "
              f"(loaded size {info['text'] + info['data'] + info['bss']})")
        for sec, (off, size, addr) in info["sections"].items():
            if sec:
                print(f"   {sec:<12} off 0x{off:06x}  size {size:7d}")


def cmd_compare(paths, args):
    roms = []
    for p in sorted(paths):
        try:
            roms.append(Rom(p))
        except SystemExit as e:
            print(e, file=sys.stderr)
    print(f"{'file':<32} {'ROMVER':<20} {'files':>5} {'IOPBOOT':>8} {'modules':>8}")
    base = None
    for r in roms:
        conf = r.read("IOPBTCONF")
        mods = [l.strip() for l in (conf or b"").decode("latin-1").splitlines()
                if l.strip() and not l.startswith(("#", "@"))]
        ib = r.by_name.get("IOPBOOT")
        print(f"{os.path.basename(r.path):<32} {r.romver():<20} {len(r.files):5d} "
              f"{('0x%05x' % ib[1]) if ib else '-':>8} {len(mods):8d}")
        if base is None:
            base = (r, set(mods))
        elif set(mods) != base[1]:
            only = set(mods) - base[1]
            miss = base[1] - set(mods)
            if only:
                print(f"    + {' '.join(sorted(only))}")
            if miss:
                print(f"    - {' '.join(sorted(miss))}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("rom", help="a rom0 image, or a directory of them with --compare")
    ap.add_argument("--list", action="store_true", help="every file in the ROM")
    ap.add_argument("--boot", action="store_true", help="the IOPBTCONF module list IOPBOOT loads")
    ap.add_argument("--hw", nargs="+", metavar="NAME", help="peripheral addresses a module touches ('*' for all)")
    ap.add_argument("--irx", nargs="+", metavar="NAME", help="a module's IRX header: its kernel name, entry, gp, segment sizes")
    ap.add_argument("--extract", metavar="NAME")
    ap.add_argument("--out", default=".")
    ap.add_argument("--compare", action="store_true", help="ROMVER and module set across a directory of dumps")
    a = ap.parse_args()

    if a.compare:
        paths = ([os.path.join(a.rom, f) for f in os.listdir(a.rom) if f.endswith(".bin")]
                 if os.path.isdir(a.rom) else [a.rom])
        return cmd_compare(paths, a)

    rom = Rom(a.rom)
    if a.extract:
        blob = rom.read(a.extract)
        if blob is None:
            raise SystemExit(f"no such file in ROM: {a.extract}")
        p = os.path.join(a.out, a.extract)
        open(p, "wb").write(blob)
        print(f"{a.extract}: {len(blob)} bytes -> {p}")
        return
    if a.irx:
        return cmd_irx(rom, a)
    if a.hw:
        return cmd_hw(rom, a)
    if a.boot:
        return cmd_boot(rom, a)
    return cmd_list(rom, a)


if __name__ == "__main__":
    main()
