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

### Why nothing registered: INIT_CMD carries two meanings — solved 2026-09-10

`SIF_CMD_INIT_CMD` is not one message. Its handler at `0x17e9c` branches on the
packet's `opt` field:

```
lw $v0,12($s1)          ; opt
bne $v0,$zero,0x17ee0
  ; opt == 0: SetEventFlag(evf, 0x100), and store the EE's buffer address
0x17ee0:
  ; opt != 0: SetEventFlag(evf, 0x800)
```

FILEIO's service thread prints its banner and then blocks in
`WaitEventFlag(evf, 0x800, WAIT_AND, NULL)` — identified from its argument
checks, where `-18` masks the mode against `~0x11` and a zero pattern is
rejected — *before* it calls `sceSifSetRpcQueue` and registers. Every module
that offers an RPC service waits on the same bit.

ps2sdk's `sceSifInitCmd` sends `opt = 0`, which records the EE's buffer and sets
bit `0x100`. That is the half the host had been sending. The modules are
released by a **second** INIT_CMD with `opt != 0`, and until it arrives the
service list stays empty and every bind returns null — which is exactly what was
observed for three rounds.

Sending both, in order, gets:

```
server: sd=0x00041330 buf=0x00041378 cbuf=0x00000000
bound. Arguments for a call go to IOP 0x00041378
```

`0x41330` is the server-data address read out of FILEIO's own code before any of
this worked, now filled in — so the prediction and the result agree. The boot
also goes further, adding `cdvd driver module version 0.1.1 (C)SCEI` to the log,
because CDVDFSV was waiting on the same bit.

**How it was found, since three rounds of reading structures had not.** The IOP
prints a line per module and a retail BIOS discards all of them; patching the
character sink to write SIO1 made the log readable
([bios-fidelity.md](bios-fidelity.md)), and the log showed FILEIO's banner
present and everything after it absent. That located the block between two
specific instructions, and the handler's `opt` branch was three disassembled
lines away. Reading the machine's own account of itself beat inferring its state
from the structures it had not yet written.

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
   an RPC and in no other way. *Transport and bind done 2026-09-10; the call
   remains.*

Steps 1-3 are also exactly what the Emotion Engine needs later, so none of it
is spent solely on closing out the disc path.
