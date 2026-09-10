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

## Timing closure: what the clock is actually worth — 2026-09-10

The EE runs at **294.912 MHz**, and a core that will not close there cannot be
cycle-accurate no matter how right its answers are. So the first slice was put
through an out-of-context synthesis, place and route on the real part
(`fit/ee/fmax.tcl`, `xcu55n-fsvh2892-2LV-e`) constrained at that clock, to get a
number instead of an opinion. The first number was **24.2 MHz** — a 41 ns path
against a 3.39 ns budget.

That figure looks fatal and is not, which is worth being precise about, because
"the EE will not fit" is the kind of conclusion that ends a project on bad
evidence. The report named the path: `gpr_reg[22][10]` to `hi_reg[29]`, **200
logic levels, 155 of them CARRY8**. That is a single combinational divider. The
first-draft RTL wrote `DIV` as `signed(a) / signed(b)` and `rem`, and synthesis
did the only thing it can with that — it unrolled a 32-step restoring division
into one enormous ripple chain and put it between two flip-flops. Nothing about
the R5900 requires that; the real chip takes **37 cycles** for `DIV` precisely
because no one builds a combinational one either.

Replacing it with a 32-cycle iterative divider (`S_DIV`, one quotient bit per
clock) moved the core to **126.2 MHz**, a 5.2x improvement from one change, and
dropped LUT use from 10,314 to 6,059. The next path was then the multiplier:
`gpr` through an unregistered DSP48E2 cascade — `PREADD`, `MULTIPLIER`, `ALU`,
`OUTPUT` — and back to a `gpr` in one cycle, 7.9 ns of it. Registering the
operands and the product (`S_MUL`, three cycles against the real R5900's four)
puts flip-flops where the DSP primitive expects them, and took the core to
**185.9 MHz**.

At that point the critical path stopped being arithmetic. The third report names
`instr_reg[21]` — the `rs` field of the instruction — reaching `gpr_reg[24][24]`
through twelve levels, **64% of the delay in routing rather than logic**. That is
decode, the 32-entry register-file read mux, the ALU and the writeback mux, all
in one cycle, and no arithmetic unit can be made multi-cycle to fix it. It is
the shape of the machine.

The divider is also where a piece of luck turned up that is worth writing down.
**Divide by zero needs no special case at all.** A restoring divider with a zero
divisor subtracts nothing on every step, so it sets every quotient bit and
shifts the dividend intact into the remainder: `LO = 0xFFFFFFFF`, `HI = dividend`
— exactly what the manual specifies for `DIVU`. Feed the same unit the operand
magnitudes and apply the signs afterwards, as `DIV` requires anyway for
truncation toward zero, and the sign fixups turn that same result into `LO = -1`
for a non-negative dividend and `LO = 1` for a negative one, which is what the
manual specifies for `DIV`. The behaviour the architecture documents as a
special case is what the hardware does when you build it plainly, which is
presumably why it is documented that way.

### What this says about the clock as a project risk

The honest reading of 24.2 MHz was never "the R5900 does not fit on this part."
It was "an unpipelined core with a combinational divider does not run fast," and
that is a statement about the draft, not the target. The evidence for that is
the fix: one change, no change to what the core computes, 5.2x.

The remaining 1.6x is the interesting part, because of *what* the last path is.
Decode, register read, execute and writeback in one cycle is not a mistake to be
corrected — it is what "not pipelined" means, and the doc has said from the
start that the core is deliberately built that way so it can be checked for
right answers before it is made fast. Splitting that chain into stages is the
next planned piece of work regardless of timing.

And it is not optional work either. **The R5900 is a six-stage, dual-issue
pipeline.** A model that retires one instruction at a time cannot be
cycle-accurate to it no matter what clock it closes at, so the pipelining that
timing wants is the same pipelining accuracy already requires. The two demands
point the same way, which is the most useful thing that could be true here: the
fix for the clock is not a detour from the roadmap, it *is* the roadmap.

Whether a *complete* R5900 — hazards, COP0, exceptions, MMI, FPU, two VUs —
closes at 294.912 MHz on an UltraScale+ -2LV part remains to be shown, but it is
demanding rather than exotic: the HBM AXI on this same card already runs at
450 MHz, and the part is specified well above 300 MHz for pipelined logic.

There is also a fallback that does not require it, and it is worth naming so the
clock never becomes a single point of failure: the EE core does not have to run
in the same clock domain as the rest of the system, and a core that closes at,
say, 200 MHz can still be cycle-accurate to a 294.912 MHz EE if the rest of the
machine is scaled with it — what matters to a game is the *ratio* of EE cycles
to IOP, GS and DMA cycles, not the absolute wall-clock rate, provided video
output is reclocked at the end. That costs real time (a 200 MHz core would run
at 68% speed unless everything is scaled) and it is not the goal, but it means
the project degrades rather than stops.

So: **not a project-halting risk.** It is a constraint that has to be respected
in every piece of RTL from here on — no wide combinational arithmetic, ever, and
nothing that crosses decode, execute and writeback in one cycle — and measured
after every datapath change rather than at the end. `fit/ee/fmax.tcl`
is that measurement and is now run alongside `sim/ee/run_diff.sh` after each
change to the datapath.

### Measurements

| Core state | Fmax | LUTs | Critical path |
|---|---|---|---|
| Combinational divide and multiply | 24.2 MHz | 10,314 | `gpr` → `hi`, 200 levels, 155 CARRY8 — the divider |
| 32-cycle iterative divider | 126.2 MHz | 6,059 | `gpr` → `gpr`, unregistered DSP48E2 cascade — the multiplier |
| Pipelined multiplier | 185.9 MHz | 6,043 | `instr` → `gpr`, 12 levels, 64% routing — decode, regfile and writeback in one cycle |

Target is 294.912 MHz. The core is 7.7x faster than the first measurement and
needs 1.6x more.

### Directed tests for the arithmetic units

Random programs generate divides and multiplies but almost never the ones that
decide whether an iterative unit is right, so two directed generators enumerate
them instead: `sim/ee/gen_div.py` (24 cases — divide by zero with each sign of
dividend, `INT_MIN / -1`, all four sign combinations, divisor larger than
dividend) and `sim/ee/gen_mul.py` (14 cases — `INT_MIN` squared, the values
whose signed and unsigned products differ in the high word, and the `rd = 0`
encoding). `sim/ee/run_diff.sh --prog FILE` runs a pre-made program through the
same reference diff.

Both units were checked against the *reference's* semantics and the reference
against the manual, since agreeing with a wrong model proves nothing: `DIV` of
`0x80000000` by `-1` gives `LO = 0xFFFFFFFF80000000`, `HI = 0`, and the model
computes the quotient as `abs(x) // abs(y)` with the sign applied and the
remainder as `x - q*y`, which is truncation toward zero with the remainder
taking the dividend's sign — what the manual requires.

## What is not started

Hazards and pipelining — the core is still one instruction at a time. MMI, the
FPU, the VUs. And the integer subset itself is not complete: no COP0, no
exceptions, no unaligned loads or stores, no `LQ`/`SQ`.

Timing is not closed either: 185.9 MHz against a 294.912 MHz target. The
measured critical path is now decode-to-writeback rather than any arithmetic
unit, so that gap closes with pipelining — which the R5900's six-stage
dual-issue design requires for accuracy anyway. The section above says why this
is a constraint rather than a wall.
