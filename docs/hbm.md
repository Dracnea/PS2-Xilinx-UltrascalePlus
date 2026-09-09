# HBM: what it is good for here, and what it is not

Both target cards carry 8 GB of HBM2 that no design in this repository has yet
touched. It is the obvious answer to the UltraRAM ceiling in
[cards.md](cards.md), but only for some of the things that could go in it, and
the difference matters enough to write down before anything is built.

## Verified on the card (2026-09-09)

The HBM works, and all 8 GB of it is reachable through a single AXI port. On the
C1100 with `bitstreams/c1100_hbm_test.bit` and `tools/ps2iop/hbm_test.py`:

```
1. hbm_init_done = 1  (both stacks up)
   0x0_00000000 ok   0x0_80000000 ok   0x0_FFFFFFE0 ok      (stack 0)
   0x1_00000000 ok   0x1_40000000 ok   0x1_FFFFFFE0 ok      (stack 1)
4. aliasing: distinct, so no address bit is being lost
PASS
```

The stack-1 addresses are the ones that matter. The HBM IP defaults to 32-bit
AXI addressing, which reaches 4 GB -- one stack -- and a design that silently
wrapped would look perfect until a disc image grew past 4 GiB.
`ip/hbm/gen_hbm.tcl` sets 33 bits, and the aliasing check is there because a
dropped high address bit shows up as two addresses sharing a value rather than
as an error.

Everything below this line was written before that run and is unchanged by it.

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
| `0x1_8000_0000` | 32 MiB | EE main memory |
| `0x1_8200_0000` | 4 MiB | **IOP BIOS ROM** |
| `0x1_8240_0000` | 2 MiB | IOP RAM (optional) |
| `0x1_8260_0000` | 64 MiB | PCRTC -> host video ring |
| `0x1_8660_0000` | 4 MiB | SPU2 -> host audio ring |
| `0x1_86A0_0000` | ~1.90 GiB | free: working buffers, headroom |

Committed: **6.10 GiB of 8 GiB**, leaving 1.90 GiB. Note that the 4 GiB stack
boundary (`0x1_0000_0000`) falls *inside* the disc cache, so the cache spans both
stacks while everything else sits in stack 1. That is a deliberate choice —
sector traffic is bulk and latency-tolerant, so it is the region that can best
afford whatever the inter-stack switch costs, and it keeps the EE's main memory
on a single stack. It also means the AXI ports must be configured for 33-bit
addressing: the IP's 32-bit default reaches one stack only, and a design that
silently wrapped would look perfect until an image grew past 4 GiB.
`ip/hbm/gen_hbm.tcl` sets 33 bits and `tools/ps2iop/hbm_test.py` checks it.

### The GS's local memory, and what actually forces HBM

Reviewed 2026-09-09, because "what does the GS need?" is the natural next
question and the answer is not the obvious one. Held on-die, at this project's
measured 4 MB = 128 URAM:

| held in UltraRAM | URAM | C1100 (640) | FK33 (320) |
|---|---:|---:|---:|
| GS local memory (4 MB) | 128 | 20 % | 40 % |
| IOP BIOS ROM (4 MB) | 128 | 20 % | 40 % |
| IOP RAM (2 MB) | 64 | 10 % | 20 % |
| EE scratchpad (16 KB) | <1 | — | — |
| **EE main memory (32 MB)** | **1024** | **160 %** | **320 %** |

The GS's 4 MB stays in UltraRAM: the bandwidth argument above is unchanged, and
at 20 % of the C1100 it is affordable. Nothing about the GS needs an HBM
allocation — a real PS2 keeps textures *in* that 4 MB and streams them there
over the GIF, so there is no second texture pool to budget for.

The line that matters is the last one. **The EE's 32 MB of main memory is 1024
URAM — more UltraRAM than either card physically has**, 1.6x the C1100's entire
supply and 3.2x the FK33's. So HBM is not an optimisation for the EE the way it
is for the BIOS ROM; it is the precondition for an EE existing at all on these
parts. Every one of the twelve EE blocks is downstream of the memory working.

What the review did add to the map is the two host-facing rings. The video path
from card to host already works at 60 fps with a test pattern, and when a real
PCRTC feeds it the frames have to be staged somewhere: 64 MiB is roughly twelve
buffers at the PS2's largest output (1280x1024x4 = 5.24 MiB), which is far more
queue than 60 fps needs and costs 1 % of the device. Audio is the same shape and
much smaller. Both are guesses at the right depth rather than measurements, and
both are cheap enough that being wrong by 2x changes nothing.

> **NOTE (unverified):** the ring depths above are sized by arithmetic, not by
> measurement, and no PCRTC or SPU2 output path exists yet to measure.
> *Verify by: instrumenting the existing card-to-host video path for underruns
> at its real frame rate once something other than a test pattern feeds it.*

### Both memories now exist, and the URAM figure is measured

`rtl/gs/gs_lmem.vhd` and `rtl/ee/ee_ram.vhd`, checked together in
`sim/mem/run_sim.sh` and fitted out of context with `fit/fit_mem.tcl`
(xcu55n, 2026-09-09):

| block | URAM | BRAM | LUTs | registers |
|---|---:|---:|---:|---:|
| `gs_lmem` — 4 MB, 256-bit dual port | **128 (20 %)** | 0 | ~0 | 270 |
| `ee_ram` — the 32 KB cache; the 32 MB is in HBM | 0 | 8 | 981 | 1226 |

So the 128-URAM figure this budget rests on is now synthesis's number rather
than arithmetic. The EE's cache costs 8 block RAMs and essentially no fabric.

The simulation runs the EE's cache against a behavioural HBM with a real
120 ns latency, because a zero-latency model would let a cache that hides
nothing pass: **a miss takes 156 ns and a hit 16 ns**, and the bench fails if a
hit is not faster than a miss, or if the hit and miss counts are not what the
access pattern implies.

Three lessons from fitting these, all of them about inference rather than logic,
and all recorded in the files themselves:

* A **3D array is not a memory**. `gs_lmem` was first written as banks-of-rows;
  synthesis warned about "3D-RAM ... 33554432 registers" and then ground for
  eleven minutes building flip-flops. A flat 2D array infers UltraRAM at once.
* A memory read **combinationally** cannot be block RAM. Reading the cache's
  data array in the same cycle as the tag compare put all 32 KB in distributed
  RAM. Reading tag and data speculatively on the request edge and comparing the
  cycle after is both the fix and how a cache actually works.
* **One read statement and one write statement.** With the write-hit and the
  line-fill writing the array from two places, synthesis reported "Infeasible
  attribute ram_style = block" and spent 14208 LUTs on it. Collapsing them into
  a single assignment fed by the state machine took it to 8 BRAMs and 981 LUTs.

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

## Staging a disc into HBM by DMA — working, 2026-09-09

The whole 4.34 GiB Star Wars Battlefront II image goes into HBM in **6.3 s**
(0.74 GB/s), and reading it back finds the filesystem where it belongs:

```
LBA 16      signature 'CD001'  label '2_01'   root directory at LBA 261
root dir    SYSTEM.CNF at LBA 2265115, 57 bytes
SYSTEM.CNF  BOOT2 = cdrom0:\SLUS_212.40;1
SLUS_212.40 at LBA 2265116, magic \x7fELF
```

That walk uses **only what HBM returned**, not the file, so it is the same
traversal `CDVDMAN` will make. It also exercises the far-end case
[disc-path.md](disc-path.md) warns about: `SYSTEM.CNF` sits at LBA 2,265,115 of
a 2,278,160-sector volume, so a truncated LBA would find the volume descriptor
and then fail on the one file that matters. Beyond the structures, 400
non-zero 32-byte beats sampled from 24 windows spanning the image are
byte-identical, the highest at `0x10a911920` — past the 4 GiB mark, which is
what checks the 33-bit HBM addressing.

`tools/ps2iop/hbm_stage.py` remains the right tool for a handful of sectors; it
writes through the probe at about ten CSR round trips per 32-byte beat, which is
fine for proving the memory and hopeless for a game.

### The IOP reads the disc out of HBM — 2026-09-09

With the image staged, `iop_hbm_disc_enable` hands the CDVD its sectors from
HBM and no host program runs at all. Boot-test stage `0E` passes five times
consecutively with `discserve.py` absent, and the disc source reports
`resp=0` with its `served` counter advancing one per run.

The control that makes that evidence is moving `iop_hbm_disc_base` so LBA 16
lands on the SYSTEM.CNF sector instead of the volume descriptor. Stage `0E`
then fails, and IOP RAM at `0x50000` holds

```
BOOT2 = cdrom0:\SLUS_212.40;1\r\nVER = 2.0...
```

which is worth more than the passing run. It shows the read really goes to HBM
rather than to a buffer left full by the previous test, that the base register
steers it, and that **the address path works past 4 GiB** — that sector is at
byte 4,638,955,520, needing bit 32 of the 33-bit address. The IOP has read the
far-end file this project kept warning about, through `CDVDMAN`'s own path.

Sector 16 alone would not have shown any of that: it begins with a fixed
ISO9660 signature, so "we saw CD001" is satisfied by a stale buffer, a wrong
base, or a lucky guess.

**A sector is four AXI bursts, not one.** The HBM controller's
`AXI_xx_ARLEN`/`AWLEN` are `[3:0]`, so a burst is at most 16 beats (PG276).
The disc source asked for the whole 2048-byte sector as one 64-beat burst,
and nothing rejected it: `ARLEN` truncated to 4 bits, HBM returned 16 beats,
and the master waited forever for the seventeenth with `resp=0`, because the
sixteen it got were fine. `iop_hbm_disc_stat` showed `state=R` on 1,872
consecutive samples, which is what localised it.

The other two masters were fine by accident rather than by design: the probe
reads single beats, and the DMA writer happened to use bursts of exactly 16.
Every AXI master on this device must keep `AxLEN <= 15`, and it is worth
checking that before adding a third.

### Four faults, each hiding the next

Worth writing down, because the first three all presented as *"the HBM DMA
writer hangs"* and none of them was the HBM DMA writer. It reported
`busy=1 written=0 state=W bursts=1 stalled=1` throughout — correctly saying HBM
had accepted an address and no data was arriving. The instrumentation added the
day before is what made each layer legible in one run instead of by inference.

1. **The driver was built for a different design.** `pcie-bringup.sh` defaulted
   to a hardcoded image when run with no argument. That design places
   `pcie_dma0` at 0x1800; the image on the card places it at 0x3000, where 0x1800
   is the HBM probe. Every DMA register write from the driver landed on the probe
   or on nothing, and every ioctl returned success. The kernel log had recorded
   it as `Version \x01` — the identifier read at the wrong address — and nobody
   read the log. Both scripts now prevent this; see
   [../bitstreams/MANIFEST.md](../bitstreams/MANIFEST.md).

2. **The driver zeroes a register this design does not have.** The driver writes
   its loopback flag to a fixed `base + 0x40` (`PCIE_DMA_LOOPBACK_ENABLE_OFFSET`),
   which holds the loopback CSR only in a design built with `with_dma_loopback`.
   This design sets it False, so `buffering_reader_fifo_control` occupies that
   address — and `litepcie_dma_init()` calls `set_loopback(fd, 0)` on every run.
   The buffering FIFO accepts a word only while `level < depth`, so a depth of
   zero means it never accepts one and the DMA Reader is backpressured forever.
   It hits the reader's control at 0x3040 and never the writer's at 0x3048, which
   is the asymmetry that identified it. What makes this one nasty is that
   **descriptors still retire and the table still drains**: retirement follows the
   PCIe completions, not the data being consumed, so the reader looks alive from
   every register software can see. `hbm_dma_stage.c` now restores the depth after
   init and reads it back.

3. **The packer carried a beat across transfers.** `acc`/`half`/`full` were never
   cleared on start, so a beat left packed by one run became the first beat of the
   next and displaced the entire image by 32 bytes. Every byte correct, all of it
   one beat late — which reads as a working transfer until something checks
   alignment, and the byte counter says PASS either way. The packer now refuses
   data unless armed and is flushed by `start`.

4. **The ring cannot be filled while the card is reading it.** The DMA Reader runs
   its descriptor table in **loop mode**: once enabled it streams the ring
   continuously and never waits for software. `reader_sw_count` is advisory
   bookkeeping rather than a gate — `hw_count` was observed *ahead* of it — so a
   fill-ahead loop is a race against a 1.4 GB/s consumer, and losing it puts real
   disc data at wrong offsets rather than producing anything that looks like
   damage. At 1 MiB it never appears, because the transfer fits in the ring and is
   in place before the reader starts.

   So `hbm_dma_stage.c` does not race. It stages in ring-sized chunks with the
   reader **stopped** while the ring is filled: stopping it holds the data FIFO,
   the converter and the buffering FIFO in reset, and `start` flushes the packer,
   so nothing survives a chunk boundary. The reader then walks descriptors
   0..N-1 in order over data already in place — ordered by construction rather
   than by timing. That costs the difference between 1.49 GB/s and 0.74 GB/s,
   which is 6 s against 3 s for a disc, and buys a result that does not depend on
   the host winning a race.

The general lesson is the one this project keeps relearning: **a byte counter
reaching its target is not evidence the bytes are right.** Faults 3 and 4 both
produced a clean `PASS` with wrong contents, and both were found only by
comparing against the disc — and fault 4 only by comparing against *non-zero*
regions, since the first 256 MiB of this image is 99.94 % zeros and a random
sample of it matches whatever the card happens to hold.

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
