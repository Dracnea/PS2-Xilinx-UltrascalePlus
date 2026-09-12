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
| MMI SIMD, and the datapath widened to 128 bits | 234.5 MHz |
| **forward selects precomputed a cycle early** | **283.5 MHz** |

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

## MMI SIMD, and the upper 64 bits — 2026-09-10

`PAND`, `PXOR`, `PCPYLD` (MMI2) and `POR`, `PNOR`, `PCPYUD` (MMI3) — **the first
instructions in this core to write the upper half of a register.** The register
file has been 128 bits wide since the first commit, on the stated reasoning that
widening it afterwards would touch every path that carries a register. That
reasoning holds up: the widening that just happened touched the operand latches,
the forwarding network, the writeback and the trace, and none of it touched the
register file.

The sub-opcode for these lives in `sa` rather than `fn`, which is why they
cannot share the decode that maps MMI's HI/LO forms onto the SPECIAL arms.

Two decisions worth recording. **The ALU's result stays 64 bits** and MMI
supplies the upper half separately, rather than widening every assignment in a
decode that is almost entirely 64-bit. And **the writeback distinguishes the two
widths**: an MMI result writes all 128 bits, everything else leaves the upper
half alone, which is what "integer instructions do not define the upper half"
means in practice. The forwarding paths carry the same distinction, or an MMI
result forwarded at any distance would lose its top half to a 64-bit writer that
never touched it.

The trace now prints all 128 bits. It had to: a trace showing only the low 64
would call two different machine states identical, which is precisely the bug
this instruction group could introduce.

**It cost 8% of the clock — 255.3 down to 234.5 MHz.** The obvious explanation
was that the forwarding mux had doubled in width on the path that was already
critical, and the obvious mitigation followed: only MMI consumes the upper half,
so the upper 64 bits do not need the lower half's single-cycle forwarding
network. That reasoning was recorded here as the next thing to do.

**It was wrong, and the timing report said so.** See below.

208 differential runs pass, and the cross-check against birdybro/PS2_fpga is
clean.

### The forward select, decided a cycle early — 283.5 MHz

Before implementing the mitigation above, the critical path was read rather than
assumed — the second time in this file that a plausible hypothesis about timing
has not survived contact with the report, and the second time that reading it
first would have saved the work:

```
Slack (VIOLATED): -0.875ns
  Source:       m_rd_reg[2]/C
  Destination:  m_val_reg[51]/D
  Data Path Delay: 4.260ns  (logic 1.449ns 34%   route 2.811ns 66%)
  Logic Levels: 11
```

The destination is `m_val[51]` — in the **lower** half. The upper half is not on
the critical path at all, so the recorded mitigation would have bought nothing.
What the widening actually cost is *routing*: two thirds of the delay is wire,
on nets with fan-outs of 102 and 79. Those are the forward-select comparators,
and doubling the datapath doubled how far their outputs have to travel.

The path begins at `m_rd` — the A1/A2 latch's destination register number — and
runs through a comparator against `d_rs`/`d_rt` before it even reaches the mux
that the ALU is waiting on. **Both operands of that comparison are register
outputs.** "Does the instruction in A2 write the register A1 is about to read"
therefore does not have to be asked in A1: it can be answered at the end of the
previous cycle, once the stage advances are decided, and handed over already
resolved.

That is what `fa_m`, `fb_m`, `fa_w` and `fb_w` are. Each folds in valid,
write-enable and `rd /= 0`, so A1's forwarding is four `if`s on a registered bit
instead of two nested comparisons. The comparator and its fan-out leave the
critical path entirely.

Keeping it correct is a bookkeeping problem, because the selects must compare
what the latches will hold *next* cycle, and the latch fields are written from
half a dozen places — the normal advance, the bubble, the exception flush, the
redirect. Each of those now mirrors its assignment onto a shadow variable, in
program order. Signals and variables both take last-write-wins in program order,
so the shadow ends the process holding exactly what the signal will hold, and
the selects are computed from the shadows as the last thing the process does.

| build | Fmax |
| --- | --- |
| MMI SIMD, datapath widened to 128 bits | 234.5 MHz |
| **forward selects precomputed** | **283.5 MHz** |

**+21%, and above the 255.3 MHz the core managed before it was ever widened.**
The 128-bit datapath is now free. 72 differential runs pass across the latency
matrix and every directed suite.

The lesson is the same one the divider and the exception redirect both taught,
and it is worth stating plainly because I have now got it wrong twice: *read the
timing report before forming a hypothesis about timing.* Both wrong guesses were
plausible, both concerned the right general area, and both would have cost a day
of work for nothing.

### A store an exception could not take back

A wider random campaign — 160 runs on seeds the standing matrix does not cover —
found the one piece of state an exception was not undoing.

Registers and HI/LO are still sitting in latches when an exception commits, so
invalidating those latches is the whole of the flush for them. **A store is not
in a latch.** By the time the faulting instruction reaches WB, the store behind
it has already handed its request to the memory port, and the write happens
whether or not the instruction is ever allowed to retire.

In seed 346 an `ADD` overflowed — `0x7d7e0000 + 0x7d7e0000` — and the `SD` one
instruction later should never have run. The reference did not run it; the core
did, and left a word in memory. **No register trace could show it**, because a
store writes no register: all 200 traced instructions matched exactly and only
the memory dump differed, which is why the standing matrix had never caught it
and why the memory dump earns its place in the comparison.

The fix is to stop the request rather than undo it: an instruction sitting in A2
with `m_exc` set is one edge from committing an exception, so nothing younger
issues a port request at all. A load is suppressed too — harmless in itself, but
the alternative is a special case — and the flush clears `m_ismem` on the
following edge, so the suppressed access cannot leave A2 waiting for a `d_ready`
that will never come.

368 runs pass: the standing matrix and the wide campaign together.

## LQ and SQ, and a quadword data port — 2026-09-11

The register file has been 128 bits wide since the first commit, and until now
nothing could move 128 bits to or from memory: `PCPYLD` and `PCPYUD` were the
only way a value ever reached a register's upper half. `LQ` and `SQ` close
that, and they are the reason the data port is now a quadword.

**The port went from 64 bits to 128.** That is the larger half of this change
and it touches every memory instruction, because a narrower access now selects
its bytes out of a quadword rather than a doubleword: the shift is
`ea(3 downto 0)` instead of `ea(2 downto 0)`, `SD` acquired a shift it did not
need before, and the unaligned forms pick their doubleword with address bit 3
and their word with bits 3:2 before doing the same arithmetic they always did.

The width was not chosen for `LQ`'s convenience. `rtl/ee/ee_ram.vhd` — the 32 MB
main memory this core attaches to — already presents 128 bits with sixteen byte
enables, so the 64-bit port was the mismatch, and the R5900's own load/store
unit is quadword-wide.

**What is checked, and what is not.** `sim/ee/gen_quad.py` walks all sixteen
offsets within a quadword for both instructions, with distinct non-zero values
in *both* halves of every register and every quadword in memory. That last
detail is the point rather than thoroughness for its own sake: an `LQ` built to
write only the low 64 bits passes every random seed and fails the third
instruction of the directed program. Both halves are usually zero, so a load
that dropped the upper one wrote the zeroes that were already there.

The rule that the low four bits of the address are *ignored* rather than
faulted is honoured in both models, and the misaligned offsets exercise it —
but the mask in the RTL is **not** what implements it and is not verified.
Every target on this port ignores those bits itself (`ee_ram.vhd` selects its
half with `addr(4)` and never reads bits 3:0), so removing the mask changes no
simulation result. It is there for a stricter target, and the comment in
`ee_core.vhd` says so rather than letting the next reader assume it was
measured.

### Two arms of the random generator had never fired — 2026-09-11

`sim/ee/gen_prog.py` chose its instruction mix with a chain of
`elif pick < k` arms and hand-written constants, and two of them were
unreachable. The COP0 arm was added below an arm testing `pick < 0.92` with a
threshold of `0.90`; the MMI SIMD arm was added later at `0.92` under the same
one. **Both were dead from the moment they were written**, so no random program
has ever contained a COP0 move or an MMI SIMD instruction, and **none of the
368 differential runs recorded above covered either**.

Nothing said so, because a generator that omits a class of instruction produces
a program that runs perfectly and proves less than it claims. This is the same
shape as the three broken instruments recorded elsewhere on this page, and it
is the most expensive shape: the test was green for the wrong reason.

The mix is now a weight table, which cannot shadow an arm, and `--census`
prints what was actually emitted so the claim can be checked rather than
assumed. Making both arms live found no bug — COP0 and MMI SIMD pass in random
programs at the first attempt — which is the good outcome and not the point.
The point is that it was not known.

## MMI's parallel ALU — 2026-09-11

MMI0 (function `0x08`) and MMI1 (`0x28`) are the SIMD arithmetic: the same
handful of operations over 4 × 32, 8 × 16 or 16 × 8 lanes, in wrapping,
signed-saturating and unsigned-saturating forms. Thirty instructions —
`PADDW`/`H`/`B`, `PSUB*`, `PCGT*`, `PCEQ*`, `PMAX*`, `PMIN*`, the `PADDS*` and
`PSUBS*` signed-saturating forms, the `PADDU*` and `PSUBU*` unsigned ones, and
`PABSW`/`PABSH`.

They are written **once** and instantiated at three widths, in both models.
That is not tidiness: a saturation bound that is right for halfwords and wrong
for bytes is precisely the fault that survives a test suite, and here the bound
is built from the lane's own width rather than written out three times. In the
RTL, `par_lane` derives `SMAX` and `SMIN` from `a'length`, and `par128` wraps it
in three static loops with the width chosen by a literal at each decode arm.

**A decode bug this uncovered.** The RTL's MMI arm read `if fn = 0x09 then MMI2
else MMI3`, so functions `0x08` and `0x28` — MMI0 and MMI1 — fell through and
were decoded as `POR`, `PNOR` or `PCPYUD`. Nothing noticed, because nothing
emitted them: the same blind spot that hid MMI2 and MMI3 themselves until the
generator's dead arms were found earlier the same day.

### The random programs are very weak here — measured

`gen_prog.py` now emits MMI0 and MMI1 at about 7 % of instructions. That is
enough to execute them and not nearly enough to check them. Mutating the RTL and
re-running three seeds:

| mutation | random seeds | `gen_mmi.py` |
|---|---|---|
| `PMAX` and `PMIN` swapped | 1 of 3 | caught |
| `PCGT` compares unsigned | 1 of 3 | caught |
| `PSUBU` wraps instead of clamping at zero | **0 of 3** | caught |
| `PABS` does not saturate the most negative value | **0 of 3** | caught |
| `PADDU` does not saturate | 1 of 3 | caught |
| `PADDSB` built at 16-bit lanes instead of 8 | **0 of 3** | caught |
| signed saturation bound off by one | **0 of 3** | caught |

Four of seven are never caught. The reason is plain once stated: a random
register holds a value that happens to compare one way, and **saturation needs
operands that actually overflow their lane**, which random values built from
`addiu` and `lui` rarely do.

`sim/ee/gen_mmi.py` builds its operands from the corners and nothing else —
`0x7F`, `0x80`, `0xFF`, `0x01` as bytes, which read as `0x7F7F`/`0x8080`-shaped
halfwords and `0x7F80FF01`-shaped words, so one pair of registers puts every
width against its own maximum, its own minimum, minus one and one. Saturation
becomes the normal case rather than a rare one. Every defined sub-opcode of both
tables is emitted against every operand pair and in both operand orders, since
subtraction and the compares are not symmetric. All seven mutations are caught.

The encodings are cross-checked against PCSX2's `tbl_MMI0` and `tbl_MMI1`, and
the saturating and absolute-value corners against its `MMI.cpp` — `|0x80000000|`
is `0x7FFFFFFF`, not itself.

### Where the clock went, and how much of that first answer was noise — 2026-09-11

The quadword port measured 283.5 → 253.2 MHz and the first note here attributed
the 30 MHz to the port. **That number was one fit against one fit, and it was
mostly wrong.** Placement on this design is not repeatable enough to support a
comparison that fine: the same netlist under three different `place_design`
directives spans 33 MHz. Every variant below was therefore fitted three times —
`Default`, `Explore` and `ExtraNetDelay_high` — on `xcu55n-fsvh2892-2LV-e`, out
of context, constrained at 3.39 ns.

| variant | Default | Explore | ExtraND | **mean** | spread | LUTs |
|---|---|---|---|---|---|---|
| **base** — before this change, 64-bit port | 283.5 | 278.5 | 274.2 | **278.7** | 9.3 | 10558 |
| **head** — 128-bit port, `LQ`/`SQ`, 128-bit alignment networks | 253.2 | 258.2 | 286.5 | **266.0** | **33.3** | 10619 |
| **narrow** — as head, alignment networks kept 64-bit | 271.7 | 278.4 | 268.1 | **272.7** | 10.3 | 10571 |
| **final** — narrow plus MMI0/MMI1 | 208.6 | 207.9 | 220.3 | **212.3** | 12.4 | 16597 |
| **shared** — final with one shared adder instead of thirty arrays | 177.2 | 173.8 | 177.8 | **176.3** | 4.0 | 12559\* |

\* post-synthesis; the others are post-route.

**The method matters more than any single row.** `head` alone ranges from 253.2
to 286.5 depending only on how the placer was asked to work — and its best run
*beats* `base`'s best. A difference of 20 MHz between two single fits of this
design is not evidence of anything. Differences of means across three
directives are worth something; differences below about 10 MHz still are not.

What the means say:

* **`LQ` and `SQ` are free.** Removing their decode with the port left at 128
  bits gave 250.8 MHz against `head`'s 253.2 under the same directive — no
  better, and well inside the spread.
* **The quadword port costs about 13 MHz**, not 30: 278.7 → 266.0.
* **Keeping the alignment networks narrow recovers about 7 of that**, 266.0 →
  272.7, and costs nothing in area — 10571 LUTs against 10619. Writing the
  store shift as one 128-bit shift by `ea(3 downto 0)` builds a sixteen-position
  barrel shifter twice as wide as the old one, and nothing needs it: every
  access narrower than a quadword is naturally aligned and lies inside one half,
  so the shift stays 64 bits and address bit 3 picks the half afterwards. That
  is what the core does now. The claim in the first version of this note — 18.5
  MHz recovered — was one fit and is withdrawn.
* **The residual cost of the wider port is about 6 MHz** and is `d_wdata`,
  `d_rdata` and their fanout.

**MMI's parallel ALU is the expensive item, by a long way:** 272.7 → 212.3, a
loss of 60 MHz, and +6026 LUTs — 57 % on top of the whole core. That is the real
clock problem on this page now, and it dwarfs everything the memory port did.

### The third shape is the right one — 2026-09-11

Two shapes had been measured for MMI's parallel ALU and neither was good: thirty
specialised lane arrays (212.3 MHz, 16597 LUTs) and one adder whose carry breaks
were chosen at run time (176.3 MHz, 13341 LUTs). The third takes the useful half
of each.

**Break the carry at elaboration, share the adder across operations.** Each lane
width gets its own static loop, so a lane is one ordinary fixed-width addition
and maps to a clean carry chain — there is simply no carry wire between lanes to
multiplex. Within a width, every operation shares that one adder: `neg` selects
add or subtract, and the saturating, comparing and min/max forms are all
selection on its sum, its carry out and three sign bits.

| shape | Fmax (3 directives) | LUTs |
|---|---|---|
| thirty specialised arrays | 208.6 / 207.9 / 220.3 → **212.3** | 16597 |
| one adder, run-time breaks | 177.2 / 173.8 / 177.8 → **176.3** | 13341 |
| **per-width adders, elaboration-time breaks** | 209.5 / 212.1 / 220.6 → **214.1** | **13916** |

Marginally *better* than the thirty arrays on the clock — 214.1 against 212.3,
which is inside the noise and so is fairly read as "the same" — and **2681 LUTs
cheaper**, 16 % of the MMI block. That is most of what the run-time version
saved, without any of its 36 MHz.

The lesson is narrow and worth keeping. *Sharing* was never the problem, and
neither was the multiplexer at the end that picks a width. What a carry chain
cannot tolerate is a multiplexer **inside** it.

### The second shape, and why it failed — measured, 2026-09-11

Thirty decode arms each calling a generic function with literal arguments means
synthesis specialises each call, so the core carried thirty independent lane
arrays. The obvious repair is to share one adder: every arithmetic and
comparison form here is one addition or one subtraction away from its answer, so
a single byte-wise adder with its carry broken at whichever lane boundaries the
width selects should serve all of them, with sign bits and multiplexers doing
the rest.

It was written, it passes all 51 regression runs and all eight mutations aimed
at it — including the two that are specific to its structure, the carry not
broken at lane boundaries and the wrong bytes-per-lane — and **it is 36 MHz
slower**: 176.3 against 212.3, consistently, with the smallest spread of any
variant here. It saves about 4000 LUTs and costs a sixth of the clock.

The reason is visible in what was built. Breaking the carry at a boundary chosen
at *run time* puts a multiplexer between every pair of bytes, which is exactly
what a fast carry chain cannot tolerate; the thirty specialised arrays each got
a clean `CARRY8` chain of a fixed width instead. Area was never the binding
constraint on this project — [hbm.md](hbm.md) and the roadmap both say the
scarce resource is UltraRAM, and the whole core is 1.9 % of the part — so the
trade goes the other way and the thirty-array form is kept.

It is worth recording rather than deleting: a shared datapath is the textbook
answer, it is smaller, and on this fabric it is the wrong one. A version that
picks the carry breaks at *synthesis* time — three specialised adders rather
than one runtime-configurable one — would plausibly get both, and is the shape
to try next.

One more thing that only synthesis found: the shared version simulated
correctly and failed `synth_design` with *array index -1 out of range*. Reading
the previous byte's carry as `cy(i - 1)` is never evaluated at `i = 0`, because
the lane-start branch is taken there, but synthesis elaborates both arms of the
unrolled loop. Carrying it in a variable makes the index impossible rather than
merely unreachable. **`xvhdl` and `xsim` passing is not evidence that a design
synthesises**, and nothing in this project's flow had said so before.

Timing therefore stands at **212.3 MHz** mean against a 294.912 MHz target, a
factor of 1.39 — the worst it has been, and MMI is why.

## The pack, extend and shuffle group, and the SA register — 2026-09-11

The rest of MMI0 and MMI1: `PEXTL`/`PEXTU`/`PPAC` at three widths, `PEXT5`,
`PPAC5`, `PADSBH` and `QFSRV`. These move lanes about rather than computing
anything, so they share nothing with the adder and are wires and multiplexers.

Three families, each one rule at three widths. `PEXTL` interleaves the *low*
half of `rt` and `rs` with `rt` supplying the even lanes; `PEXTU` does the same
from the upper half; `PPAC` keeps every other lane, `rt`'s into the low half and
`rs`'s into the upper. `PPAC` is the truncating partner of `PEXT` — taking every
other lane of a 2W-bit value keeps the low W bits of each of its lanes — which
is why the two are encoded adjacently.

`PEXT5` spreads an RGBA5551 word to a byte per channel, five bits shifted up by
three with zeros below and never replicated. That is the **same expansion the
Graphics Synthesizer applies to a 16-bit frame buffer**, arrived at
independently on the other track the same day, minus the `0x80` that only a
pixel read wants; `PPAC5` is its truncating inverse and keeps exactly the bits
`pack16` keeps. `PADSBH` is the one instruction whose halves differ: the low
four halfwords subtract and the upper four add.

### QFSRV brings architectural state with it

`QFSRV` shifts `{rs, rt}` right by **SA bytes** and keeps the low 128 bits,
which makes it the instruction for realigning a quadword that straddles a
boundary — and is why its shift amount lives in a register rather than in the
instruction word. So the shift-amount register comes with it, and its four
writers: `MTSA` (SPECIAL `0x29`), `MFSA` (SPECIAL `0x28`), and `MTSAB` and
`MTSAH`, which are the two members of REGIMM that neither branch nor link
(`rt` = 24 and 25).

`MTSAB` and `MTSAH` **exclusive-or** their operand with the immediate rather
than replacing it, which lets a byte offset be flipped without a
read-modify-write. That is not a transcription slip, and it is the one detail
here a test can miss silently — see below.

SA is four bits in both models: it names a byte within a quadword and nothing
else, and `MTSAB` and `MTSAH` already mask to that much. `MTSA` takes a whole
register on hardware and this model keeps its low four bits, which is the single
place here that goes beyond PCSX2 — it stores the full 32 bits and would
disagree after an `MTSA` of something larger. The generators never emit one, so
the two are not compared on it. SA is now printed in the differential trace
beside HI and LO, because a register that only `QFSRV` reads and only three
instructions write is otherwise nearly invisible.

### What the directed test had to be taught

Ten mutations were aimed at this group. Eight were caught at the first attempt;
two were not, and both for reasons worth recording.

* **The corner operands are wrong for permutations.** The arithmetic half of
  `gen_mmi.py` uses `0x7F`, `0x80`, `0xFF`, `0x01` repeated sixteen times, which
  is exactly right for saturation and useless for a shuffle: repeating the same
  byte hides any reordering completely. The shuffle half needs every byte
  distinct and now has its own operand pairs. This is the same trap that made
  the Graphics Synthesizer's first directed test prove nothing, in a different
  costume.
* **`MTSAB` with a zero operand cannot tell exclusive-or from addition.** The
  first version of the QFSRV sweep set SA from `r0`, and `0 xor imm` and
  `0 + imm` are the same for every immediate — so a mutation replacing the
  exclusive-or with an addition passed. The sweep now runs from four non-zero
  bases, and `MTSAH` and `MTSA` get their own sweeps rather than being assumed
  to follow `MTSAB`.

All ten are caught now: both operand orders of `PEXTL`, `PEXTU` reading the
wrong half, `PPAC` keeping the wrong lanes, `PEXT5` replicating, `PPAC5` taking
the wrong bits, `PADSBH` adding where it should subtract, `QFSRV` indexing bits
instead of bytes or concatenating its operands the wrong way round, `MTSAH`
forgetting its shift, and `MTSAB` adding instead of exclusive-oring.

### QFSRV's shifter, written twice — 2026-09-11

The whole group first cost **37 MHz**: 214.1 for the core without it against
177 with it, for only 1812 LUTs. That is a critical path, not an area problem,
and it was worth finding out which instruction owned it.

| variant | Fmax (Default) | LUTs |
|---|---|---|
| the group, `QFSRV` as `shift_right` on 256 bits | 174.6 | 15728 |
| the group with `QFSRV` deleted outright | 186.2 | 14291 |
| the group, `QFSRV` as sixteen byte multiplexers | **195.1** | — |

`QFSRV` written as `shift_right(unsigned(rs & rt), 8 * SA)` builds a barrel
shifter sized for its 256-bit operand. Written as sixteen byte-wide selections
out of that same 256-bit value — which is the same function — it builds what the
instruction actually needs: sixteen 16-to-1 multiplexers, one per output byte.

The second form is worth **20 MHz, more than deleting the instruction was**, and
that last part is the surprising bit: the expensive thing was never QFSRV's
presence, it was the shape the shifter was written in. Same lesson the load and
store alignment networks taught earlier in the day, and it did not transfer on
its own: *make the shifter the width of the answer, not the width of the
operand.*

## The core wired to its own main memory — 2026-09-11

`ee_core` and `ee_ram` had never been connected. Each was verified against a
model of the other: `sim/ee/tb_ee_core.sv` gives the core a flat memory with a
settable latency, and `sim/mem/tb_mem.sv` gives the cache a behavioural HBM and
no processor. `rtl/ee/ee_top.vhd` is the seam, and it is not just wiring —
there are three differences to reconcile, and two of them bit.

**Two masters, one port.** `ee_ram` serves one 128-bit access at a time and the
core has two ports. Data wins: a load is holding up an instruction that is
already half executed, while a fetch is speculative and has a queue to wait in.

**Three fetches in flight, answered one at a time.** `i_read` is a single-cycle
pulse and the core allows three outstanding, replies required in order, so the
addresses queue in `ee_top` and are served in turn.

**A held strobe against a pulsed request**, which is where both bugs were. The
core raises `d_read` and holds it until `d_ready`; `ee_ram` latches its request
in `IDLE` on the first cycle `req` is high and therefore wants a pulse. Holding
`req` until `ack` makes `ee_ram` see it still high when it returns to `IDLE` and
run the same access twice. `sim/mem/tb_mem.sv` drives it as a pulse and does not
say why; this is why.

### Two deadlocks, and what they looked like

Neither was subtle once found and both looked like something else first.

The first attempt guarded against re-issuing the core's held strobe by waiting
for it to fall before accepting anything. That **deadlocks**: the core clears
`d_read` from a stage that needs an instruction to advance, so an arbiter which
refuses to fetch until `d_read` falls, when `d_read` cannot fall until a fetch
arrives, stops dead.

The second attempt used a flag cleared when the strobe fell, which survived
sixty instructions and deadlocked at a hundred and ten. On **back-to-back
loads** the core clears `d_read` and raises it again for the next access in the
same clocked process, so the later assignment wins and `d_read` is never
observed low at all. A flag waiting for a falling edge that never comes waits
forever. What works is a one-cycle hold: the core cannot signal a new request
until the cycle after it sees `d_ready`, because `d_read` is registered.

> A third suspicion cost time and was wrong. A directed test of `ee_ram`'s
> half-selection appeared to show it returning the half belonging to the
> *previous* request — a clean off-by-one, in somebody else's module. It was the
> test: it held `req` until `ack` and so issued every access twice. `ee_ram` is
> correct. Checking the harness before believing a result about the module under
> it would have saved the detour.

### What it costs to run on a real memory

`sim/ee/run_top_diff.sh` runs any program the ordinary differential takes, with
the core fetching and loading through the cache and a behavioural HBM. **15 of
15 pass** — the directed generators and eight random programs.

CPI is the number worth carrying forward. The core measures **1.78** against a
flat memory that answers in one cycle, and **9.4 to 10.5** here on a cold cache
with an eight-cycle AXI latency. A hundred-and-fifty-instruction program takes
about 1500 cycles and misses thirty times. That is not a defect — it is what a
cold cache in front of HBM costs, and it is the first honest look at the number,
since every CPI quoted on this page until now assumed memory that was always
ready.

### What the whole thing costs on the part — 2026-09-11

`ee_top` fitted out of context on `xcu55n-fsvh2892-2LV-e`:

| | |
|---|---|
| CLB LUTs | 16769 (1.92 %) |
| CLB registers | 9089 (0.52 %) |
| **Block RAM** | **8 tiles** |
| UltraRAM | 0 |
| **Fmax** | **201.3 MHz** |

Two things worth keeping.

**The cache is in block RAM.** `ee_ram.vhd` carries a long comment about an
earlier version that synthesis refused to put in block RAM — "Infeasible
attribute ram_style = block" — and that landed its 32 KB in distributed RAM at
14208 LUTs. Eight block RAM tiles and no sign of that is the fix holding.

**The memory subsystem costs nothing in clock.** The core alone measures 192.7
MHz as a mean over three placement directives; the core with its cache, its
arbiter, its fetch queue and an AXI master measures 201.3, and the critical path
is still inside the core — `d_ir` to `m_val`, the same forwarding-and-result-mux
region that has limited it all along. Nothing in the memory path is close.

That is the useful half of the result. The EE's clock problem remains entirely a
problem about MMI and the forwarding loop, and attaching real memory did not add
to it.

## MMI2 and MMI3: the permutes, the variable shifts, and HI/LO whole — 2026-09-11

Three groups, leaving only the multiply-accumulate half of those two tables.

**The permutes** — `PINTH`, `PINTEH`, `PEXEH`, `PEXCH`, `PREVH`, `PCPYH`,
`PEXEW`, `PEXCW`, `PROT3W` — are pure lane selections, so they are one function
driven by a table rather than nine sets of hand-written assignments. Reading
nine of these out of someone else's source one assignment at a time is exactly
the transcription that goes wrong silently, and a table can at least be counted.

**The variable shifts** — `PSLLVW`, `PSRLVW`, `PSRAVW` — are the odd ones. They
read words 0 and 2 of `rt`, shift each by the low five bits of the matching word
of `rs`, and write the results *sign-extended to sixty-four bits* into
doublewords 0 and 1. A 128-bit register in and out, but only half the lanes read
and different widths on each side, which is why they cannot join the parallel
ALU's table.

**`PMFHI`, `PMFLO`, `PMTHI` and `PMTLO` see HI and LO whole**, and HI on the
R5900 is 128 bits — which is exactly the second pair this core already keeps.
`HI` is `hi1:hi`. Every other writer touches one half, chosen by `p1`, so the
wide write is a flag beside the existing path rather than a change to it, and
the forwarding network learned the same distinction.

*Checked by eight mutations, all caught:* `PCPYH` broadcasting one halfword
instead of two, `PREVH` reversing all eight instead of within halves, `PSRAVW`
shifting logically, `PMTHI` writing only the low half, `PMFHI` reading LO,
`PINTH` taking the wrong half of `rs`, `PEXCW` leaving the words alone, and the
shifts taking their amount from the wrong word. The directed program sweeps
`PMTHI`/`PMFHI` with both halves distinct and follows them with a `MULT1`, since
a wide write and the second HI/LO pair are exactly the two things that could be
crossed.

### PMULTW and PMULTUW, and a width that was wrong in silence — 2026-09-11

The first two of the multiply group: two 32x32 products from words 0 and 2,
into doublewords 0 and 1 of rd, with the low word of each product going to LO
and the high word to HI, each sign-extended from 32 bits. **Three 128-bit
destinations from one instruction**, which is what the wide HI/LO write was
built for.

The signed form worked at the first attempt and the unsigned form returned
zeros. The cause is worth recording because nothing warned about it: a 32x32
multiply already gives 64 bits, and resizing the operands to 64 first makes a
*128-bit* product, which assigned to a 64-bit signal is a length mismatch that
`xvhdl` does not flag and `xsim` answers with zeros. Zeros in rd, HI and LO
together look exactly like an instruction that was never decoded, which is where
the first half-hour went.

The directed program caught it on the run it was added to, which is the useful
part: `gen_mmi.py` already had the machinery to check that HI and LO move
together and that a wide write does not disturb the second pair.

## The parallel divides — 2026-09-11

`PDIVW`, `PDIVUW` and `PDIVBW` are done. These were the half of MMI2 and MMI3
that had been deferred four times, and the reason to do them now rather than
later is that they are *machinery*: unlike the accumulating forms below, nothing
about what they compute is in question.

### Two dividers, because the results have to arrive together

`PDIVW` divides word 0 by word 0 and word 2 by word 2, and both quotients land
in the 128-bit LO at once. With one divider that is sixty-six cycles; with two
it is thirty-three, which is what the scalar `DIV` already takes. The second
divider is thirty-two bits of subtractor next to a datapath that is already a
hundred and twenty-eight wide, so the trade is not close.

It steps unconditionally, beside the first, rather than under an enable. A
scalar `DIV` therefore leaves it churning on operands nothing will read, which
costs a little toggling and saves an enable term on a path that is already
tight.

### Divide by zero needed no code at all

None of these instructions has a special case for a zero divisor, and none needs
one. A restoring divider with a zero divisor finds that zero "fits" at every
step: it sets every quotient bit and shifts the dividend intact into the
remainder. That is `LO = 0xFFFFFFFF`, `HI = dividend` — which for `PDIVUW` is
the architectural answer directly, and which the existing sign fixups turn into
`LO = -1` for a non-negative dividend and `LO = 1` for a negative one, the
architectural answer for `PDIVW`. The signed case with no representable
quotient, `0x80000000 / -1`, falls out the same way: the magnitude divider
returns `0x80000000` and the sign fixup leaves it alone.

This is worth stating because the tempting alternative — a guard that tests for
zero and writes constants — would be more code, would need its own test, and
would be a *second* description of behaviour the divider already has. The
directed program tests it in every lane and in both instructions anyway, because
"it falls out" is a claim and not a measurement.

The scalar `DIV` in `sim/ee/r5900_ref.py` now goes through the same `divw`
helper the parallel forms use. Two copies of these rules that could drift is the
failure this is meant to make impossible.

### PDIVBW is the same two dividers, twice

`PDIVBW` divides all four words by one halfword of `rt`, read as **signed** — so
a divisor field of `0xFFFF` is minus one and not 65535, which is the only place
the halfword-ness matters and the first thing the directed test checks. Four
divides through two units is two passes: words 0 and 1, one cycle to copy the
results out and reload, then words 2 and 3. Sixty-six cycles, and a counter that
now runs to 66 rather than 33.

A third and fourth divider would spend four times the area to save thirty-three
cycles on an instruction that is rare in real code. The one cycle between the
passes is why the count is 66 and not 65, and a mutation that takes it back —
stealing an iteration from the second pass — is one of the eight the directed
program catches.

Both loads of the divider pair go through one `load_div` procedure. A second
pass that disagreed with the first about how magnitudes are taken would be wrong
on exactly the two words that nothing else in the file tests.

### What found what

`sim/ee/gen_pdiv.py` is the directed program: every sign combination, zero
divisors one lane at a time and then both, `0x80000000 / -1`, divisors larger
than dividends, one and minus one, operands with the high bit set so that the
signed and unsigned forms diverge, and decoys in words 1 and 3 — which these
instructions never read — chosen so that a divider fed from the wrong half of
the register produces them. Then `PDIVBW` against seven divisors including zero,
one, minus one, `0x7FFF` and `0x8000`, with decoys in `rt`'s other three
halfwords.

It passed first try, so it was mutated: sixteen changes to the RTL — lanes
crossed, `PDIVUW` reading its operands as signed, a sign fixup dropped, a
divider fed from word 1 instead of word 2, one iteration short, `PDIVUW`
zero-extending instead of sign-extending, the interlock removed, the divisor
read unsigned or from the wrong halfword, the first pass's results not held, the
words of LO swapped. **All sixteen fail.** The one that would otherwise have
been easiest to miss is the sign-extension: `PDIVUW` does unsigned division and
still sign-extends its 32-bit results into their 64-bit halves, because the
result is a word and a word landing in a doubleword is always sign-extended on
this machine, however its operands were read.

## The halfword multiply-accumulate group — 2026-09-12

`PMULTH`, `PMADDH`, `PHMADH`, `PMSUBH` and `PHMSBH`. Five instructions that
form the same eight products — rs and rt read as signed halfwords, eight
16 × 16 multipliers — and differ only in what they do with them afterwards.

### Splitting a deferral that had been treated as one thing

This page has said since MMI2 and MMI3 went in that the multiply-accumulate
half was deferred because *"the accumulating forms carry hardware quirks nobody
has explained"*, citing PCSX2's `PMADDW` adding `0x70000000` under a condition
its own comment calls "PlayStation 2 division voodoo".

That was true of the **word** forms and was quietly assumed of the halfword
ones. Checking rather than assuming: the halfword group is plain arithmetic
with no such quirk anywhere in it. So it is done, and `PMADDW`, `PMSUBW` and
`PMADDUW` remain deferred for the reason that actually applies to them.

The lesson is small and worth having: a deferral inherits its justification
from whatever was in view when it was written, and the scope drifts outward if
nobody re-reads it.

### The lane map is the instruction

Nothing here is interesting arithmetic. What makes these five instructions
rather than eight multiplies is where the products go, and it is not obvious:
they are dealt to HI and LO in *pairs*, alternating, working up the register.

    p0 p1 -> LO words 0,1      p2 p3 -> HI words 0,1
    p4 p5 -> LO words 2,3      p6 p7 -> HI words 2,3

and rd takes the first word of each pair — LO0, HI0, LO2, HI2. Written that
way it is one loop over four groups, and the five instructions differ in two
lines: the pair of values each group produces. The horizontal forms
(`PHMADH`, `PHMSBH`) combine the two products of a group instead of keeping
them apart, which is the only structural difference among the five.

The directed program's operands are therefore all-distinct halfwords rather
than corner values: a product taken from the wrong lane, or landing in HI where
it belonged in LO, has to produce a number that appears nowhere else in the
answer. Corners are in there too — `0x8000 × 0x8000` in every lane, accumulated
four deep, which takes the sums well past 32 bits, because **these wrap and do
not saturate**. That is the opposite of MMI0's arithmetic and it is what makes
the accumulating forms usable as a dot product.

### PHMSBH writes the complement of a product, and nobody knows why

`PHMSBH`'s second word of each pair is `NOT p`, not `p`. No manual this project
has says so. It is PCSX2's behaviour, marked in its own source as undocumented,
and it is the only account of it anywhere.

It is implemented, because a guess that matches the only known description is
better than a different guess, and it is **tagged in both implementations and
given a probe entry**, because testing a guess against a copy of itself proves
only that the two agree. This is the same treatment the depth clamp got.

### Twelve mutations, ten caught, and the two that were not

Ten of twelve fail: HI and LO swapped, rd taking the wrong word of the pair,
the complement dropped, halfwords read unsigned, `PMSUBH` adding, `PHMADH`
doubling the wrong product, the pair's words swapped, the group base computed
from the wrong half of the index, an accumulate that stops accumulating, and
the interlock removed.

Two survive, and both are **equivalent mutants** — which is a conclusion, not a
gap, and it was checked against the whole regression rather than asserted:

**Reading HI and LO unforwarded is indistinguishable here.** These are
multi-cycle instructions: one sits in A1 for four cycles and reads its
accumulator on the last of them, by which time any producer — even one
immediately before it — has been through A2 and WB with a cycle to spare. The
forwarding distance is shorter than the interlock. The forwarded read stays
anyway, because it costs nothing and it is what keeps this correct if the
interlock is ever shortened.

**The second multiplier pipeline stage is invisible.** Reading the product from
the first stage gives the same answer, because nothing overwrites it before the
retire. That is expected: the second stage exists so the tool has a register to
push into the DSP's own output pipeline, exactly as the scalar `MULT`'s does.
It is a timing structure, and a functional test cannot see a timing structure.

### PMADDUW, and a deferral that had grown twice — 2026-09-12

Re-reading the deferral once shrank it from "the multiply-accumulate half" to
"the word-wide forms". Reading the actual code it refers to shrinks it again:
**`PMADDUW` has no quirk either.** It is a plain unsigned accumulate, and the
only thing unusual about it is the shape of its accumulator.

That accumulator is not a doubleword of `HI` or `LO` like every other one here.
It is **one word of each** — `LO`'s word holds the low half of a 64-bit value
and `HI`'s the high — which is exactly the shape `PMULTUW` leaves behind, and
is what lets the two compose into a running sum of 32 × 32 products. So the
directed test builds that composition, and separately seeds `HI` and `LO` with
four distinguishable words so that an accumulator assembled from the wrong two
is visible. Eight mutations, eight caught.

So MMI is down to **two** instructions, and for the first time the reason is
narrowed to exactly what it is rather than inherited. `PMADDW` and `PMSUBW`
divide by `0xFFFFFFFF` where a shift by 32 belongs, because — per the only
account of it — the PS2's multiplier is off by one; and `PMADDW` adds
`0x70000000` when `rt`'s low 31 bits are all zero or all one and `rs /= rt`,
but only in the low half. Neither is derivable from anything, both come from a
GPL-3 emulator this project uses as an oracle and never as a source, and
implementing them would mean writing down behaviour that cannot be checked
against anything except the thing it was copied from. They wait for a console.

**Twice now, re-reading a deferral has made it smaller.** A deferral inherits
its justification from whatever was in view when it was written, and nothing
re-narrows it later unless someone goes back and asks which parts the reason
actually covers.

## PMULTW was costing sixty megahertz, unmeasured — 2026-09-12

A fit of `ee_top` after the parallel divides came back at **140.1 MHz**, against
201.3 recorded on this page. The divides were not the cause — the critical path
named no divider signal at all. It ran from a forwarding select through a
cascade of DSP stages into `m_val`, which is a 32-bit multiply sitting
combinationally in the single cycle a result is written.

That is `PMULTW`. It was added in the same session as the GS board target, and
**no fit was run after it**: the 201.3 MHz on this page predates it, so the cost
had been sitting there unrecorded ever since.

The fix was already written, elsewhere in the same file. The scalar `MULT` had
solved this on the first day by capturing its operands and walking the product
through the DSP's own pipeline registers over three cycles, under the interlock
`is_muldiv` provides. `PMULTW` and `PMULTUW` simply had never been given the
same treatment; they now load the same two multipliers the parallel divides'
second unit taught the file to have, and read their products out three cycles
later.

**140.1 → 203.9 MHz** (200.8 / 205.5 / 205.3 over three placement directives),
and the critical path is back where it has always been: `d_ir` to `m_val`, the
forwarding-and-result-mux region.

The lesson is not about multipliers. **A feature added without a fit is a clock
regression that nobody will attribute later** — by the time it was noticed, two
sessions of other work stood between the cause and the measurement, and the
first guess was the divides that had just gone in.

| | Fmax | LUTs |
|---|---|---|
| `ee_top` before MMI2/MMI3 multiplies | 201.3 | 16769 |
| with PMULTW combinational (never measured until now) | 140.1 | 19707 |
| **PMULTW multi-cycle, and the parallel divides** | **203.9** | 20290 |

## What is not started

This section had drifted and said the opposite of the page above it — that the
core "is still one instruction at a time", written before it was pipelined and
never revisited. It is a five-stage single-issue pipeline; what is missing is
below.

**The big pieces.** The FPU (COP1) and the two vector units. No TLB.

**The pipeline itself.** Single issue against the R5900's dual, and no branch
predictor — the R5900 has a BTAC and this does not, so every taken branch pays
a full fetch refill. Both are the deeper-pipeline work that the clock gap
eventually needs and neither is a small change.

**Two instructions of MMI**, `PMADDW` and `PMSUBW`, described above: they carry
quirks derivable from nothing and checkable against nothing but the emulator
they came from, so they wait for a console. Everything else in MMI0, MMI1, MMI2
and MMI3 is done, along with the unaligned group, `LQ` and `SQ`.

Timing, three placement directives per variant, against a 294.912 MHz target:

| core | Fmax mean | LUTs |
|---|---|---|
| before MMI0/MMI1 | 272.7 | 10571 |
| + the parallel ALU, per-width adders | 214.1 | 13916 |
| + the pack, extend and shuffle group | 192.7 | 15612 |
| **+ all of MMI2 and MMI3** | **190.8** | 17038 |

The last row is the correction to what the first three imply. It is easy to read
this table as "MMI costs clock", and then to expect every further MMI
instruction to cost more — the permutes, the variable shifts, HI and LO whole,
five multiplies, three divides, the halfword multiply-accumulate group and
`PMADDUW` between them cost **two megahertz**.

The 80 MHz was never MMI in general. It was specifically the **parallel ALU and
the shuffle group**, which are single-cycle and sit in the same result mux as
the scalar ALU. Everything added since is multi-cycle and therefore nowhere near
that path, which is also why `PMULTW` was worth sixty megahertz the moment it
stopped being an exception to that rule.

The memory port costs about 6 MHz by comparison.

### The parallel ALU is not where the clock went — measured, 2026-09-12

This page said for three sessions that the way forward was to move the parallel
ALU's saturating forms out of the single-cycle path and into A2. That was a
guess and it is wrong, and the experiment is cheap enough that it should have
been run when the sentence was first written.

The parallel ALU was given its own two cycles behind the existing multiply
interlock — which needs no new hazard logic, because that interlock is already
longer than the forwarding distance. Correctness is unaffected: 19 of 19.

| | Fmax mean (3 directives) | `gen_mmi` CPI | other programs |
|---|---|---|---|
| control | 190.8 | 1.00 | 1.23 / 1.11 |
| parallel ALU registered | **199.3** | **1.54** | 1.23 / 1.11 |

**+8.5 MHz for +54 % cycles on SIMD code.** Reverted.

The interesting part is why the gain is so small. Adding the parallel ALU cost
58 MHz when it went in; taking it *entirely* off the single-cycle path gives
back 8.5. So its depth was never the problem — what it did was widen the
datapath to 128 bits and add thirty arms to the result multiplexer, and
registering the ALU shrinks neither.

The new critical path says the same thing outright: `m_p1` to `m_lou[63]`, nine
logic levels and **77 % routing**. That is wire between two 128-bit pipeline
latches. There is no arithmetic left in it to split.

**So the EE's clock problem is width and fan-out, not any one unit**, and
splitting units one at a time will keep returning single-digit megahertz. The
deeper-pipeline work should start from the register file, the forwarding
network and the result mux — the things that are 128 bits wide and fan out
everywhere — rather than from any arithmetic block. That is a different and
larger piece of work than this page has been assuming.

IPC is better but not closed: CPI 1.78 on ordinary code, 2.15 on branch-heavy.
What is left is multiply/divide latency (inherent), one stall per memory access,
and the absence of a branch predictor — the R5900 has a BTAC and this core does
not, so every taken branch pays a full fetch refill.
