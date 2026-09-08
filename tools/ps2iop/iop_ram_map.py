#!/usr/bin/env python3
"""Read a dump of the IOP's RAM and say how far the BIOS got.

    tools/ps2iop/iop_ram_map.py ram.bin --rom /path/to/rom0.bin [--verbose]

A retail PS2 BIOS prints nothing: no module in any rom0 dump here writes to
the IOP's serial port, so the console FIFO in the diagnostic image stays empty
and the POST register only moves when THREADMAN is running. What the boot
does leave behind is RAM, and that is the evidence this reads.

IOPBOOT copies each module IOPBTCONF names into RAM - .text, .rodata and
.data, relocated - and starts it. Relocation rewrites instructions, but the
module's own name string in .rodata (the one in its .iopmod header, e.g.
"Multi_Thread_Manager") is never relocated, so finding that string in the dump
is good evidence the module was loaded. Reported in IOPBTCONF order, the last
one present is where the boot stopped.

The dump comes from the peek port:

    tools/ps2iop/iop_post.py --csr <image>.csr.csv reset hold
    tools/ps2iop/iop_post.py --csr <image>.csr.csv dump ram.bin
"""
import argparse, os, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from romdir import Rom, irx_info


def boot_modules(rom):
    conf = rom.read("IOPBTCONF")
    if conf is None:
        raise SystemExit("no IOPBTCONF in this ROM")
    return [l.strip() for l in conf.decode("latin-1").splitlines()
            if l.strip() and not l.startswith(("#", "@"))]



def relocated_bytes(blob, secs, sec):
    """Byte offsets inside `sec` that the loader rewrites, from its .rel table.

    An IRX relocation's r_offset is module-relative, not section-relative -
    LOADCORE's .rodata sits at module address 0x1c30 and its relocations name
    0x1c40 upward - so the section's sh_addr has to come off before the offset
    means anything here. Getting that wrong excludes nothing, which makes a
    "signature" that includes the very bytes the loader rewrites and therefore
    never matches a loaded module.
    """
    rel = secs.get(".rel" + sec)
    base = secs[sec][2]
    out = set()
    if rel:
        off, size = rel[0], rel[1]
        for i in range(off, off + size - 7, 8):
            where, _info = struct.unpack_from("<II", blob, i)
            out.update(range(where - base, where - base + 4))
    return out


def signature(blob, info, minlen=16):
    """A run of bytes the loader does not rewrite, and where it lands in RAM.

    Relocation changes instructions and pointers, so the only bytes that
    survive a load unchanged are the ones no relocation entry names. The
    longest such run in .rodata (strings, jump tables' constant parts) is a
    reliable fingerprint, and .text is the fallback for a module with no
    .rodata. Returns (bytes, offset within the loaded image) or None.
    """
    text = info["sections"].get(".text")
    if not text:
        return None
    best = None
    for sec in (".rodata", ".data", ".text"):
        s = info["sections"].get(sec)
        if not s or s[1] < minlen:
            continue
        off, size, addr = s
        moved = relocated_bytes(blob, info["sections"], sec)
        run_start = None
        for i in range(size + 1):
            clean = i < size and i not in moved
            if clean and run_start is None:
                run_start = i
            elif not clean and run_start is not None:
                if (best is None or i - run_start > len(best[0])) and i - run_start >= minlen:
                    # sh_addr is the module-relative address, which is exactly
                    # the offset the byte has in the loaded image
                    best = (blob[off + run_start:off + i], addr + run_start)
                run_start = None
        if best and len(best[0]) >= 32:
            break
    return best


def find_all(hay, needle):
    at, out = hay.find(needle), []
    while at >= 0 and len(out) < 8:
        out.append(at)
        at = hay.find(needle, at + 1)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dump", help="the IOP RAM image (2 MB from address 0)")
    ap.add_argument("--rom", required=True, help="the rom0 image that was booted")
    ap.add_argument("--verbose", action="store_true", help="also list what is in RAM outside the modules")
    a = ap.parse_args()

    ram = open(a.dump, "rb").read()
    rom = Rom(a.rom)
    mods = boot_modules(rom)

    print(f"{a.dump}: {len(ram)} bytes of IOP RAM")
    print(f"{a.rom}: ROMVER {rom.romver()}, {len(mods)} modules in IOPBTCONF\n")
    # "loaded at" is where the signature landed minus its offset in the module,
    # so it is the module's base only while its sections sit contiguously, which
    # is how IOPBOOT lays them out; treat it as indicative, not as an address to
    # branch to. Presence and the order of presence are the reliable part.
    print(f"{'#':>3}  {'module':<12} {'kernel name':<24} {'loaded at':>10}  size")
    found = {}
    for i, name in enumerate(mods, 1):
        blob = rom.read(name)
        info = irx_info(blob) if blob else None
        if info is None:
            print(f"{i:>3}  {name:<12} {'(not an IRX)':<24}")
            continue
        sig = signature(blob, info)
        label = info["name"] or "(no name in .iopmod)"
        if sig is None:
            print(f"{i:>3}  {name:<12} {label:<24} {'no signature':>10}")
            continue
        hits = find_all(ram, sig[0])
        if not hits:
            print(f"{i:>3}  {name:<12} {label:<24} {'-':>10}")
            continue
        found[name] = i
        size = info["text"] + info["data"] + info["bss"]
        bases = sorted(max(h - sig[1], 0) for h in hits)
        where = f"0x{bases[0]:08x}"
        note = f"  ({len(hits)} copies)" if len(hits) > 1 else ""
        print(f"{i:>3}  {name:<12} {label:<24} {where:>10}  {size}{note}")

    # IOPBOOT loads in IOPBTCONF order, so the highest-numbered module present
    # is how far it got. A gap below that is not an absence: a module whose
    # .rodata is entirely relocated, or which carries no distinctive constant,
    # simply cannot be fingerprinted, so "-" means "not detected", never "not
    # loaded". The last one found is the number to quote.
    last = max(found.values()) if found else 0
    print(f"\n{len(found)} of {len(mods)} modules detected in RAM")
    if last:
        print(f"the boot reached at least #{last} {mods[last - 1]}"
              f" ({irx_info(rom.read(mods[last - 1]))['name'] or 'unnamed'})")
    gaps = [f"#{i} {n}" for i, n in enumerate(mods[:last], 1) if n not in found]
    if gaps:
        print(f"not detected below that, so not fingerprintable rather than missing: "
              f"{', '.join(gaps)}")
    if last < len(mods):
        print(f"the boot did not reach #{last + 1} {mods[last]}"
              f" ({irx_info(rom.read(mods[last]))['name'] or 'unnamed'}) — "
              f"that module, or the one before it, is where to look next")
    else:
        print("every module IOPBTCONF names is in RAM")

    if a.verbose:
        print("\nnon-zero RAM regions (16 KB granularity):")
        step = 16384
        for off in range(0, len(ram), step):
            chunk = ram[off:off + step]
            if any(chunk):
                nz = sum(1 for b in chunk if b)
                print(f"   0x{off:08x}  {nz * 100 // len(chunk):3d}% non-zero")


if __name__ == "__main__":
    main()
