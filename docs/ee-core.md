# The R5900 integer core: how it gets built, and how it gets checked

Milestone 3 of [roadmap.md](roadmap.md), and the multi-year item. This page is
the plan and the standard of evidence, written before the RTL so the standard
is not set by what the RTL turns out to do.

## What already exists

`rtl/ee/ee_ram.vhd` is the 32 MB main memory and `rtl/gs/gs_lmem.vhd` the GS's
4 MB local memory, both sized in [hbm.md](hbm.md). There is no core. The IOP's
R3000A came from PSX_MiSTer and is 32-bit; the R5900 is a different machine and
is written from the EE Core User's Manual rather than adapted.

## The order, and why it is this order

[ps2-hardware-study.md](ps2-hardware-study.md) §7 sets it: the integer core
first, then MMI, then the FPU, then VU1, then VU0 and the COP2 coupling. What
matters is that **every step ends somewhere testable**, which for a CPU means
one thing: a reference that says what the state should be, and a way to compare
against it instruction by instruction.

So the reference is built first. That is not ceremony. This project has spent
days on faults that were invisible because nothing could report them — a DMA
that finished early and said nothing, a FIFO that dropped a word and said
nothing, a completion that never became an interrupt. A CPU has far more places
to hide a wrong answer than a DMA channel does.

## The reference model

`sim/ee/r5900_ref.py` executes the integer subset and prints architectural
state, one line per instruction. It models **no timing at all** — one
instruction per step, no pipeline, no cache, no memory latency — because its
job is to say what the state should be after instruction N. A difference is
then a difference in behaviour, not in scheduling.

`sim/ee/test_ref.py` checks the reference against hand-computed expectations,
because a reference nothing has checked is just a second opinion. The cases are
chosen where the R5900 departs from stock MIPS III, or where a plausible
implementation is wrong in a way ordinary code never reveals:

* **A 32-bit result is sign-extended through all 64 bits.** `addu` of
  `0xffffffff` gives `0xffffffffffffffff`, not `0x00000000ffffffff`.
* **`MULT` and `MULTU` write a GPR as well as HI/LO.** On this core
  `mult rd, rs, rt` is three-operand; `rd = 0` is the MIPS-compatible encoding
  and writes nothing. An implementation that only wrote LO would pass every
  test that never used the `rd` form.
* **`DIV` and `DIVU` do not trap**, and division by zero has defined results.
* **`LWU` zero-extends where `LW` sign-extends** — invisible until an address
  goes above `0x7fffffff`.
* **An integer write leaves a GPR's upper 64 bits alone.** GPRs are 128 bits;
  integer instructions define only the low half and MMI reads the rest later.
  Zeroing the upper half is the easy mistake and it stays hidden until MMI.
* Delay slots, `DSLL32`/`DSRL32`/`DSRA32`'s `sa+32`, and writes to `r0`.

Ten cases, all passing. They will grow with the subset.

## How the RTL will be judged

The same shape as `sim/run_sim.sh`: xsim, a testbench that runs a program and
prints state, and a diff against the reference for the same program. The
testbench prints the format `r5900_ref.py` prints, so a mismatch names an
instruction rather than a symptom.

Three properties this has to keep:

1. **The reference must be able to disagree.** If a test can only pass, it is
   not evidence — the lesson from a random sample of a disc image that matched
   300 of 300 because the region was zeros.
2. **Programs come from a generator, not from taste.** Hand-written tests probe
   what the author already thought of. Random instruction sequences over a
   constrained encoding space find the rest, and the reference makes them
   self-checking.
3. **A trap is recorded, not raised.** The RTL has no exception path yet, so
   the reference notes overflow and `SYSCALL`/`BREAK` and carries on. A silent
   divergence would be worse than a loud unimplemented one.

## Where PCSX2 comes in

The study says to verify against PCSX2's interpreter, and that remains the plan
for the cases the manual leaves ambiguous — it is a second implementation, not
an authority, and where the two disagree the manual decides. The reference here
is what makes that comparison cheap: both produce state per instruction, so
disagreements are a diff rather than an investigation.

## The first slice runs — 2026-09-10

`rtl/ee/ee_core.vhd` executes the integer subset and agrees with the reference
on **twenty random programs**, twelve without branches and eight with, about 160
instructions each, covering ALU and shift operations, 64-bit forms, immediates,
loads and stores of every width, multiply and divide, and branches with their
delay slots. `sim/ee/run_diff.sh` generates a program, runs both, and diffs.

Two faults it found, both of which would have been invisible without it:

**Loads and stores never reached the memory state.** The advance logic tested
`state /= S_WAIT_D` — but `state` is a signal, so it still read `S_EXEC` at that
point, the branch was always taken, and the later `state <= S_FETCH` overrode
the `state <= S_WAIT_D` assigned earlier in the same process. Stores appeared to
work, because `d_write` was asserted for the one cycle the instruction spent in
`S_EXEC` and the memory model accepted it; loads silently never wrote their
register. The symptom was a single wrong memory word two hundred instructions
later, which points nowhere near the cause.

**Memory instructions reported the wrong PC.** They retire from `S_WAIT_D`, by
which time the PC has advanced, so a divergence named the instruction after the
one responsible.

And one fault in the harness rather than the core: sampling `retire_pc` on the
clock edge while reading the registers just after it took the two from different
cycles, which looked exactly like a PC off by one instruction while every
register matched. Worth recording because the harness is the instrument, and an
instrument that lies is worse than none.

## What is not started

Hazards and pipelining — the core is still one instruction at a time. MMI, the
FPU, the VUs. And the integer subset itself is not complete: no COP0, no
exceptions, no unaligned loads or stores, no `LQ`/`SQ`.
