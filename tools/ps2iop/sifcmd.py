#!/usr/bin/env python3
"""Speak SIFCMD to the IOP, as the Emotion Engine would.

    tools/ps2iop/sifcmd.py init [--eebuf 0x00100000]
    tools/ps2iop/sifcmd.py send --cid 0x80000002 [--opt 0] [--word W]...
    tools/ps2iop/sifcmd.py watch [--seconds 2]

SIFCMD is the layer above the SIF DMA channels.  A packet is a 16-byte header

    word 0   psize in bits 0-7, dsize in bits 8-31
    word 1   dest -- where the IOP should put the payload, or 0 for none
    word 2   cid  -- which handler to run
    word 3   opt  -- the handler's own field

followed by that handler's arguments (ps2sdk sifcmd-common.h).  `psize` counts
the header and the arguments together; `dsize` is a separate bulk payload that
this tool does not use.

The packet goes to the IOP address it published in SMCOM, which for the 0220A
BIOS is 0x19600.  SIF DMA moves quadwords, so a 20-byte packet is padded to 32:
the tag's word count has its low two bits dropped by the hardware, and a count
that is not a multiple of four would lose the tail.

`init` sends SIF_CMD_INIT_CMD, whose argument is the EE's own receive buffer
address -- the other half of the exchange that starts with the IOP publishing
its buffer in SMCOM.  There is no EE here, so the address is a fiction the host
maintains; what matters is whether the IOP accepts it and answers.
"""
import argparse, os, struct, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sif1 import Card, tag

SIF_CMD_CHANGE_SADDR = 0x80000000
SIF_CMD_SET_SREG     = 0x80000001
SIF_CMD_INIT_CMD     = 0x80000002
SIF_CMD_RESET_CMD    = 0x80000003
SIF_CMD_RPC_END      = 0x80000008
SIF_CMD_RPC_BIND     = 0x80000009
SIF_CMD_RPC_CALL     = 0x8000000A
SIF_CMD_RPC_RDATA    = 0x8000000C

NAMES = {v: k for k, v in globals().items() if k.startswith("SIF_CMD_")}


def header(psize, dsize, dest, cid, opt):
    return [(psize & 0xFF) | ((dsize & 0xFFFFFF) << 8), dest, cid, opt]


def send(card, iopbuf, words, quiet=False):
    """Pad to a quadword and hand it to the IOP through SIF1."""
    padded = list(words) + [0] * (-len(words) % 4)
    card.push(tag(iopbuf, len(padded)))
    card.push(padded)
    if not quiet:
        print(f"  sent {len(words)} words (padded to {len(padded)}) to IOP 0x{iopbuf:06x}")
    return len(padded)


def drain(card, limit=64):
    out = []
    while card.rd("iop_sif0_stat") & 1 and len(out) < limit:
        out.append(card.rd("iop_sif0_pop"))
    return out


SREGS = {0: "RPCINIT"}


def decode(words):
    """What comes out of SIF0 is the EE's own DMA tag and then the packet.

    Channel 9 forwards four words from TADR+8 before the payload, so the first
    thing in the stream is not the SIFCMD header -- it is the tag the IOP built
    for the EE's DMA controller, and its second word is where the EE is meant to
    put what follows.  Reading those four as a header decodes nonsense that
    looks almost plausible, which is worse than failing outright.
    """
    if len(words) < 8:
        return f"  (only {len(words)} words: a tag and a packet need at least 8)"
    qwc, eedest = words[0] & 0xFFFF, words[1]
    lines = [f"  EE tag: qwc={qwc} ({qwc * 4} words) -> EE address 0x{eedest:08x}",
             f"          {' '.join(f'{w:08x}' for w in words[:4])}"]
    p = words[4:]
    psize, dsize, dest, cid, opt = p[0] & 0xFF, p[0] >> 8, p[1], p[2], p[3]
    name = NAMES.get(cid, "unknown")
    lines.append(f"  packet: psize={psize} dsize={dsize} dest=0x{dest:08x} "
                 f"cid=0x{cid:08x} ({name}) opt=0x{opt:08x}")
    args = p[4:]
    if args:
        lines.append("          args: " + " ".join(f"{w:08x}" for w in args))
    if cid == SIF_CMD_SET_SREG and len(args) >= 2:
        lines.append(f"          -> SREG[{args[0]}] "
                     f"({SREGS.get(args[0], '?')}) = {args[1]}")
    return "\n".join(lines)


def snapshot(card):
    """Everything the IOP could answer with, in one look."""
    st = {}
    for c in (9, 10):
        card.wr("iop_dma_dbg_sel", c)
        st[c] = (card.rd("iop_dma_dbg_chcr"), card.rd("iop_dma_dbg_madr"),
                 card.rd("iop_dma_dbg_tadr"))
    st["sif0_tags"] = card.rd("iop_sif0_tags")
    st["sif1_tags"] = card.rd("iop_sif1_tags")
    st["sif0_readable"] = card.rd("iop_sif0_stat") & 1
    return st


def report(card, label):
    s = snapshot(card)
    print(f"  {label}")
    for c in (9, 10):
        chcr, madr, tadr = s[c]
        print(f"    ch{c:<3d} CHCR={chcr:08x}{'  ARMED' if chcr & 0x01000000 else '':8s}"
              f" MADR={madr:08x} TADR={tadr:08x}")
    print(f"    tags sent by the IOP={s['sif0_tags']}  received={s['sif1_tags']}"
          f"  stream has data={s['sif0_readable']}")
    return s


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--csr", default="build/c1100_ps2_iop/csr.csv")
    ap.add_argument("--dev", default="/dev/litepcie0")
    ap.add_argument("--iopbuf", type=lambda x: int(x, 0), default=None,
                    help="IOP receive buffer; default is whatever SMCOM says")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("init"); p.add_argument("--eebuf", type=lambda x: int(x, 0), default=0x00100000)
    p = sub.add_parser("send")
    p.add_argument("--cid", type=lambda x: int(x, 0), required=True)
    p.add_argument("--opt", type=lambda x: int(x, 0), default=0)
    p.add_argument("--dest", type=lambda x: int(x, 0), default=0)
    p.add_argument("--word", type=lambda x: int(x, 0), action="append", default=[])
    p = sub.add_parser("watch"); p.add_argument("--seconds", type=float, default=2.0)
    a = ap.parse_args()
    c = Card(a.csr, a.dev)

    iopbuf = a.iopbuf if a.iopbuf is not None else c.rd("iop_sif_smcom")
    if a.cmd != "watch":
        print(f"IOP receive buffer: 0x{iopbuf:06x}"
              f"{' (from SMCOM)' if a.iopbuf is None else ''}")
        if not iopbuf:
            sys.exit("SMCOM is zero: the IOP has not published a buffer, so it is not ready")

    if a.cmd == "watch":
        t0 = time.time()
        while time.time() - t0 < a.seconds:
            if c.rd("iop_sif0_stat") & 1:
                print("packet from the IOP:")
                print(decode(drain(c)))
                return 0
            time.sleep(0.005)
        print("nothing came back")
        return 0

    if a.cmd == "init":
        pkt = header(20, 0, 0, SIF_CMD_INIT_CMD, 0) + [a.eebuf]
        print(f"SIF_CMD_INIT_CMD, telling the IOP the EE's buffer is 0x{a.eebuf:08x}")
    else:
        args = a.word
        pkt = header(16 + 4 * len(args), 0, a.dest, a.cid, a.opt) + args
        print(f"cid 0x{a.cid:08x} ({NAMES.get(a.cid,'unknown')})")

    before = report(c, "before:")
    send(c, iopbuf, pkt)
    time.sleep(0.3)
    after = report(c, "after:")

    if after["sif0_tags"] > before["sif0_tags"] or after["sif0_readable"]:
        print("\nthe IOP answered:")
        print(decode(drain(c)))
    elif after[9][0] & 0x01000000:
        print("\nchannel 9 is armed: the IOP is preparing a reply")
    else:
        print("\nno reply. The packet was delivered -- received tags went "
              f"{before['sif1_tags']} -> {after['sif1_tags']} -- and the IOP did not send.")
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
