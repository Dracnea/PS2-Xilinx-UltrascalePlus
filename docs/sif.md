# The SIF, and what it takes to play the Emotion Engine

The IOP kernel boots and stops, because after `BOOTEND` it waits for the EE and
there is no EE. Everything the console does with a disc after that point is the
EE asking the IOP for files over the SIF, so the host has to become convincing
enough to ask. This page records what the SIF actually is at register level,
measured where possible and cited where not, because the parts that are merely
plausible are the parts that cost days.

## What is on the card today

`rtl/iop/iop_sif.vhd` is the mailbox: MSCOM, SMCOM, MSFLAG, SMFLAG, CTRL and
BD6, with the flag registers behaving as semaphores rather than storage. That
is enough to get the IOP from 21 resident modules to 28 and set
`SIFINIT | CMDINIT | BOOTEND` ([ps2-bios-boot.md](ps2-bios-boot.md)). It carries
no data: the mailbox is four words, and file I/O moves kilobytes.

Data moves on two DMA channels, and **neither has a data path yet**. In
`iop_dma.vhd` only channels 6 (OTC) and 3 (CDVD) transfer; every other channel
accepts its registers and reports completion immediately.

## What the BIOS has actually programmed

Measured on the C1100 with the 0220A BIOS booted to `BOOTEND`, through the DMA
register window:

```
ch  MADR      BCR       CHCR      TADR
 9  00000000  00000000  00000000  00000000   SIF0, IOP -> EE
10  00000000  00000020  40000300  00000000   SIF1, EE -> IOP
```

So SIFCMD configures channel 10 and leaves channel 9 alone; `CHCR = 0x40000300`
is bit 30 (bus snooping), bit 8 (chopping) and bit 9 — SyncMode 1, "sync blocks
to DMA requests" — with bit 0 clear, which is device-to-RAM and correct for EE
to IOP. `TADR` is zero, consistent with SIF1 taking its tags from the stream.
`SMCOM` reads `0x00019600`: the IOP publishing where the EE should send.

### Bit 24 was clear, and that was this design's fault

This page previously concluded from the reading above that the IOP configures
SIF1 and **never arms it**, and listed three candidate stimuli for what might.
That was wrong, and the way it was wrong is worth keeping.

`iop_dma.vhd` had no data path for channel 10. A CHCR write with bit 24 set
therefore took the registers-only route and **completed on the next cycle**, so
bit 24 was cleared long before any host poll could see it. Sampling every 2 ms
for six seconds found it clear every time, and the obvious reading of that — the
channel is never armed — was an artefact of the observer.

With a real data path the same measurement reads `41000300`: armed, waiting for
the EE. The IOP had been arming SIF1 all along, and re-arms after every
completion. None of the three stimuli mattered; the premise did.

The lesson is not "instrument more", because the instrument was right. It is
that **a register whose value is produced by a stub says nothing about the
hardware** — the DMA controller was answering for a channel it had not
implemented.

## The two directions are not symmetric

From PCSX2's `Sif.h`, `Sif0.cpp` and `Sif1.cpp`, which is the authority for how
the hardware behaves since ps2tek documents the EE's DMAC and not the IOP's.

Both directions move a 4-word tag, `struct sifData`:

```c
struct sifData
{
    s32 data;        // IOP address (low 24 bits -> MADR); bits 30-31 stop bits
    s32 words;       // word count
    tDMA_TAG tag_lo; // the EE's own DMA tag
    tDMA_TAG tag_hi;
};
```

**SIF1, EE to IOP.** The tag arrives *in the FIFO*, ahead of the data:

```c
sif1.fifo.read((u32*)&sif1.iop.data, 4);
hw_dma10.madr    = sif1data & 0xffffff;
sif1.iop.counter = sif1words & 0xFFFFC;
```

so the IOP's channel 10 takes its destination and length from the stream. That
is why `TADR` is zero and stays zero.

**SIF0, IOP to EE.** The tag is read *from IOP memory at TADR*:

```c
sif0.iop.data    = *(sifData *)iopPhysMem(hw_dma9.tadr);
hw_dma9.madr     = sif0data & 0xFFFFFF;
sif0.iop.counter = sif0words & 0xFFFFF;
```

and the EE's half of the tag, at `tadr + 8`, is pushed into the FIFO ahead of
the data for the EE to read. So SIF0 is the direction that needs `TADR`, a
chain walk, and **a path that reads IOP RAM** — which `iop_dma.vhd` does not
have at all today: its RAM master is write-only, and the arbiter in
`iop_top.vhd` forces `ram_rnw_m` low whenever the DMA is granted.

Both directions clear `CHCR` bit 24 when the transfer ends
(`HW_DMA10_CHCR &= ~0x01000000`), which confirms that bit's meaning on this
controller.

The FIFO is **128 words** (`FIFO_SIF_W`), shared, and it is what lets the EE
push a packet before the IOP is ready to take it.

## Both directions work — 2026-09-10

**SIF1, EE to IOP.** A four-word tag at the head of the stream, then the data.
Checked on the card: a loopback to `0x60000` consumes exactly 4 + 16 words and
lands byte-exact; the same to `0x61000` lands there instead while `0x60800`
stays untouched, so the tag really steers the destination; and a packet aimed at
the BIOS's own receive buffer arrives at `0x19600` as written with `MADR`
advanced to `0x19610`.

**SIF0, IOP to EE.** The IOP builds a tag in RAM, points `TADR` at it and starts
channel 9; the DMA reads six words from `TADR`, takes the source and count from
the first two, forwards the four words at `TADR+8` as the EE's own tag, and then
streams the payload. Boot-test stage `13` does exactly that and the host drains

```
ee7a6000 ee7a6001 ee7a6002 ee7a6003   the EE's tag, forwarded untouched
5150f000 .. 5150f007                  the payload, from RAM
```

with the tag reported as `addr=0x071000 len=8`. Changing the tag to name
`0x72000` and 12 words moves both: `addr=0x072000 len=12`, and 16 words come out
instead of 12. That is what makes it a reading of the tag rather than a
coincidence.

**This is the first DMA in this design that reads IOP memory.** Writes complete
on the grant cycle; a read's grant only means the access was issued, and the
word arrives later on `ram_rvalid`. The arbiter in `iop_top.vhd` now honours
`dma_ram_rnw` instead of forcing writes, and tracks whether the access in flight
was a read so the word gets back to the right master.

### SIFCMD: the BIOS answers — 2026-09-10

Sending `SIF_CMD_INIT_CMD` to the address the IOP published in `SMCOM`, with the
EE's own buffer address as its argument, gets a reply:

```
EE tag: qwc=2 -> EE address 0x00abc000
        90000002 00abc000 00000000 00000000
packet: psize=24 dsize=0 dest=0x00000000 cid=0x80000001 (SIF_CMD_SET_SREG)
        args: 00000000 00000001      -> SREG[0] (RPCINIT) = 1
```

The IOP re-armed SIF1, programmed channel 9 with a tag at `0x179cc`, and sent
`SET_SREG(RPCINIT = 1)` — RPC is initialised and the EE may bind. Changing the
buffer address in the request moves the address in the reply's EE tag, so the
IOP really did record what it was told rather than answering from something it
already had.

Note what the stream contains: **four words of the EE's own DMA tag, then the
packet.** Decoding the first four as a SIFCMD header produces a header that
looks almost plausible — a psize, a dsize, a cid of zero — which is worse than
failing outright, and it is what the first reading of this reply did.

### The bug that had silenced half the DMA controller

None of the above happened until a one-bit fix. The packet had been arriving
correctly for two builds — `MADR` advancing, tags counting, `CHCR` bit 24
clearing — and the IOP ignored it, because the completion never became an
interrupt.

`master_flag()` took the master interrupt enable from whichever DICR it was
testing. For bank 2 that is **DICR2 bit 23, which does not exist**: ps2tek says
plainly that DICR2 bit 23 is unused and that *DICR* bit 23 is the master channel
interrupt enable for DICR and DICR2 alike. The BIOS had set everything correctly
— `DICR = 0x00800000`, `DICR2 = 0x000c0400` enabling channels 9 and 10, INTC
mask bit 3 set — and this design required a bit the hardware never defines.

So **no channel from 7 to 12 could raise an interrupt**: SIF0, SIF1, SIO2in,
SIO2out, DEV9, SPU2's second core. Bank 1 was correct, so CDVD and OTC worked,
and every disc test in this repository uses exactly those two channels. The
fault was invisible until something needed a bank-2 interrupt, and when it
finally surfaced it looked like a protocol problem — "the IOP ignores my
packet" — with a hardware-model cause.

It was found by building the visibility rather than reasoning about the
protocol: DICR, DICR2, the controller's IRQ line and the INTC's pending and
mask words are now host-readable, and they showed every enable set except the
one this design was looking for. The four candidate explanations at the time
included a malformed packet, with `psize` as the favourite, and that would have
been the next hour.

### SIFRPC: the transport works, the services are absent — 2026-09-10

`SIF_CMD_RPC_BIND` to the fileio service id `0x80000001` is received, dispatched
and answered:

```
cmd=0x80000008 (SIF_CMD_RPC_END) psize=64
echoed: cd=0x00abc200 pkt_addr=0x00abc100
for cid=0x80000009 (SIF_CMD_RPC_BIND)
server: sd=0x00000000 buf=0x00000000 cbuf=0x00000000
```

The echoed `cd` and `pkt_addr` are the host's own fictional EE addresses coming
back, which is what confirms the 64-byte packet layout. But the server fields
are null: **nothing is bound.**

Twenty candidate service ids were tried — fileio, loadfile, mcserv, padman and
others — and every one answered the same way. So the RPC layer is alive and
answering correctly; the IOP simply has no registered servers. Searching a
2 MB dump of IOP RAM agrees: no aligned `SifRpcServerData_t` holding
`0x80000001` exists, and `0x80000006` and `0x80000592` never appear at all.

### The service table, read directly

The bind handler and the table it searches were found by walking the IOP's own
structures out of a RAM dump rather than inferring them from failures.

`SMCOM` names the receive buffer at `0x19600`. The SIFCMD data block that owns
it is at **`0x196c0`**:

```
+0x00 00019600   the receive buffer, which is what SMCOM publishes
+0x08 00abc000   the EE buffer address -- the one the host sent in INIT_CMD
+0x0c 000196f0   the handler table
+0x10 00000020   32 slots
```

The handler table at `0x196f0` is (function, data) pairs indexed by the low byte
of the cid, and it is populated exactly where it should be:

```
[ 0] CHANGE_SADDR func=00017e4c data=000196c0
[ 1] SET_SREG     func=00017e30 data=000196c0
[ 2] INIT_CMD     func=00017e9c data=000196c0
[ 3] RESET_CMD    func=0001a9f8 data=0001ad20
[ 8] RPC_END      func=000187c4 data=0001a870
[ 9] RPC_BIND     func=00018a78 data=0001a870
[10] RPC_CALL     func=00018c38 data=0001a870
[12] RPC_RDATA    func=00018898 data=0001a870
```

Disassembling `RPC_BIND` at `0x18a78` shows it take the sid from word 8 of the
packet, call a lookup at `0x18a18`, and on a zero result write zero to the
reply's `sd`, `buf` and `cbuf` — which is exactly the reply the host received.

The lookup is nine instructions and names the table outright:

```
lw $a1,32($a1)      ; the service queue list head, at rpc_data + 0x20
beq $a1,$zero,fail  ; null -> not found
lw $v1,8($a1)       ; queue->start
lw $v0,0($v1)       ; server->sid
beq $v0,$a0,found
lw $v1,56($v1)      ; server->next
lw $a1,20($a1)      ; queue->next
```

The RPC data block is at `0x1a870` and holds live buffers — `+0x04 = 0x19870`,
which is the address channel 9 was observed sending from. Its list head,
**`0x1a890`, reads `0x00000000`.**

So the lookup fails at its first dereference. There is no server missing from a
queue: **no queue has ever been registered.** The RPC subsystem is initialised
and dispatching correctly, and nothing has called into it to offer a service.

### Why nothing registers: FILEIO never gets that far

Read out of the same dump, by walking the structures rather than guessing.

**The module is resident and healthy.** Its module-info block is at `0x3fd00`,
naming `FILEIO_service` with entry `0x3fd30`, which matches the module map.

**It does not refuse to start.** FILEIO's entry begins with `QueryBootMode(3)`
and, if that key exists with bit 0 or bit 1 set, prints `' No SIF
service(fileio)'` or `' No FILEIO service'` and returns without starting. The
boot-mode table pointer lives at absolute `0x3f0`, points at `0x32c0`, and holds
exactly one entry — key 4, length 0. **There is no key 3**, so the query returns
zero and FILEIO takes the normal path.

**Its threads exist and were started.** The IOP has five thread control blocks;
every TCB begins with the same word (`0x11948`), which makes them enumerable,
and the status byte is at `+0x44`:

```
TCB       entry     stack     size  prio  status
0x0117c8  0001aef8  001fce00  4096   10   WAIT
0x011820  0001aa58  001fde00  2048    0   -
0x0391e0  00040ca0  001fae00  2048   96   WAIT     FILEIO
0x039238  00040a34  001fb600  4096   80   WAIT     FILEIO
0x039290  00039434  001fc600  2048    0   RUN
```

Both FILEIO threads are **WAIT**, not DORMANT and not absent: `CreateThread`
and `StartThread` both succeeded.

**It never reaches the registration.** Disassembling the service thread at
`0x40a34` shows it print its banner, take its thread id, call
`sceSifSetRpcQueue` with a queue descriptor at `0x41318`, then register with
`$a1 = 0x80000001` — the fileio service id — and a server-data block at
`0x41330`. Both of those blocks read **all zeros**, so neither call has run.
That is consistent with the service list head at `0x1a890` being null, and with
every bind the host has sent coming back with `sd`, `buf` and `cbuf` zero.

The thread's stack carries the return addresses `0x40a74` (the call before
`GetThreadId`), then `0x18630` inside the SIF library, then kernel frames —
which places the block inside SIF RPC initialisation, ahead of the registration.

> **NOTE (unverified): what it is waiting on.** The saved return addresses put
> the thread in the SIF init path, but a return address on a stack is where a
> call *was* made, not necessarily where the thread is parked now, and the exact
> kernel primitive has not been identified.
> *Verify by:* capturing the IOP's serial console, which this image does not.
> The signals exist in the board file (`con_wr`, `con_data`) and only the
> diagnostic image consumes them. Every module prints as it initialises —
> FILEIO's own `'Multi Threaded Fileio module.(99/11/15)'` is in its data
> segment — so the console says how far each module got and in what order,
> which is a far better instrument for this than reading more disassembly.

**A theory that was wrong, recorded because the method matters.** The first
explanation was that the IOP's thread scheduler never ticks: INTC bit 16 —
TIMER5 in intrman's numbering — is unmasked by the BIOS and was never observed
pending across three seconds of 1 ms sampling, and no scheduler tick would mean
no module thread ever runs. It fitted the evidence exactly, including why
interrupt-context work (SIFCMD) succeeds while thread-context work does not.

It was wrong, twice over. Boot-test stage `14` programs timer 5 directly at each
of its four prescaler settings and **all four raise their interrupt**; and
sampling INTC every 2.6 us instead of every millisecond — 1.57 million samples
in four seconds — catches **TIMER5 pending while the BIOS runs**. The tick is
there and always was. The bit was never
observed pending because the BIOS's own handler acknowledges it faster than the
host can sample — the same mistake as reading `CHCR` bit 24 on a channel whose
completion was instant, twice now in one week: *sampling a bit that is cleared
promptly and concluding the event never happens.*

Stage `14` also chases down the note in `iop_timer32.vhd` that the prescaler
bits came from PCSX2 rather than measurement. It settles less than it looks
like: it proves each of the four settings interrupts, not that `/8` divides by
eight. The ratios are still unmeasured.

Writing it exposed two faults in the test rather than the design, both worth
keeping: the shared exception handler acknowledged only timer 3, so a timer 5
interrupt was never cleared and re-entered forever; and a target of 64 counts in
repeat mode re-fires every 1.7 us at 36.864 MHz, which is faster than the
handler returns. Both present as a hung test.

### What the channels must not do

Both SIF channels sit armed for long stretches with nothing moving, and the
transfer engine runs one channel at a time. Parking either of them in the shared
registers stops CDVD and OTC dead for as long as the other side stays quiet —
which is not a hypothetical: channel 10 did exactly that in its first version,
and no disc test caught it because every disc test runs the boot ROM, where SIF1
is never armed. Each channel keeps its own state and yields the engine whenever
its stream is dry or full, resuming mid-tag or mid-transfer. Verified by running
the ISO9660 walk with SIF1 armed and starved.

## Order of work

1. ~~**SIF1 FIFO and channel 10.**~~ **Done 2026-09-10.**
2. ~~**The DMA RAM read path.**~~ **Done 2026-09-10.**
3. ~~**SIF0 and channel 9**, including the walk of the tag at `TADR`.~~
   **Done 2026-09-10.**
4. ~~**SIFCMD on the host**: packet headers, and the `SIF_CMD_INIT_CMD`
   exchange that gives each side the other's buffer address.~~
   **Done 2026-09-10.**
5. **SIFRPC on the host**: bind, then call, then the FILEIO service — which is
   the point of all of it, because `CDVDMAN` and `IOMAN` are invoked through
   an RPC and in no other way. *Transport done 2026-09-10; blocked on the IOP
   registering a service to bind to.*

Steps 1-3 are also exactly what the Emotion Engine needs later, so none of it
is spent solely on closing out the disc path.
