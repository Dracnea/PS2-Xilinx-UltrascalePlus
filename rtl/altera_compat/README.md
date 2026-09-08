# altera_compat — Vivado-synthesisable stand-ins for the Altera megafunctions MiSTer cores instantiate

MiSTer cores are written for Quartus and lean on Intel/Altera library cells:
`altsyncram`, `altdpram`, `lpm_mult`, `lpm_divide`, `scfifo`, `dcfifo`,
`altshift_taps`, `altera_mult_add`, `altddio_out`. MiSTeX's approach is to
hand-port each file that uses one. That works for a core someone has already
ported (SNES, NES) and does not scale to the Peip cores — GBA, PSX and N64
share a handful of thin wrappers (`dpram.vhd`, `SyncRamDualByteEnable.vhd`,
`RamMLAB.vhd`, `Shiftreg.vhd`, `cpu_mul.vhd`) around exactly these cells.

So this directory supplies the cells themselves, as plain Verilog with the
same module names, parameter names and port names, so the upstream wrappers
synthesise unmodified. Parameters that only steer Quartus (device family,
`lpm_hint`, `ram_block_type`, `lpm_type`) are accepted and ignored.

Everything here is written from the Intel megafunction *interface*
documentation (parameter and port names), not from any Intel source, and is
BSD-2-Clause like the rest of this repo.

## What is modelled, and the one semantic gap

- `altsyncram` — single/dual/bidir dual port, independent widths per port
  (mixed-width via a narrowest-port base word), byte enables, optional
  output registers, `address_reg_b = CLOCK1` clocking. **Read-during-write on
  the same port returns OLD data** (Xilinx read-first). Intel's
  `NEW_DATA_NO_NBE_READ` returns the new data. No MiSTer core I have read
  relies on same-cycle read-after-write through one port, but this is the
  gap to check first if a ported core misbehaves. `init_file` is not
  supported here — MiSTeX converts MIF files and feeds them to its own
  `spram`/`dpram` replacements instead.
- `altdpram` — the MLAB / LUT-RAM form: registered write, asynchronous read.
- **`numwords` / `numwords_a` / `numwords_b` = 0 means `2**widthad`.** Intel's
  VHDL component declarations default them to 0 with that meaning, and when a
  model is bound from a VHDL wrapper the 0 overrides the Verilog parameter
  default. Before this was handled (2026-09-06) `altdpram` sized its array
  `[0:-1]` under xsim and dropped every write — the PSX CPU's register file
  read X for every register. Synthesis was not affected. Any wrapper that
  passes `numwords` explicitly (PSX's `dpram.vhd` does) never saw it.
- `lpm_mult`, `lpm_divide` — signed/unsigned per Intel's representation
  parameters, `lpm_pipeline` output register stages (a plain register chain;
  no retiming is implied, so a 16-bit divider with `lpm_pipeline = 6` is one
  combinational divide followed by six registers unless synthesis retimes).
- `scfifo`, `dcfifo` — normal and show-ahead; `dcfifo` is a Gray-pointer
  asynchronous FIFO.
- `altshift_taps` — one tap, `tap_distance` deep.
- `altera_mult_add` — one multiplier, dynamic `signa`/`signb`, optional
  output register.
- `altddio_out`, plus a Series-7-named `ODDR` — both map onto `ODDRE1`, the
  UltraScale+ output DDR register (US+ has no `ODDR` cell).

These are functional models good enough for synthesis, fit and timing; the
SDRAM-facing cells are moot on these cards anyway (they have no SDRAM — see
the memory-backend notes in `docs/`).
