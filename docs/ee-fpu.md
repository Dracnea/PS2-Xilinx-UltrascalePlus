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
