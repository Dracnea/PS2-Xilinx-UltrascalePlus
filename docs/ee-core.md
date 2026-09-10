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
| Five-stage pipeline | 212.0 MHz | 6,859 | `w_rd` → forwarding mux → 64-bit branch compare → `fetch_pc` adder |
| …the same, floorplanned | **226.3 MHz** | 6,859 | as above |

Target is 294.912 MHz. The core is 9.4x faster than the first measurement and
needs 1.3x more.

**The unconstrained number understates the core by about 7%.** Half the critical
path was routing, which is the signature of a small module placed loose on a
very large die: at 0.8% utilisation the placer has no reason to keep anything
together, and the core pays wire delay it would never pay inside a real design.
Confining it to two clock regions with a pblock (`fit/ee/fmax_pblock.tcl`) moved
it from 212.0 to 226.3 MHz with no RTL change at all. Both numbers are kept
above because the unconstrained one is the comparable series, but 226.3 MHz is
the honest figure for the core as it stands, and future measurements should
carry the floorplan.

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

## The pipeline — 2026-09-10

The core is now five stages, single issue, in order: IF with a two-entry fetch
queue, ID for decode and register read, EX for the ALU and the multi-cycle
multiply and divide, MEM for the data port, and WB where every piece of
architectural state is written. It agrees with the reference across **184 runs
— eight memory-latency configurations by twenty-three programs each**, with no
change to the reference's answers, only to how many cycles the RTL takes to
produce them.

### Two rules about where state is written

Both exist so the differential trace stays meaningful rather than for any
architectural reason.

**Nothing commits before WB.** HI and LO are computed in EX but carried down the
pipeline and written in WB alongside the register file. Writing them in EX would
be simpler and is architecturally harmless — the pipeline is in order, so no
later reader could see them early — but the testbench samples all architectural
state at each retire, and an EX write would make one instruction's HI visible
while an *older* instruction was still retiring. The trace would diverge from
the reference for a reason that has nothing to do with the answer being wrong.

**Every read is forwarded.** ID bypasses the instruction sitting in WB as it
reads the register file, because that instruction writes on the very edge ID's
read would otherwise miss. EX forwards from MEM and from WB, MEM last so the
younger writer wins. Between the three, every dependence distance is covered
except one: a load whose value is still in flight, which is what the load-use
interlock stalls a cycle for.

### The bug that took the longest to find

A pipelined core has a failure mode the unpipelined one could not have, and this
one cost the most to track down, so it is worth recording in full.

`ORI r30, r18, 0x80ed` read the *pre-load* value of `r18` two instructions after
an `LB` wrote it — while `r18` itself ended up perfectly correct in the register
file. Forwarding was not missing; it was **discarded**.

The instructions around the dependence were themselves memory operations, so MEM
was the bottleneck and the `ORI` sat in EX for two cycles:

```
EX ir=365E80ED rs=18 || MEM ismem=1 || WB v=1 we=1 rd=18 val=0   <- LB in WB, forwarding works
EX ir=365E80ED rs=18 || MEM ismem=1 || WB v=0 ...                <- LB retired; EX advances now
```

Forwarding is recomputed every cycle, but only the value present on the cycle EX
*finally advances* is the one latched into EX/MEM. The `LB` retired during the
wait, left WB, and the correct operand went with it. The register file was no
help either: ID read it cycles earlier and EX never reads it at all.

The fix is to write the forwarded operands back into the ID/EX latch on every
cycle EX is stalled, so a forwarded value survives a stall of any length. It is
safe in general because only *older* instructions can ever occupy MEM and WB, so
a capture can only move an operand forward in time, never backwards.

What makes this worth writing down is how narrow the window was. The same
dependence with NOPs between the instructions passes. The same program at
`dlat=5` passes — it only fails at `dlat=1`, where the stall lands in exactly
the wrong place. It was found because the harness runs every program at several
memory latencies and requires all of them to produce identical architectural
state, which is a much sharper instrument than any single configuration.

### Two instruments that had to be fixed before they could find anything

**The instruction memory could only answer every other cycle.** The old model
gated on `i_read && !i_ready`, so the core could never fetch two cycles running.
That looks like a harmless detail of a testbench and is not: with a bubble
between every pair of instructions, **dependent instructions are never adjacent
in the pipeline, and not one forwarding path is ever exercised**. A testbench
that cannot produce the hazard cannot find the bug. The port is now pipelined
with configurable latency (`+ilat`, `+dlat`), and the matrix runs every program
at eight combinations.

**The reference halted on NOP.** Its loop said `if not mem.load(cpu.pc, 4):
break`, meaning a zero instruction word ended the program — but `0x00000000` is
`SLL r0, r0, 0`, a perfectly ordinary NOP, and spacing dependent instructions
apart with NOPs is exactly how a directed hazard test is written. The first such
test stopped at its first gap and the diff counted the handful of instructions
before it as a pass. The halt condition is now the PC leaving the loaded
program, which is the thing that was actually meant. The random programs never
contained a zero word in their body, which is why this survived twenty seeds.

### Directed hazard tests

`sim/ee/gen_hazard.py` emits 152 instructions of deliberate hazards, because a
random program produces a dependence between adjacent instructions only by
accident — with 32 registers the odds are about one in sixteen per pair — and
essentially never produces the specific shapes that break a pipeline. Every
pattern is emitted at distances 1, 2 and 3, since in this pipeline distance 1 is
served from MEM, distance 2 from WB and distance 3 by the ID read bypass; a
suite testing only distance 1 would leave two thirds of the forwarding logic
unexercised. It covers:

- ALU results forwarded at each distance, and the same across a congested MEM
  stage, which is the shape described above
- load-use at each distance, a load feeding the base register of the next load,
  and a load feeding a store's data operand
- narrow loads, where the sign extension is inside the forwarded value
- HI/LO forwarded at each distance, two multiplies back to back so the younger
  writer must win, and MTHI/MTLO as ordinary HI/LO writers
- a write to `r0`, which must **not** be forwarded — a network that matches on
  the register number without excluding `r0` turns the next read of `r0` into
  the discarded result, and nothing in a random program would show it
- branches whose condition was computed one instruction earlier, and a delay
  slot that reads the register its own `JAL` just wrote
- loads and multiplies sitting in delay slots

The suite was checked against the unfixed core before being trusted: it fails
there and passes on the fix. A test that does not catch the bug it was written
for is worth nothing.

### What the remaining 1.3x needs, and what it does not

Three changes were made to the pipelined core chasing the critical path, and
they are worth recording because two of them **did not work**: moving the branch
target and link address out of EX into ID, where they belong (213.1 MHz), and
narrowing the program counter from 64 bits to the 32 the address bus actually
has (212.0 MHz). Both are real improvements to the RTL — the 64-bit PC was
doubling every PC adder in the design for nothing — and neither moved the clock
by more than placement noise.

The reason is visible in the full path, which took reading cell by cell rather
than trusting the summary line:

```
w_rd -> forwarding compare and mux -> 64-bit branch comparison (CARRY8)
     -> do_flush -> fetch_pc adder (CARRY8) -> fetch_pc
```

Three structures in series, and removing any one of them leaves the other two.
The forwarding mux cannot move — it is what makes the pipeline correct. The
branch comparison cannot move earlier, because it needs the forwarded operand.
So the answer is not to shorten the chain but to **cut it with a register**,
which means splitting EX into two stages.

That is also what the hardware being modelled does. The R5900's pipeline is
Q, R, **A1, A2**, S — *two* execute stages, not one. A core with a single EX
stage was never going to be cycle-accurate to it, so the split is required for
accuracy on exactly the same schedule that timing wants it, which is the second
time in this project that those two demands have pointed the same way.

### The delay slot and the redirect

Branches resolve in EX. By then the delay slot is the queue head, so the common
case is simple: the delay slot moves into EX on the same edge the branch leaves
it, and everything behind it is flushed.

The case that needs care is when the delay slot has *not* arrived — the fetch
queue is empty because the reply is still in flight. Flushing then would discard
the delay slot itself, which must execute. So the redirect is held in
`redir_pend` and applied on the edge the delay slot finally enters EX. The
`ilat=9` column of the matrix exists to make the queue run dry often enough that
this path is taken constantly rather than occasionally.

## What is not started

Hazards and pipelining — the core is still one instruction at a time. MMI, the
FPU, the VUs. And the integer subset itself is not complete: no COP0, no
exceptions, no unaligned loads or stores, no `LQ`/`SQ`.

Timing is not closed either: 185.9 MHz against a 294.912 MHz target. The
measured critical path is now decode-to-writeback rather than any arithmetic
unit, so that gap closes with pipelining — which the R5900's six-stage
dual-issue design requires for accuracy anyway. The section above says why this
is a constraint rather than a wall.
