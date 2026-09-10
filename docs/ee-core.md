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
| Five-stage pipeline, one EX | 212.0 MHz | 6,859 | `w_rd` → forwarding mux → 64-bit branch compare → `fetch_pc` adder |
| Execution split into A1/A2 | 242.8 MHz | 7,081 | `m_rd` → forwarding mux → 64-bit ALU → result register |
| Fetch unit with 3 requests in flight | 251.9 MHz | 6,424 | `w_we` → forwarding mux → 64-bit ALU → result register |
| Unaligned loads and stores added | 252.1 MHz | — | unchanged |
| Exceptions added | **228.2 MHz** | — | `w_rd` → forwarding mux → ALU → result register (unchanged in shape) |

The unaligned group cost nothing in clock, which was not obvious in advance: it
adds a shifter and a merge to the memory path. It stays off the critical path
because that path is the ALU in A1, and the merge happens in A2 where there is
slack.

**Correction: the 10% was not exceptions.** An ablation says so, and it also
says the earlier attribution was built on a comparison that did not hold.

| build | Fmax |
|---|---|
| reported after unaligned loads and stores | 252.1 MHz |
| the same RTL plus MMI pipeline-1 and COP0, re-measured | 233.2 MHz |
| …plus exceptions (current) | 228.2 MHz |
| current with only the exception redirect removed | 250.9 MHz |
| **the redirect registered instead of removed** | **255.3 MHz** |

The 252.1 figure was measured **before MMI and COP0 were added**, and neither of
those was re-measured, so "252.1 → 228.2" spanned three changes rather than one.
Most of the loss is not the exception path at all.

The controlled comparison was the removal row — the same RTL with one thing
taken out — and it said the exception **redirect** cost about 9%. It computed the
vector or `EPC` and drove the fetch PC in the same cycle it committed, in front
of the branch redirect that was already there.

**Registering it recovers all of that and more: 255.3 MHz**, which is above every
earlier measurement including the ones taken before exceptions existed. The
pipeline is still invalidated on the cycle the exception commits, so nothing
younger can retire and precision is untouched; only the fetch redirect waits a
cycle, which is free because exceptions are rare and the pipeline behind one is
empty anyway. It is what the branch redirect already does, for the same reason.

The removal row also undercuts the second: a design with *more* logic in it
(250.9) measures faster than one with less (233.2). Both cannot be a property of
the RTL, so placement variance here is worth about ±8%, which is wider than the
±5% estimated earlier and wide enough that no single-fit comparison of two
different designs should be trusted. Ablations of one change against one base
are the only comparisons that mean anything.

**The first hypothesis was wrong, and is recorded because it was tested.** The first
guess was the overflow check: it was written as a 33-bit add with the carry and
sign bits compared, which puts a wider adder *in series* on the path that was
already critical. Rewriting it to read overflow off the sign bits — two operands
of the same sign giving a sum of the other sign — puts that test beside the
32-bit adder instead of after a wider one, and moved the number from 227.7 to
228.2 MHz. That is nothing. The hypothesis was wrong.

The rewrite is kept because it is the better formulation regardless, but the
10% remains unexplained: the critical path is unchanged in *shape* (`w_rd` →
forwarding mux → ALU → result register) and only slightly longer in levels, so
the cost is more likely spread through congestion than sitting in one place.
Given that placement variance on this design has already measured at ±5% in both
directions, part of the gap may not be real at all. It is recorded rather than
explained, and worth a proper look before the next datapath change rather than
an assumption now.

Target is 294.912 MHz. The core is 10.4x faster than the first measurement and
needs 1.17x more.

**A note on how much these numbers can be trusted.** The core occupies 0.8% of
this device, and a module that small placed loose on a die this large can spread
out and pay routing delay it would never pay inside a real design — half the
critical path was routing, which is exactly that symptom. Confining it to two
clock regions with a pblock (`fit/ee/fmax_pblock.tcl`) was worth +6.7% on the
single-EX core (212.0 → 226.3 MHz) and **−4.2% on the A1/A2 core** (242.8 →
232.5 MHz), with no RTL change either time. So the floorplan does not reliably
help, and the first result should not have been read as "the unconstrained
number understates by 7%" — one measurement in one direction is not a trend.
What the pair actually establishes is that placement variance here is worth
roughly ±5%, which is the resolution of every figure in this table. A change
smaller than that has not been shown to do anything.

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

### Execution split into A1 and A2 — 2026-09-10

`forwarding mux → 64-bit branch compare → do_flush → fetch PC adder` is three
structures in series, and the section below records two attempts to shorten it
that changed nothing. A chain like that is not shortened, it is cut. So
execution is now two stages, as it is on the real R5900, whose integer pipeline
is Q, R, **A1, A2**, S:

- **A1** decides: forwarding, the ALU, the branch condition, the branch target,
  the effective address, and the multi-cycle multiply and divide.
- **A2** acts: the data port, and the branch redirect.

That took the core from 212.0 to **242.8 MHz**, and the new critical path is
`m_rd → forwarding mux → 64-bit ALU → result register`, which is the honest
fundamental path of a single-cycle ALU with forwarding rather than an accident
of where a computation was written.

**It cost nothing in cycles.** Resolving the branch a stage later means one more
instruction is killed on a taken branch, so the split ought to cost a cycle per
taken branch — and measured, it does not: 430 cycles for 160 instructions on a
branch-heavy program before and after, 393 on an ordinary one, and 603 for 200
instructions on a synthetic program that is nothing but taken branches and has
no memory operations at all. Identical in all three.

The reason is worth knowing, because it says where the next IPC work is. The
redirect cannot issue a fetch on the cycle it fires if a request is already in
flight — and with one outstanding request the fetch unit is nearly always busy —
so the new request goes out on the following edge either way. **The fetch unit,
not the branch redirect, is what limits IPC**, and at CPI 2.4 to 3.0 it limits it
by a lot. More outstanding requests and a deeper queue is a separate piece of
work from anything to do with the clock, and the testbench now prints cycles and
CPI on every run so that work can be measured rather than assumed. Fmax alone is
the wrong figure of merit for a pipeline: a change that buys its clock back by
inserting stalls is not an improvement, and only the pair of numbers shows it.

#### The bug: a delay slot can be in three places

Moving the redirect a stage later broke every branch-heavy seed, and the failure
was that an instruction executed **twice**:

```
ref:  47 pc=0bc   48 pc=0c0   49 pc=0c4
rtl:  47 pc=0bc   48 pc=0c0   49 pc=0c0   <- executed again
```

When the branch reaches A2, its delay slot can be in one of three places, and
the first version told apart only two. It handled "already in A1" (flush, and
kill what ID is holding) and "still in the fetch path" (defer the redirect until
it arrives). It missed the third: **entering A1 on that very edge**. Treating
that as "still in the fetch path" meant the deferred redirect fired on the next
instruction to enter A1 — the one *after* the delay slot — so the redirect was
applied an instruction too late.

That is normally invisible, because the extra wrong-path instruction it lets
through is thrown away anyway. It becomes visible when the branch target happens
to be the next sequential address after the delay slot, which a short forward
branch makes true: the late redirect then re-fetches an instruction already in
the pipeline and runs it a second time. `gen_hazard.py` now emits that shape
deliberately — taken branches at offsets 1 and 2, with and without a forwarded
condition, plus a `JAL` to the address right after its own delay slot — and the
suite was checked against the two-way version first: it fails there and passes
on the fix.

### What the first attempts at this needed, and what they did not

Two changes were made to the pipelined core chasing the critical path before the
split, and both are worth recording because **neither worked**: moving the
branch target and link address out of EX into ID, where they belong
(213.1 MHz), and narrowing the program counter from 64 bits to the 32 the
address bus actually has (212.0 MHz). Both are real improvements to the RTL —
the 64-bit PC was doubling every PC adder in the design for nothing — and
neither moved the clock by more than the ±5% the measurement can resolve. They
are kept because they are right, not because they helped.

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
which means splitting EX into two stages — which is what the section above
does, and it is the change that finally moved the number.

That is also what the hardware being modelled does. The R5900's pipeline is
Q, R, **A1, A2**, S — *two* execute stages, not one. A core with a single EX
stage was never going to be cycle-accurate to it, so the split was required for
accuracy on exactly the same schedule that timing wanted it, which is the second
time in this project that those two demands have pointed the same way.

### The fetch unit — 2026-09-10

The A1/A2 split ended with the observation that the fetch unit, not the branch
redirect, was what limited IPC. Profiling said how much: the core now counts
why no instruction entered A1 on each cycle (`dbg_stall`, printed by the
testbench as a breakdown), and on a program with **no memory operations in it at
all**, fetch starvation was 322 of 483 cycles — 67%.

The cause was a design error, not a tuning problem. The unit allowed **one**
outstanding request, on the stated reasoning that a two-entry queue would absorb
replies and keep the rate up. That reasoning was wrong. A reply is observed two
edges after its request is issued, and with one request in flight the next
cannot go out until the previous comes back — so the unit issues on every
*other* edge, and the core is pinned at CPI 2 no matter what the pipeline does.
Sustaining one instruction per cycle needs as many requests in flight as there
are cycles of latency to cover. That is Little's law, and no amount of buffering
substitutes for it: a queue smooths bursts, it does not create throughput.

Three requests in flight and a four-entry queue:

| program | CPI before | CPI after | fetch cycles before | after |
|---|---|---|---|---|
| ordinary | 2.45 | **1.78** | 114 | 3 |
| branch-heavy | 2.68 | **2.15** | 93 | 5 |
| taken branches only, no memory | 3.01 | **2.51** | 322 | 162 |

It also cost nothing in area or clock — 251.9 MHz against 242.8, and slightly
fewer LUTs, because the per-request PC no longer has to be carried alongside the
request. Replies come back in order, so `resp_pc` — the PC of the next reply
that will be kept — advances by four each time one is kept and is reloaded with
the target on a redirect, since the first reply kept after a redirect is by
definition the first request issued after it.

What remains in each bucket says where the next work is, and it is no longer
fetch: **72 to 108 cycles of multiply/divide** (a divide is 34 cycles, against
37 on the real R5900 — inherent), and **45 to 66 cycles of data port**, which is
one stall per memory access because the request is issued at the A1→A2 edge and
answered a cycle later. The branch-only program is the exception and still ends
up fetch-bound, because every taken branch flushes the queue and pays the full
refill: that is the cost of having no branch predictor, which the R5900 has and
this core does not.

### A third instrument, and a false failure it produced

Fixing fetch made four seeds fail, with every register matching for all 160
traced instructions and only the memory image differing — which reads exactly
like a store to a wrong address. It was neither.

A store commits to memory in A2, one stage *before* it retires in WB. So at the
moment the last traced instruction retires, the instruction after it is sitting
in A2 with its store already performed. The reference, which stops cleanly, has
not performed it. Instruction 160 of seed 1 is `SB r21, 0x23d8(r0)` and 0x23d8
is precisely the address that differed.

This was latent all along and only surfaced when fetch was fixed: with a starved
front end the pipeline behind the retiring instruction was usually empty, and
with a full one it never is. The harness now raises `--steps` to cover the whole
generated program, so nothing but NOP padding is ever in flight past the trace
window.

The pattern is worth naming, because this is the third time in this file: **an
instrument that was wrong in a way that made the core look right, or wrong, for
reasons that had nothing to do with the core.** The instruction port that could
not fetch two cycles running, the reference that halted on NOP, and now a trace
window narrower than the pipeline is deep. Each was found only because something
else changed and made it visible.

### The delay slot and the redirect

The branch condition and target are decided in A1 and acted on in A2, so by the
time the redirect fires the delay slot has moved on from the fetch queue and the
question "where is it?" has three answers, all of which occur:

1. **Already in A1** — the normal case. It entered A1 on the edge the branch
   left. Flush the queue and kill what ID is holding, since that is wrong-path.
2. **Entering A1 on this very edge** — flush behind it, but let it through.
   Treating this as case 3 is what caused the duplicate-execution bug above.
3. **Still in the fetch path** — the queue ran dry and the reply is in flight.
   Flushing now would discard the delay slot itself, so the redirect is held in
   `redir_pend` and applied on the edge it finally enters A1.

The `ilat=9` column of the matrix exists to make the queue run dry often enough
that case 3 is taken constantly rather than occasionally. Case 2 needs no such
help — it is the common case at `ilat=1`, which is why every branch-heavy seed
failed at once when it was missing.

## A second opinion on the reference — 2026-09-10

The reference the RTL is diffed against had been checked two ways: written from
the EE Core User's Manual, and hand-computed at the corners. Neither is a second
implementation, and **a reference that is wrong in the same way as the RTL it
checks produces a green harness and a broken core**. That gap was worth closing.

`birdybro/PS2_fpga` is a second R5900 model, MIT-licensed, written independently
from the same manual, and in Python — so the two can be stepped side by side on
the same instruction rather than compared as prose.
`tools/ee/xcheck_r5900.py` does that: it loads their model from a checkout at
run time, generates instructions from the set both implement, and diffs the
architectural state after each one. **160,000 instructions across eight seeds,
with no disagreements.**

Three things had to be understood to make the comparison mean anything:

- **Their model rejects instructions whose architecturally-unused encoding
  fields are non-zero**, where hardware ignores them — MIPS calls those cases
  UNPREDICTABLE and real silicon does not look. That is a defensible choice for
  a verification model and not a disagreement about behaviour, but a generator
  filling every field at random had three quarters of its output refused.
  Emitting canonical encodings is what made the comparison cover the
  instruction set rather than the encoding space.
- Their module does not import on Python 3.12 as checked out — a forward
  reference in a method annotation without `from __future__ import annotations`.
  The tool inserts that line into a copy in memory rather than editing their
  tree.
- Nothing is copied. The tool needs a checkout to say anything, which is the
  right dependency for something whose job is to disagree with us.

### MMI pipeline-1

The comparison also named a real gap. The R5900 has a **second HI/LO pair**,
written by `MULT1`, `MULTU1`, `DIV1`, `DIVU1`, `MFHI1`, `MFLO1`, `MTHI1` and
`MTLO1`. These are not SIMD: they are the ordinary multiply and divide aimed at
that pair, so a compiler can keep two multiply chains in flight without
spilling, and their function codes mirror the SPECIAL ones exactly.

Both the model and the core now decode them through the *same* arms as the
SPECIAL forms with a flag saying which pair they touch, rather than duplicating
the arms — duplicated arms are how the second pair would quietly drift from the
first. The trace carries `hi1` and `lo1`, the random generator emits the MMI
forms interleaved with the ordinary ones, and 192 differential runs pass.

The bug this introduced is worth recording because it is specific to a variable
in a clocked process: the flag was computed *after* the forwarding block that
decides which pair `MFHI` and `MFLO` read. A VHDL process variable keeps its
value between invocations, so the read did not merely default — it used the
*previous instruction's* flag. `MFLO1` returned `LO`. The decode now happens
before the operands, and the flag is assigned unconditionally rather than reset
with the other defaults further down.

## COP0, the register file — 2026-09-10

`MFC0` and `MTC0`, and the 32 registers behind them. That is the whole slice:
the exception path, the TLB and the `CO` forms — `TLBR`, `TLBWI`, `ERET` — are
not here, and are counted as traps rather than guessed at.

Two decisions worth recording.

**`Count` does not run.** On hardware it is a free-running cycle counter, and
that is exactly why it is absent: the reference models no timing, so a counter
that advanced would make every trace disagree with the RTL for a reason that has
nothing to do with either being wrong. It belongs with the exception path, which
is where a cycle count starts to mean something.

**`PRId` is read-only** and reads `0x00002E20`, which is how the BIOS tells an EE
from an IOP. A write to it must not take, and the directed test checks that
rather than assuming it.

COP0 state is only observable through a GPR, so every test is `MTC0` followed by
`MFC0` — which makes the *distance* between them the thing that matters, exactly
as it does for HI and LO. At distance 1 the value comes from A2, at 2 from WB,
and at 3 or more from the register file, so `sim/ee/gen_cop0.py` writes and reads
back every register at each distance. A COP0 file without forwarding passes any
test that spaces the pair apart, which is why the random generator emits the two
independently and lets the distance fall where it may.

200 differential runs pass.

## Exceptions — 2026-09-10

`SYSCALL`, `BREAK`, and `ADD`/`ADDI` overflow now raise for real, with `EPC`,
`Cause` and `Status.EXL` set as the manual specifies and `ERET` returning. The
TLB and its `CO` instructions are still counted as traps rather than guessed at.

**WB is where an exception commits, and that makes it precise by construction.**
WB is the in-order commit point: everything older has already written, the
faulting instruction writes nothing, and everything younger is still sitting in
a latch. So the flush is nothing more than invalidating those latches — there is
no state to undo, because nothing younger has committed.

`EPC` names the *branch* rather than the delay slot when the fault happened in
one, because resuming at the slot alone would skip the branch and take the wrong
path, and `Cause.BD` says which it was. An exception raised while `EXL` is
already set does not overwrite `EPC`: the first one is the one worth keeping.

The harness needed one convention to make any of this testable. The vector is at
`0x80000180`, so the instruction address space is **aliased to the 64 KB test
image** — the reference masks the fetch and the testbench masks `i_addr`
identically. Without it, an exception test would need a megabyte of
mostly-empty image and the handler could never be reached at all.

### Two bugs, one of which only a slow memory could find

**Instructions younger than the exception still retired.** Clearing `m_valid`
stops the *next* instruction from entering WB, but the one already moving from
A2 into WB on that same edge had been transferred earlier in the process and
retired behind the exception. Precise means nothing younger commits, so
`w_valid` has to be cancelled too.

**`Cause.BD` was lost whenever the fetch queue ran dry.** The flag was derived
from "is the instruction currently in A1 a branch", which is only true when the
branch and its delay slot are adjacent. Let the queue run dry and a bubble sits
between them: the derivation says no, `EPC` names the delay slot instead of the
branch, and an exception in a delay slot then resumes *past* the branch and
takes the wrong path. It passes at `ilat=1` and fails at `ilat=3`, which is
exactly what the latency matrix exists to catch — 207 of 208 runs passed, and
the one that did not was this. The flag is now set when a branch leaves A1 and
held until its delay slot actually arrives.

### A note on the reference's own test tooling

Adding the address mask broke `tools/ee/xcheck_r5900.py` in a way worth
recording, because the symptom pointed nowhere near the cause: after exactly
16,384 instructions the two models disagreed about a register that the
instruction in question does not write. The tool writes each generated
instruction at an increasing PC, and at 16,384 steps that PC reaches `0x10000`,
which the new mask folds back to `0x0000` — so the fetch returned the *first*
instruction of the run rather than the one just written. A model comparison is
only as good as the agreement about what was executed.

208 differential runs pass, and the cross-check is clean again.

## What is not started

Hazards and pipelining — the core is still one instruction at a time. MMI, the
FPU, the VUs. And the integer subset itself is not complete: no
no TLB, no `LQ`/`SQ`, and none of MMI's SIMD
instructions — only the
pipeline-1 forms that share the SPECIAL encodings. The unaligned group — `LWL`, `LWR`, `SWL`, `SWR`,
`LDL`, `LDR`, `SDL`, `SDR` — is done.

Timing is not closed: 242.8 MHz against a 294.912 MHz target, a factor of 1.21.
The critical path is now `forwarding mux → 64-bit ALU → result register`, which
is the fundamental path of a single-cycle ALU and closes by splitting the ALU
itself across A1 and A2 rather than by moving anything else around.

IPC is better but not closed: CPI 1.78 on ordinary code, 2.15 on branch-heavy.
What is left is multiply/divide latency (inherent), one stall per memory access,
and the absence of a branch predictor — the R5900 has a BTAC and this core does
not, so every taken branch pays a full fetch refill.
