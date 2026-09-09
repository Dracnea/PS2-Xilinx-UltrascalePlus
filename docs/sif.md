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

Measured on the C1100 on 2026-09-09 with the 0220A BIOS booted to `BOOTEND`,
through the DMA register window added the same day:

```
ch  MADR      BCR       CHCR      TADR
 9  00000000  00000000  00000000  00000000   SIF0, IOP -> EE
10  00000000  00000020  40000300  00000000   SIF1, EE -> IOP
```

Both were sampled every 2 ms for six seconds and **neither changes**. So:

* SIFCMD configures channel 10 and leaves channel 9 entirely alone.
* `CHCR = 0x40000300` is bit 30 (bus snooping), bit 8 (chopping enable) and
  bit 9 — SyncMode 1, "sync blocks to DMA requests". Bit 0 is clear, which is
  device-to-RAM and correct for EE to IOP.
* **Bit 24, start/busy, is clear.** The channel is configured and not armed.
* `TADR` is zero, which is consistent with SIF1 taking its tags from the FIFO
  rather than from memory (below).
* `SMCOM` reads `0x00019600`: the IOP publishing the address of its SIFCMD
  receive buffer, which is where the EE is expected to send.

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

## The open question, and how to settle it

Nothing observed so far says **what makes the IOP arm channel 10.** It is
configured and idle, and it stays that way through six seconds of sampling with
the BIOS running. A packet pushed into the FIFO would simply wait there.

The candidates, in the order worth testing:

1. The EE finishing its side of `sceSifInitCmd` — the EE publishes its own
   buffer address (`MAINADDR`) and the IOP responds by arming. The host has so
   far only set MSFLAG bit 16; it has never written MSCOM.
2. An MSFLAG bit the IOP treats as a doorbell, which would need `iop_sif.vhd`
   to raise an interrupt rather than only store the value.
3. The IOP arming lazily on some timer or kernel event, which the six-second
   sample argues against.

> **NOTE (unverified):** the arming trigger is the one part of this page that
> is a list of guesses rather than a reading.
> *Verify by:* implementing the SIF1 FIFO and channel 10 data path, pushing a
> well-formed tag, then applying each stimulus in turn and watching CHCR bit 24
> through the DMA register window. The window exists precisely so this is a
> reading rather than an argument.

## Order of work

1. **SIF1 FIFO and channel 10.** Host writes tag and data into a FIFO; the
   channel drains it into IOP RAM. Reuses the device-to-RAM direction that
   channel 3 already proves. Settles the arming question by experiment.
2. **The DMA RAM read path.** `dma_ram_rnw` out of `iop_dma`, the arbiter
   honouring it, and read data returned on `ram_done`. Needed by SIF0 and by
   nothing else so far.
3. **SIF0 and channel 9**, including the walk of the tag at `TADR`.
4. **SIFCMD on the host**: packet headers, and the `SIF_CMD_INIT_CMD` exchange
   that gives each side the other's buffer address.
5. **SIFRPC on the host**: bind, then call, then the FILEIO service — which is
   the point of all of it, because `CDVDMAN` and `IOMAN` are invoked through
   an RPC and in no other way.

Steps 1-3 are also exactly what the Emotion Engine needs later, so none of it
is spent solely on closing out the disc path.
