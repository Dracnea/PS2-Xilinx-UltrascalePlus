#!/usr/bin/env python3
"""Drive the C1100 PS2 IOP bring-up design over PCIe: load a ROM, release reset,
watch the POST register.

    iop_post.py [--dev /dev/litepcie0 | --uart PORT] [--csr csr.csv] status
    iop_post.py ... load ROM.hex|ROM.bin [--addr WORD]     # write an image into the IOP ROM
    iop_post.py ... reset {hold|release}
    iop_post.py ... pad [VALUE]                            # read or set the SIO2 port-0 pad (iop_pad0)
    iop_post.py ... run ROM.hex|ROM.bin [--timeout SEC] [--pad0 VALUE]   # load, release, poll until AA/EE
    iop_post.py ... peek ADDR [--words N]                  # read IOP memory (CPU must be in reset)
    iop_post.py ... dump FILE [--addr A] [--length N]      # dump IOP RAM to a file, 2 MB by default
    iop_post.py ... verify ROM.bin [--samples N]           # read the ROM back and compare with the file
    iop_post.py ... sif [show|ee-init|set NAME VALUE]      # the EE's half of the SIF mailbox
    iop_post.py ... cdvd [log|disc on|disc off]           # what the BIOS asked the drive for

`run` writes `iop_pad0` before releasing reset. The CSR resets to 0xFFFF (nothing
pressed) but boot_test.s stage 09 expects the pad to answer 0x5A3C, which is what
the testbench drives, so that is the default; pass --pad0 0xFFFF to make stage 09
fail on purpose and prove the pad path is live.

Two transports reach the same registers. The default is the litepcie driver's
LITEPCIE_IOCTL_REG ioctl over PCIe, which is fast enough to stream a 4 MB BIOS
in seconds. `--uart /dev/ttyUSB2` instead goes through litex_server on the
card's UARTbone, which needs no kernel driver and no root at all - useful when
PCIe is down or on a machine where the driver cannot be built - but at 115200
baud it carries about 1150 register writes a second, so a 4 MB image takes a
quarter of an hour and a 4096-word test image about four seconds.

ROM images are either the assembler's one-hex-word-per-line files
(cores/PS2/sim/asm_r3000.py) or raw little-endian words.  Word address 0 is
0xBFC00000, the reset vector.  Register access goes through the litepcie
driver's LITEPCIE_IOCTL_REG ioctl, the same path litepcie_util uses, so the
device node needs to be readable (tools/99-litepcie.rules) and the csr.csv must
be the one generated with the loaded bitstream.
"""
import argparse, fcntl, os, struct, sys, time

REPO_ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))


def venv_root():
    """Where LiteX lives: $PS2_VENV, this repo's venv, or a MiSTeX-ports one.

    The board targets and these tools need migen/litex/litepcie/litescope. Any
    virtualenv with them will do; README.md says how to make one. The
    MiSTeX-ports fallback is there because that is where the first C1100 work
    on this project was built.
    """
    for c in (os.environ.get("PS2_VENV"),
              os.path.join(REPO_ROOT, "venv"),
              os.path.expanduser("~/MiSTeX-ports/venv")):
        if c and os.path.isdir(c):
            return c
    return None


def add_venv_to_path():
    v = venv_root()
    if not v:
        return
    for lib in sorted(os.listdir(os.path.join(v, "lib"))):
        sp = os.path.join(v, "lib", lib, "site-packages")
        if os.path.isdir(sp):
            sys.path.insert(0, sp)


def build_dir(image):
    """Where a board target's build lands: <repo>/build/<image>."""
    return os.environ.get("PS2_BUILD_DIR") or os.path.join(REPO_ROOT, "build", image)

# _IOWR('S', 0, struct litepcie_ioctl_reg { u32 addr; u32 val; u8 is_write; })  -> 12 bytes
LITEPCIE_IOCTL_REG = (3 << 30) | (12 << 16) | (ord("S") << 8) | 0

POST_PASS = 0xAA
POST_FAIL = 0xEE


class Dev:
    def __init__(self, path, csr_csv):
        self.fd = os.open(path, os.O_RDWR)
        self.regs = {}
        with open(csr_csv) as f:
            for line in f:
                parts = line.strip().split(",")
                if parts and parts[0] == "csr_register":
                    self.regs[parts[1]] = int(parts[2], 0)

    def readl(self, addr):
        buf = struct.pack("IIB3x", addr, 0, 0)
        out = fcntl.ioctl(self.fd, LITEPCIE_IOCTL_REG, buf)
        return struct.unpack("IIB3x", out)[1]

    def writel(self, addr, val):
        fcntl.ioctl(self.fd, LITEPCIE_IOCTL_REG, struct.pack("IIB3x", addr, val & 0xFFFFFFFF, 1))

    def reg(self, name):
        if name not in self.regs:
            sys.exit(f"csr.csv has no register {name}; is it the csr.csv of the loaded bitstream?")
        return self.regs[name]

    def rd(self, name):  return self.readl(self.reg(name))
    def wr(self, name, v): self.writel(self.reg(name), v)


class UartDev:
    """The same register interface over the card's UARTbone, via litex_server.

    Starts a litex_server on the tty unless one is already bound to the port,
    and speaks to it with litex's RemoteClient, so no driver and no root are
    needed. Reads cost a round trip (about a millisecond); writes stream, and
    the socket back-pressures once the UART falls behind, which is why the ROM
    load reports its own rate rather than trusting a burst that has only been
    queued.
    """
    slow = True      # writes queue at UART speed; load() paces itself on this

    def __init__(self, csr_csv, port="/dev/ttyUSB2", tcp_port=1234, baud=115200):
        import subprocess
        add_venv_to_path()
        from litex import RemoteClient
        self.server = None
        for attempt in range(2):
            try:
                # The default 2 s timeout is far too short: a queued write burst
                # drains at UART speed, and a read behind it waits for the whole
                # queue. raise_on_timeout matters more - without it litex returns
                # default values on a timeout, which would look like real data.
                self.wb = RemoteClient(csr_csv=csr_csv, port=tcp_port,
                                       timeout=120.0, raise_on_timeout=True)
                self.wb.open()
                self.wb.regs  # touch, so a dead server fails here
                break
            except Exception:
                if attempt or self.server is not None:
                    raise
                exe = os.path.join(venv_root() or sys.prefix, "bin", "litex_server")
                self.server = subprocess.Popen(
                    [exe, "--uart", "--uart-port", port, "--uart-baudrate", str(baud),
                     "--bind-port", str(tcp_port)],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
                time.sleep(3)
        self.regs = {}
        with open(csr_csv) as f:
            for line in f:
                parts = line.strip().split(",")
                if parts and parts[0] == "csr_register":
                    self.regs[parts[1]] = int(parts[2], 0)

    def reg(self, name):
        if name not in self.regs:
            sys.exit(f"csr.csv has no register {name}; is it the csr.csv of the loaded bitstream?")
        return getattr(self.wb.regs, name)

    def rd(self, name):    return self.reg(name).read()
    def wr(self, name, v): self.reg(name).write(v & 0xFFFFFFFF)

    def close(self):
        try:
            self.wb.close()
        except Exception:
            pass
        if self.server is not None:
            self.server.terminate()


def open_dev(args, csr):
    """Whichever transport the arguments ask for."""
    if getattr(args, "uart", None):
        return UartDev(csr, port=args.uart, tcp_port=getattr(args, "port", 1234))
    return Dev(args.dev, csr)


def read_image(path):
    if path.endswith(".hex"):
        words = []
        with open(path) as f:
            for line in f:
                s = line.split("//")[0].strip()
                if s:
                    words.append(int(s, 16))
        return words
    data = open(path, "rb").read()
    if len(data) % 4:
        data += b"\0" * (4 - len(data) % 4)
    return list(struct.unpack("<%dI" % (len(data) // 4), data))


def status(dev):
    s = dev.rd("iop_status")
    return {
        "post":       s & 0xFF,
        "cpu_error":  (s >> 8) & 1,
        "mem_idle":   (s >> 9) & 1,
        "locked":     (s >> 10) & 1,
        "heartbeat":  (s >> 11) & 1,
        "post_count": dev.rd("iop_post_count"),
        "rom_count":  dev.rd("iop_rom_count"),
        "reset":      dev.rd("iop_reset") & 1,
    }


def show(dev):
    s = status(dev)
    print(f"POST {s['post']:02X}  post_count {s['post_count']}  reset {s['reset']}  "
          f"locked {s['locked']}  heartbeat {s['heartbeat']}  cpu_error {s['cpu_error']}  "
          f"mem_idle {s['mem_idle']}  rom_count {s['rom_count']}")
    return s


def load(dev, path, addr=0, progress=None, chunk=None):
    """Write an image into the IOP ROM, re-anchoring the pointer every chunk.

    The ROM write port auto-increments: `iop_rom_addr` sets the pointer and
    each `iop_rom_data` write stores a word and steps it on. The step happens
    in the IOP clock domain, one pulse per host write through a
    `PulseSynchronizer`, so the pointer's position after N writes is N pulses
    of trust. That is fine for the 4096-word boot test and **was not** for a
    4 MB BIOS: on 2026-09-08 a full image left the CPU executing whatever was
    at 0xBFC00000 and running off into empty RAM without ever writing POST,
    while the same file truncated to 512 KB booted normally. The pointer is 20
    bits, so one slipped word in a million shifts every later word and a
    pointer that ends up past the end wraps onto the reset vector - which is
    the mechanism that fits, though it has not been measured directly.

    So the address is rewritten at the start of every chunk. Any slip is then
    confined to the chunk it happened in and can never wrap, and the read of
    `iop_rom_count` at each boundary paces a slow transport at the same time.
    """
    words = read_image(path)
    step = chunk or (4096 if getattr(dev, "slow", False) else 65536)
    t0 = time.time()
    for base in range(0, len(words), step):
        dev.wr("iop_rom_addr", addr + base)
        for w in words[base:base + step]:
            dev.wr("iop_rom_data", w)
        # a read forces a queued transport to drain, so the rate below is the
        # transfer's and not the socket's
        got = dev.rd("iop_rom_count")
        if progress and len(words) > step:
            done = min(base + step, len(words))
            el = time.time() - t0
            progress(f"   ROM {done}/{len(words)} words  {el:6.1f} s elapsed, "
                     f"{(len(words) - done) / max(done / el, 1e-6) / 60:5.1f} min left")
    dt = time.time() - t0
    print(f"loaded {len(words)} words at word address {addr} in {dt:.2f} s "
          f"({len(words) / max(dt, 1e-6):.0f} words/s); rom_count {got}")
    return len(words)


def peek(dev, addr, words=1):
    """Read `words` words of IOP memory from byte address `addr`.

    The peek port only answers while the IOP is in reset, and reading
    `iop_peek_data` advances the pointer by four and fetches the next word, so
    a run of words costs one register read each after the first address write.
    `iop_peek_count` counts completed fetches; comparing it before and after
    catches a host that outran the fetch.
    """
    if "iop_peek_addr" not in dev.regs:
        sys.exit("this bitstream has no peek port (rebuild with the memory peek; see docs/ps2-iop-bringup.md)")
    if not (dev.rd("iop_reset") & 1):
        sys.exit("the IOP is running; hold it in reset first (iop_post.py reset hold)")
    before = dev.rd("iop_peek_count")
    dev.wr("iop_peek_addr", addr & 0x1FFFFFC)
    out = [dev.rd("iop_peek_data") for _ in range(words)]
    got = dev.rd("iop_peek_count") - before
    # the count includes the fetch each read kicked off, plus the first
    if got < words:
        print(f"warning: {words} words read but only {got} fetches completed; "
              f"the host outran the peek port", file=sys.stderr)
    return out


ROM_BASE = 0x800000        # bit 23 of a peek address selects the ROM

# SIF host writes: what iop_sif_go selects
SIF_MSCOM, SIF_MSFLAG_SET, SIF_MSFLAG_CLR, SIF_SMFLAG_CLR, SIF_CTRL, SIF_BD6 = range(6)
SIF_STAT_SIFINIT = 0x00010000     # the bit SIFMAN spins on, set by the EE


# The CDVD command log. CDVDMAN issues every N command through one dispatcher
# with the opcode in a register (0220A ROM, CDVDMAN .text+0x2fc4), so the
# opcodes cannot be read out of the BIOS statically. The hardware records what
# it was actually asked for instead.
CDVD_LOG_WORDS = 8


def cdvd_log(dev, limit=32):
    n = dev.rd("iop_cdvd_log_count")
    print(f"CDVD command log: {n} commands since reset")
    if n == 0:
        print("   (nothing yet -- the driver only talks to a drive it believes has a disc:"
              "\n    try `cdvd disc on` before releasing reset)")
        return
    shown = min(n, limit)
    first = n - shown if n > limit else 0
    for e in range(first, n):
        base = (e % 32) * CDVD_LOG_WORDS
        words = []
        for w in range(5):
            dev.wr("iop_cdvd_log_addr", base + w)
            words.append(dev.rd("iop_cdvd_log_data"))
        hdr = words[0]
        kind = "S" if (hdr >> 31) & 1 else "N"
        op   = (hdr >> 16) & 0xFF
        npar = hdr & 0xFF
        par  = b"".join(struct.pack("<I", words[1 + i]) for i in range(4))[:max(npar, 0)]
        line = f"   #{e:3d}  {kind} command 0x{op:02X}  {npar:2d} params"
        if par:
            line += "  " + " ".join(f"{b:02x}" for b in par)
        # a read command's parameters are LBA then sector count, per PCSX2
        if kind == "N" and npar >= 8:
            lba = int.from_bytes(par[0:4], "little")
            cnt = int.from_bytes(par[4:8], "little")
            line += f"\n         -> looks like a read: LBA {lba} ({lba*2048} bytes in), {cnt} sectors"
            if npar >= 11:
                line += f", mode byte 0x{par[10]:02x}"
        print(line)


def sif_write(dev, sel, value):
    """One write to the SIF as the Emotion Engine would make it."""
    dev.wr("iop_sif_data", value)
    dev.wr("iop_sif_go", sel)


def sif_show(dev):
    r = {n: dev.rd("iop_sif_" + n) for n in
         ("mscom", "smcom", "msflag", "smflag", "regctrl")}
    print(f"  MSCOM  {r['mscom']:08x}   (EE -> IOP mailbox word)")
    print(f"  SMCOM  {r['smcom']:08x}   (IOP -> EE mailbox word)")
    print(f"  MSFLAG {r['msflag']:08x}   (EE sets, IOP clears)"
          + ("   bit16 SIFINIT set" if r["msflag"] & SIF_STAT_SIFINIT else ""))
    print(f"  SMFLAG {r['smflag']:08x}   (IOP sets, EE clears)"
          + ("   bit16 the IOP is ready and waiting" if r["smflag"] & SIF_STAT_SIFINIT else ""))
    print(f"  CTRL   {r['regctrl']:08x}")
    return r


def sif_ee_init(dev, mscom=0x00000000):
    """Answer the IOP's SIF init the way the Emotion Engine does.

    The BIOS's SIFMAN publishes its own ready bit in SMFLAG and then spins on
    MSFLAG bit 16 until the EE answers (SIFMAN .text+0x1ec on the 0220A ROM).
    With no EE, nothing ever sets it and the boot stops there with the CPU
    still running -- which is exactly what the card did on 2026-09-08. This
    plays the EE's part: put a word in MSCOM, then set MSFLAG bit 16.
    """
    before = sif_show(dev)
    if not (before["smflag"] & SIF_STAT_SIFINIT):
        print("note: the IOP has not published its ready bit yet; setting MSFLAG anyway")
    sif_write(dev, SIF_MSCOM, mscom)
    sif_write(dev, SIF_MSFLAG_SET, SIF_STAT_SIFINIT)
    time.sleep(0.05)
    print("after answering as the EE:")
    return sif_show(dev)


def verify(dev, path, samples=64, window=16):
    """Read the loaded ROM back through the peek port and compare it with the file.

    Reads `window` consecutive words at each of `samples` offsets spread over
    the image, plus the first and last window, which is enough to catch both a
    wholesale failure and a shift: a shifted image matches nowhere, and a
    partially written one matches at the start and not at the end. Cheap - a
    few hundred register reads - and the only way to know the card holds what
    the file says, which no counter on the host can tell you.
    """
    words = read_image(path)
    offsets = sorted({0, max(len(words) - window, 0)} |
                     {(i * len(words)) // samples for i in range(samples)})
    bad = []
    for off in offsets:
        n = min(window, len(words) - off)
        if n <= 0:
            continue
        got = peek(dev, ROM_BASE + off * 4, n)
        want = words[off:off + n]
        if got != want:
            first = next(i for i in range(n) if got[i] != want[i])
            bad.append((off + first, want[first], got[first]))
    checked = sum(min(window, len(words) - o) for o in offsets)
    if not bad:
        print(f"ROM verify: {checked} words at {len(offsets)} offsets all match {path}")
        return 0
    print(f"ROM verify: {len(bad)} of {len(offsets)} sampled windows differ from {path}")
    for off, want, got in bad[:20]:
        print(f"   word {off:7d} (rom0+0x{off * 4:06x}): file {want:08x}  card {got:08x}")
    return 1


def run(dev, path, timeout, pad0=0x5A3C):
    dev.wr("iop_reset", 1)
    dev.wr("iop_pad0", pad0 & 0xFFFF)
    print(f"iop_pad0 = 0x{dev.rd('iop_pad0') & 0xFFFF:04X}")
    load(dev, path)
    seen = None
    dev.wr("iop_reset", 0)
    t0 = time.time()
    while time.time() - t0 < timeout:
        s = status(dev)
        if s["post"] != seen:
            seen = s["post"]
            print(f"[{time.time()-t0:7.3f}s] POST {seen:02X}  (count {s['post_count']})")
            if seen == POST_PASS:
                print("PASS"); return 0
            if seen == POST_FAIL:
                print("FAIL: test reported failure"); return 1
        if s["cpu_error"]:
            print("FAIL: cpu error flag"); return 1
        time.sleep(0.01)
    print(f"FAIL: timeout, last POST {seen if seen is not None else 0:02X}")
    return 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dev", default="/dev/litepcie0")
    ap.add_argument("--uart", metavar="TTY", nargs="?", const="/dev/ttyUSB2",
                    help="drive the card over UARTbone through litex_server instead of PCIe")
    ap.add_argument("--port", type=int, default=1234, help="litex_server TCP port for --uart")
    ap.add_argument("--csr", default="csr.csv")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    p = sub.add_parser("load");  p.add_argument("rom"); p.add_argument("--addr", type=lambda x: int(x, 0), default=0)
    p = sub.add_parser("reset"); p.add_argument("state", choices=["hold", "release"])
    p = sub.add_parser("run");   p.add_argument("rom"); p.add_argument("--timeout", type=float, default=5.0)
    p.add_argument("--pad0", type=lambda x: int(x, 0), default=0x5A3C)
    p = sub.add_parser("pad");   p.add_argument("value", nargs="?", type=lambda x: int(x, 0))
    p = sub.add_parser("peek");  p.add_argument("addr", type=lambda x: int(x, 0))
    p.add_argument("--words", type=int, default=8)
    p = sub.add_parser("verify"); p.add_argument("rom"); p.add_argument("--samples", type=int, default=64)
    p = sub.add_parser("cdvd")
    p.add_argument("action", nargs="?", default="log", choices=["log", "disc"])
    p.add_argument("state", nargs="?", choices=["on", "off"])
    p = sub.add_parser("sif")
    p.add_argument("action", nargs="?", default="show", choices=["show", "ee-init", "set"])
    p.add_argument("name", nargs="?", choices=["mscom", "msflag-set", "msflag-clear", "smflag-clear", "ctrl", "bd6"])
    p.add_argument("value", nargs="?", type=lambda x: int(x, 0), default=0)
    p = sub.add_parser("dump");  p.add_argument("file")
    p.add_argument("--addr", type=lambda x: int(x, 0), default=0)
    p.add_argument("--length", type=lambda x: int(x, 0), default=2 * 1024 * 1024)
    a = ap.parse_args()

    dev = open_dev(a, a.csr)
    if a.cmd == "status":
        show(dev)
    elif a.cmd == "load":
        load(dev, a.rom, a.addr)
    elif a.cmd == "reset":
        dev.wr("iop_reset", 1 if a.state == "hold" else 0)
        show(dev)
    elif a.cmd == "pad":
        if a.value is not None:
            dev.wr("iop_pad0", a.value & 0xFFFF)
        print(f"iop_pad0 = 0x{dev.rd('iop_pad0') & 0xFFFF:04X}")
    elif a.cmd == "peek":
        for i, w in enumerate(peek(dev, a.addr, a.words)):
            print(f"  {a.addr + 4 * i:08x}: {w:08x}")
    elif a.cmd == "cdvd":
        if "iop_cdvd_log_count" not in dev.regs:
            sys.exit("this bitstream has no CDVD command log; rebuild with it")
        if a.action == "disc":
            v = dev.rd("iop_cdvd_disc")
            v = (v | 1) if a.state == "on" else (v & ~1)
            if not (v >> 8) & 0xFF:
                v |= 0x14 << 8                      # default disc type: PS2 DVD
            dev.wr("iop_cdvd_disc", v)
            print(f"disc {'present' if v & 1 else 'absent'}, type 0x{(v >> 8) & 0xFF:02X}")
        else:
            cdvd_log(dev)
    elif a.cmd == "sif":
        if "iop_sif_msflag" not in dev.regs:
            sys.exit("this bitstream has no SIF host port; it predates rtl/iop/iop_sif.vhd")
        if a.action == "show":
            sif_show(dev)
        elif a.action == "ee-init":
            sif_ee_init(dev)
        else:
            sel = {"mscom": SIF_MSCOM, "msflag-set": SIF_MSFLAG_SET,
                   "msflag-clear": SIF_MSFLAG_CLR, "smflag-clear": SIF_SMFLAG_CLR,
                   "ctrl": SIF_CTRL, "bd6": SIF_BD6}[a.name]
            sif_write(dev, sel, a.value)
            sif_show(dev)
    elif a.cmd == "verify":
        sys.exit(verify(dev, a.rom, a.samples))
    elif a.cmd == "dump":
        t0 = time.time()
        words = peek(dev, a.addr, a.length // 4)
        with open(a.file, "wb") as f:
            f.write(struct.pack("<%dI" % len(words), *words))
        print(f"{len(words) * 4} bytes from 0x{a.addr:08x} in {time.time() - t0:.1f} s -> {a.file}")
    elif a.cmd == "run":
        sys.exit(run(dev, a.rom, a.timeout, a.pad0))


if __name__ == "__main__":
    main()
