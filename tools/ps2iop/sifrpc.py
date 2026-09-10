#!/usr/bin/env python3
"""Bind to an RPC service on the IOP, as the Emotion Engine would.

    tools/ps2iop/sifrpc.py bind [--sid 0x80000001]
    tools/ps2iop/sifrpc.py raw --cid 0x80000009 --word W ...

SIFRPC sits on top of SIFCMD: an RPC packet *is* a SIFCMD packet whose cid is
one of the RPC ones and whose body is 64 bytes rather than the usual 16-24.

    words 0-3    the SIFCMD header, psize = 64
    word  4      rec_id -- 0x04 marks an RPC packet, 0x01 that it was allocated
    word  5      pkt_addr, where the packet lives in EE memory
    word  6      rpc_id, the EE's own sequence number, echoed back
    word  7      cd, the EE's client-data structure
    word  8      sid for a bind; rpc_number for a call

There is no EE, so `pkt_addr` and `cd` are addresses in a fiction the host
keeps. They matter anyway: the IOP echoes them back, and a reply that quotes
the wrong one is a reply to somebody else.

A successful bind answers with the service's buffers in *IOP* memory. Those are
what a call writes its arguments into, so binding is not a handshake to get past
-- it is how the address for everything after it is learnt.
"""
import argparse, os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sif1 import Card, tag
from sifcmd import (header, send, drain, SIF_CMD_RPC_BIND, SIF_CMD_RPC_CALL,
                    SIF_CMD_RPC_END, NAMES)

RPC_PACKET_SIZE = 64                      # RPC_PACKET_SIZE in ps2sdk
PACKET_F_ALLOC  = 0x01
REC_ID_RPC      = 0x04

FILEIO_SID = 0x80000001

# The fiction: where the EE's own structures would live if there were an EE.
EE_BUF      = 0x00ABC000
EE_PKT_ADDR = 0x00ABC100
EE_CLIENT   = 0x00ABC200
EE_RECV     = 0x00ABC300


def bind_packet(sid, rpc_id, cd=EE_CLIENT, pkt_addr=EE_PKT_ADDR):
    w = header(RPC_PACKET_SIZE, 0, 0, SIF_CMD_RPC_BIND, 0)
    w += [REC_ID_RPC | PACKET_F_ALLOC, pkt_addr, rpc_id, cd, sid]
    return w + [0] * (RPC_PACKET_SIZE // 4 - len(w))


def decode_rend(words):
    """The reply to a bind or a call, once the EE tag is stripped."""
    if len(words) < 12:
        return None, f"  (only {len(words)} words; a rend packet needs 12 after the tag)"
    p = words[4:] if (words[0] & 0xFFFF0000) == 0x90000000 else words
    if len(p) < 12:
        return None, "  (packet too short after the EE tag)"
    out = dict(psize=p[0] & 0xFF, dsize=p[0] >> 8, dest=p[1], cmd=p[2], opt=p[3],
               rec_id=p[4], pkt_addr=p[5], rpc_id=p[6], cd=p[7],
               cid=p[8], sd=p[9], buf=p[10], cbuf=p[11])
    lines = [f"  cmd=0x{out['cmd']:08x} ({NAMES.get(out['cmd'],'unknown')}) "
             f"psize={out['psize']}",
             f"  echoed: rpc_id={out['rpc_id']} cd=0x{out['cd']:08x} "
             f"pkt_addr=0x{out['pkt_addr']:08x}",
             f"  for cid=0x{out['cid']:08x} ({NAMES.get(out['cid'],'unknown')})",
             f"  server: sd=0x{out['sd']:08x} buf=0x{out['buf']:08x} cbuf=0x{out['cbuf']:08x}"]
    return out, "\n".join(lines)


def await_reply(card, seconds=1.0):
    t0 = time.time()
    while time.time() - t0 < seconds:
        if card.rd("iop_sif0_stat") & 1:
            time.sleep(0.05)                 # let the whole packet land
            return drain(card)
        time.sleep(0.005)
    return []


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--csr", default="build/c1100_ps2_iop/csr.csv")
    ap.add_argument("--dev", default="/dev/litepcie0")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("bind")
    p.add_argument("--sid", type=lambda x: int(x, 0), default=FILEIO_SID)
    p.add_argument("--rpc-id", type=int, default=1)
    a = ap.parse_args()
    c = Card(a.csr, a.dev)

    iopbuf = c.rd("iop_sif_smcom")
    if not iopbuf:
        sys.exit("SMCOM is zero: the IOP has not published a buffer")
    print(f"IOP command buffer 0x{iopbuf:06x}")

    # Anything already in the stream is from an earlier exchange.
    stale = drain(c)
    if stale:
        print(f"  (drained {len(stale)} stale words first)")

    pkt = bind_packet(a.sid, a.rpc_id)
    print(f"SIF_CMD_RPC_BIND, sid=0x{a.sid:08x}, cd=0x{EE_CLIENT:08x}, rpc_id={a.rpc_id}")
    send(c, iopbuf, pkt)

    words = await_reply(c)
    if not words:
        print("\nno reply.")
        c.wr("iop_dma_dbg_sel", 9)
        print(f"  ch9 CHCR={c.rd('iop_dma_dbg_chcr'):08x} "
              f"tags sent={c.rd('iop_sif0_tags')}")
        return 1
    print(f"\nreply, {len(words)} words:")
    out, text = decode_rend(words)
    print(text)
    if out and out["cid"] == SIF_CMD_RPC_BIND:
        if out["buf"]:
            print(f"\nbound. Arguments for a call go to IOP 0x{out['buf']:08x}, "
                  f"server data 0x{out['sd']:08x}")
            return 0
        print("\nthe service replied with a null buffer: bound to nothing, "
              "which is what an unknown sid looks like")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
