# Licensing

**The work as a whole is GPL-2.0** — see [LICENSE](LICENSE).

That is not a preference, it follows from what the design is made of. The IOP
subsystem reuses the R3000A CPU, the memory controller, the timers and the SPU
from [PSX_MiSTer](https://github.com/MiSTer-devel/PSX_MiSTer) (Robert Peip),
which is GPL-2.0, and `rtl/iop/iop_memorymux.vhd` is a direct derivative of
that project's `rtl/memorymux.vhd`. A derivative of GPL-2.0 code is GPL-2.0,
and so is anything linked into the same design.

| what | licence | note |
|---|---|---|
| `third_party/PSX_MiSTer` | GPL-2.0 | a pinned submodule, not vendored — upstream's code stays upstream's, at the exact commit git records |
| `rtl/iop/iop_memorymux.vhd` | GPL-2.0 | derived from PSX_MiSTer's `memorymux.vhd`; only the address decode differs, and `diff` against upstream shows exactly what |
| `rtl/psx/*.vhd` | GPL-2.0 | PSX_MiSTer support files carried here because they are modified for UltraScale+ inference |
| the rest of `rtl/iop/*.vhd` | GPL-2.0 | new code, but it instantiates and is instantiated by the above, so it ships under the same terms |
| `boards/`, `platforms/`, `tools/` | BSD-2-Clause | LiteX/MiSTeX-derived and new host-side code; BSD-2-Clause is GPL-compatible, so it combines cleanly |
| `rtl/altera_compat/*` | BSD-2-Clause | stand-ins for Intel megafunctions so Intel-targeted RTL infers Xilinx primitives |

If you take the RTL, take the GPL-2.0 obligations with it. If you only want
the host-side tools in `tools/`, those are BSD-2-Clause on their own.

## A correction worth recording

This work previously lived in `Dracnea/FPGA-Retro`, whose README states that
files carry `SPDX-License-Identifier: BSD-2-Clause`. For the PS2 IOP sources
that statement was wrong: a file whose own header says it is derived from
GPL-2.0 code cannot be BSD-2-Clause. The per-file attribution in those headers
was always correct; the blanket statement was not. This repository states the
position properly.
