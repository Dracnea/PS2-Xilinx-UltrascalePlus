# The IOP subsystem: what each RTL file is

The first buildable piece of a PlayStation 2 on these cards, in the order
[docs/ps2-hardware-study.md](ps2-hardware-study.md) §7 lays out:
the IOP first, because it is the one block for which RTL already exists. The
PS2's I/O processor is the PS1's CPU (an R3000A at 36.864 MHz) with a
different address map, 2 MB of RAM, a 4 MB ROM, 32 interrupt sources and
three more timers. All of that is here, plus (2026-09-06, second pass) the
SPU2 as two PSX SPU cores with on-chip work RAM, SIO2 with a digital pad on
port 0, and the CDVD register block with no disc. DMA, SIF and the second
SSBUS config block are register stubs.

Results and the bring-up procedure are in
[docs/ps2-iop-bringup.md](ps2-iop-bringup.md); a real BIOS booting on this
subsystem is [docs/ps2-bios-boot.md](ps2-bios-boot.md).

## What is in `rtl/iop`

| file | what | origin |
|---|---|---|
| `iop_top.vhd` | the subsystem: CPU, memory mux, RAM/ROM, SSBUS config, INTC, timers 0-5, POST register, stubs; reset sequencing; the host's memory peek port; **the RAM arbiter** (below) | new |
| `iop_memorymux.vhd` | the IOP address map on the PSX memory mux's state machine; only the decode changed, `diff` against `PSX/upstream/rtl/memorymux.vhd` shows exactly what | PSX_MiSTer, modified |
| `iop_ram.vhd` | 2 MB RAM + 4 MB ROM as 128-bit-row UltraRAM behind the PSX SDRAM-controller protocol, with the instruction-cache line fill | new |
| — | **the RAM arbiter** lives in `iop_top`. The RAM port has three masters: the CPU's memory mux, the peek port, and the DMA controller. `iop_ram` samples a request only while its FSM is idle and answers with a single `ram_done` pulse, and the mux has no stall input, so two rules follow and both are load-bearing. The mux is shown `ram_done_mux` — its own completions only — or a DMA write looks to it like the answer to a request it never made. And a CPU request that arrives while the DMA holds the port is latched and replayed when the port frees, because otherwise `iop_ram` drops it and the mux waits for a completion that never comes. One entry is enough: the mux keeps a single access in flight | new |
| — | **the peek port** lives in `iop_top`: while the CPU is held in reset the RAM port is switched from the memory mux to `peek_req`/`peek_addr`, so the host can read any word of RAM or ROM back for a post-mortem. No arbitration and no extra memory — the mux has no request in flight while the CPU is reset. Checked in `sim/tb_iop.sv` after the boot test passes | new |
| `iop_intc.vhd` | I_STAT / I_MASK / I_CTRL, 32 sources, PS2SDK bit numbering | new |
| `iop_timer32.vhd` | timers 3-5 (32-bit) at 0x1F801480, modelled on the PSX `timer.vhd` | new |
| `iop_spu2.vhd` | two PSX SPU cores at 0x1F900000 / 0x1F900400 with the 32-bit bus split into the 16-bit halfword each register wants; IRQs to INTC bit 9. **PSX register layout**, not the SPU2's — see the file header | new (cores: PSX_MiSTer `spu.vhd`, `spu_ram.vhd`, `spu_gauss.vhd`) |
| `iop_spuram.vhd` | 512 KB of SPU work RAM per core as 128-bit-row UltraRAM behind `spu_ram`'s SDRAM-style port | new |
| `iop_sio2.vhd` | SIO2 at 0x1F808200: SEND1/2/3, FIFOs, CTRL, RECV1-3, I_STAT, INTC bit 17; a PS1-protocol digital pad answers on port 0 from the `pad0_buttons` port, everything else reads as absent | new |
| `iop_cdvd.vhd` | CDVD at 0x1F402000: N/S command ports, status, error, I_STAT, INTC bit 2; answers the boot-time S commands with PCSX2's values, reports disc presence from the host, logs every command for the host to read back, and **reads sectors**: N commands 0x06/0x07/0x08 take an LBA and a count, fetch each sector through the host sector port, and hand the words to DMA channel 3 | new |
| `iop_dma.vhd` | the DMA controller: 13 channels in two banks, DPCR/DICR and their bank-2 twins, DMACEN, the interrupt on INTC bit 3. **Channels 6 (OTC) and 3 (CDVD) are complete** — OTC needs no peripheral, so it is the one channel that can prove the controller on its own, and channel 3 now carries real sector data from the CDVD block into RAM. `dev_ready` means "this word is taken", not "I am listening": it is asserted only when the RAM write for the word is granted, or the device outruns the DMA and the word count never reaches zero. Every other channel accepts its registers and reports completion, as the stub did | new (OTC word format and CHCR/DICR semantics from PSX_MiSTer `dma.vhd`) |
| `iop_sif.vhd` | the SIF mailbox at 0x1D000000: MSCOM, SMCOM, MSFLAG, SMFLAG, CTRL, BD6. The flag registers are semaphores, not storage — the EE sets MSFLAG and the IOP's write clears it, and SMFLAG is the reverse — which is what a register stub could not imitate and what stopped the BIOS boot | new |
| `iop_regstub.vhd` | a read-back register file standing in for a peripheral that does not exist yet | new |
| (unmodified) `cpu.vhd`, `memctrl.vhd`, `timer.vhd`, `datacache.vhd`, `divider.vhd`, the RAM/FIFO wrappers | PSX_MiSTer, GPL-2.0, Robert Peip | via `cores/PSX/upstream` |

**Stubs** (programmed and read back, no behaviour): SSBUS config 2
(0x1F801400). DMA and the SIF used to be here and are now real blocks. Not present at
all: the PS1's SPU window, pads/SIO, GPU, MDEC, CD-ROM; reads there return
zero. What the three new blocks do *not* do: SPU2 has the PS1 register map
and no DMA; SIO2 has no memory cards, multitap or DMA channels 11/12; CDVD
has no sector path (every read command returns error 0x12, no disc).

Address map differences from the PSX that are implemented: 4 MB BIOS window
at 0x1FC00000; the expansion-1 window narrowed to 0x1F000000-0x1F3FFFFF so
CDVD at 0x1F402000 reaches the internal bus; the seven new 32-bit internal
buses above. RAM is 2 MB and mirrors above that.

## Simulation

```
cd sim && ./run_sim.sh            # assemble boot_test.s, build in xsim, run, grep PASS
```

`boot_test.s` runs from the reset vector and reports through the POST register
at 0x1F802070: 01 alive, 02 RAM word test, 03 byte/halfword access, 04 code
copied to RAM and run cached, 05 timer 3 polled, 06 timer 3 interrupt through
the BEV vector (the handler writes 5A), 07 SPU2 voice registers on both
cores, 08 SPU2 transfer FIFO into work RAM (the bench checks the RAM row),
09 SIO2 pad poll (FF 41 5A + the buttons the bench drives, RECV1, I_STAT,
INTC bit 17), 0A CDVD (no disc, S command 03/00, N command 00, INTC bit 2),
0B a halfword write through a register stub (the write mask), 0C the SIF
mailbox handshake against the bench playing the EE, 0D DMA channel 6 (OTC)
building its linked list backwards and the list checked word by word, 0E a
CDVD sector read: N command 0x06 for LBA 16, delivered to RAM by DMA channel
3, with the ISO9660 primary volume descriptor signature checked in RAM and
INTC bit 2 raised. AA all passed, EE a check failed. It
is assembled by `asm_r3000.py`, a two-pass MIPS I assembler with no
dependencies, so the test needs no cross toolchain.

`./run_sim.sh --debug` runs `tb_iop_dbg.sv` instead, which prints every CPU,
RAM and peripheral-bus transaction and takes plusargs through `XSIM_ARGS`:
`cycles=N`, `quiet=1` (hide instruction fetches), `regs=1 rfrom=A rto=B`
(register-file trace), `rf=1` (the register-file model's own view), `pfrom=A
pto=B` (every non-sequential PC change with SR/CAUSE/EPC), `tfrom=N` (start
the transaction trace late), `spu=1` (SPU core 0's FIFO and work-RAM port).
Each of the bugs below was found with one of those.

## Fit and build

```
cd fit && ./run_fit.sh [part]        # out-of-context synthesis, build/fit_iop_<part>/
```

The C1100 bitstream targets are `boards/c1100_ps2_iop.py` (a LitePCIe gen3 x4
endpoint with the IOP on CSRs) and `boards/c1100_ps2_diag.py` (the same plus
UARTbone, a POST ring, a stall detector, the console FIFO and a LiteScope on
the CPU bus). The host tools are in `tools/ps2iop/`.

## What simulation found (2026-09-06)

Each of these produced a hang with POST stuck, and each is now either fixed in
the RTL or recorded in the file it belongs to:

1. **The CPU came up at PC 0.** PSX_MiSTer's CPU takes its reset state (PC,
   PRID, a zeroed register file) from its savestate-load port, driven in
   `psx_top` by the savestate block. `iop_top` now pulses `SS_reset` on the
   first reset cycle and holds its internal reset 64 cycles longer than the
   external one so the 32-cycle register-file load finishes first.
2. **Cache-line fills raced the CPU.** Delivering the four words of a line at
   one per clk1x cycle with `ram_done` on the second word (the SDRAM
   controller's nominal timing) makes the CPU miss and refetch the later
   words; the real controller streams them at clk3x. `iop_ram` now raises
   `ram_done` with the last word.
3. **The register file read X for every register.** Not an IOP bug:
   `rtl/altera_compat/altdpram.v` and `altsyncram.v` sized their arrays from a
   `numwords` parameter that Intel's VHDL component declaration defaults to 0
   (meaning "2**widthad"), and that 0 overrides the Verilog default when the
   model is bound from VHDL. Every write was dropped. Fixed in the models;
   this affected any core simulated through them, and synthesis was
   unaffected (identical utilisation before and after).
4. **Peripheral read data was OR'ed together.** The PSX memory mux ORs every
   bus's read data, so a block must return zero except in the cycle after its
   read strobe. `iop_intc` and `iop_regstub` drove theirs combinationally and
   corrupted memctrl reads with pending timer-IRQ flags; both now register
   like the PSX `irq.vhd`. The timers also pulsed their IRQ lines once after
   reset (mode bit 10 reset to 0); it now resets to 1.
5. **The test itself cleared BEV.** Writing SR = IM2 | IEc sent the interrupt
   to 0x80000080 in RAM, which executed zeros up to the copied test routine
   and "returned" into stage 4 forever. The ROM now keeps BEV set.
6. **Stores arrive word-aligned.** The PSX CPU aligns store addresses and
   puts the lanes in the write mask, so a `sh` to 0x1F900006 reaches the bus
   as address ...004, mask 1100, data in bits 31:16; loads keep their byte
   address. The mux now exports the write mask on the SPU2, SIO2 and CDVD
   buses and those blocks pick the halfword/byte from it (second pass).
7. **Peripheral read data is sampled one cycle after the strobe.** A block
   that registers its bus_dataRead at the strobe is on time; re-registering
   the SPU's already-registered output made every SPU2 read return zero.
8. **xsim cannot read a VHDL array element from a SystemVerilog bench.** It
   warns and then returns junk, which made a correct SPU RAM transfer look
   like a failure; `iop_spuram` mirrors the checked row into a scalar signal
   under `synthesis translate_off` for the bench.

## What the CDVD read path found (2026-09-09)

Stage `0E` took four RTL fixes to pass, and three of them are the same bug in
different clothes: a signal read or driven a cycle away from where it belonged.
Recording them together because the family is worth recognising on sight.

1. **`ram_done_mux` was computed and connected to nothing.** `iop_top` derived
   the CPU's masked completion correctly and then passed the memory mux the raw
   `ram_done`, so every DMA write completion reached the CPU as the answer to a
   request it never made. The comment above the arbiter had described the
   intended behaviour from the start; only the wire was missing. The symptom was
   a CPU that stopped taking branches — `b halt` fell through — and marched off
   the end of ROM executing zeros.
2. **A CPU access during a DMA transfer was dropped.** `iop_ram` samples a
   request only while its FSM is idle. With fix 1 in place the CPU no longer
   saw a stray completion to unblock it, so the dropped access became a
   permanent stall and the core raised its error flag. The arbiter now holds one
   CPU request and replays it when the port frees.
3. **`ram_req` was only ever cleared on reset.** A request left standing after
   the last word kept the arbiter granting the DMA and re-writing that word.
   OTC hid this completely: the repeated write put the same value back at the
   same address, so the list still read back correctly.
4. **`dev_ready` was asserted on state, not on a grant.** Channel 3 held it high
   for the whole transfer rather than when a word was actually consumed, so the
   CDVD advanced faster than the DMA took words and the count never reached
   zero.

The bench now traps on the first instruction fetch past the end of the loaded
image and on an unexpected POST 00, dumping the fetch and data rings with the PC
of each access alongside DMA and CDVD state. All four were found with it. Three
of them pass any test that checks only whether a transfer *completed*, which is
the argument for checking contents instead.

## Next

A real BIOS now boots this subsystem on the C1100 and reaches `BOOTEND` with
28 modules loaded ([docs/ps2-bios-boot.md](ps2-bios-boot.md)). The SIF mailbox
and the DMA controller, which were the two blockers, are both real blocks now;
so is the CDVD read path, in simulation.

(Done 2026-09-08: the write mask now reaches all four stub buses, so a
halfword or byte store to a stub keeps the rest of the register. Boot-test
stage 0B checks it, and fails with POST EE if the mask is removed.)

The order from here is in [docs/roadmap.md](roadmap.md).

Still on the IOP: an SPU2 register decode in front of the two PSX cores
(and 2 MB shared RAM), the remaining DMA channels and their sync modes (SPU2,
SIO2 and the SIF all move their data by DMA on the real console; channels 3 and
6 are done), memory cards on SIO2, and the SIF's chain mode. After
that the study's step 2: the Graphics Synthesizer as a standalone unit fed
over PCIe, the first block with no RTL to start from.
