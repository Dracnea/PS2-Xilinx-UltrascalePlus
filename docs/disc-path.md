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

> **NOTE (unverified):** the numeric N command opcodes are not recorded here.
> `ps2tek` documents the register map but not the command set, PCSX2 is the
> only executable reference, and `CDVDMAN` takes its opcodes in a register from
> its callers rather than as immediates, so they cannot be read out of the ROM
> statically. *Verify by: watching writes to 0x1F402004 on the LiteScope while
> the booted kernel issues a real read — the instrument for that already exists
> and the answer will be this BIOS's own, which is the one that matters.*

### 3. A sector source behind it

Two stages, and the second is the one worth having:

* **Host-served.** The CDVD block raises a request with an LBA; the host reads
  that sector from the `DiscSource` and writes it back over PCIe. Simple, needs
  no HBM, and the round trip is milliseconds — slower than a real drive but
  entirely usable for bring-up.
* **HBM-backed.** Stream the whole image into the card's 8 GB of HBM once, and
  the CDVD block reads sectors from memory with no host in the loop. A 4.7 GB
  disc at PCIe speed is a few seconds to load and then behaves like a disc that
  is simply *there*. See [hbm.md](hbm.md).

The IOP cannot tell the two apart, so the first can ship and be replaced.

## Order

1. DMA channel 3, verified by the OTC channel and a loopback that needs no disc.
2. The CDVD N read command, against a host-served sector.
3. The BIOS reading `SYSTEM.CNF` off a test image — first real milestone.
4. The same against the real disc, expecting `SLUS_212.40`.
5. HBM as the backing store, which changes nothing above it.
