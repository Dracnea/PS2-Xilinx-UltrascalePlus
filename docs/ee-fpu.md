# The Emotion Engine's FPU — what it is, and what can be checked

*Written 2026-09-12, before any RTL. The point of writing it first is that the
FPU is the one block in this machine whose behaviour cannot be fully checked
against anything currently available, and knowing which half is which decides
how it should be built.*

## It is not IEEE 754, and that is the easy part

COP1 is a single-precision unit with the familiar layout — sign, eight exponent
bits, twenty-three mantissa bits — and three deliberate omissions:

* **No denormals.** An operand whose exponent is zero is read as ±0, keeping its
  sign and discarding its mantissa. A *result* that lands denormal is flushed to
  ±0 and sets the underflow flag.
* **No infinities.** An operand whose exponent is 0xFF is read as ±Fmax,
  `0x7F7FFFFF` with the sign kept. A result that would be infinite becomes
  ±Fmax and sets the overflow flag.
* **No NaN.** There is no encoding left for one, which follows from the two
  above rather than being a separate rule.

So every value in the machine is an ordinary finite number, and the range is
closed by saturation at both ends rather than by escape into Inf and NaN. Two
consequences matter for the RTL: **every operand passes through a conditioner**
before it is used, and **every result passes through a saturator** after. Those
two functions are the whole of the format.

Division by zero is not an exception either. The result is ±Fmax with the sign
of the two operands exclusive-ored, and a flag — `D` if the dividend was
non-zero, `I` if it was also zero, the second standing in for what IEEE would
call an invalid operation.

`MAX.S` and `MIN.S` compare as *signed integers*, with the order reversed when
both operands are negative. That is the standard trick and it works precisely
because there are no NaNs to spoil it.

## The flags

`FCR31` carries condition and cause bits at fixed positions — `C` at bit 23,
then `I`, `D`, `O`, `U` as causes at bits 17, 16, 15, 14, and the same four as
sticky flags at bits 6, 5, 4, 3. The causes are cleared per instruction and the
sticky ones accumulate until written.

There is a documented disagreement here worth carrying into the implementation
rather than discovering later: the EE Core User's Manual implies every cause
flag is cleared by every instruction, and the EE Core Instruction Set Manual
says only certain ones are. PCSX2 carries a comment saying exactly this and
follows the second reading. Nothing settles it but a console.

## What cannot be checked, and why that changes the plan

Everything above is *structure* — which bit pattern maps to which, which flag is
set when. It can be implemented, modelled and diffed with confidence, because
both descriptions of it agree and neither is anyone's guess.

**The arithmetic cannot.** The PS2 rounds toward zero and has a multiplier that
is documented, by the only people who have measured it, as not quite exact. The
obvious oracle does not help:

> **PCSX2 computes with host floats.** Its `ADD_S` is a C `+` on two `float`s,
> which rounds to *nearest*, not toward zero. It is therefore a faithful model
> of the PS2's **format and flags** and an unfaithful one of its **arithmetic**,
> and the difference is in the last bit of nearly every result.

That is not a criticism of PCSX2 — a games emulator is right to spend its
accuracy elsewhere — but it means a differential test of this project's FPU
against PCSX2 would disagree constantly for reasons that say nothing, and a
differential test against a reference model written from the same assumptions
would agree for reasons that say nothing either.

So the plan the rest of this project uses — write the model and the RTL from the
manual, diff them, mutate to prove the test bites — gives less here than
elsewhere. It proves the two implementations agree. It cannot prove either
matches silicon.

## How to build it anyway

**Separate the two halves and test them differently.**

The conditioner, the saturator, the flag logic, the compares, the moves, the
loads and stores, `ABS`, `NEG`, `MOV`, the branch on the condition bit: all
structure, all checkable, all worth the usual treatment — a reference model, a
directed test over every corner of the encoding (zero, denormal, Fmax, the
exponent boundaries, both signs), random streams, and mutation testing.

The adder, multiplier, divider and square root: implement round-toward-zero
exactly, because that much *is* specified, and accept that the last bit of
`MUL`, `DIV` and `SQRT` is unverified until a console runs the probe below.
Keep the rounding mode in one place so that a measurement can change it without
touching thirty instructions.

**The probe this needs** is a sweep: a few thousand operand pairs chosen to
straddle rounding boundaries — pairs whose exact product needs bit 24, pairs
whose quotient is a repeating binary fraction — executed on a console with the
results dumped. That is a different shape from the GS probes, which draw and
read back, but it uses the same `ps2link` path and it would settle the last bit
of every arithmetic instruction at once. It is recorded in
`hw/ps2probe/README.md`.

**Do not start with `ADD.S`.** Start with the conditioner and the flags, because
that is the part that can be finished and known to be right.

## The half that could be finished, finished — 2026-09-14

`rtl/ee/ee_fpu_pkg.vhd`, in the order this page asked for: **not `ADD.S`**.

The conditioner is the whole of the special-case handling, and once it is right
no other part of the unit ever has to consider a special value again:

| operand | reads as |
|---|---|
| exponent 0 — a denormal, or zero | a **signed** zero, mantissa discarded |
| exponent 255 — what IEEE calls infinity or NaN | the **largest finite value of the same sign** |
| anything else | itself |

The sign surviving a flush is not a nicety. `MAX` and `MIN` compare as integers,
and they would order +0 and −0 differently if it were dropped — which is the
kind of fault that appears in one game, in one place, years later.

The compares are done on conditioned values as integers, which works here for a
reason that does not hold on an IEEE machine: with no NaN there is nothing
unordered, and the format is monotonic in its bit pattern within each sign. The
only special case is that +0 and −0 have different patterns and must compare
equal.

`ABS` and `NEG` deliberately do **not** condition their operand: a denormal
negated is still that denormal with the other sign, and only an arithmetic
instruction flushes it.

### How it is checked

`sim/ee/run_fpu_diff.sh` drives the package from a vector file and diffs the
result against `ps2_float.py`, which does its arithmetic in exact rationals.
**924 vectors, identical.**

Random 32-bit patterns would be nearly useless: almost all of them are ordinary
normals with a middling exponent, and the conditioner's entire job is at the two
ends. So `gen_fpu_vectors.py` enumerates the corners — both zeros, the smallest
and largest denormal, the smallest normal, the largest finite value, the
exponent-255 patterns, every bit set — and pairs **every corner with every
corner**, because the comparisons care about the pairing and not just the
operands. Random pairs with exponents biased toward the ends are added on top
rather than relied upon.

Eight mutations, all caught: the denormal not flushed, exponent 255 not
saturated, the sign dropped on a flush, +0 ≠ −0, the both-negative comparison
inverted, a negative not less than a positive, `ABS` negating instead of
clearing, and `MIN`/`MAX` exchanged.

**What is still open** is exactly what this page said would be: the last bit of
`MUL`, `DIV` and `SQRT`. Those are implemented to the specification — round
toward zero, in one place so a measurement can change it — and remain unverified
until the console sweep in `hw/ps2probe/README.md` runs.
