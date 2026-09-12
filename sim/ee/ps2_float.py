#!/usr/bin/env python3
"""The PlayStation 2's floating-point number system, exactly.

The EE's COP1 is single precision with three deliberate omissions -- no
denormals, no infinities and therefore no NaN -- so every value it can hold is
an ordinary finite number and the range is closed by saturation at both ends.
See docs/ee-fpu.md for what that costs and what it buys.

**This module does its arithmetic in exact rationals, not in host floats.**
That is the whole reason it exists as a separate file. The obvious way to model
a 32-bit float is to use the machine's own, and it is wrong here in a way that
is invisible until it matters: a host float rounds to *nearest*, the PS2
truncates toward *zero*, and the two differ in the last bit of a large fraction
of all results. PCSX2 models the PS2 this way and is right to -- a games
emulator's accuracy is better spent elsewhere -- but a replication cannot.

So each operation is computed as an exact `Fraction` and then rounded once, by
truncation, at the end. That is slower than a float by a large factor and
exactly right, which is the correct trade for a reference model.

What is *not* settled here is the last bit of `MUL`, `DIV` and `SQRT` on real
silicon: the multiplier is documented, by the only people who have measured it,
as not quite exact. Truncation is what the manual specifies and what this
implements; a console sweep is the probe that would confirm it. Everything else
below -- the conditioner, the saturator, the flags, the comparisons -- is
structure and is not in doubt.
"""

from fractions import Fraction

M32     = 0xFFFFFFFF
POS_MAX = 0x7F7FFFFF          # the largest finite value: sign 0, exp 254, all mantissa
EXP_ALL = 0x7F800000          # the exponent field, all ones


# ---- the flags, at their positions in FCR31 --------------------------------
FLAG_C  = 1 << 23             # the condition bit, set by the compares
CAUSE_I = 1 << 17             # invalid: a divide of zero by zero
CAUSE_D = 1 << 16             # divide by zero
CAUSE_O = 1 << 15             # overflow: a result that would have been infinite
CAUSE_U = 1 << 14             # underflow: a result that would have been denormal
STICKY_I, STICKY_D, STICKY_O, STICKY_U = 1 << 6, 1 << 5, 1 << 4, 1 << 3


def parts(x):
    """(sign, exponent, mantissa) of a 32-bit pattern."""
    x &= M32
    return (x >> 31) & 1, (x >> 23) & 0xFF, x & 0x7FFFFF


def cond(x):
    """The operand conditioner: what the unit reads when it is handed `x`.

    Denormals -- and zero, which has the same exponent -- read as a signed zero
    with the mantissa discarded. Anything with a full exponent field, which on
    an IEEE machine would be an infinity or a NaN, reads as the largest finite
    value of the same sign. Everything else is itself.

    Every operand of every arithmetic instruction goes through this, which is
    why the unit never has to consider a special value again.
    """
    s, e, m = parts(x)
    if e == 0:
        return s << 31
    if e == 0xFF:
        return (s << 31) | POS_MAX
    return x & M32


def value(x):
    """The exact rational a conditioned pattern represents."""
    s, e, m = parts(cond(x))
    if e == 0:
        return Fraction(0)
    v = Fraction(0x800000 + m, 0x800000) * Fraction(2) ** (e - 127)
    return -v if s else v


def pack(fr, sign_of_zero=0):
    """The pattern nearest `fr` *toward zero*, and the flags that implies.

    Returns (pattern, cause-flags). Rounding toward zero is the only mode the
    PS2 has, so this is not a parameter: a result is truncated, never rounded up
    and never rounded to even.
    """
    if fr == 0:
        return sign_of_zero << 31, 0
    s = 1 if fr < 0 else 0
    a = -fr if fr < 0 else fr

    # the exponent is the position of the leading one
    e = 0
    while a >= 2:
        a /= 2
        e += 1
    while a < 1:
        a *= 2
        e -= 1

    if e > 127:
        # too large to represent: the PS2 saturates rather than producing an
        # infinity, because it has no encoding for one
        return (s << 31) | POS_MAX, CAUSE_O
    if e < -126:
        # too small: there are no denormals to fall back on, so it is zero
        return s << 31, CAUSE_U

    m = int((a - 1) * 0x800000)          # truncation, and `a` is exact here
    return (s << 31) | ((e + 127) << 23) | m, 0


# ---- the operations --------------------------------------------------------
#
# Each conditions its operands, computes exactly, and packs once.  Doing the
# arithmetic on the *rationals* rather than on mantissas and exponents is what
# makes "compute exactly then truncate once" true by construction rather than
# by careful bookkeeping.

def add(a, b):
    return pack(value(a) + value(b))


def sub(a, b):
    return pack(value(a) - value(b))


def mul(a, b):
    return pack(value(a) * value(b))


def div(a, b):
    """Division, including the cases that are not errors on this machine.

    A zero divisor does not raise: the result is the largest finite value with
    the sign of the two operands exclusive-ored, and a flag says which kind of
    zero it was -- `D` for a normal dividend, `I` for zero divided by zero,
    which is what this machine has instead of an invalid-operation trap.
    """
    ca, cb = cond(a), cond(b)
    if parts(cb)[1] == 0:                       # divisor is zero
        sign = ((ca ^ cb) >> 31) & 1
        flag = CAUSE_I if parts(ca)[1] == 0 else CAUSE_D
        return (sign << 31) | POS_MAX, flag
    return pack(value(a) / value(b))


def sqrt_(x):
    """Square root of the absolute value -- the PS2 ignores the sign.

    Computed by bisection on exact rationals to one more bit than the format
    holds, then truncated, so that the result is the largest representable value
    not exceeding the true root.
    """
    v = abs(value(x))
    if v == 0:
        return 0, 0
    lo, hi = Fraction(0), max(v, Fraction(1))
    for _ in range(200):
        mid = (lo + hi) / 2
        if mid * mid <= v:
            lo = mid
        else:
            hi = mid
    return pack(lo)


def fmax(a, b):
    """MAX.S compares as signed integers, with the order reversed when both are
    negative -- the standard trick, which works here precisely because there are
    no NaNs to spoil the ordering."""
    a, b = cond(a), cond(b)
    sa = a - (1 << 32) if a >> 31 else a
    sb = b - (1 << 32) if b >> 31 else b
    if sa < 0 and sb < 0:
        return a if sa < sb else b
    return a if sa > sb else b


def fmin(a, b):
    a, b = cond(a), cond(b)
    sa = a - (1 << 32) if a >> 31 else a
    sb = b - (1 << 32) if b >> 31 else b
    if sa < 0 and sb < 0:
        return a if sa > sb else b
    return a if sa < sb else b
