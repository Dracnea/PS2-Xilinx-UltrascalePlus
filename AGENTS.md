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

## 6a. A fault that answers to nothing physical is not a timing fault

The EE bring-up spent days being treated as a timing problem because it looked
exactly like one: intermittent, about one release in five, structured, and
passing every simulation. It was `x_valid` — the EX2 stage's valid bit — not
being cleared by reset, so releasing reset started the pipeline holding whatever
EX2 contained when the *previous* run was stopped.

The way to have found it sooner is a rule, not a hunch:

- **Change one physical quantity and see if the fault notices.** Implementation
  directives, clock uncertainty, the clock itself (`--ee-div 8` halves it), and
  the rail are four independent knobs. The failure rate did not move for any of
  them — 26 of 100 at 294.912 MHz and 850 mV, 23 of 100 at 147.456 MHz, 20 of
  100 at 720 mV. Setup timing scales with the period; hold does not, but hold
  scales with voltage. Something indifferent to *both* is logic.
- **Extra margin making the card worse is a redirect, not noise.** The build
  with 0.150 ns of real margin failed twice as often as the one with none. That
  was the moment to stop building bitstreams and start reading RTL.
- **A passing simulation may be answering a narrower question than you asked.**
  The testbench released reset once, from configuration, where every flop holds
  its declaration value. Nine of nine passing said "one release from a clean
  pipeline works" — never "reset clears the pipeline". A fault that needs a
  *previous* run to leave state behind is invisible to that shape of test.
- **When reset is suspect, diff the reset branch against the flush path.** Both
  exist to put the pipeline in a known state and they should clear the same
  set. Here the flush cleared EX2 and reset did not, and the flush's own comment
  named the risk. `grep` for every signal assigned in the clocked process and
  subtract the ones the reset branch clears; the survivors are the candidates.

Corollary for measurement, and it is the same lesson as §4: **a re-test that
disturbs the thing being tested proves nothing.** An experiment here "re-read
the registers after a failing run and got correct values", which was read as
clearing the core — but it pulsed reset between the reads, so it had re-run the
program. Reading three times without touching reset gave the same wrong values
every time, and the opposite conclusion.

## 6b. The rail is part of the build, and it is sticky

The EE images are built against the `-2L` speed file, which characterises
VCCINT at 0.85 V; the C1100's default is 0.800 V. A speed file describes silicon
at a stated voltage, so a `-2L` image at 0.800 V is signed off against a faster
part than the one in the slot.

- **Setting a rail needs a separate tool**, [UltraScale+ Voltage
  Control](https://github.com/Dracnea/UltrascalePlusVoltageControl), and a card
  whose satellite controller runs extended firmware. It is not in this
  repository.
- **The setpoint is global and survives reconfiguration and host reboots.** A
  rail moved for one experiment is still moved for the next thing loaded. Read
  it rather than assume it — `tools/reload.sh` prints the rails on the way
  through, and the voltage tool confirms on the die with SYSMON.
- **A recorded voltage goes stale.** `docs/ps2-hardware-study.md` said the card
  sat at 0.800 V for three days after it had been moved to 0.851 V, and that
  stale line sent one investigation down a wrong path. Any voltage written into
  a document should carry the date it was read.
- Reading the rail needs a JTAG session, which drops PCIe. There is no on-chip
  monitor exposed over PCIe in these images, so the cheap moment to read it is
  during a reload you were doing anyway.

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
