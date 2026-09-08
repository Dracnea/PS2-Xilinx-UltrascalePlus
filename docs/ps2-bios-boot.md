# Booting a real PS2 BIOS on the C1100's IOP

[ps2-iop-bringup.md](ps2-iop-bringup.md) records the IOP subsystem itself —
what was simulated, what it costs on the die, and the boot-test image that
passes on silicon. This page is about the next question: give that IOP a real
PlayStation 2 BIOS, and what does the BIOS ask for, how far does it get, and
what is missing.

BIOS images are the operator's own `rom0` dumps from consoles they own. None
is in this repository and none ever will be. Everything below is derived from
the dumps on the machine that ran the tests, and the tools work on any dump.

## Reading a rom0 image: `tools/ps2iop/romdir.py`

A rom0 is a flat archive with a directory of 16-byte entries — 10 bytes of
name, a `u16` EXTINFO length, a `u32` file length — beginning at the entry
named `RESET`, with the file data packed in directory order from offset 0 and
each file padded to 16 bytes. Every entry's EXTINFO bytes are concatenated in
the same order in the `EXTINFO` file and carry the build date, version and
description.

```
tools/ps2iop/romdir.py rom0.bin --list        # every file, with version and date
tools/ps2iop/romdir.py rom0.bin --boot        # the modules IOPBOOT loads, in order
tools/ps2iop/romdir.py rom0.bin --irx NAME    # a module's IRX header
tools/ps2iop/romdir.py rom0.bin --hw NAME     # the hardware registers it touches
tools/ps2iop/romdir.py <dir>    --compare     # ROMVER and module set across dumps
```

The same format carries `rom1`, the DVD player firmware, so those dumps read
too — `--list` shows their `DVDID*`/`DVDVER*` region tables and the build
string in the `ROMDIR` entry's EXTINFO. They have no `IOPBTCONF` and no
`IOPBOOT`, so `--boot` reports as much rather than guessing.

### The boot module list is the same in every dump

`IOPBTCONF` is the list IOPBOOT reads and loads. Across the 53 rom0 dumps on this
machine — `0100J` (the launch Japanese SCPH-10000, January 2000) through
`0250J` (2010), every region, and the `Misc BIOS` devkit images — the list is
**byte-identical**: the same 29 modules in the same order, and `IOPBOOT`
itself at rom0 + `0x4A000` in every single one.

```
  1 SYSMEM      2 LOADCORE    3 EXCEPMAN    4 INTRMANP    5 INTRMANI
  6 SSBUSC      7 DMACMAN     8 TIMEMANP    9 TIMEMANI   10 SYSCLIB
 11 HEAPLIB    12 EECONF     13 THREADMAN  14 VBLANK     15 IOMAN
 16 MODLOAD    17 ROMDRV     18 STDIO      19 SIFMAN     20 IGREETING
 21 SIFCMD     22 REBOOT     23 LOADFILE   24 CDVDMAN    25 CDVDFSV
 26 SIFINIT    27 FILEIO     28 SECRMAN    29 EESYNC
```

That matters for the FPGA work: the hardware the IOP kernel needs does not
depend on which BIOS an owner happens to have, so there is one target to hit,
not a family of them.

## What the boot code actually touches

`--hw` disassembles a module and follows `lui` + `ori`/`addiu` chains into
loads and stores, so it recovers the absolute hardware addresses a module
uses. (Relocatable data references appear as `lui 0` and are correctly
ignored; addresses reached through a pointer in a structure — DMACMAN builds
its channel addresses that way — are not recovered, so the list is a floor,
not a ceiling.)

Over IOPBOOT and all 29 modules of the `0220A` ROM, 50 distinct addresses:

| region | addresses | answered by | state |
|---|---|---|---|
| SIF `0x1D000000`–`0x40` | 6 | `iop_regstub` | **stub** — reads back writes, no EE |
| CDVD `0x1F402004`–`0x18` | 15 | `iop_cdvd` | real, no disc |
| SSBUS `0x1F801020` | 1 | PSX `memctrl` | real |
| INTC `0x1F801070/74/78` | 3 | `iop_intc` | real |
| DMA `0x1F8010A0`–`0xF4` | 7 | `iop_regstub` | **stub** — no transfers |
| SSBUS2 `0x1F801400/450/472` | 3 | `iop_regstub` | **stub** |
| DMA2 `0x1F801520`–`0x578` | 10 | `iop_regstub` | **stub** |
| POST `0x1F802070` | 1 | POST register | real |
| cache control `0xFFFE0130/0190` | 2 | inside the PSX CPU | real for `0130` |

Two things follow.

**Nothing the boot code touches is unmapped.** Every address lands on a block
that answers, so the boot should not take a bus fault anywhere in the module
list. The stubs store what is written and return it, which is what
initialisation code needs.

**The functional gaps are exactly DMA and the SIF.** SIFMAN programs DMA
channels 5 and 6 (`0x1F801520`/`0x1F801530`) and the SIF's own registers, and
CDVDMAN programs channel 3 (`0x1F8010B0`). Nothing behind those registers
moves data, and there is no EE on the other side of the SIF to answer, so the
kernel comes up and then waits.

`0x1F801450` is the most load-bearing single register in the boot: ten of the
29 modules read it. It is the IOP's mode/configuration word, and the stub
answering 0 is what puts the ROM on its PS2 path rather than its PS1 one.

### A retail BIOS prints nothing

The diagnostic image built for this work captures the IOP's serial port
(SIO1, `0x1F801050`) into a FIFO the host drains, on the assumption that the
kernel's `Kprintf` goes there as it does on a devkit. Scanning every file of
every dump for accesses to that port says otherwise: **no module in any retail
rom0 here writes to SIO1.** The only SIO traffic in the whole ROM is SBIN's
use of SIO0 (`0x1F801040`), the PS1-side controller port.

So the console FIFO stays empty on a retail boot, and it is not a fault in the
capture. Emulators show IOP console text because they intercept the `Kprintf`
call itself, not because the console writes to a port. The signals that do
exist on hardware are the POST register — which THREADMAN writes once it is
running — the bus trace, and RAM.

## The memory peek port

Because RAM is where the evidence is, `iop_top` gained a read port the host
can use while the CPU is held in reset:

```
peek_req / peek_addr (byte address, bit 23 selects the 4 MB ROM over the 2 MB
RAM)  ->  peek_valid / peek_data
```

It costs no memory: while the IOP is in reset the memory mux has no request in
flight, so the RAM port is simply switched over to the peek instead of
arbitrated, and `iop_ram`'s own reset is released for the duration of a read.
A real console has no such port; this one exists to take a post-mortem.

On CSRs (`iop_peek_addr`, `iop_peek_data`, `iop_peek_count`) it is arranged so
that **reading `iop_peek_data` advances the address by four and fetches the
next word**, so dumping memory is one address write and then one register read
per word. `iop_peek_count` counts completed fetches, so a dump can check it
was not read faster than the port could answer.

```sh
tools/ps2iop/iop_post.py --csr <image>.csr.csv reset hold
tools/ps2iop/iop_post.py --csr <image>.csr.csv dump ram.bin        # 2 MB
tools/ps2iop/iop_ram_map.py ram.bin --rom /path/to/rom0.bin
```

`bios_run.py --dump-ram 0x200000` does it as part of a run, after the POST
ring and the trace have been read — reset has to be re-asserted for the peek
port to answer, and asserting it clears the ring, so the order matters.

`iop_ram_map.py` turns the dump into an answer. IOPBOOT copies each module's
`.text`, `.rodata` and `.data` into RAM and relocates it. Relocation rewrites
exactly the bytes the module's `.rel.*` tables name and nothing else, so the
longest run of *un*-relocated bytes — usually a block of strings in `.rodata`
— is a fingerprint that survives loading unchanged. Searching the dump for
each module's fingerprint, and reporting the result in `IOPBTCONF` order,
gives the unbroken prefix that loaded and names the first module that did not.
Two modules in the list (`IGREETING`, `SIFINIT`) carry no name in their
`.iopmod` header, which is why the fingerprint and not the name is what is
searched for; and `INTRMANP`/`INTRMANI` and `TIMEMANP`/`TIMEMANI` are two
pairs that share a kernel name, so the tool reports how many copies of a
fingerprint it found rather than assuming one.

Verified in simulation (`sim/run_sim.sh`): after the boot
test passes, the bench holds the CPU in reset and reads back through the peek
port the pattern stage 02 wrote to RAM at `0x00010000` and two words of the
ROM image it loaded, and all four match. **Verified on the C1100 on
2026-09-08**, driven over UARTbone: a freshly configured card reads zeros from
both RAM and ROM, and after 64 KB of a real BIOS is written into the ROM,
`iop_post.py verify` reads 272 words back at 17 offsets spread through the
image and every one matches the file.

`iop_post.py verify ROM.bin` is the tool that matters here — it samples
windows across a loaded image and compares them with the file, so "the card
holds what I sent" stops being an assumption. No host-side counter can tell
you that: `iop_rom_count` counts writes the host issued, not words the fabric
stored.

## Driving the card without a driver, and without root

`tools/ps2iop/iop_post.py` and `bios_run.py` now take `--uart [/dev/ttyUSB2]`
and reach exactly the same registers over the card's UARTbone through
`litex_server` instead of over PCIe. That needs no kernel driver, no generated
`litepcie.ko` and no root at all — the FTDI tty is enough — which is the only
way in when PCIe is down, and the easiest way in on someone else's machine.

The cost is bandwidth. UARTbone at 115200 baud carries about 850 register
writes a second, so the 4096-word boot test loads in five seconds and a 4 MB
BIOS takes about twenty-five minutes; over PCIe the same BIOS is a couple of
seconds. Two details had to change for the long transfer to work at all: the
`RemoteClient` timeout (litex defaults to two seconds, and worse, silently
returns default values on a timeout unless `raise_on_timeout` is set, which
would look like real register data), and pacing — an unpaced write burst fills
the socket faster than the UART empties it, so the ROM load now reads a
register back every few thousand words, which both paces the stream and makes
the reported rate honest.

## First runs on the card, 2026-09-08

All three runs below were driven over UARTbone with the diagnostic image
`c1100_ps2_diag` (md5 `43545949277f48ce1463be7ea31b213f`) already on the card,
no PCIe and no root. Logs are in `build/ps2_bios/`.

### The full 4 MB image: the CPU never started

`build/ps2_bios/20260908-155629-ps2-0220a-20060905/`, `0220A` (`20060905`),
1,048,576 words streamed in 951 s:

```
after 30 s: POST 00  post_count 0  cpu_error 0  mem_idle 1
POST ring:  0 writes since reset; 1,110,922,066 IOP cycles (30.127 s)
stall:      idle_cycles 16777215  stalled 1
console:    0 bytes
trace:      8184 samples, 0 bus events
```

Not one POST write, and not one bus request in the whole capture — but the
IOP clock ran (1.11 G cycles in 30.1 s is 36.87 MHz) and `cpu_error` stayed
low. The analyzer's fetch addresses say where the CPU went: 995 distinct
addresses, every one of them between `0x80000080` and `0x80001008`, stepping
by four and cycling. That is the general exception vector and the 4 KB of
zeroed RAM above it, executed as `NOP`s — one instruction cache's worth, which
is why no fetch ever reached the bus.

### The same image truncated to 512 KB: it boots

`build/ps2_bios/20260908-161555-bios-512k/`, the first 512 KB of the same
file, 131,072 words:

```
   # 0  POST FC  at cycle    2721  (0.074 ms)     table B's own write
   # 1  POST 02  at cycle    9426  (0.256 ms)     the PS2 init table
   # 2  POST 03  at cycle   22024  (0.597 ms)
   # 3  POST 04  at cycle   59903  (1.624 ms)
   # 4  POST 05  at cycle   60173  (1.632 ms)
   # 5  POST 08  at cycle   60648  (1.645 ms)
   # 6  POST 09  at cycle   60995  (1.654 ms)     the search for IOPBOOT
stall: idle_cycles 2  stalled 0        (the CPU is still working)
```

That is the xsim sequence of 2026-09-08 exactly — `fc 02 03 04 05 08 09` — at
1.65 ms of IOP time, and the CPU is still issuing bus requests ten seconds
later rather than stalling. So the ROM path, the CPU, the POST register and
the whole reset sequence work on silicon with a real BIOS; what failed above
was the transfer of the 4 MB image, not the boot.

### The full 4 MB image, 2026-09-08 16:56 — it boots

With the peek-port image on the card, the whole `0220A` file loaded, was read
back and compared before reset was released, and ran:

```
loaded 1048576 words in 913 s over the UART
ROM verify: 2064 words at 129 offsets all match ps2-0220a-20060905.bin
POST ring: 7 writes
   FC   0.074 ms     table B's own write
   02   0.256 ms     the PS2 init table, not the PS1 one
   03   0.597 ms
   04   1.624 ms
   05   1.632 ms
   08   1.645 ms
   09   1.654 ms     the search for IOPBOOT
stall: idle_cycles 3   stalled 0      — 36.8 s later the CPU is still working
```

**The two earlier failures are unexplained, not fixed.** Both ran on the
previous bitstream, which had no way to read the ROM back, so there is no
longer any evidence of what was in its ROM — the image, the tool and the file
are the same now and it works. Two hypotheses were tested and killed on the
way: pointer drift in the ROM write port (the anchored load did not fix it)
and the length of the reset assertion (reset was held about fifteen minutes
during this successful load too). What has changed is that the question cannot
be silently open again: `bios_run.py` now verifies the loaded ROM through the
peek port before releasing reset, and logs the result. `iop_rom_count` never
could have answered it — it counts writes the host issued, not words the
fabric stored.

### How far it gets: 21 of the 29 modules

`build/ps2_bios/20260908-boot-4mb/ram-256k.bin`, the first 256 KB of IOP RAM
read through the peek port after 37 seconds of running, against the ROM:

```
  1 SYSMEM     0x00000830     11 HEAPLIB    0x0000a130     17 ROMDRV   0x00015930
  2 LOADCORE   0x00001630     12 EECONF     (not detected) 18 STDIO    0x00016330
  3 EXCEPMAN   0x00003430     13 THREADMAN  0x0000aa30     19 SIFMAN   0x00016a30
  4 INTRMANP   0x000040a0     14 VBLANK     (not detected) 20 IGREETING(not detected)
  5 INTRMANI   0x00003d30     15 IOMAN      0x00012930     21 SIFCMD   0x00017e30
  6 SSBUSC     0x00005c30     16 MODLOAD    0x00013e30     ----------------------
  7 DMACMAN    0x00006030                                  22 REBOOT   not reached
  8 TIMEMANP   (not detected)                              23-29     not reached
  9 TIMEMANI   (not detected)
 10 SYSCLIB    0x00008530
```

The addresses climb monotonically in `IOPBTCONF` order from `0x830` to
`0x17e30`, so this is a real load sequence and not a scatter of coincidental
matches. The five gaps below #21 are modules whose loaded bytes carry no
fingerprint that survives relocation; nothing above #21 is present at all.

**So the IOP kernel loads 21 of its 29 modules and stops after SIFCMD**, the
SIF RPC interface — and it stops *running*, not hanging: the stall detector
reads 3 idle cycles 37 seconds in, so the CPU is spinning, not faulted.

That is exactly where the static analysis said it would stop. SIFMAN (#19)
programs the SIF's registers and DMA channels 5 and 6, and SIFCMD (#21) builds
the RPC layer on top; behind all of it is `iop_regstub`, which stores what is
written and returns it, with no EE on the other side to answer. A kernel that
comes up and then waits for the Emotion Engine is the correct behaviour of
this design, and the next block of work — a real DMA controller and a SIF with
something on the far end — is what moves the number past 21.

## Why it stops after SIFCMD, measured — 2026-09-08

The module map said the boot reaches #21 `SIFCMD` and goes no further, with the
CPU still running. The obvious guess was the DMA controller. **That guess was
wrong**, and the card said so.

With the BIOS still in ROM and the CPU spinning, the LiteScope on the CPU's
memory bus was armed with an unconditional trigger and caught the loop. 309 bus
events, and only three addresses in them:

```
   0xBD000020   x155     SIF MSFLAG
   0x001FFD80   x77      a kernel flag in IOP RAM
   0xBF801078   x77      INTC I_CTRL  (read clears it: CpuSuspendIntr)

   LD 0xbd000020 = 00000000
   LD 0xbd000020 = 00000000      (read twice: sceSifGetMSFLAG de-glitches)
   LD 0x001ffd80 = 00000001
   LD 0xbf801078 = 00000001
   ... forever
```

No instruction fetches appear because the loop fits inside the 4 KB
instruction cache, so only its data accesses reach the bus.

Disassembling `SIFMAN` from the ROM finds the loop exactly:

```
 SIFMAN .text+0x1c8   lui   $s1,0x0001          ; 0x00010000
 SIFMAN .text+0x1ec   jal   0x00000eb0
 SIFMAN .text+0x1f4   jal   0x0000008c          ; sceSifGetMSFLAG
 SIFMAN .text+0x204   addu  $s0,$v0,$zero
 SIFMAN .text+0x208   and   $s0,$s0,$s1         ; MSFLAG & 0x00010000
 SIFMAN .text+0x20c   beq   $s0,$zero,0x1ec     ; spin while clear
```

**The IOP is waiting for MSFLAG bit 16 — and MSFLAG is written by the Emotion
Engine, never by the IOP.** A register stub returns zero forever, so the wait
cannot end. Nothing about DMA is involved: no DMA register appears in the
trace at all.

## The SIF, with the host standing in for the EE

`rtl/iop/iop_sif.vhd` replaces the stub with the real mailbox. The registers
are semaphores rather than storage, which is the part a stub cannot fake:

| | | |
|---|---|---|
| `0x00` | MSCOM | EE writes, IOP reads |
| `0x10` | SMCOM | IOP writes, EE reads |
| `0x20` | MSFLAG | **the EE sets bits; an IOP write clears the bits it names** |
| `0x30` | SMFLAG | **the IOP sets bits (a write ORs them in); the EE clears** |
| `0x40` | CTRL | stored |
| `0x60` | BD6 | SIFMAN reads it early and compares against `0x1D000060` |

Both sides act in the same cycle rather than one assignment overwriting the
other — the IOP clears MSFLAG while the EE sets it, and sequencing those would
silently drop whichever lost, which in a mailbox is a hang waiting to happen.

There is no Emotion Engine, so **the host plays it**. `iop_sif`'s host port is
on CSRs (`iop_sif_data` + `iop_sif_go`, and the five registers readable), and
`tools/ps2iop/iop_post.py sif ee-init` performs the EE's side of the
handshake: put a word in MSCOM, then set MSFLAG bit 16.

```sh
tools/ps2iop/iop_post.py --csr <image>.csr.csv sif            # show the mailbox
tools/ps2iop/iop_post.py --csr <image>.csr.csv sif ee-init    # answer as the EE
tools/ps2iop/bios_run.py <rom0.bin> --ee-init                 # boot, then answer
```

Verified in simulation: boot-test stage `0C` is the same handshake in
miniature — the IOP publishes `SMFLAG = 0x00010000`, the testbench notices,
writes `MSCOM` and sets `MSFLAG` bit 16, and the IOP sees it, clears it and
reads the mailbox back. With the SIF as a stub that stage never ends.

### On silicon, 2026-09-08 19:40 — the IOP kernel finishes booting

Bitstream `d48bfa2a4fb7071dc221e376163701f0`, over PCIe (the 4 MB BIOS loads in
**1.8 s** at 581k words/s, against sixteen minutes over the UART), verified
against the file at 97 sampled windows first.

From a cold boot the mailbox is empty and the CPU is on the MSFLAG spin. One
host write — MSFLAG bit 16, the Emotion Engine's part — and:

```
before the EE answers:  MSCOM 00000000  SMCOM 00000000  MSFLAG 00000000  SMFLAG 00000000
after:                  MSCOM 00000000  SMCOM 00019600  MSFLAG 00010000  SMFLAG 00070000
```

`SMFLAG = 0x00070000` is `SIF_STAT_SIFINIT | SIF_STAT_CMDINIT |
SIF_STAT_BOOTEND` (0x10000 / 0x20000 / 0x40000 in PS2SDK). **BOOTEND is the
IOP telling the EE that its boot is over.** `SMCOM = 0x00019600` is the IOP
publishing the address of its SIF0 receive buffer in RAM, which is the other
half of what the handshake is for. Reproducible from reset.

The module map moves accordingly — 21 before, **28** after:

```
 22 REBOOT    0x0001a930      25 CDVDFSV   0x00039330
 23 LOADFILE  0x0001ae30      27 FILEIO    0x0003fd30
 24 CDVDMAN   0x0001ce30      28 SECRMAN   0x00041a30
```

`CDVDMAN` is 113,728 bytes of driver and it initialised against the CDVD
register block with no disc behind it, which is the answer to whether the stub
was good enough for the boot: it was.

**All 29 are accounted for.** `EESYNC`, `SIFINIT` and `IGREETING` are absent
from RAM because they are meant to be: their entry points return 1
(`NO_RESIDENT_END`), so LOADCORE runs them once and frees them. EESYNC
demonstrably ran — it is the module that calls `sceSifSetSMFLAG(0x40000)`,
and BOOTEND is set.

Afterwards the CPU goes quiet: an 8184-sample capture of the CPU's memory bus
contains **no bus events at all**, and the stall detector reads 113,743 idle
cycles (3.1 ms) without tripping its 114 ms threshold. So it is running and
occasionally waking — the shape of a kernel idle thread with a timer — rather
than either spinning or hung.

> *Verify by:* the exact identity of the idle loop is inferred from the absence
> of bus traffic and from the stall detector, not from a program counter. The
> instruction cache satisfies the loop, so the fetches never reach the bus.

### The DMA controller does not disturb any of it — 2026-09-08

Adding a third master to the RAM port is exactly the kind of change that breaks
something that already worked, so it was checked rather than assumed. With
`iop_dma` present (md5 `244d7d90a68435b6b5e978fa09e8d179`), the same 4 MB
`0220A` image, verified against the file at 65 windows:

```
before the EE answers:  POST 09   SMFLAG 00000000
after MSFLAG bit 16:    SMFLAG 00070000 = SIFINIT | CMDINIT | BOOTEND
                        SMCOM  00019600   cpu_error 0
module map:             reached #28 SECRMAN, 22 of 29 fingerprinted
```

Identical to the run before the DMAC existed. The boot test also passes all
fifteen stages on the card in 5.54 ms, `0D` among them, which is the DMA
controller moving real data on real fabric.

## Known limitations

- `iop_regstub` ignores the bus write mask: a halfword or byte store writes the
  whole 32-bit register. SIFMAN does write DMA block counts with `sh`
  (`0x1F8010A4`, `0x1F801524`, `0x1F801534`), so those registers hold the
  wrong value in the stub. Nothing reads them back for anything today, but the
  mask has to go in when the DMA controller becomes real — the memory mux
  already exports write masks for the CDVD, SIO2 and SPU2 buses and would need
  the same four for DMA, DMA2, SSBUS2 and SIF.
- The address recovery in `--hw` misses addresses formed through a pointer in
  memory, which is how DMACMAN reaches its channel registers, so treat the
  table above as the minimum set.
