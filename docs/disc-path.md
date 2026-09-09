# The disc path: from a file, a drive or a disc, to the IOP

What has to exist before the PS2 can read a game, how the pieces divide between
the card and the host, and why the host side is one abstraction rather than
three.

**Status: design and host side. No gateware yet.** The reference implementation
on the host works and is checked against a real disc; the CDVD read path and
the DMA channel it needs are the next things to build.

## The shape of it

```
   a file          a block device        a drive with a disc
   game.iso           /dev/sdb                /dev/sr0
        \                 |                      /
         \                |                     /
          +----- tools/ps2iop/discsource.py ---+        "give me sector N"
                          |
                    (PCIe, or HBM)
                          |
                    CDVD block  ---- DMA channel 3 ---->  IOP RAM
                          |
                   CDVDMAN in the BIOS
                          |
              IOMAN / ISO9660 -> SYSTEM.CNF -> the game's ELF
```

The console asks for **sectors**. Everything above `discsource.py` decides where
a sector comes from; nothing below it needs to know. That is what lets an
interface offer "play from an image" and "play from the drive" as the same
feature, and it is why those three sources are one class on the host and not
three code paths through the gateware.

On Linux they genuinely are the same thing — an ISO file, a raw block device
and an optical drive are all opened, seeked and read identically, and a PS2
disc is 2048-byte sectors in all three cases. The differences that do exist are
handled once, on the host: a drive can be empty or spinning up (`ENOMEDIUM`,
`EIO` — a state to report, not a crash), a drive seeks badly so reads are
cached, and a truncated image must report a short read rather than return zeros
that look like a legitimately blank sector.

## What exists today

| | |
|---|---|
| `tools/ps2iop/discsource.py` | the abstraction above: image, block device or drive, with caching and honest errors |
| `tools/ps2iop/isoread.py` | walks a disc as the BIOS will — volume descriptor, root directory, `SYSTEM.CNF`, the boot executable |
| `tools/ps2iop/mkiso.py` | builds a disc-shaped test image, sparse, with far-end LBAs |

Checked against a real disc (Star Wars Battlefront II, USA, v2.01):

```
   4,665,671,680 bytes / 2,278,160 sectors, label '2_01'
   root directory at LBA 261
   SYSTEM.CNF at LBA 2,265,115:  BOOT2 = cdrom0:\SLUS_212.40;1
   SLUS_212.40  at LBA 2,265,116, 166,708 bytes, valid ELF magic
```

**That is the pass criterion.** When the hardware reads that disc through the
BIOS's own `CDVDMAN` and `IOMAN` and answers `SLUS_212.40`, the disc path
works — with no Emotion Engine and no pixel drawn.

> The files the BIOS needs are at the **far end** of the disc, LBA 2,265,115 of
> 2,278,160. A read path that truncated an LBA to 16 or 20 bits would find the
> volume descriptor at sector 16 and then fail on the one file that matters, so
> the test image is built with the same shape (`mkiso.py --sectors`).

## What has to be built

### 1. The IOP DMA controller, channel 3

Sector data reaches IOP memory by DMA on channel 3; `CDVDMAN` programs
`0x1F8010B0`/`B4`/`B8` and waits for the completion interrupt. Today the DMAC
is an `iop_regstub`, so nothing moves. **This is now on the critical path** —
it was not what blocked the kernel boot, but it is what blocks the disc.

PSX_MiSTer has a PS1 DMA controller and the IOP's is that plus a second bank of
channels, so this follows the pattern the rest of the IOP was built on.

### 2. The CDVD read path

`rtl/iop/iop_cdvd.vhd` answers the boot-time S commands and reports no disc.
It needs the N command read path: a read command takes **LBA in parameter bytes
0-3, sector count in 4-7**, a retry count, spindle control, and a block-size
mode byte (2048 for the DVD case). Completion sets the data-ready status and
raises `I_STAT` bit 0 and INTC bit 2.

**The opcodes are now measured, from this BIOS.** `CDVDMAN` issues every N
command through a single dispatcher at `.text+0x2ee8`, whose prologue parks
`$a0` as the opcode, `$a1` as the parameter buffer and `$a2` as the parameter
count. Its thirteen call sites give the command set directly:

| opcode | parameters | |
|---|---:|---|
| `0x00`-`0x05` | few, or passed in a register | NOP, reset, standby, stop, pause, seek |
| **`0x06`, `0x07`, `0x08`** | **11** | **the sector reads**: LBA(4), sector count(4), retry, spindle, mode |
| `0x09` | 1 | two call sites |
| `0x0C` | 7 | |

Eleven parameters is the signature: it is exactly the read layout PCSX2
documents. An earlier guess in `iop_cdvd.vhd` had the read set as
`0x06|0x08|0x0A|0x0C|0x0E` — two commands that are not reads, and one real one
missing. It now matches the BIOS.

**Watching the hardware was tried first and did not answer it**, which is worth
recording. With a disc reported present, the booted kernel issued thirteen
commands and every one was an S command: `0x40` / `0x41`×n / `0x43`, three
times over — the MechaCon NVM config read, fetching language, timezone and
screen settings. Not one N command. After `BOOTEND` the IOP idles waiting for
the Emotion Engine, and on a real console it is the EE that asks for files, so
no disc read is ever initiated with no EE present. The command log
(`iop_post.py cdvd log`) is what established that, and it stays useful for
watching a read once something asks for one.

### 3. A sector source behind it

Two stages, and the second is the one worth having:

* **Host-served.** The CDVD block raises a request with an LBA; the host reads
  that sector from the `DiscSource` and writes it back over PCIe. Simple, needs
  no HBM, and the round trip is milliseconds — slower than a real drive but
  entirely usable for bring-up.
* **HBM-backed.** The card's HBM holds a **cache** of the disc rather than a
  copy of it, so the size of the game stops being a question the design has to
  answer: a single-layer title ends up resident in its entirety and never
  misses, and a dual-layer one keeps its working set resident and takes an
  occasional miss. One mechanism, not a small-disc path and a large-disc path.
  [hbm.md](hbm.md) has the geometry and the arithmetic — a maximal DVD9 is
  7.95 GiB against 8 GiB of HBM, which fits only by leaving nothing for
  anything else, which is why a cache and not a copy.

### What is supported

| | |
|---|---|
| single-layer disc (up to 4.38 GiB) | fully resident in the cache; never misses after staging |
| dual-layer single-disc title (up to 7.95 GiB) | works, partially resident, occasional miss |
| multi-disc game, one image per disc | each disc fits; needs a *disc change* in the interface, which is a feature rather than a limit |
| **patched image merging both discs into one file** | **not supported**, and deferred deliberately — the problem is the filesystem layout and the game's own swap logic, not the size. A list of known images is kept rather than a half-working guess |

`tools/ps2iop/discsource.py info` classifies an image against those cases, so
the answer comes from the tooling rather than from someone remembering.

**This is the reason the CDVD block must be built with a sector *source* behind
an interface, rather than with a host round trip baked into it.** The IOP
cannot tell the two apart, and the second can then replace the first without
touching anything above it.

The IOP cannot tell the two apart, so the first can ship and be replaced.

## The sector port, and the bug only the card could find (2026-09-09)

The CDVD asks for one sector at a time: `iop_cdvd_sec_req` goes high with the
wanted LBA in `iop_cdvd_sec_lba`, the host writes 512 words to
`iop_cdvd_sec_data`, then pulses `iop_cdvd_sec_done`. The write pointer is kept
in the gateware so a sector costs 512 CSR writes rather than 1024.

That pointer is where the first real sector read went wrong, and the shape of
the mistake is worth keeping. `sec_ptr` increments on the CSR write strobe, but
the write pulse only reaches the IOP clock domain a few cycles later, through
`sec_arm`/`sec_go` and a `PulseSynchronizer`. Crossing the *live* pointer meant
that by the time the pulse arrived it already read N+1, so word N was written at
index N+1 and the whole sector landed shifted by one word. The card read the
real disc and put this in IOP RAM:

```
00050000: 00000000   <- never written
00050004: 30444301   <- word 0 of sector 16
00050008: 00013130   <- word 1
0005000c: 59414c50      "PLAY"
00050010: 54415453      "STAT"
```

The data was right, the alignment was not. The fix is to latch the pointer at
the moment of the write and cross *that*, so address and data travel together.
With that in place the card reads sector 16 of a real disc and IOP RAM at
0x50000 holds `CD001 PLAYSTATION ... 2_01`, byte-identical to the image.

The general point: **the testbench cannot find this class of bug.** It drives
`sec_waddr`/`sec_wdata`/`sec_we` directly, with the alignment correct by
construction, because modelling the CSR path and its clock-domain crossings in
the IOP bench would mean modelling LiteX. Everything between a CSR and the IOP's
clock domain is therefore only ever tested on the card, which is an argument for
the hardware test checking *contents* — this bug passes any check that only asks
whether a sector arrived.

## Measured on the card

A poll of a CDVD register costs about **9.3 us** of IOP time -- the boot test's
0E wait loop runs 131072 iterations and takes 1.22 s when no sector ever
arrives, against the ~25 ms that instruction count would suggest at 36.864 MHz.
So roughly 340 cycles per peripheral read. Everything else is fast: stages 01
through 0D together take 20 ms. This is worth knowing before sizing any timeout
that polls CDVD, and before reading anything into how long the real BIOS spends
waiting on the drive.

## Order

1. DMA channel 3, verified by the OTC channel and a loopback that needs no disc.
2. The CDVD N read command, against a host-served sector.
3. The BIOS reading `SYSTEM.CNF` off a test image — first real milestone.
4. The same against the real disc, expecting `SLUS_212.40`.
5. HBM as the backing store, which changes nothing above it.
