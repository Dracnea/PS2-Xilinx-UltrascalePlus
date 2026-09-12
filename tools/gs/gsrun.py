#!/usr/bin/env python3
"""Run a GIF stream on the card and diff the result against sim/gs/gs_ref.py.

    tools/gs/gsrun.py --csr build/c1100_gs/csr.csv --prog stream.hex
    tools/gs/gsrun.py --csr build/c1100_gs/csr.csv --prog stream.hex --dump 0 512

This is the same comparison sim/gs/run_diff.sh makes, against the same reference,
with the card standing in for the simulator.  That is the whole point of the
board target: everything the Graphics Synthesizer does has been checked against
gs_ref.py in simulation, and the question this answers is what that is worth on
silicon.

A quadword goes out as four CSR writes and a push.  That is slow -- a few
thousand quadwords is a few thousand round trips -- and it is the right trade
for a bring-up, because it needs no DMA engine to be correct before the thing
being tested can be tested at all.  `busy` has to be polled between pushes: the
GIF holds its ready line low for as long as a primitive takes to draw, which for
a large sprite is thousands of cycles.

Local memory reads back one 256-bit word at a time through a second window,
which is what lets the host compute the very checksum gs_ref.py prints.
"""
import argparse, fcntl, os, struct, sys, time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "sim", "gs"))

LITEPCIE_IOCTL_REG = (3 << 30) | (12 << 16) | (ord("S") << 8) | 0
VM_WORDS = 4 * 1024 * 1024 // 4          # the GS's 4 MB, in 32-bit words


def regs_from_csv(path):
    regs = {}
    with open(path) as f:
        for line in f:
            p = line.strip().split(",")
            if p and p[0] == "csr_register":
                regs[p[1]] = (int(p[2], 0), int(p[3]))
    return regs


class Card:
    def __init__(self, dev, csr):
        self.fd = os.open(dev, os.O_RDWR)
        self.regs = regs_from_csv(csr)

    def rd(self, name):
        addr, _ = self.regs[name]
        return struct.unpack("IIB3x", fcntl.ioctl(
            self.fd, LITEPCIE_IOCTL_REG, struct.pack("IIB3x", addr, 0, 0)))[1]

    def wr(self, name, val):
        addr, _ = self.regs[name]
        fcntl.ioctl(self.fd, LITEPCIE_IOCTL_REG,
                    struct.pack("IIB3x", addr, val & 0xFFFFFFFF, 1))


    def check_link(self):
        """Refuse to report anything off a dead PCIe link.

        A card that was JTAG-programmed and not re-enumerated answers every
        register with 0xFFFFFFFF and raises no error.  Read as pixel data that
        is a white frame; read as a checksum it is a mismatch that looks like a
        Graphics Synthesizer bug.  Two patterns, because a stuck-high bus
        passes a test that only writes ones.
        """
        for probe in (0xA5A55A5A, 0x0F0FF0F0):
            self.wr("ctrl_scratch", probe)
            got = self.rd("ctrl_scratch")
            if got != probe:
                msg = (f"the PCIe link is not answering: wrote 0x{probe:08x}, "
                       f"read 0x{got:08x}")
                if got == 0xFFFFFFFF:
                    msg += ("\n  all ones is the signature of a card that was "
                            "JTAG-programmed and not re-enumerated;"
                            "\n  run: sudo tools/pcie-bringup.sh c1100_gs")
                raise SystemExit("FAIL  " + msg)
        self.wr("ctrl_scratch", 0x12345678)      # LiteX's reset value, put back

    # ---- the GS ---------------------------------------------------------
    def reset(self):
        self.wr("gs_reset", 1)
        self.wr("gs_reset", 0)

    def push(self, qw, timeout=5.0):
        """One GIF quadword.  Waits for the previous one to be taken first."""
        end = time.time() + timeout
        while self.rd("gs_status") & 1:              # busy
            if time.time() > end:
                raise TimeoutError("the GIF never took the previous quadword")
        for i in range(4):
            self.wr(f"gs_gif_w{i}", (qw >> (32 * i)) & 0xFFFFFFFF)
        self.wr("gs_gif_push", 1)

    def drain(self, timeout=10.0):
        """Wait until the GS is *idle*, not merely until the last push was taken.

        `busy` falls when the GIF accepts a quadword, which for a quadword that
        kicks a primitive is long before the primitive is drawn -- the GIF holds
        its ready line low for the whole of it.  Waiting on `busy` alone reports
        a 4 MB clear as finishing in no measurable time, then resets the GS in
        the middle of it and reads the pixel count before the drawing has
        happened.  Both of those looked like the card disagreeing with the
        model.

        Idle is `busy` clear *and* `ready` set: nothing pushed and nothing being
        drawn.
        """
        end = time.time() + timeout
        while True:
            st = self.rd("gs_status")
            if (st & 1) == 0 and (st & 2) != 0:
                return
            if time.time() > end:
                raise TimeoutError(f"the GS is still working (status {st:#x})")

    def read_word(self, addr, timeout=1.0):
        """One 256-bit word of local memory."""
        self.wr("gs_rd_addr", addr)
        end = time.time() + timeout
        while not (self.rd("gs_status") & 4):        # rd_done
            if time.time() > end:
                raise TimeoutError(f"no answer reading word {addr}")
        v = 0
        for i in range(8):
            v |= self.rd(f"gs_rd_d{i}") << (32 * i)
        return v


def clear_stream():
    """A GIF stream that writes zero over the whole of local memory.

    The card keeps its 4 MB across `gs_reset` -- a reset clears the logic, not
    the UltraRAM -- while gs_ref.py starts every run with the memory zeroed.
    So the second stream of a session disagrees with the model everywhere the
    first one drew, and the values give it away: they are the previous test's
    colour, blended under the new one.  Simulation never shows this because it
    starts fresh each time.

    Clearing needs no host write port and no rebuild.  One sprite at page 0
    with FBW = 16, covering 1024 x 1024 pixels of PSMCT32, is exactly 512 pages
    -- the whole of local memory, once.  At roughly a pixel a cycle it is about
    eight milliseconds.
    """
    def tag(nloop, eop, regs, nreg):
        return nloop | (eop << 15) | ((nreg & 15) << 60) | (regs << 64)
    items = [
        (0x4C, 0 | (16 << 16) | (0 << 24)),                   # FRAME_1: page 0, 1024 wide
        (0x18, 0),                                            # XYOFFSET_1
        (0x40, 0 | (1023 << 16) | (0 << 32) | (1023 << 48)),  # SCISSOR_1
        (0x42, 0), (0x46, 1),
        (0x4E, 0 | (1 << 32)),                                # ZBUF_1, ZMSK=1: depth untouched
        (0x47, (1 << 16) | (1 << 17)),                        # TEST_1: ALWAYS
        (0x01, 0),                                            # RGBAQ: zero
        (0x00, 6),                                            # PRIM: sprite, no blending
    ]
    regs = 0
    for i in range(len(items)):
        regs |= 0xE << (4 * i)
    out = [tag(1, 0, regs, len(items))]
    for a, d in items:
        out.append((d & ((1 << 64) - 1)) | (a << 64))
    out.append(tag(1, 1, 0xEE, 2))
    out.append((0 | (0 << 16)) | (0x05 << 64))
    out.append((1024 << 4) | ((1024 << 4) << 16) | (0x05 << 64))
    return out


def fnv1a(data):
    """The checksum gs_ref.py prints, over the whole 4 MB."""
    h = 0x811C9DC5
    for b in data:
        h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF
    return h


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dev", default="/dev/litepcie0")
    ap.add_argument("--csr", required=True)
    ap.add_argument("--prog", required=True, help="a GIF stream, one quadword per line")
    ap.add_argument("--dump", nargs=2, type=lambda x: int(x, 0), default=[0, 256],
                    metavar=("FROM", "LEN"), help="bytes of local memory to compare in detail")
    ap.add_argument("--no-clear", action="store_true",
                    help="skip clearing local memory first (it survives gs_reset)")
    ap.add_argument("--whole", action="store_true",
                    help="read all 4 MB back and compare the checksum too (slow)")
    a = ap.parse_args()

    qwords = [int(l.split("//")[0].strip(), 16)
              for l in open(a.prog) if l.split("//")[0].strip()]

    import gs_ref
    gs = gs_ref.GS()
    at = 0
    while at < len(qwords):
        nxt = gs.gif_packet(qwords, at)
        if nxt <= at:
            break
        at = nxt

    card = Card(a.dev, a.csr)
    card.check_link()
    card.reset()
    if not a.no_clear:
        # The card's memory survives a reset and the model's does not, so they
        # have to be made to agree before anything is compared.
        t = time.time()
        for qw in clear_stream():
            card.push(qw)
        card.drain(timeout=30.0)
        print(f"cleared 4 MB of local memory in {time.time()-t:.2f}s")
        card.reset()
    t0 = time.time()
    for qw in qwords:
        card.push(qw)
    card.drain()
    dt = time.time() - t0
    print(f"fed {len(qwords)} quadwords in {dt:.1f}s "
          f"({len(qwords)/max(dt,1e-9):.0f}/s)")

    pixels = card.rd("gs_pixels")
    unknown = card.rd("gs_unknown")
    print(f"card: {pixels} pixels drawn, {unknown} writes to undefined registers")
    print(f"model: {gs.pixels} pixels drawn")
    bad = 0
    if pixels != gs.pixels:
        print("MISMATCH pixels drawn -- a primitive that drew nothing, or too much")
        bad += 1

    # the registers, which cost nothing to check and catch a decode fault
    for r in range(0x00, 0x80):
        card.wr("gs_dbg_sel", r)
        v = card.rd("gs_dbg_lo") | (card.rd("gs_dbg_hi") << 32)
        # gs_ref keeps only the addresses the manual defines, and the card has
        # all 128 -- so an undefined one reads 0 from the model, which is also
        # what it must read from the card: a write to an address the manual does
        # not define has to leave every register alone.  `.get` is how the
        # reference's own --raw dump prints them.
        want = gs.reg.get(r, 0)
        if v != want:
            print(f"MISMATCH register {r:02x}: card {v:016x} model {want:016x}")
            bad += 1

    base, ln = a.dump
    for w in range(base // 32, (base + ln + 31) // 32):
        got = card.read_word(w)
        want = int.from_bytes(bytes(gs.vm[w * 32:(w + 1) * 32]), "little")
        if got != want:
            print(f"MISMATCH word {w:05x} (byte {w*32:08x}):")
            print(f"  card  {got:064x}")
            print(f"  model {want:064x}")
            bad += 1

    if a.whole:
        # 131072 reads; minutes, not seconds, but it is the same checksum the
        # simulation prints and so the same comparison exactly.
        print("reading all 4 MB back...")
        buf = bytearray(4 * 1024 * 1024)
        for w in range(VM_WORDS // 8):
            buf[w*32:(w+1)*32] = card.read_word(w).to_bytes(32, "little")
        h_card, h_model = fnv1a(buf), fnv1a(bytes(gs.vm))
        print(f"VMSUM card {h_card:08x} model {h_model:08x}")
        if h_card != h_model:
            bad += 1

    print("\n" + ("the card agrees with the model" if bad == 0
                  else f"{bad} disagreements -- the card is the one that is right"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
