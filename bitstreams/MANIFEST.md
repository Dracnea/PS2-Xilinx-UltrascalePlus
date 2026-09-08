# Bitstreams

Built images, kept in the repo so a card can be brought up without a Vivado
seat. **The md5 is the identity, not the filename** — record it and check it.

Both declare BAR0 **64-bit prefetchable**: an earlier 32-bit BAR landed in a
host window the firmware never routed and every register read returned
`0xffffffff` (`docs/c1100-pcie-transport.md`).

| file | md5 | part | built from | verified |
|---|---|---|---|---|
| `c1100_ps2_diag.bit` | `d48bfa2a4fb7071dc221e376163701f0` | xcu55n-fsvh2892-2LV-e | `boards/c1100_ps2_diag.py` — `c1100_ps2_iop` plus UARTbone (`/dev/ttyUSB2`, 115200), a 64-entry POST ring with IOP cycle stamps, a CPU-bus stall detector, the IOP serial console as a FIFO, a LiteScope on the CPU's memory bus (`zanalyzer_iop.csv` beside it), the memory peek port, and the SIF's host side (`iop_sif_*`) so the host can play the Emotion Engine | Rebuilt 2026-09-08 with the real SIF: WNS +0.429 ns, 0 failing endpoints of 105,266, all timing constraints met, no `No clocks matched`; 22,910 LUTs, 227 URAM (unchanged). **On hardware the same day: the IOP kernel boots to completion** — one host write of MSFLAG bit 16 takes it from 21 to 28 resident modules and `SMFLAG` to `SIFINIT \| CMDINIT \| BOOTEND` (`docs/ps2-bios-boot.md`). Supersedes md5 `00786de7…`, whose entry read: Built 2026-09-08: WNS +0.376 ns, WHS +0.010 ns, 0 failing endpoints of 107,712, `All user specified timing constraints are met`, no `No clocks matched` in the log. 22,639 LUTs (2.60 %), 25,070 registers, 83 BRAM, 227 URAM — the peek port costs no memory, it switches the existing RAM read port over rather than adding one. **On hardware 2026-09-08:** a full 4 MB `0220A` BIOS loaded, verified against the file at 129 sampled windows, and booted — POST `FC 02 03 04 05 08 09` in 1.654 ms, then 21 of the 29 IOP kernel modules loaded (`docs/ps2-bios-boot.md`). |
| `c1100_ps2_iop.bit` | `3ac569521c495e99049842f3307e54ef` | xcu55n-fsvh2892-2LV-e | `boards/c1100_ps2_iop.py` — a LitePCIe gen3 x4 endpoint plus the IOP subsystem on CSRs | Builds and closes timing: WNS +0.168 ns, 98,932 endpoints, 0 failing; 20,791 LUTs, 82 BRAM, 224 URAM. **PASS on hardware 2026-09-07:** `boot_test.s` reaches POST AA in 10 ms with all twelve stage writes, the pad-`0xFFFF` run fails at stage 09 as designed, five repeats pass (`docs/ps2-iop-bringup.md`). Predates the peek port, so `iop_post.py verify`, `dump` and `peek` do not work against it. |

| `fk33_ps2_iop.bit` | `85c057310f10ddafd2c3f555dae266b9` | xcvu33p-fsvh2104-2-e | `boards/fk33_ps2_iop.py` — the same IOP subsystem on the SQRL Forest Kitten 33: a LitePCIe gen3 x4 endpoint, the IOP on CSRs, and a heartbeat LED. The RTL is identical to the C1100's; only the platform, the 200 MHz reference and the MMCM divider differ | Built 2026-09-08: WNS +0.609 ns, 0 failing endpoints of 97,275, `All user specified timing constraints are met`, no `No clocks matched`. 21,167 LUTs (4.81 %), 22,089 registers, 82 BRAM, **224 URAM — 70 % of this die**, against 35 % of a C1100 ([cards.md](../docs/cards.md)). 12.8 MB rather than 56 because this platform compresses the bitstream. **Never loaded: no FK33 is attached to the machine it was built on, so it is verified as far as synthesis, place, route and timing and no further.** In particular the PCIe lane count, link speed and BAR placement are inherited from the C1100 work and assumed. |

Loading one: `tools/jtag-load.sh bitstreams/<image>.bit [device-glob]`, then
`sudo tools/pcie-bringup.sh <image>` to drop the stale PCIe identity, rescan
and insert the driver built for that image. A card that held a bitstream with
no PCIe endpoint needs that rescan (or a warm reboot) before the host sees the
new device.

The `csr.csv` beside each image is the one generated with it, and the host
tools need it: `--csr bitstreams/<image>.csr.csv`. A csr.csv from a different
build reads every register at the wrong address.
