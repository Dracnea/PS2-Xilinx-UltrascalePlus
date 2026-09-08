# HBM: what it is good for here, and what it is not

Both target cards carry 8 GB of HBM2 that no design in this repository has yet
touched. It is the obvious answer to the UltraRAM ceiling in
[cards.md](cards.md), but only for some of the things that could go in it, and
the difference matters enough to write down before anything is built.

## What the hardware offers

| | |
|---|---|
| capacity | 8 GB (two 4 GB stacks) on both `xcu55n` and `xcvu33p` |
| organisation | 32 independent pseudo-channels |
| per channel | a 256-bit AXI port at up to 450 MHz = **14.4 GB/s** |
| aggregate | **460.8 GB/s** |
| reach | a built-in switch lets any AXI port address any pseudo-channel, so the full 8 GB is reachable from one port |
| access | the Xilinx HBM IP, configured in IPI or the IP GUI, presenting AXI |

> **NOTE (unverified): read latency.** HBM2 latency is what decides two of the
> four cases below and no figure here is measured. The working assumption is
> 100-150 ns; a single AXI transaction on a lightly loaded port should be near
> the low end. *Verify by: an AXI traffic generator on one pseudo-channel with
> a LiteScope on the ready/valid handshake, before committing any latency-
> sensitive block to it.*

## What should move, and what should not

The IOP costs **224 UltraRAMs** — 35 % of a C1100, **70 % of an FK33**. Where
those go:

### 1. The BIOS ROM (4 MB, 128 URAM) — **move it**

The strongest case, and it is not close. The IOP's instruction fetch from ROM
is uncached and already costs about **33 IOP cycles** per instruction, because
the PSX memory controller honours the BIOS access delay — 895 ns at
36.875 MHz. An HBM read at an assumed 100-150 ns is **4 to 6 IOP cycles**,
comfortably inside a budget the design already tolerates and does not notice.

So the 4 MB ROM can leave the die for free, and that single change is what
makes a whole console plausible on the FK33:

| | URAM on chip | FK33 (320) |
|---|---:|---:|
| IOP as built today | 224 | 70 % |
| IOP with the ROM in HBM | 96 | 30 % |
| ...plus the GS's 4 MB local memory | 224 | 70 %, and it fits |

### 2. Game data — **move it, and this is the interesting one**

8 GB holds an entire dual-layer disc with room to spare. Stream the image into
HBM once over PCIe and the disc is simply *there*: the CDVD block reads sectors
from HBM with no host in the loop, no per-sector round trip, and seek times
that are a memory latency rather than a drive's. That is much closer to how a
console behaves than a host answering every sector, and it is the reason the
disc path and HBM belong in the same conversation — see
[disc-path.md](disc-path.md).

Access is bulk and sequential, latency-tolerant and bandwidth-friendly: exactly
what HBM is built for.

### 3. IOP RAM (2 MB, 64 URAM) — **possible, not urgent**

The same latency argument applies (roughly 4 IOP cycles), but this is the CPU's
working memory rather than a cold ROM, so it is more exposed to a latency
figure that has not been measured. Worth doing only if the URAM is actually
needed; the ROM alone frees twice as much.

### 4. GS local memory (4 MB, 128 URAM) — **leave it in UltraRAM**

The Graphics Synthesiser's whole design is a very wide, very random port into
4 MB: the real one runs 2048 bits at 147.456 MHz, about **38 GB/s**, mixing
framebuffer, Z-buffer and texture reads. One HBM pseudo-channel gives 14.4
GB/s, so it would take three or more channels *and* an access pattern that HBM
handles worse than sequential streaming.

UltraRAM is the right primitive for this: 4096 x 72 bits per block, two ports,
a couple of cycles of latency, and the bandwidth scales with how many blocks
are ganged. The GS's local memory is the one thing on this list that genuinely
wants to be on the die.

## Order of work

1. Measure the latency. Everything above turns on a number nobody here has
   measured, and it is an afternoon with a traffic generator and a LiteScope.
2. The BIOS ROM. Biggest URAM win, least latency risk, and `iop_ram` already
   makes the ROM depth a generic (`ROM_ROWS_LOG2`), so the change is contained.
3. The disc in HBM, as the CDVD block's backing store.
4. IOP RAM, if a later block needs the UltraRAM.
5. Never the GS's local memory.

Nothing here blocks the disc path: the first version serves sectors from the
host over PCIe, and HBM replaces the host as the source without the IOP or the
CDVD block noticing.
