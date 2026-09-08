# AGENTS.md — read me first

This repo is **public**. It holds the work to rebuild a PlayStation 2 on AMD
UltraScale+ accelerator cards, and it is intended to be shared.

## 1. The public/private boundary is absolute

The maintainer also runs **private** FPGA work on the same machines and the
same cards. None of it belongs here — not the files, and not references to
them.

- Nothing from the private trees is copied, quoted, or cited in this repo.
- Watch for leakage through **provenance**, not just through file moves. It is
  natural to write "pin data taken from `<private-path>/foo.xdc`" in a header
  comment; doing so publishes the existence and structure of private work.
  Re-attribute derived data to its **public** upstream instead — for the C1100
  pinout that is Corundum's AU55N target, where it actually originates.
- Keep the engineering claim, drop the private locator. "Verified through
  place-and-route on this card" is fine. Naming the private build that
  verified it is not.
- Grep before the first push of any migrated file. A public repo's history
  cannot be quietly corrected afterwards.

## 2. Sources: public documentation only

The PS2 is documented well enough in public that nothing else is needed, and
nothing else is permitted here.

- **Use:** [ps2tek](https://psi-rockin.github.io/ps2tek/), PCSX2's source and
  its hardware tests, PS2SDK, published MIPS and R3000A documentation, and
  clean-room decompilation projects.
- **Never use, download, or cite** leaked Sony source or SDKs. A design derived
  from stolen source could never be published, which would defeat the point of
  the project.
- BIOS and disc images belong to whoever dumped them from their own console.
  None is committed, and `.gitignore` refuses `*.bin` so one cannot be added by
  accident.

## 3. Nothing goes in a document unless it is verified

A statement here is one someone will act on without re-checking.

- **Verified** = measured on real hardware, or observed directly in a tool's
  output. State it plainly, with the measurement and the date where it matters.
- **Not verified** = reasoned, inferred, or true of a different card. It still
  gets written down, but tagged:

  ```markdown
  > **NOTE (unverified):** the FK33 can hold the IOP with a smaller BIOS ROM.
  > *Verify by: an out-of-context fit on xcvu33p with ROM_ROWS_LOG2 = 16.*
  > Delete this note and state the result plainly once confirmed.
  ```

- **"X does not work" needs the same proof as "X works".** A negative claim
  stops the next person trying, so an unverified one costs more than silence.
- **Contradictions get recorded, not resolved.** Two runs legitimately produce
  two different numbers. Keep both with dates rather than averaging.
- **A failure that stops reproducing is not a failure that was explained.** Say
  which it was. On 2026-09-08 two 4 MB BIOS loads failed and then the same file
  worked; both mechanisms proposed for it had already been tested and killed,
  and the docs say so rather than inventing a third.
- Never cite a file you have not confirmed exists. Grep first.

## 4. Trust the card, not the host's idea of the card

The lesson that cost the most here: `iop_rom_count` counts register writes the
host issued, not words the fabric stored, and for two long debugging runs
nobody could tell the difference.

- The design has a **memory peek port** for exactly this. `iop_post.py verify`
  reads a loaded ROM back and compares it with the file; `bios_run.py` does it
  on every run before releasing reset. Do not remove that step to save time.
- The same applies to any new host-side counter: ask what it would read if the
  hardware were doing nothing, and if the answer is "the same", it is not
  evidence.

## 5. Constraints are not code — verify they took effect

The C1100 PCIe bring-up lost two full builds to constraints that read correctly
and did nothing (see `docs/c1100-pcie-transport.md`). Both were visible in the
log and invisible in the result.

- After any timing-constraint change, **grep the build log** for
  `No clocks matched`, `12-4739`, and `is not supported`. Only the two
  `12-4739` lines from Xilinx's own PCIe IP are expected.
- A constraint verified against a **routed checkpoint** is not verified for the
  **build**. A checkpoint has every clock resolved; the build XDC is read in
  order. Generated and internal clocks only exist after synthesis.
- An unchanged WNS after a constraint change is the signature of an inert
  constraint, not of a wrong diagnosis.

## 6. Hardware safety

- **`hbm_cattrip` (BE45) must be driven low** on the C1100 by any design that
  does not instantiate HBM. Floating it powers the card off via the satellite
  controller.
- **Never `SIGKILL` a process holding an FTDI channel.** `SIGTERM`, wait,
  verify the channel came back. A hard kill leaves all four channels marked
  open at the driver level with nothing holding them.
- Programming over JTAG while the card is enumerated on PCIe drops the link.
  Remove the PCIe device first, then program, then rescan.
- These are passively cooled datacenter cards. Watch temperatures in a desktop
  chassis.

## 7. Licence

The IOP derives from PSX_MiSTer, so **the work as a whole is GPL-2.0** — see
[LICENSING.md](LICENSING.md). PSX_MiSTer is a pinned submodule and is never
vendored: upstream's code stays upstream's, at the commit git records. If you
add RTL that links into the IOP, it is GPL-2.0 too; say so in its header.

## 8. Layout

One idea per directory: `rtl/` is what runs on the fabric, `boards/` wires it
to a specific card, `tools/` is the host side, `docs/` is what was measured.
A new card is a `platforms/` file and a `boards/` target, not a fork of the
RTL — the point of this repo is that the PS2 core is card-independent.
