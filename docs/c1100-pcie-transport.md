# C1100 PCIe transport — verified build result

Stage 3 of the retro video path (`PCIe → host RAM`), built standalone so the
link and the DMA are proven before anything is built on top of them.

Build target: `boards/c1100_ps2_iop.py`
Device: `xcu55n-fsvh2892-2LV-e` (Varium C1100 / Alveo U55N)
Toolchain: Vivado 2026.1

## Result

```
WNS +0.721   TNS 0.000   WHS +0.011   THS 0.000
27,816 endpoints, 0 failing
All user specified timing constraints are met.
```

`build/c1100_pcie/gateware/xilinx_c1100.bit` — 56,660,149 bytes,
md5 `496aca5739e08b33e44b763ee8eeba8e`.

Loaded over JTAG onto a physical C1100; `End of startup status: HIGH`.

## Cost

| resource | used | available | util |
|---|---:|---:|---:|
| CLB LUTs | 4,579 | 871,680 | **0.53%** |
| CLB Registers | 8,776 | 1,743,360 | 0.50% |
| Block RAM tiles | 24 | 1,344 | 1.79% |
| URAM | 0 | 640 | 0% |
| DSP | 0 | 5,952 | 0% |

This is the number that matters for the whole project: a full PCIe gen3 x4
endpoint with scatter-gather DMA and a frame source costs **half a percent** of
the device. The multi-instance goal — several complete retro systems resident at
once — is well supported by this part, and ~28 MB of untouched on-chip memory is
enough to hold multiple 8/16-bit systems with no external memory at all.

## What the design contains

- PCIe gen3 x4 endpoint (`USPPCIEDMA`), 128-bit datapath, BAR0 128 KB
- LitePCIe DMA with scatter-gather, MSI
- `hbm_cattrip` driven low (see the trap in the README)
- A frame generator emitting `(frame << 24) | pixel_index`, so DMA integrity is
  a **word-for-word check rather than a judgement by eye**
- Host software generated alongside: kernel driver, `litepcie_util.c`,
  `litepcie_test.c`, `csr.csv`, generated headers

SoC identifier string: `C1100 PCIe video transport x4 gen3`.

## Bringing the link up

The host enumerates BARs at boot. A card that previously held a bitstream with
no PCIe endpoint will still show its stale factory identity after a JTAG load,
so the host must be told to look again:

```sh
# after programming over JTAG
sudo sh -c 'echo 1 > /sys/bus/pci/devices/0000:XX:00.0/remove; sleep 1; echo 1 > /sys/bus/pci/rescan'
lspci -nn -d 10ee:      # expect 10ee:9034 with a 128K BAR0
```

A warm reboot achieves the same thing. `build/.../software/rescan.py` automates
this, but note it only removes devices whose IDs are in its own list — a card
sitting on a factory shell ID will not match, so remove it by address as above.

## The reset-CDC constraint — three attempts, and why the first two failed

The design initially missed timing at **WNS −0.806** on exactly one path:
`soc_rst` crossing from the 125 MHz sys domain into the 100 MHz input domain,
0.399 ns of delay against a 2.000 ns requirement. One endpoint. Every real clock
domain passed comfortably. The diagnosis was right from the start; applying it
correctly took three tries.

| attempt | mechanism | result |
|---|---|---|
| 1 | `set_max_delay -datapath_only -from …` via `add_platform_command` | **applied but ineffective** — matched 4 real cells, appeared in `report_exceptions`, moved slack only −0.806 → −0.802. A `-from` with no `-to` does not override the inter-clock requirement. |
| 2 | `set_clock_groups` via `add_platform_command` | **silently inert** — landed at XDC line 79, *before* the `create_clock` statements, so both clock names matched nothing. Identical −0.806. |
| 3 | `add_false_path_constraints_by_name` | lands in the pre-placement `.tcl`, after synthesis, when the clocks resolve. **+0.721.** |

**The lesson worth carrying forward.** Attempt 2 was verified against a routed
checkpoint first, where it produced +0.729 slack exactly as intended — and then
did nothing in the build. A checkpoint has every clock already resolved, while
the build XDC is read *in order*. Checkpoint verification proves a constraint's
semantics but says nothing about whether it will resolve at the point the flow
reads it.

LiteX's own API documents the trap:

```python
def add_false_path_constraints_by_name(self, *clock_names):
    # On Vivado, some generated/internal clocks are only resolvable after synthesis.
    # Emit explicit set_clock_groups in pre_placement commands for robust resolution.
```

Both failures shared a shape: **a constraint that reads correctly, emits a
warning nobody looks at, and produces a build indistinguishable from having no
constraint at all.** The tell was in the log each time — `No clocks matched`,
and `CRITICAL WARNING: [Vivado 12-4739] set_clock_groups: No valid object(s)
found`. Grep builds for those two signatures.

The final +0.721 landed within 8 ps of the +0.729 measured on the checkpoint,
confirming the checkpoint experiment had been predicting the right thing all
along — only the delivery mechanism was wrong.

### Not our warnings

Build 3 still reports two `12-4739` criticals. Both come from **Xilinx's own
generated PCIe IP constraints** (`ip_pcie4c_uscale_plus_impl_x1y0.xdc`:
`set_false_path -from [get_pins sys_reset]`, and a switching-activity constraint
that only affects power estimation). Build 2 had ten; the eight that vanished
were ours.

## Hardware bring-up, verified

Loaded over JTAG (`End of startup status: HIGH`), then PCIe remove + rescan.
The endpoint enumerates and the driver binds:

```
c1:00.0 Memory controller [0580]: Xilinx Corporation Device [10ee:9034]
        Control: Mem+ BusMaster+
        Region 0: Memory at b6c00000 (32-bit, non-prefetchable) [size=128K]
        Kernel driver in use: litepcie
/dev/litepcie0
```

Link parameters read from sysfs:

| | |
|---|---|
| current / max link speed | 8.0 GT/s (gen3) |
| current / max link width | x4 |
| MSI | allocated, irq 347 |

Link trained at the design's full target, gen3 x4, with no downshift.

### 2026-09-07: BAR0 reads return 0xFFFFFFFF — the endpoint enumerates but no register is reachable

The section above verified enumeration, link training and driver binding. It
did **not** verify a register read: no `litepcie_util info` output was
recorded, and none of the three images derived from this design had been
loaded. Today two of them were (`c1100_ps2_iop.bit`, then
`c1100_hps_video_test.bit`), with the same result on both:

```
litepcie 0000:c1:00.0: Version \xff\xff\xff...          (driver probe)
SoC Identifier   : ����...                               (litepcie_util info)
Write 0x12345678 to Scratch register:  Read: 0xffffffff  (litepcie_util scratch_test)
video_dims / video_frames / video_drops : ffffffff        (tools/csrw.py)
iop_status : ffffffff                                     (tools/ps2iop/iop_post.py)
```

Host side, identical to the 09-05 record: `10ee:9034`, BAR0 at `b6c00000`
(128 K, inside the root port's window `b6c00000-b6cfffff`, assigned on
rescan), `Control: Mem+ BusMaster+`, LnkSta 8 GT/s x4, MSI allocated,
`litepcie` bound, no AER or link message in the kernel log. Config-space
access therefore works (it is answered by the hard IP) and memory access
to BAR0 does not (it is answered by the fabric). `c1100_pcie_video_transport.bit`
itself has not been re-tested since 09-05 and was never read from, so as
of today **no register read has ever succeeded on this card** — this is a
bring-up defect in the base transport design, not a regression in the
derived images.

Ruled out from user space: the 100 MHz input (BK43/BK44 is the pin every
working design on this card uses, Corundum's `clk_100mhz_1`); pin placement
(`xilinx_c1100_io.rpt` shows the lanes on quad 227, refclk on `MGTREFCLK0_225`,
and the link trained); the driver (`ctrl_scratch` reads ff through the
driver's ioctl, the driver's own probe read the identifier as ff).

Three cases remain, and they are distinguishable only from the root port's
status registers, which need root. `tools/pcie-diag.sh` (run with sudo,
default image the transport one) clears the status bits on both ends,
reads BAR0 directly through `resource0` with the driver unloaded, times the
reads, then dumps `DevSta`/`UESta`/`CESta` on both ends and the kernel log:

| case | what the host sees | meaning |
|---|---|---|
| completion timeout | reads take ms each; root port `DevSta` CorrErr/NonFatal, `UESta` CmpltTO | the endpoint never answered: the CQ → sys crossing is stuck, i.e. the sys domain is not running or is held in reset |
| unsupported request | reads fast; endpoint `DevSta UnsupReq+`, root port `Status: <MAbort+` | the endpoint rejected the BAR hit: BAR/aperture mismatch between the IP and the depacketizer |
| completion with data ff | reads fast; no error bits anywhere | the endpoint answered: LiteX's wishbone timeout returned ff, so the on-chip address decode never selected the CSR bridge |

Result of that run (2026-09-07, `build/pcie_diag/20260907-180309.log`, on
the transport image itself): **the third case.** Every read completes in
0.6 µs (1000 reads in 0.6 ms), through the driver and through `resource0`
alike, and not one status bit is set afterwards on either end — endpoint
`DevSta` clean, root port `DevSta`/`UESta`/`CESta`/`RootSta` clean, no
`RxMA`, root port `Control: Mem+`. So the endpoint answers every read
itself, fast, with all ones; writes are accepted and have no effect
(scratch stays `ffffffff`); the DMA writer never delivers a byte and the
MSI count stays 0. It is not the on-chip bus timeout either: that is
1,000,000 sys cycles, 8 ms per read. Something between the hard IP's CQ
interface and the wishbone bridge is producing a successful completion
without performing the access. The LitePCIe these images were built with
is upstream `0439d65` (2026-09-01), whose UltraScale+ path was rewritten in
2026 (Verilog AXI-Stream adapters replaced by LiteX ones in February, the
support wrapper removed, completion-descriptor and requester-descriptor
fixes still landing in June and July), which is where the suspicion sits.

**Diagnostic image, `c1100_pcie_diag.py`.** The transport design plus
UARTbone on the card's FPGA UART 0 (BJ41/BK41, Corundum's `uart_txd[0]` /
`uart_rxd[0]`, reaching the on-board FT4232H, whose channels are
`/dev/ttyUSB1..3`; `tools/uart-probe.sh` finds the right one) and two
LiteScope analyzers, one in the pcie domain on the hard IP's raw CQ/CC
streams, one in sys on the PCIe wishbone master and the endpoint's
request/completion streams. The pcie_* CSR addresses are unchanged from the
transport image (the additions sort last), so the transport build's driver
and csr.csv stay valid for the PCIe side. `tools/pcie-scope.py` arms both
analyzers over the UART, performs one BAR0 read through PCIe, and decodes
the CQ descriptor, the CC descriptor and the wishbone cycle it captured.
Neither the UART nor the analyzers need root; only the PCIe rescan does.

Its first build failed on the by-name `set_clock_groups` the transport
target carries (`add_false_path_constraints_by_name("clkout", "clk100_p")`):
with more modules in the design the MMCM output net is `crg_clkout`, so
`No clocks matched 'clkout'` and this time Vivado stopped with
`12-5201: cannot set the clock group when only one non-empty group
remains`. The fourth build lost to that constraint. The diagnostic target
removes it and declares the groups by MMCM pin, as the later targets do.

Loaded 2026-09-07 (md5 `f0f1e6fd…`). Over the UART, without PCIe being
re-enumerated: the identifier string reads `C1100 PCIe video transport x4
gen3`, `ctrl_scratch` reads back what is written, `ctrl_bus_errors` is 0,
the PHY reports link up, and an immediate-trigger capture on both
analyzers shows `pcie_rst` 0, `user_lnk_up` 1, CQ `tready` 0xF, `sys_rst`
0, MMCM locked. **So the sys domain, the CSR bus and the PHY status path all
work; the fault is confined to the request/completion path between the hard
IP's CQ/CC interfaces and the wishbone bridge.** The capture of a real BAR0
read (which needs the root rescan first) is the next measurement.

**The capture, 2026-09-07 19:43 (`build/pcie_scope/20260907-194326`, after
the root rescan onto the diagnostic image).** Both analyzers armed — pcie
on CQ `tvalid` rising, sys on the wishbone master's `cyc` — then one write
and one read through the driver: the read returned `ffffffff`, and
**neither analyzer triggered.** Repeated with an immediate trigger under
continuous traffic (103,630 read+write pairs during the 1024-sample window
and 1.75 million writes in total): CQ `tvalid`, CC `tvalid`, RQ `tvalid`
and RC `tvalid` are 0 in every sample, and the scratch register read over
the UART afterwards is still `0x12345678`. **No request ever reaches the
hard block's completer-request interface.** And the root port's *secondary*
status — which the earlier dumps did not include — reads `<MAbort+`:
Received Master Abort, i.e. the endpoint answered with Unsupported
Request. So the integrated block itself is refusing these requests on
arrival, before any user logic, while at the same time the host's config
accesses work (BAR readback, MSI Enable took) and the PHY reports L0, gen3
x4, DL up (`0x20ad` decoded with the CSR's field layout).

PG213 lists what makes the block answer a memory request itself: the target
BAR not enabled, Memory Space Enable clear in *its* view of the function,
the function in D3, or an FLR pending. None of those was observable from
the first diagnostic image, which is why the second one (below) publishes
the block's own `cfg_function_status`, power state, FLR, error, message and
NP-credit outputs as CSRs (`zhardip_*`, `tools/pcie-hardip.py`) and counts
CQ beats in hardware.

One bug found on the way, harmless here: LitePCIe's `pcie_phy_phy_bus_master_enable`
CSR is assigned the whole 16-bit `cfg_function_status`, so it reports bit 0
(I/O Space Enable), not bit 2 (Bus Master Enable). It reads 0 on this host
with `BusMaster+` set.

**The block's own status, after the host re-enumerated the image
(2026-09-07 20:13):** `cfg_function_status` `0x000e` (MSE 1, BME 1, INTx
disabled — exactly the host's Command register), power state D0_active,
LTSSM L0, gen3, x4, no FLR, no error output, no message received, NP
credits granted, and **CQ beats still 0** while the host read `ffffffff`.
Before re-enumeration the same registers read all-zero, so they do track
the host's config writes. And the endpoint's own Device Status never sets
Unsupported Request Detected after the reads, which it must if the block
had refused them. So neither side records an error, the block sees no
request, and the host gets all ones in 0.6 µs: **the strongest reading now
is that the memory requests never reach the card at all.** Config accesses
do (they set MSE, BAR0, MSI Enable), but config and memory take different
routes through the host fabric.

The suspect is the host's routing of the 32-bit window. The root bus
`0000:c0` has a 32-bit window `b6c00000-b8dfffff` from ACPI; at boot the
firmware used only its top for the two internal ports (`b8c00000`,
`b8d00000`) and gave this port only a 64-bit prefetchable window
(`1801e000000-180200fffff`) for the factory image's BARs. The 32-bit window
`b6c00000-b6cfffff` was assigned by Linux at the first rescan. If the data
fabric was not programmed to route that part of the window, reads return
all ones with no PCIe error on either end, which is what is observed.
`c1100_pcie_video_transport.bit` on 2026-09-05 was never read from, so
this was never exercised before.

**Differential experiment (third diagnostic build):** BAR0 becomes 64-bit
prefetchable (Corundum's configuration on this card), so the kernel places
it in the port's prefetchable window, which the firmware did route at boot.
Same design otherwise. If reads then work, the transport was fine all
along and the fix is that BAR type (or a warm reboot with the image loaded,
so the firmware assigns the windows). `tools/pcie-diag.sh` now also clears
and prints the root port's secondary status and shows `/proc/iomem` around
the BARs.

**Result, 2026-09-07 20:50 (`build/pcie_diag/20260907-205049.log`): it
works.** BAR0 landed at `1801e000000` (64-bit, prefetchable, 128 K) inside
the port's boot-time prefetchable window, and:

```
raw read scratch     @0x0004 = 0x12345678          (driver unloaded, resource0 mmap)
1000 reads: 2.1 ms total  -> 2.1 us each           (real completions; was 0.6 us for the all-ones)
Write 0x12345678 to Scratch register:  Read: 0x12345678
Write 0xdeadbeef to Scratch register:  Read: 0xdeadbeef
litepcie 0000:c1:00.0: Version C1100 PCIe video transport x4 gen3
Secondary status: ... <MAbort-                     (cleared first, stayed clear)
```

and the analyzers finally saw a request: a MemWr to `0x1801e000004`, BAR 0,
aperture 17, requester `c0:00.0`, followed by the wishbone write of
`0xa5a5f00d` to address 4 and its ack; the UART read the same value back.

**Root cause: the host, not the card.** Linux assigned the 32-bit
non-prefetchable BAR0 into `b6c00000-b6cfffff`, a window it carved from
the root bus's 32-bit range at the first rescan; the firmware had only
routed this port's 64-bit prefetchable window (used by the factory image's
BARs) at boot. Accesses to the unrouted window return all ones from the
host fabric with no PCIe transaction at all, which is why neither end ever
logged anything and why config accesses (a different path) kept working.
The LitePCIe design, the rewritten PHY path and the 128 KB aperture were
all fine.

**Fix, applied to every C1100 target:** BAR0 is declared 64-bit
prefetchable (`pf0_bar0_64bit`/`pf0_bar0_prefetchable`, Corundum's
configuration on this card), so the kernel places it in the window the
firmware routed. The alternative is a warm reboot with the image loaded so
the firmware assigns the windows itself; the BAR type is the one that
survives a rescan.

**DMA, measured the same evening on the diagnostic image (same transport):**
`litepcie_util dma_test` runs the writer through its 256-entry table in
loop mode (2,111 loops in a few seconds, 38,032 MSIs), and
`tools/frametest` — now that it sets liblitepcie's `writer_enable`, which
`litepcie_dma_process` needs and the tool never set — reports:

```
enable -> 1st word: 132.7 us / 216.9 us (two runs)
bytes transferred : 67108864 (64.0 MiB)
words checked     : 4194304   sequence errors: 8191 (one per 8 KB buffer boundary)
```

Two findings behind those numbers. The test frame source drives its 32-bit
word into the DMA's 128-bit sink, so every 16-byte beat carries one word
and three zeros (the checker now expects that; a real core's `video_sink`
packs four pixels per beat). And inside each 8 KB buffer the sequence is
perfect; the one error per buffer is a jump of 4096 words, i.e. the source
produced nine buffers while the test's host loop consumed one and the ring
wrapped. The source is not throttled by the test, so that is a statement
about the test loop (26 MB/s), not about the transport. Pacing the source
or a zero-copy consumer is the next refinement; `retroview`'s litepcie
transport is that consumer.

**The driver must match the image.** LitePCIe's kernel module and
`litepcie_util` are generated per build with the CSR addresses of that
build (`csr.h`): the DMA table, enable and MSI registers are hard-coded.
The pcie_* blocks do not sit at the same addresses in every image — LiteX
allocates CSR pages in name order, so whatever sorts before `pcie_*`
shifts them: `pcie_dma0` is at `0x1800` in the transport, diagnostic and
PS2 images but at `0x2000` in the HPS test images. Loading the transport
build's driver with `c1100_hps_video_test` (2026-09-07 22:04) gave a live
sink (`video_dims` 640x480, frames counting, no drops) and a DMA writer
that never started: the driver had programmed the table into
`identifier_mem`. Each build directory now carries its own compiled
`software/kernel/litepcie.ko`, and `video-capture.sh` / `pcie-diag.sh` /
`hw-test.sh` load the one that matches the bitstream. Register-level tools
(`csrw.py`, `iop_post.py`) are unaffected because they take addresses from
the image's `csr.csv`. Pinning the pcie_* CSR pages to fixed indices in
every C1100 target, so one driver serves all images, is the cleaner
follow-up.

Everything below the enumeration section for
`c1100_hps_test`, `c1100_hps_video_test` and `c1100_ps2_iop` is being
re-measured on images rebuilt with that BAR; the PS2 IOP `hw-test.sh`
output of 2026-09-07 17:24 (POST FF, `cpu_error` 1, counts 0xffffffff) was
the all-ones read, not an IOP result.

**Device node permissions.** The driver creates `/dev/litepcie0` as
`root:root 0600`, so every tool needs root. `tools/99-litepcie.rules` relaxes
this to the `plugdev` group, which makes iterating on measurements practical.
