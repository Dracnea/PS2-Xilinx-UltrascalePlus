# Bitstreams

Built images, kept in the repo so a card can be brought up without a Vivado
seat. **The md5 is the identity, not the filename** — record it and check it.

Both declare BAR0 **64-bit prefetchable**: an earlier 32-bit BAR landed in a
host window the firmware never routed and every register read returned
`0xffffffff` (`docs/c1100-pcie-transport.md`).

| file | md5 | part | built from | verified |
|---|---|---|---|---|
| `c1100_ps2_diag.bit` | `570d2e75bb37bbe6c9e19a09e5311fb9` | xcu55n-fsvh2892-2LV-e | `boards/c1100_ps2_diag.py` — `c1100_ps2_iop` plus UARTbone (`/dev/ttyUSB2`, 115200), a 64-entry POST ring with IOP cycle stamps, a CPU-bus stall detector, the IOP serial console as a FIFO, a LiteScope on the CPU's memory bus (`zanalyzer_iop.csv` beside it), the memory peek port, the SIF's host side (`iop_sif_*`) so the host can play the Emotion Engine, the DMA controller, and the CDVD command log with disc-presence reporting | **Rebuilt 2026-09-09 with the CDVD command log** (md5 `570d2e75…`): WNS +0.392 ns, 0 failing endpoints of 115,828, all timing constraints met, no `No clocks matched`; 32,190 LUTs (the 32-entry log inferred as distributed RAM and cost about 7,900 of them), 227 URAM unchanged. Used on hardware the same day to record what `CDVDMAN` asks a drive for (`docs/disc-path.md`). Superseded md5 `244d7d90…`: **rebuilt 2026-09-08 with the DMA controller** (md5 `244d7d90…`): WNS +0.312 ns, WHS +0.011 ns, 0 failing endpoints of 105,020, all timing constraints met, no `No clocks matched`; 24,293 LUTs, 83 BRAM, 227 URAM (unchanged — the DMAC cost about 1,383 LUTs and no memory), and the CSR map is byte-identical to the image before it. **On hardware the same day:** the boot test runs all fifteen POST stages in 5.54 ms, including `0C` (the SIF handshake answered by the host as the EE) and **`0D`, the first DMA transfer on real fabric** — channel 6 built the ordering table, and the linked list, end marker, DICR flag and INTC bit 3 all checked. The BIOS boot is unchanged by the new bus master: `SMFLAG` still reaches `SIFINIT | CMDINIT | BOOTEND` with 28 resident modules. Superseded md5 `d48bfa2a…`: WNS +0.429 ns, 0 failing endpoints of 105,266, all timing constraints met, no `No clocks matched`; 22,910 LUTs, 227 URAM (unchanged). **On hardware the same day: the IOP kernel boots to completion** — one host write of MSFLAG bit 16 takes it from 21 to 28 resident modules and `SMFLAG` to `SIFINIT \| CMDINIT \| BOOTEND` (`docs/ps2-bios-boot.md`). Supersedes md5 `00786de7…`, whose entry read: Built 2026-09-08: WNS +0.376 ns, WHS +0.010 ns, 0 failing endpoints of 107,712, `All user specified timing constraints are met`, no `No clocks matched` in the log. 22,639 LUTs (2.60 %), 25,070 registers, 83 BRAM, 227 URAM — the peek port costs no memory, it switches the existing RAM read port over rather than adding one. **On hardware 2026-09-08:** a full 4 MB `0220A` BIOS loaded, verified against the file at 129 sampled windows, and booted — POST `FC 02 03 04 05 08 09` in 1.654 ms, then 21 of the 29 IOP kernel modules loaded (`docs/ps2-bios-boot.md`). |
| `c1100_ps2_iop.bit` | `9232938e3e0ba8bf2321e6cd691f5c96` | xcu55n-fsvh2892-2LV-e | `boards/c1100_ps2_iop.py` — a LitePCIe gen3 x4 endpoint, the IOP subsystem on CSRs, HBM with three masters, and both SIF DMA channels | **Rebuilt 2026-09-10 with SIF0 and the DMA read path** (md5 `9232938e…`): WNS +0.252 ns, WHS +0.010 ns, 0 failing endpoints of 137,692, all timing constraints met; 36,969 LUTs, 36,287 FFs, 83 RAMB36, 224 URAM. **On hardware the same day: both SIF directions carry data.** SIF1 lands a packet in the BIOS's own receive buffer at 0x19600; SIF0 has the IOP build a tag in RAM, point TADR at it and stream the EE's tag plus a payload out to the host, with the tag's address and count both proven to steer it. This is the first image whose DMA controller reads IOP memory. Supersedes md5 `f33f8528…`: the disc-source burst fix, on which the IOP first read the disc out of HBM. |

| `fk33_ps2_iop.bit` | `85c057310f10ddafd2c3f555dae266b9` | xcvu33p-fsvh2104-2-e | `boards/fk33_ps2_iop.py` — the same IOP subsystem on the SQRL Forest Kitten 33: a LitePCIe gen3 x4 endpoint, the IOP on CSRs, and a heartbeat LED. The RTL is identical to the C1100's; only the platform, the 200 MHz reference and the MMCM divider differ | Built 2026-09-08: WNS +0.609 ns, 0 failing endpoints of 97,275, `All user specified timing constraints are met`, no `No clocks matched`. 21,167 LUTs (4.81 %), 22,089 registers, 82 BRAM, **224 URAM — 70 % of this die**, against 35 % of a C1100 ([cards.md](../docs/cards.md)). 12.8 MB rather than 56 because this platform compresses the bitstream. **Never loaded: no FK33 is attached to the machine it was built on, so it is verified as far as synthesis, place, route and timing and no further.** In particular the PCIe lane count, link speed and BAR placement are inherited from the C1100 work and assumed. |

Loading one: `tools/jtag-load.sh bitstreams/<image>.bit [device-glob]`, then
`sudo tools/pcie-bringup.sh` to drop the stale PCIe identity, rescan and insert
the driver built for that image. A card that held a bitstream with no PCIe
endpoint needs that rescan (or a warm reboot) before the host sees the new
device.

**The driver must be the one generated with the image on the card**, and since
2026-09-09 the tools enforce that rather than trusting the operator to
remember: `jtag-load.sh` records what it loaded in `build/.last-loaded`,
`pcie-bringup.sh` defaults to that record instead of a name fixed in the
script, and it finishes by checking the identifier the card reports against
that image's `csr.csv`, failing if they differ. Naming the image explicitly
(`sudo tools/pcie-bringup.sh c1100_ps2_iop`) still works and still wins.

That check exists because the failure it catches is silent. A driver built for
another design puts every DMA register at an address belonging to something
else; the ioctls all succeed, nothing reaches the hardware, and the only
outward sign is the identifier string coming back as rubbish in the middle of
a long log. It cost most of a day on 2026-09-09 ([hbm.md](../docs/hbm.md)).

The `csr.csv` beside each image is the one generated with it, and the host
tools need it: `--csr bitstreams/<image>.csr.csv`. A csr.csv from a different
build reads every register at the wrong address.
