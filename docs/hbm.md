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

8 GiB is enough to hold a single-layer disc outright and enough to keep the
working set of even the largest dual-layer title resident. Stage the image into
HBM and the disc is simply *there*: the CDVD block reads sectors
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

## A memory map, and why the disc region is a cache

The disc does **not** get a whole-image copy, and the arithmetic is worth
setting out because it is closer than it looks.

A dual-layer DVD9 holds 8.54 x 10^9 bytes, which is **7.95 GiB**. The HBM on
these parts is two 4 GiB stacks, **8 GiB** = 8.59 x 10^9 bytes. So a maximal
DVD9 image does technically fit — with about 50 MiB to spare, and nothing left
for the EE's 32 MiB of main memory, the BIOS ROM, or any headroom at all. Some
images are larger still: Gran Turismo 4 is the usual example of a title that
fills a DVD9, and PAL releases of it are reported at over 9 GB. God of War,
God of War II and Xenosaga Episode I are in the same class.

Treating "does this game fit?" as a question the design has to answer is the
wrong shape. So the disc region is a **cache over the host-held image**, and
the size of the game stops mattering:

| base | size | region |
|---|---:|---|
| `0x0_0000_0000` | 6 GiB | **disc sector cache**, 6144 chunks of 1 MiB |
| `0x1_8000_0000` | 32 MiB | EE main memory, for when there is an EE |
| `0x1_8200_0000` | 4 MiB | **IOP BIOS ROM** |
| `0x1_8240_0000` | 2 MiB | IOP RAM (optional) |
| `0x1_8260_0000` | ~1.96 GiB | free: working buffers, headroom |

### Why 6 GiB, and what falls outside it

6 GiB is chosen so that the overwhelming majority of titles are **entirely
resident** and the cache never misses after staging. A single-layer DVD5 is
4.38 GiB, comfortably inside it. What sits outside divides into three cases,
and they are genuinely different problems:

* **Genuine dual-layer single-disc titles.** Gran Turismo 4 is the usual
  example; God of War, God of War II and Xenosaga Episode I are in the same
  class. These are one disc of up to 7.95 GiB, so a 6 GiB cache holds most but
  not all of it. **These work**: the cache keeps the working set and takes an
  occasional miss, which the IOP sees as a slow sector. Nothing special is
  needed for them.
* **Multi-disc games.** Each disc is its own image and each fits easily; the
  game asks the player to swap discs as it always did. What this needs is not
  memory but a *disc change* — the interface tells the CDVD block the disc went
  away and came back, and the new image is staged. That is a feature to build,
  not a limit to work around, and it is the same thing a person with a real
  drive does.
* **Patched combined images**, where someone has merged both discs of a
  two-disc game into one file. These are the awkward case, and not because of
  size: the filesystem layout is not what the game expects, and the game's own
  disc-swap logic has nothing to swap to. That is a compatibility problem
  rather than a memory one, so it is **deliberately deferred**, with a list of
  known-unsupported images kept rather than a half-working guess at handling
  them.

Sizing the HBM region to swallow the largest image anyone has ever built would
cost the space the BIOS ROM and the EE's main memory need, and those are what
make the system fast. 6 GiB is the allocation that serves nearly every disc
fully and degrades gracefully rather than the one that serves every conceivable
file and starves everything else.

### One mechanism, not two

The point of a cache here is that **a small disc is simply one that never
misses.** A 4.7 GiB single-layer title is resident in its entirety after it is
staged and behaves exactly like a whole-image copy; an 8.5 GB title keeps its
working set resident and takes an occasional miss. There is no "small game
path" and "large game path" to write, test and keep in step — which is what
makes it worth building this way from the start rather than retrofitting it
when the first DVD9 title fails.

Sketch, at the level a later implementation should start from:

* **Chunk**: 1 MiB, 512 sectors. Big enough that the tag table is small and a
  miss amortises over many sectors; small enough that a miss costs a
  millisecond rather than a second.
* **Tags**: 6144 entries, one per slot, holding the disc chunk resident there
  and a valid bit. 24 KiB — block RAM, not HBM.
* **Mapping**: direct-mapped, `slot = chunk mod 6144`, which is a mask rather
  than a divide if the count is a power of two (4096 slots = 4 GiB is the
  tidier choice if the arithmetic matters more than the capacity).
* **Miss**: the CDVD read stalls, the host is asked for that chunk, it lands by
  DMA, the tag updates, the read completes. The IOP sees a slow sector, which
  is exactly what a real drive gives it.
* **Prefetch**: reading near the end of a chunk fetches the next one. Game
  streaming is overwhelmingly sequential, so this is most of the benefit for
  very little logic.

> **NOTE (unverified):** hit rates, the right chunk size and whether prefetch
> is worth its complexity are all guesses until something real reads a disc.
> *Verify by: logging the CDVD sector requests of an actual boot and an actual
> game load, then replaying them against candidate cache geometries offline —
> which needs no gateware and can be done as soon as the CDVD read path
> produces a request log.*

**None of this is needed for the first working version.** The host-served path
serves any disc of any size today, just slowly. The cache is what makes it
behave like a console, and the reason it is written down now is so that the
CDVD block is built with a sector *source* behind an interface rather than a
host round trip baked into it.

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
