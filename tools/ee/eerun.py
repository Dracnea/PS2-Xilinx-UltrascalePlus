#!/usr/bin/env python3
"""Run a program on the R5900 on the card, and say what it did.

    tools/ee/eerun.py --csr build/c1100_ee/csr.csv --clock
    tools/ee/eerun.py --csr build/c1100_ee/csr.csv --prog prog.hex --steps 200
    tools/ee/eerun.py --csr build/c1100_ee/csr.csv --prog prog.hex --compare

It works against both EE images. c1100_ee keeps its memory on the chip and a
CSR window writes it; c1100_ee_hbm has no such window because the memory is HBM,
so the program goes in through the HBM probe on the card's second AXI port.
Which one is present is decided by looking for the window rather than by a flag,
because the csr.csv already says.

**Fixed 2026-09-17.** Loading against c1100_ee_hbm first produced a core that
ran away into undefined instructions, which looked like an EE fault and was
not: ee_ram places the EE's 32 MB at HBM_BASE, 6 GiB into HBM, and this tool was
writing at 0. See "The EE-HBM image on the card" in docs/ee-core.md.

`--clock` measures cd_ee and says whether it is the console's 294.912 MHz.
`--prog` loads a program, releases reset, waits for it to retire `--steps`
instructions, and prints the general registers.
`--compare` then runs the same program through sim/ee/r5900_ref.py and diffs the
final register state -- which is the only form of "it works" worth having: the
card agreeing with the model that every simulation test is checked against.

The register file is read through a snapshot that `cd_ee` refreshes every 64
cycles, so a read is a value the core held recently rather than the value it
holds this instant. For a program that has stopped -- which is what these
programs do, by parking in a branch to themselves -- those are the same thing.
"""
import argparse
import fcntl
import os
import re
import struct
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "sim", "ee"))

LITEPCIE_IOCTL_REG = (3 << 30) | (12 << 16) | (ord("S") << 8) | 0


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

    # A CSR wider than 32 bits occupies several registers, and csr.csv has said
    # so all along -- the word count is its fourth column, which these two read
    # and then discarded.  That was harmless while every CSR here was one word
    # wide and stopped being harmless the moment this tool met the HBM image,
    # whose probe_addr is 33 bits and therefore two: the address went into the
    # *high* word, every write landed somewhere far away, and the writes still
    # answered AXI resp=0 because they were perfectly valid writes to the wrong
    # place.
    #
    # LiteX lays a multi-word CSR out most-significant word first, and a
    # CSRStorage latches when its last word is written, so the words go from low
    # address to high.  tools/ps2iop/iop_post.py has done this correctly since
    # the IOP work; this is the same rule and not a second version of it.
    def readl(self, addr):
        return struct.unpack("IIB3x", fcntl.ioctl(
            self.fd, LITEPCIE_IOCTL_REG, struct.pack("IIB3x", addr, 0, 0)))[1]

    def writel(self, addr, val):
        fcntl.ioctl(self.fd, LITEPCIE_IOCTL_REG,
                    struct.pack("IIB3x", addr, val & 0xFFFFFFFF, 1))

    def rd(self, name):
        addr, n = self.regs[name]
        v = 0
        for i in range(n):
            v = (v << 32) | self.readl(addr + 4 * i)
        return v

    def wr(self, name, val):
        addr, n = self.regs[name]
        for i in range(n):
            self.writel(addr + 4 * i, (val >> (32 * (n - 1 - i))) & 0xFFFFFFFF)

    def check_link(self):
        """Refuse to report anything off a dead PCIe link.

        A card that was JTAG-programmed and not re-enumerated answers every
        register with 0xFFFFFFFF and raises no error. Two patterns, because a
        stuck-high bus passes a test that only writes ones.
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
                            "\n  run: sudo tools/pcie-bringup.sh c1100_ee")
                raise SystemExit("FAIL  " + msg)
        self.wr("ctrl_scratch", 0x12345678)

    # ---- memory, written while the core is held in reset -----------------
    def mem_access(self, addr, wdata=None):
        self.wr("ee_mem_addr", addr)
        self.wr("ee_mem_we", 0 if wdata is None else 1)
        if wdata is not None:
            for i in range(4):
                self.wr(f"ee_mem_w{i}", (wdata >> (32 * i)) & 0xFFFFFFFF)
        while self.rd("ee_status") & 1:
            pass
        self.wr("ee_mem_go", 1)
        while self.rd("ee_status") & 1:
            pass
        v = 0
        for i in range(4):
            v |= self.rd(f"ee_mem_r{i}") << (32 * i)
        return v

    # ---- the same, for an image whose memory is HBM ----------------------
    #
    # c1100_ee_hbm.py keeps the CSR window the same shape as c1100_ee.py's
    # *minus the memory port*, because the memory is no longer on the chip: the
    # core's AXI master goes to HBM and the host reaches the same memory through
    # the HBM probe on a second port.  Everything else here -- reset, pc_reset,
    # retires, the register snapshot -- is identical, so only loading changes.
    #
    # The probe moves one 256-bit beat at a time and costs about ten CSR round
    # trips per beat.  That is slow and is the right trade for this: a test
    # program is a few hundred instructions, and a loader that needed DMA to be
    # correct first could not be used to find out whether the core works.
    #
    # **There is an offset, and missing it costs a night.**  EEWithMemory crosses
    # the core's AXI into the HBM port with nothing but a clock-domain crossing,
    # which is what made "no offset" look obviously true.  The offset is one
    # level further down: ee_ram.vhd carries a generic
    #
    #     HBM_BASE : std_logic_vector(32 downto 0) := "1" & x"80000000"
    #
    # and adds it to every AXI address it issues, so the EE's 32 MB of main
    # memory lives at **6 GiB** in HBM and the core's address 0 is HBM byte
    # address 0x1_8000_0000.  A loader writing at 0 writes 6 GiB away from
    # anything the core will ever fetch -- and every write succeeds, reads back
    # correctly, and answers AXI resp=0, because they are perfectly good writes
    # to a place nothing is looking at.
    #
    # This is read from the RTL rather than written as a constant twice.  Two
    # copies of a base address is exactly the bug above, wearing a different
    # hat.
    BEAT = 32                              # bytes in one 256-bit beat

    def hbm_beat(self, addr, words):
        assert addr % self.BEAT == 0 and len(words) == 8
        self.wr("probe_addr", addr)
        self.wr("probe_ctrl", 0x4)                    # clear the lane pointer
        for w in words:
            self.wr("probe_wdata", w & 0xFFFFFFFF)
        self.wr("probe_ctrl", 0x1)                    # write
        return self.hbm_wait()

    def hbm_read(self, addr):
        assert addr % self.BEAT == 0
        self.wr("probe_addr", addr)
        self.wr("probe_ctrl", 0x2)
        resp = self.hbm_wait()
        out = []
        for lane in range(8):
            self.wr("probe_rlane", lane)
            out.append(self.rd("probe_rdata"))
        return out, resp

    def hbm_wait(self, tries=10000):
        for _ in range(tries):
            s = self.rd("probe_stat")
            if (s >> 1) & 1:                          # done
                return (s >> 2) & 3                   # AXI response
        raise SystemExit(
            "FAIL  the HBM probe never reported done: the AXI clock or the "
            "HBM IP is not running")

    # sim/ee/gen_prog.py aims every load and store at a scratch area at 0x2000,
    # 0x400 bytes of it, so that a random program cannot rewrite its own code.
    # The reference model's memory is sparse and reads zero where nothing has
    # been stored; HBM reads whatever was last in it, which after a power-on or
    # a run of tools/ps2iop/hbm_test.py is neither zero nor the same twice.
    #
    # On the on-chip images this never came up -- that memory comes up zeroed --
    # and it is not a fault in either model.  It is the card and the model
    # starting from different memory, and the only honest fix is to make the
    # card start from the model's.  Clearing through 0x4000 covers the code and
    # the scratch with room to spare, and costs 512 beats.
    CLEAR_BYTES = 0x4000

    @staticmethod
    def hbm_base(root=None):
        """HBM_BASE, read out of rtl/ee/ee_ram.vhd."""
        if root is None:
            root = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..")
        src = os.path.join(root, "rtl", "ee", "ee_ram.vhd")
        pat = re.compile(r'HBM_BASE\s*:\s*std_logic_vector\([^)]*\)\s*:=\s*'
                         r'"([01]+)"\s*&\s*x"([0-9a-fA-F]+)"')
        with open(src) as f:
            m = pat.search(f.read())
        if not m:
            raise SystemExit(
                f"could not find HBM_BASE in {src}.\n"
                f"  It is the base of the EE's memory inside HBM and a loader "
                f"that guesses it writes somewhere the core never reads.")
        return (int(m.group(1), 2) << (4 * len(m.group(2)))) | int(m.group(2), 16)

    def load_hbm(self, words, base=None, verify=True, clear=CLEAR_BYTES):
        if base is None:
            base = self.hbm_base()
        """Instruction words into HBM, eight to a beat, read back to check.

        The read-back is not ceremony.  Loading through a probe that has never
        carried a program before is exactly the step where a silent failure
        looks like a broken core: the registers would come back wrong and the
        obvious conclusion -- that the R5900 is at fault -- would be the wrong
        one.  Checking the memory first makes the next result mean something.
        """
        if self.rd("hbm_init_done") & 1 != 1:
            raise SystemExit(
                "FAIL  hbm_init_done is 0: the HBM controllers have not "
                "finished bringing the stacks up, so nothing below would mean "
                "anything.")
        if clear:
            zero = [0] * 8
            for b in range((clear + self.BEAT - 1) // self.BEAT):
                resp = self.hbm_beat(base + b * self.BEAT, zero)
                if resp != 0:
                    raise SystemExit(f"FAIL  clearing HBM: beat {b} answered "
                                     f"AXI resp={resp}")
        beats = (len(words) + 7) // 8
        for b in range(beats):
            lane = [words[b * 8 + j] & 0xFFFFFFFF if b * 8 + j < len(words)
                    else 0 for j in range(8)]
            resp = self.hbm_beat(base + b * self.BEAT, lane)
            if resp != 0:
                raise SystemExit(f"FAIL  HBM write beat {b} answered AXI "
                                 f"resp={resp}")
        if not verify:
            return
        for b in range(beats):
            got, resp = self.hbm_read(base + b * self.BEAT)
            want = [words[b * 8 + j] & 0xFFFFFFFF if b * 8 + j < len(words)
                    else 0 for j in range(8)]
            if resp != 0 or got != want:
                raise SystemExit(
                    f"FAIL  HBM did not hold the program: beat {b} at "
                    f"0x{base + b * self.BEAT:x} resp={resp}\n"
                    f"  wrote {[f'{w:08x}' for w in want]}\n"
                    f"  read  {[f'{w:08x}' for w in got]}")

    def has_onchip_mem(self):
        return "ee_mem_addr" in self.regs

    def load(self, words):
        """A list of 32-bit instruction words, packed four to a 128-bit line."""
        if not self.has_onchip_mem():
            return self.load_hbm(words)
        for i in range(0, len(words), 4):
            q = 0
            for j in range(4):
                if i + j < len(words):
                    q |= (words[i + j] & 0xFFFFFFFF) << (32 * j)
            self.mem_access(i // 4, q)

    def gpr(self, n):
        self.wr("ee_dbg_sel", n)
        # The snapshot is refreshed every 64 cd_ee cycles and crossed on a
        # toggle, so the value for a newly selected register is not there for a
        # few microseconds. Waiting is cheaper than a handshake for a debug path.
        time.sleep(0.002)
        v = 0
        for i in range(4):
            v |= self.rd(f"ee_dbg_gpr{i}") << (32 * i)
        return v


def measure_clock(card, seconds):
    if not card.rd("ee_clk_locked") & 1:
        raise SystemExit(
            "FAIL  the PS2 clock tree did not lock.\n"
            "  Nothing else on this page means anything: cd_ee has no clock,\n"
            "  or one at the wrong rate, and the core is not running at all.")
    t0 = time.time()
    c0 = card.rd("ee_clk_ticks")
    time.sleep(seconds)
    c1 = card.rd("ee_clk_ticks")
    dt = time.time() - t0
    ticks = (c1 - c0) & 0xFFFFFFFF
    mhz = ticks / dt / 1e6
    target = 294.912
    ppm = (mhz - target) / target * 1e6
    print("PS2 clock tree locked: 1")
    print(f"counted {ticks} EE-domain ticks in {dt:.4f} s")
    print(f"measured {mhz:.4f} MHz")
    print(f"  synthesised target {target:.6f} MHz")
    print(f"  a PlayStation 2's  {target:.6f} MHz")
    print(f"  difference {ppm:+.0f} ppm (the host's own clock is worth a few ppm"
          " at best, so this confirms the divider, not the parts per million)")
    ok = abs(ppm) < 200
    print("PASS  the card is running at the console's clock" if ok else
          "FAIL  that is not the console's clock")
    return ok


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dev", default="/dev/litepcie0")
    ap.add_argument("--csr", required=True)
    ap.add_argument("--clock", action="store_true")
    ap.add_argument("--seconds", type=float, default=2.0)
    ap.add_argument("--prog")
    ap.add_argument("--steps", type=int, default=200)
    ap.add_argument("--pc", type=lambda x: int(x, 0), default=0)
    ap.add_argument("--compare", action="store_true")
    a = ap.parse_args()

    card = Card(a.dev, a.csr)
    card.check_link()

    ok = True
    if a.clock or not a.prog:
        ok &= measure_clock(card, a.seconds)
    if not a.prog:
        return 0 if ok else 1

    words = [int(l.split("//")[0].strip(), 16) for l in open(a.prog)
             if l.split("//")[0].strip()]
    card.wr("ee_reset", 1)
    card.wr("ee_pc_reset", a.pc)
    card.load(words)
    print(f"loaded {len(words)} instructions")

    # Let it run, then read the registers. The program parks in a branch to
    # itself, so once it gets there the register file never changes again and a
    # read at leisure describes a definite moment.
    #
    # Polling a retire counter and then asserting reset does NOT: at 294.912 MHz
    # thousands of instructions retire between two CSR reads, so three identical
    # runs on a *working* core would stop in three different places. The first
    # card test did exactly that and the differing retire counts -- 1415, 1358,
    # 1131 -- looked like evidence of a fault when half of it was the harness.
    card.wr("ee_reset", 0)
    time.sleep(0.05)
    n = card.rd("ee_retires")
    print(f"retired {n} instructions "
          f"({card.rd('ee_traps')} unimplemented, stall={card.rd('ee_stall')})")
    regs = [card.gpr(i) for i in range(32)]
    card.wr("ee_reset", 1)
    if n == 0:
        print("FAIL  the core retired nothing at all")
        return 1
    for i in range(0, 32, 2):
        print("  r%-2d=%032x  r%-2d=%032x" % (i, regs[i], i + 1, regs[i + 1]))

    if a.compare:
        import r5900_ref
        mem = r5900_ref.Mem()
        for k, w in enumerate(words):
            mem.store(k * 4, 4, w)
        cpu = r5900_ref.R5900(mem, 0)
        # Run until the PC stops moving, which is the park, then a little more
        # so a two-instruction loop cannot look stationary by accident.
        # **The park is a two-instruction cycle, not a stationary PC.**
        # gen_card ends its programs with `BEQ r0, r0, -1` and a NOP in the
        # delay slot, so a parked model runs branch, slot, branch, slot and its
        # PC alternates between two addresses forever. A detector waiting for
        # the PC to stop moving therefore never fires -- which is what the old
        # one did, on every program, so it printed "the model never parked" and
        # compared anyway every single time. The note was always there and
        # always ignored, which is the worst state for a warning to be in.
        #
        # What parking actually looks like is a cycle, so that is what is
        # detected: the PC equal to the one two steps back, sustained. Period 1
        # and period 2 are both covered, and requiring several repetitions keeps
        # an ordinary two-instruction loop in the middle of a program from
        # ending the run early.
        prev2, prev1, cyc, parked = None, None, 0, False
        for _ in range(20000):
            cpu.step()
            if prev2 is not None and cpu.pc == prev2:
                cyc += 1
                if cyc > 8:
                    parked = True
                    break
            else:
                cyc = 0
            prev2, prev1 = prev1, cpu.pc

        # **A program that never parks cannot be compared, and saying so is not
        # the same as passing it.**  This used to print a note and compare
        # anyway, which is worse than either: the card is still running when its
        # registers are read, so the comparison is against a moving target and
        # reports a FAIL that has nothing to do with the core.  Seed 6 of
        # gen_card showed it plainly -- one PASS and then three failures naming
        # three different sets of registers, from the same program on the same
        # silicon.
        #
        # The park is what makes the card's state a definite moment; without it
        # there is no moment to compare.  So this is a distinct outcome, not a
        # failure, and it points at the generator rather than at the hardware.
        if not parked:
            print("INCONCLUSIVE  the model never parked, so this program does "
                  "not terminate.")
            print("  The card is still running when its registers are read, so "
                  "there is no")
            print("  single moment to compare against. This says nothing about "
                  "the core --")
            print("  it says the generated program has a loop, and gen_card "
                  "should not have")
            print("  emitted it. Try another seed.")
            return 2
        # r128, not r: r() is the low 64 bits. MMI writes the upper half,
        # and comparing with r() reports a correct core as broken for
        # every register whose result lives up there.
        bad = [i for i in range(32) if cpu.r128(i) != regs[i]]
        if bad:
            print(f"FAIL  {len(bad)} registers differ from the model: {bad[:8]}")
            for i in bad[:4]:
                print(f"    r{i}: card {regs[i]:032x}")
                print(f"         model {cpu.r128(i):032x}")
            return 1
        print("PASS  every register agrees with the model")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
