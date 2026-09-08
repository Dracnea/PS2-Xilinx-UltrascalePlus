# PS2 IOP bring-up: simulation, fit and the C1100 bitstream

The first step of the order [ps2-hardware-study.md](ps2-hardware-study.md) §7
gives — the I/O processor subsystem, built from PSX_MiSTer's R3000A — taken
through xsim, out-of-context synthesis on both dies, and a C1100 bitstream.
What the block contains and what simulation found is in
[docs/iop-subsystem.md](iop-subsystem.md). This page holds
the measurements.

Everything under "measured" was produced on 2026-09-06 with Vivado/xsim
2026.1. The bitstream was loaded on the C1100 on 2026-09-07 (last section);
the POST run on hardware is the next step.

## Simulation — verified

`sim/run_sim.sh`, the boot ROM `boot_test.s` on `iop_top`
at 36.864 MHz with the PSX core's phase-aligned 2x/3x clocks:

```
[111339000] reset released
[122298000] POST 01        alive
[3712451000] POST 02       RAM word test (256 words, uncached)
[3757697000] POST 03       byte / halfword access, both endian orders of lb/lbu/lh/lhu/sb/sh
[3841598000] POST 04       routine copied to RAM, executed cached (KSEG0), result checked
[3858307000] POST 05       timer 3 polled to target with reset-on-target
[3977689000] POST 5a       timer 3 interrupt taken through the BEV vector, acknowledged in I_STAT
[3993368000] POST 06
[3995239000] POST aa
PASS
```

That is 143,000 IOP cycles, 3.9 ms of console time, in about 3 minutes of
xsim. Instruction fetch from the ROM is uncached and costs ~33 cycles per
instruction (the PSX memctrl's BIOS delay is honoured), which is why the RAM
test dominates.

Five bugs stood between "compiles" and this output; they are listed in the
core README. The one with reach beyond the PS2 is the third: the Altera
compatibility models sized their arrays from a `numwords` parameter that the
Intel VHDL component declaration defaults to 0, so **any core simulated
through `rtl/altera_compat` had a register file that dropped every write.**
Synthesis was never affected (utilisation is identical before and after the
fix), which is why none of the fits caught it.

## Out-of-context fit — measured

`fit/run_fit.sh`, `synth_design -mode out_of_context` on
`iop_top`, clocks 27.126 / 13.563 / 9.042 ns:

| | xcu55n (C1100) | xcvu33p (FK33) |
|---|---:|---:|
| CLB LUTs | 12,546 (1.44 %) | 12,635 (2.87 %) |
| CLB registers | 25,454 (1.46 %) | 25,683 (2.92 %) |
| Block RAM tiles | 20.5 (1.53 %) | 20.5 (3.05 %) |
| **URAM** | **192 of 640 (30 %)** | **192 of 320 (60 %)** |
| DSP | 8 | 8 |
| clk1x WNS | +20.957 ns | +20.657 ns |
| clk2x / clk3x | pulse-width only, met | met |
| inert-constraint signatures in log | 0 | 0 |

The URAM is the 2 MB RAM (64) and the 4 MB ROM (128) as 128-bit rows. A first
version organised them as 32-bit words and cost 384 URAM on the same die: a
URAM is 4096 x 72, and a 32-bit-wide array wastes 40 bits of every row. The
ROM is the PS2's real BIOS size; for a bring-up image it could be a fraction
of that (both depths are generics on `iop_ram`), and on the FK33 it will have
to be.

The first fit also reported WNS -4.279 on 32 paths, all clk2x → clk1x with a
**0.001 ns requirement**: the clock periods were 27.127 / 13.563, whose edges
land 1 ps apart at the end of the cycle. Periods that are exact multiples
(27.126 / 13.563 / 9.042) remove every failing path. Nothing in the design
changed.

## C1100 bitstream — built, not loaded

`boards/c1100_ps2_iop.py`: the PCIe gen3 x4 endpoint from
`c1100_pcie_video.py` unchanged, plus a second MMCM for the IOP clocks and
`iop_top` on CSRs (`iop_reset`, `iop_rom_addr`, `iop_rom_data`, `iop_status`,
`iop_post_count`, `iop_rom_count`). The IOP clocks are 36.875 / 73.75 /
110.625 MHz — 100 MHz / 2 x 22.125, then / 30, 15, 10 — 0.03 % above the
console's 36.864 MHz, which integer MMCM ratios cannot reach from 100 MHz
(11/30 gives 36.667, 0.5 % low).

Measured, Vivado 2026.1, xcu55n-fsvh2892-2LV-e:

```
WNS +0.449   TNS 0.000   WHS +0.010   THS 0.000
126,287 endpoints, 0 failing
All user specified timing constraints are met.
```

| clock | WNS (ns) |
|---|---:|
| clk100_p (reference) | +8.657 |
| sys (125 MHz) | +1.432 |
| IOP clk1x (36.875 MHz) | +1.557 |
| IOP clk2x / clk3x | pulse-width only, met |

| resource | used | of | util |
|---|---:|---:|---:|
| CLB LUTs | 17,035 | 871,680 | 1.95 % |
| CLB registers | 34,534 | 1,743,360 | 1.98 % |
| Block RAM tiles | 45 | 1,344 | 3.35 % |
| URAM | 192 | 640 | 30.0 % |
| DSP | 8 | 5,952 | 0.13 % |

`bitstreams/c1100_ps2_iop.bit`, 56,660,149 bytes, md5
`6fab44411aa52d957b86e0790d04cb40`, with its `csr.csv` beside it. The PCIe
transport alone was 4,579 LUTs; the IOP adds the 12.5k of the fit.

Three builds were needed, and none of the failures was in the IOP:

1. LiteX passes pre-synthesis and pre-placement Tcl through `str.format`,
   so Tcl braces in those strings must be doubled.
2. The sys clock is named `clkout` in `c1100_pcie_video.py`'s design and the
   transport doc's constraint refers to it by that name. With the 100 MHz
   reference buffered once for two MMCMs, the net is `crg_clkout` and the
   by-name `set_clock_groups` matched nothing: `No clocks matched 'clkout'`,
   the third time that log line has cost a build in this repo. The
   constraint now names clocks by MMCM output pin, which cannot go stale.
   The routed result confirms it took: every sys ↔ IOP crossing is in a
   `MultiReg` or `PulseSynchronizer` and the inter-clock paths are gone
   from the timing report.
3. bitgen's DRC AVAL-168 rejected `CLKFBOUT_MULT_F = 11.0625` because the
   generated Verilog prints it as `11.062`, which is off the 0.125 grid.
   `DIVCLK_DIVIDE = 2, CLKFBOUT_MULT_F = 22.125` is the same 1106.25 MHz VCO
   with a value that survives three-decimal formatting. Placement and
   routing had already met timing; only the bitstream write failed.

## Loading it — the procedure, not yet run

```sh
# program over JTAG, then restore the PCIe identity (docs/c1100-pcie-transport.md)
sudo sh -c 'echo 1 > /sys/bus/pci/devices/0000:c1:00.0/remove; sleep 1; echo 1 > /sys/bus/pci/rescan'
lspci -nn -d 10ee:                       # expect 10ee:9034, BAR0 128K, driver litepcie

cd sim && python3 asm_r3000.py boot_test.s boot_test.hex --size 4096
tools/ps2iop/iop_post.py --csr bitstreams/c1100_ps2_iop.csr.csv status   # locked=1, heartbeat toggling between calls
tools/ps2iop/iop_post.py --csr bitstreams/c1100_ps2_iop.csr.csv run sim/boot_test.hex
```

`run` holds reset, streams the image through `iop_rom_data` (one ioctl per
word; 4096 words is well under a second), releases reset and prints each POST
transition until AA, EE or the timeout. The expected output is the sequence
in the simulation section with wall-clock stamps instead of picoseconds.

What would make the first attempt fail, in the order to check: `locked` = 0
(the fractional feedback multiplier — fall back to DIVCLK 1 / MULT 11.0); `heartbeat` not
toggling (the IOP clock domain is not running); `post_count` staying 0 with
`cpu_error` = 0 (the ROM did not load: check `rom_count` matches the image
length); POST EE (a stage failed on silicon that passed in xsim — the
`boot_test.s` header says which stage precedes it).

## What this does and does not establish

Established: the PS1 CPU core, its memory mux and the PSX peripherals reused
here run correctly on this fabric at the IOP's clock through a real boot
sequence, with the RAM and ROM on chip; the IOP-specific additions (INTC,
32-bit timers, address map) behave as documented for the parts the test
exercises; the whole thing costs 1.4 % of the C1100's logic and 30 % of its
URAM with the full-size ROM.

Not established: anything about the EE, VUs or GS, which remain the
"nothing to port" of the retro-cores verdict; SPU2, SIO2, CDVD, SIF and DMA
behaviour, all of which are stubs; the IOP kernel booting (that needs the
DMA controller and SIF at minimum, and the real BIOS, which is not
redistributable). The verdict in the retro-cores survey in Dracnea/FPGA-Retro stands; this
is the first block of the long road it describes.

## Second pass, 2026-09-06: SPU2, SIO2, CDVD — simulated and fitted

The next three blocks of §7 step 1, on top of the stage above, simulation
and fit only (the C1100 stayed on its other work). What each is and is not
is in the file headers and in [docs/iop-subsystem.md](iop-subsystem.md).

- **SPU2** as two instances of PSX_MiSTer's SPU (`iop_spu2.vhd`) at
  0x1F900000 / 0x1F900400, each with 512 KB of work RAM in URAM
  (`iop_spuram.vhd`) behind `spu_ram`'s SDRAM-style port. The register
  layout is the PS1's, not the SPU2's, and there is no DMA: the cores, RAM,
  transfer FIFO and IRQ plumbing are real, the SPU2 decode in front of them
  is the next job.
- **SIO2** (`iop_sio2.vhd`): command queue, FIFOs, CTRL, RECV1-3, I_STAT,
  INTC bit 17, with a PS1-protocol digital pad on port 0 fed from a
  `pad0_buttons` port on `iop_top`. Semantics from PCSX2's Sio2 (ps2tek
  lists only the addresses); unverified against hardware.
- **CDVD** (`iop_cdvd.vhd`): the N/S command ports, status, error, I_STAT,
  INTC bit 2; the boot-time S commands answered with PCSX2's values; no
  disc, no sector path. Unverified against a drive.

Simulation — verified (`run_sim.sh`, 2026-09-06):

```
[122298000]  POST 01 .. [3993368000] POST 06     as before
[4022203000] POST 07   SPU2 voice registers written/read on both cores (sh/lhu)
[5133148000] POST 08   SPU2 transfer FIFO -> work RAM 0x2000 (row checked by the bench: 4444 3333 2222 1111)
[5201017000] POST 09   SIO2 pad poll: FF 41 5A 3C 5A, RECV1 0x1100, I_STAT, INTC bit 17
[5265062000] POST 0a   CDVD: no disc, N ready 0x4A, S 03/00 -> 03 06 02 00, N 00 -> I_STAT, INTC bit 2
[5266933000] POST aa   PASS
```

190,000 IOP cycles, 5.2 ms of console time. Three more findings on the way,
recorded as items 6-8 of the core README: stores reach the internal buses
word-aligned with the lanes in the write mask (the mux now exports that
mask), peripheral read data is sampled exactly one cycle after the strobe,
and xsim returns junk for a VHDL array element read from a SystemVerilog
bench (the RAM now mirrors the checked row into a scalar for the bench).

Out-of-context fit — measured, clocks 27.126 / 13.563 / 9.042 ns:

| | xcu55n (C1100) | xcvu33p (FK33) |
|---|---:|---:|
| CLB LUTs | 16,349 (1.88 %) | 16,349 (3.72 %) |
| CLB registers | 13,306 (0.76 %) | 13,306 (1.51 %) |
| Block RAM tiles | 57.5 (4.28 %) | 57.5 (8.56 %) |
| **URAM** | **224 of 640 (35 %)** | **224 of 320 (70 %)** |
| DSP | 34 | 34 |
| clk1x WNS | +20.734 ns | +20.726 ns |
| inert-constraint signatures in log | 0 | 0 |

Of that, the SPU2 is 8,311 LUTs, 5,660 registers, 32 BRAM tiles and 32
URAM (the two 512 KB work RAMs), SIO2 375 LUTs and CDVD 58. The register
count *fell* from the first pass's 25,454: the SPU2 stub it replaces was a
512-entry, 32-bit read-back register file, 16k flip-flops of nothing. The
FK33 now has 70 % of its URAM in this one subsystem; the 4 MB ROM (128 of
the 224) is the lever there.

Not done, and needed before the C1100 image is rebuilt with this: the
board target `c1100_ps2_iop.py` does not yet connect `iop_top`'s new
`pad0_buttons` input (a CSR) and `spu_l0/r0/l1/r1` outputs; the bitstream in
`bitstreams/` is the first-pass IOP.

### Bitstream rebuilt with the second pass (2026-09-06, later)

`c1100_ps2_iop.py` gained an `iop_pad0` CSR (SIO2 port 0 buttons, active
low, PS1 bit order) and the four SPU2 audio outputs, unconnected until there
is an audio sink. Rebuilt with SPU2, SIO2 and CDVD in:

```
WNS +0.168   TNS 0.000   WHS +0.010   THS 0.000
98,932 endpoints, 0 failing
All user specified timing constraints are met.
```

| resource | used | util |
|---|---:|---:|
| CLB LUTs | 20,791 | 2.39 % |
| CLB registers | 22,145 | 1.27 % |
| Block RAM tiles | 82 | 6.10 % |
| URAM | 224 | 35.0 % |

`bitstreams/c1100_ps2_iop.bit`, md5 `9164ab8c3f872f460f6694d0dd60f8ec`, with
its `csr.csv`. The first-pass image (md5 `6fab4441…`) is superseded.

**Rebuilt 2026-09-07 21:10 with BAR0 64-bit prefetchable** (the fix for the
all-ones reads, [c1100-pcie-transport.md](c1100-pcie-transport.md)): md5
`3ac569521c495e99049842f3307e54ef`, WNS +0.168 ns, 0 failing endpoints, no
inert-constraint signature in the log, `iop_*` CSR addresses unchanged.
That is the image to run `hw-test.sh` against.

## On silicon, 2026-09-07 22:04 — PASS

`build/ps2_hw/20260907-220404.log`, the rebuilt image, BAR0 at
`1801e000000`, link gen3 x4:

```
1. POST 00  post_count 0  reset 1  locked 1  heartbeat 0  cpu_error 0  mem_idle 1  rom_count 0
2. heartbeat 0 / heartbeat 1        toggling
3. loaded 4096 words ... rom_count 4096
4. pad0 = 0x5A3C:  [0.000s] POST 00  [0.010s] POST AA (count 12)   PASS
5. pad0 = 0xFFFF:  [0.000s] POST 00  [0.010s] POST EE (count 10)   stage 09 fails, as it must
6. PASS PASS PASS PASS PASS
7. POST AA  post_count 12  reset 0  locked 1  cpu_error 0  rom_count 32768
```

Twelve POST writes (01-06, 5a, 07-0A, AA) is exactly the simulated
sequence; the whole boot test runs in under the 10 ms poll interval, as
5.2 ms of console time should. The negative run proves the `iop_pad0` CSR
reaches SIO2 on hardware: with nothing pressed the pad answers something
other than `0x5A3C` and stage 09 reports EE after ten writes. So the IOP
subsystem — R3000 core, memory mux, RAM and ROM in URAM, INTC, timers, the
SPU2 stand-in with its work RAM, SIO2 and the CDVD stub — runs on the C1100
at 36.875 MHz exactly as it did in xsim, and the fractional MMCM
(DIVCLK 2 / MULT 22.125) locks. `rom_count` reads 32768 at the end because
the tool streamed the 4096-word image eight times over the run.

The `SoC Identifier` printed by the driver at the top of that log is `.`
(the identifier read as `\x01`): the transport build's driver reads the
identifier at the transport image's address, which in this image is
`iop_reset`. Cosmetic there, but the same mismatch is fatal for DMA (see
[c1100-pcie-transport.md](c1100-pcie-transport.md), "the driver must match
the image"); `hw-test.sh` now loads the driver generated with this image.

## Loaded on the C1100, 2026-09-07

The card came free (a power cut had reverted it to its flash image, which the
host enumerates as `10ee:5058` with no driver). The second-pass image above was
loaded over JTAG:

```
[load] c1100_ps2_iop.bit (56659936 bytes of config data)
[load] STAT=0x109079fc  DONE=1 EOS=1 CRC_ERR=0
```

Configuration is verified on silicon: DONE and EOS high, no CRC error.
`sudo tools/ps2iop/hw-test.sh` (the root part — stale `5058` identity
dropped, rescan, `litepcie.ko` — then the sequence below as the invoking
user, logged to `build/ps2_hw/`) was run the same day. **Result: no IOP
result.** Every CSR read, `iop_status` included, returned `0xffffffff`, so the
log shows POST FF, `cpu_error` 1 and counts of 4294967295 — the value of a
BAR0 read that the fabric did not answer, not anything the IOP did. The
identifier and scratch registers of the transport itself read the same, and
so does the HPS video image loaded afterwards. This is a defect in the PCIe
transport that every C1100 image shares; the analysis and the root-side
diagnostic to run next are in
[c1100-pcie-transport.md](c1100-pcie-transport.md) ("BAR0 reads return
0xFFFFFFFF"). The IOP test sequence stands and reruns unchanged once a
register read works.

Two things found while preparing the run, both now handled in
`tools/ps2iop/iop_post.py`:

- **Stage 09 needs the pad set.** `iop_pad0` resets to `0xFFFF` (nothing
  pressed) and `boot_test.s` stage 09 expects the pad to answer `0x5A3C`,
  which is what `tb_iop.sv` drives. On hardware that stage would have failed
  for no fault of the design. `run` now writes `iop_pad0` (default `0x5A3C`)
  before releasing reset, and `run --pad0 0xFFFF` is a deliberate negative
  test: stage 09 must then report EE, which proves the CSR reaches SIO2.
- **`tools/frametest` must not be run against this image.** It hard-codes the
  transport image's CSR map and `0x1000` is `iop_reset` here; the DMA integrity
  test belongs to `c1100_pcie_video_transport.bit`.

Planned sequence in `hw-test.sh`, in the order the failure modes above are
checked: status (`locked` = 1, POST 00, counts 0), heartbeat read twice 0.5 s
apart (must differ), ROM load with `rom_count` = 4096, the boot test with
pad `0x5A3C` (expect 01..0A then AA), the same with pad `0xFFFF` (expect EE at
09), five repeats of the passing run, final status.

## Booting a real BIOS — 2026-09-08

What a real BIOS asks of the hardware, how the ROM images are read, the
memory peek port and how far the boot gets on the card are in
[ps2-bios-boot.md](ps2-bios-boot.md). What follows is the first pass, in
simulation, that established the IOP takes the PS2 path at all.

The owner's own rom0 dumps (4 MB each, the `ROMVER` strings intact, kept
outside the repo) went into the IOP ROM, which is that size for this reason.
Read from the ROM before running anything:

- The reset vector (`0xBFC00000`) reads PRId and branches: below `0x59` (the
  R5900 reads `0x2E20`) is the IOP path at `0xBFC02000`.
- The IOP path reads PRId again: **below `0x10` it takes the PS1-compatibility
  init table** (SSBUS delays, COM_DELAY, EXP1 at `0x1F000000`, the SIO2 port
  registers), writes POST 01, then after POST 07 searches the first 512 KB of
  ROM for a module named `TBIN` and, finding none, falls into the POST FA
  halt loop. **From `0x10` up (and `0x1F801450` bit 3 clear) it takes the PS2
  init table** (CDVD at `0x1F402000`, DEV9, SPU2, cache configuration at
  `0xFFFE0140/0144`), writes POST 02, and after POST 07 searches for `IOPBOOT`
  and jumps to it with the RAM size code in `a0`. Every PRId test in the
  0220A ROM compares against `0x10`, `0x23` or `0x59`.
- The reset path's other dependencies, all present: `0xBF801060` (RAM size),
  `0xBF802070` (POST), `0xBF8010F0` (DPCR), `0xBD000020` (SIF MSFLAG, read
  and written once, behind a `0xBF801450` bit-31 test that the stub answers
  0), `0xFFFE0130` (cache control, handled inside the PSX CPU).

**xsim, 0220A ROM, PRId 2 (the PSX core's default), 40 ms of IOP time:**

```
[28443903000] reset released          (the 1M-word ROM load takes 28 ms of bench time)
[28512206000] POST fe                 (table A's own write to 0x1F802070)
[28653289000] POST 01
[28996840000] POST 03
[30020629000] POST 04
[30027953000] POST 05
[30036199000] POST 06
[30045612000] POST 07
FAIL: timeout, last POST 07           (inside the ROM scan for TBIN: 512 KB in 16-byte steps, uncached)
```

So the first thing a real BIOS proved is that the IOP core was reporting a
PS1 CPU. `iop_top` now loads PRId `0x1F` through the CPU's savestate port
during reset (the upstream CPU is untouched; `IOP_PRID` in `iop_top.vhd`).
**xsim, same ROM, PRId `0x1F`, 90 ms of IOP time:**

```
[28517740000] POST fc                 (table B's own write)
[28699620000] POST 02                 (the PS2 init table, not the PS1 one)
[29041353000] POST 03 04 05
[30089068000] POST 08
[30098481000] POST 09                 (the search for IOPBOOT)
FAIL: timeout, last POST 09
last 64 distinct instruction fetches: ... bfc4ab1c bfc4ab20 ... bfc4ac18 (a loop)
last data accesses:  LD 000016f0 = 00001c90   ST 000016f0 = 3c020000
                     LD 000016f4 = 00000000   ST 000016f4 = 244232c0
```

`IOPBOOT` lives at rom0+0x4A000 = `0xBFC4A000`, so the CPU is inside it, and
that loop (`0xBFC4AB1C`-`0xBFC4AC1C`) is its **ELF relocation pass**: it reads
relocation entries, forms a hi/lo pair and patches the two instructions it
points at. The stores prove it — `3c020000` is `lui $v0,0` and `244232c0` is
`addiu $v0,$v0,0x32C0`, a relocated address being written into a module that
has just been copied into IOP RAM at `0x16F0`. **So the BIOS reaches its IOP
kernel loader and starts loading the modules `IOPBTCONF` lists**, and it does
so on this core, with this memory map, with the peripherals that exist.

Simulation cannot go much further: 90 ms of console time cost about an hour of
xsim, and IOPBOOT has ~30 modules to load. The card runs it in real time,
which is what the diagnostic image is for.

## The diagnostic image and running a BIOS on the card

`c1100_ps2_diag` (`boards/c1100_ps2_diag.py`, md5
`43545949277f48ce1463be7ea31b213f`, WNS +0.390 ns, CSR map of the plain image
unchanged) is `c1100_ps2_iop` plus:

- **UARTbone** on the card's FPGA UART 0, so every register is reachable
  without PCIe (`/dev/ttyUSB2` at 115200; `tools/uart-probe.sh` finds it).
- **A POST ring**: the last 64 POST writes, each with the IOP cycle count at
  which it happened, so a fast sequence is not lost between host polls.
- **A stall detector**: cycles since the CPU last issued a bus request, and a
  flag once 2^22 of them (114 ms) pass with none.
- **The serial console**: `iop_console.vhd` answers the IOP's SIO1 port
  (`0x1F801050`), where the kernel's `Kprintf` writes, always ready, and every
  byte goes into a FIFO the host drains. This is how the IOP kernel says what
  it is doing.
- **A LiteScope** in the IOP clock domain on the CPU's memory bus (address,
  data, write mask, request/done), the POST writes, `cpu_error` and the stall
  flag, run-length encoded and triggered by the stall flag with the history
  before it, so a hang leaves the last few thousand bus transactions readable.

`sudo tools/ps2iop/bios-hw.sh /path/to/rom0.bin [seconds]` does the whole run:
JTAG load, PCIe rescan and driver, then (as the invoking user)
`tools/ps2iop/bios_run.py`, which streams the 4 MB image into the ROM in about
two seconds, releases reset, watches POST, and then prints the ring, the
console text, the stall state and the decoded bus trace into
`build/ps2_bios/<timestamp>-<name>/`.
