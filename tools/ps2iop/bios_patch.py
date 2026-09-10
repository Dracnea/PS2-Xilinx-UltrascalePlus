#!/usr/bin/env python3
"""Redirect a PS2 BIOS's printf output to SIO1, so the host can read it.

    tools/ps2iop/bios_patch.py rom0.bin rom0-tty.bin
    tools/ps2iop/bios_patch.py rom0.bin --check

A retail BIOS formats its messages into a buffer and flushes them through IOMAN
to file descriptor 1.  Nothing is bound to that descriptor on a console with no
EE, so every module's boot message is discarded and the IOP's serial port stays
silent -- which is why `iopcon.py` reads nothing from a stock image.

This replaces the kernel's character sink with eight instructions that store
each character straight to SIO1's data register at 0x1F801050, where
`rtl/iop/iop_console.vhd` picks it up:

    sltiu $v0,$a1,0x100     ; a real character, not one of the sink's
    beq   $v0,$zero,skip    ; control codes (512, 513)
    nop
    lui   $v0,0x1F80
    ori   $v0,$v0,0x1050
    sb    $a1,0($v0)        ; SIO1 DATA
    skip: jr $ra
    nop

**This produces a modified BIOS, and results obtained with it must say so.**
The gateware is untouched: no hardware behaviour changes, and the console block
being written to is the one a real IOP has. What changes is the software the
console runs, in the same sense that any custom firmware does -- see
docs/bios-fidelity.md for what that does and does not compromise.

The sink is found by its first six instructions rather than by address, so the
patch either matches exactly once or refuses.
"""
import argparse, struct, sys

# The sink's prologue: addiu sp,-32 / sw s0,16(sp) / addu s0,a0,zero /
# sw s1,20(sp) / addu s1,a1,zero / addiu v0,zero,512
SINK_PROLOGUE = [0x27BDFFE0, 0xAFB00010, 0x00808021, 0xAFB10014, 0x00A08821, 0x24020200]

PATCH = [
    0x2CA20100,   # sltiu $v0,$a1,0x100
    0x10400004,   # beq   $v0,$zero,+4  -> the jr
    0x00000000,   # nop
    0x3C021F80,   # lui   $v0,0x1F80
    0x34421050,   # ori   $v0,$v0,0x1050
    0xA0450000,   # sb    $a1,0($v0)
    0x03E00008,   # jr    $ra
    0x00000000,   # nop
]


def find_sink(rom):
    pat = b"".join(struct.pack("<I", x) for x in SINK_PROLOGUE)
    hits, off = [], rom.find(pat)
    while off != -1:
        hits.append(off)
        off = rom.find(pat, off + 1)
    return hits


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("rom")
    ap.add_argument("out", nargs="?")
    ap.add_argument("--check", action="store_true", help="report the site and change nothing")
    a = ap.parse_args()

    rom = bytearray(open(a.rom, "rb").read())
    hits = find_sink(rom)
    if len(hits) != 1:
        sys.exit(f"expected exactly one character sink, found {len(hits)}: "
                 f"{[hex(h) for h in hits]}. Refusing to guess which.")
    off = hits[0]
    print(f"character sink at ROM offset 0x{off:06x}")
    if a.check:
        print("  " + " ".join("%08x" % x for x in
              struct.unpack("<8I", bytes(rom[off:off + 32]))))
        return 0
    if not a.out:
        sys.exit("give an output file, or --check")

    rom[off:off + 32] = b"".join(struct.pack("<I", x) for x in PATCH)
    open(a.out, "wb").write(bytes(rom))
    print(f"wrote {a.out}: printf now goes to SIO1 and the host can read it")
    print("NOTE: this is a modified BIOS. Say so wherever a result depends on it.")
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
