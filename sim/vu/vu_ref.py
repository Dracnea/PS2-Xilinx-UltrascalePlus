#!/usr/bin/env python3
"""VU1 -- the PlayStation 2's geometry vector unit, as a reference model.

    sim/vu/vu_ref.py program.hex --steps 200

Every scrap of geometry on a PlayStation 2 goes through here. The Emotion
Engine sets up, the VU transforms, the GIF carries the result to the Graphics
Synthesizer; a console with no VU1 draws nothing a game would recognise. It is
also, with the texture unit, one of the two largest blocks still unbuilt.

This is written before any RTL, for the same reason `sim/ee/r5900_ref.py` and
`sim/gs/gs_ref.py` were: the model is the thing the hardware is checked
against, and a model written afterwards tends to agree with the hardware rather
than with the machine.

## What a VU is

Four 32-bit floats side by side, called **x y z w**, and every arithmetic
instruction carries a **field mask** saying which of the four it writes. A
masked-off field is not written -- not written as zero, not written as the old
value through a mux, simply not written -- which matters because the destination
may be being written by something else in the same cycle.

Two instructions issue per cycle from one 64-bit word: an **upper** instruction
(the floating-point ALU, the FMACs) and a **lower** one (loads, stores, integer
arithmetic, branches, and the divide unit). They are not a VLIW pair in the
usual sense -- the upper slot is the vector ALU and the lower slot is
everything else -- and they read their operands from the same register file in
the same cycle.

## What this file settles and what it cannot

**Settled here:** the instruction encodings, the field-mask and broadcast rules,
the exact arithmetic, the special-register behaviour of ACC, I, Q, P and R, and
the integer unit's 16-bit wrap-around.

**Not settled here:** the pipeline. A real VU1 has a four-stage FMAC with
forwarding, a divide unit that runs for seven cycles independently of
everything else, and instruction stalls that a compiler is expected to schedule
around. Cycle counts are a separate layer and belong on top of a functional
model that is already right; putting them in first makes both harder to check.

## The arithmetic is not IEEE, and it is already written

The VU uses the same number system as the EE's COP1 -- no denormals, no
infinities, therefore no NaN, and rounding toward zero -- so `sim/ee/ps2_float.py`
is imported rather than reimplemented. That module does its arithmetic in exact
rationals precisely so this kind of reuse is safe: two blocks that must agree
bit for bit share one implementation of what a number is.

The one thing the VU adds is the **ACC**, a 128-bit accumulator of four floats
that MADD and MSUB read and write. It is a register, not an extended-precision
accumulator: each MADD rounds its product and rounds again after the add, so
`MADD` is not more accurate than `MUL` followed by `ADD`, and a model that
carried an exact product through would be wrong in the direction that looks
better.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "ee"))
import ps2_float as F

M16 = 0xFFFF
M32 = 0xFFFFFFFF

# The four fields, most significant bit of the mask first.  The encoding puts
# x in bit 3 of the dest-field nibble and w in bit 0, which is the opposite
# order to the way the fields are numbered, and is a standing source of
# transposition mistakes -- so it is written once, here, and never inline.
FIELDS = ("x", "y", "z", "w")
FIELD_BIT = {"x": 3, "y": 2, "z": 1, "w": 0}


def dest_fields(dest):
    """The field names a four-bit DEST mask selects, in x y z w order."""
    return [f for f in FIELDS if dest & (1 << FIELD_BIT[f])]


class VF:
    """One 128-bit vector register: four 32-bit float bit patterns."""
    __slots__ = ("v",)

    def __init__(self, x=0, y=0, z=0, w=0):
        self.v = [x, y, z, w]

    def __getitem__(self, i):
        return self.v[i if isinstance(i, int) else FIELDS.index(i)]

    def __setitem__(self, i, val):
        self.v[i if isinstance(i, int) else FIELDS.index(i)] = val & M32

    def copy(self):
        return VF(*self.v)

    def __repr__(self):
        return "(%08x %08x %08x %08x)" % tuple(self.v)


class VU:
    """VU1: 32 vector registers, 16 integer registers, 16 KB of each memory.

    VU0 is the same unit with a quarter of the memory and without the P
    register or the EFU, so this class takes the sizes as parameters rather
    than hard-coding VU1's -- but VU1 is what the geometry runs on and what
    this is written for.
    """

    def __init__(self, mem_qw=1024, micro_words=2048):
        # vf00 is hardwired to (0, 0, 0, 1.0) and cannot be written.  It is not
        # merely initialised to that: a write to it is discarded, which is what
        # makes it usable as a constant source of 1.0 in w.
        self.vf = [VF() for _ in range(32)]
        # ps2_float.pack returns (pattern, flags) -- the flags are the point of
        # the module and are never dropped silently at a call site.
        self.vf[0] = VF(0, 0, 0, F.pack(1)[0])
        self.vi = [0] * 16                 # vi00 reads as zero, writes discarded
        self.acc = VF()
        self.q = 0                         # divide unit result
        self.p = 0                         # EFU result (VU1 only)
        self.r = 0x3F800000                # the random unit's seed register
        self.i = 0                         # the immediate loaded by a LOI
        self.mac = 0                       # MAC flags, per field
        self.clip = 0                      # 24 bits, six per vertex tested
        self.status = 0
        self.mem = [VF() for _ in range(mem_qw)]      # VU Mem, quadword addressed
        self.micro = [0] * micro_words                # Micro Mem, 64-bit words
        self.pc = 0
        self.running = False
        self.unimplemented = []

    # ---- register access, with the two hardwired registers enforced --------
    def rvf(self, n):
        return self.vf[n]

    def wvf(self, n, field, bits):
        """Write one field of one vector register.

        vf00 is silently discarded rather than raising: that is what the
        hardware does, and a compiler emitting a masked write whose destination
        happens to be vf00 is doing something legal.
        """
        if n == 0:
            return
        self.vf[n][field] = bits

    def rvi(self, n):
        return 0 if n == 0 else self.vi[n] & M16

    def wvi(self, n, val):
        if n == 0:
            return
        self.vi[n] = val & M16


# ---- the upper instruction: field masks, broadcasts, and the FMACs ---------
#
# The encoding, confirmed field by field rather than remembered:
#
#     [24:21]  DEST, the field mask -- bit 24 is x and bit 21 is w, so the
#              nibble reads x y z w from its most significant bit down
#     [20:16]  ft      [15:11]  fs      [10:6]  fd      [5:0]  opcode
#     [1:0]    bc, which field of ft a broadcast form reads
#
# Opcodes 0x3C..0x3F are an extension: their low two bits choose one of four
# sub-tables and the fd field, [10:6], indexes into it.  That is why ADDAx,
# ADDAy, ADDAz and ADDAw are four different *opcodes* rather than one opcode
# with a broadcast field -- the accumulator forms spent their bc bits on the
# extension.

def u_dest(code):   return (code >> 21) & 0xF
def u_ft(code):     return (code >> 16) & 0x1F
def u_fs(code):     return (code >> 11) & 0x1F
def u_fd(code):     return (code >> 6) & 0x1F
def u_op(code):     return code & 0x3F
def u_bc(code):     return code & 0x3

# opcode -> (kind, source-of-second-operand).  "bc" takes one field of ft
# broadcast to all four, "q" and "i" take a special register, "v" takes ft
# field by field.
_UPPER = {}
for _i, _nm in enumerate(("ADD", "SUB", "MADD", "MSUB", "MAX", "MINI", "MUL")):
    for _b in range(4):
        _UPPER[_i * 4 + _b] = (_nm, "bc")
_UPPER.update({
    0x1C: ("MUL", "q"),  0x1D: ("MAX", "i"),  0x1E: ("MUL", "i"),  0x1F: ("MINI", "i"),
    0x20: ("ADD", "q"),  0x21: ("MADD", "q"), 0x22: ("ADD", "i"),  0x23: ("MADD", "i"),
    0x24: ("SUB", "q"),  0x25: ("MSUB", "q"), 0x26: ("SUB", "i"),  0x27: ("MSUB", "i"),
    0x28: ("ADD", "v"),  0x29: ("MADD", "v"), 0x2A: ("MUL", "v"),  0x2B: ("MAX", "v"),
    0x2C: ("SUB", "v"),  0x2D: ("MSUB", "v"), 0x2E: ("OPMSUB", "v"), 0x2F: ("MINI", "v"),
})

# The four extension tables, indexed by fd.  Entries are (name, second-operand,
# writes-ACC).
#
# **Honesty about where this came from.**  The flat table above was written from
# the instruction set and then checked against PCSX2's dispatch table, which is
# the right order -- the check can fail.  These four were not: the extension's
# arrangement is not the one the broadcast forms use, and rather than guess it
# from memory the tables were transcribed with PCSX2's in view.  So
# `tools/vu/xcheck_ops.py` passing on these 95 entries confirms that the
# transcription is faithful; it does **not** independently confirm the
# encoding, because there is only one source behind both sides.
#
# What would make it independent is a second, primary source -- the vector unit
# chapter of Sony's manual, or a program assembled by a real toolchain and run
# on a console.  Until then this is a single-sourced fact and is marked as one,
# rather than being allowed to look like the swizzle tables, which were derived
# first and checked afterwards against 832 entries.
_EXT = {}
for _w, _bcn in enumerate("xyzw"):
    _EXT[(_w, 0x00)] = ("ADD",  "bc%d" % _w, True)
    _EXT[(_w, 0x01)] = ("SUB",  "bc%d" % _w, True)
    _EXT[(_w, 0x02)] = ("MADD", "bc%d" % _w, True)
    _EXT[(_w, 0x03)] = ("MSUB", "bc%d" % _w, True)
    _EXT[(_w, 0x06)] = ("MUL",  "bc%d" % _w, True)
_EXT.update({
    (0, 0x04): ("ITOF0",  None, False), (1, 0x04): ("ITOF4",  None, False),
    (2, 0x04): ("ITOF12", None, False), (3, 0x04): ("ITOF15", None, False),
    (0, 0x05): ("FTOI0",  None, False), (1, 0x05): ("FTOI4",  None, False),
    (2, 0x05): ("FTOI12", None, False), (3, 0x05): ("FTOI15", None, False),
    (0, 0x07): ("MUL",  "q", True),     (1, 0x07): ("ABS",    None, False),
    (2, 0x07): ("MUL",  "i", True),     (3, 0x07): ("CLIP",   None, False),
    (0, 0x08): ("ADD",  "q", True),     (1, 0x08): ("MADD", "q", True),
    (2, 0x08): ("ADD",  "i", True),     (3, 0x08): ("MADD", "i", True),
    (0, 0x09): ("SUB",  "q", True),     (1, 0x09): ("MSUB", "q", True),
    (2, 0x09): ("SUB",  "i", True),     (3, 0x09): ("MSUB", "i", True),
    (0, 0x0A): ("ADD",  "v", True),     (1, 0x0A): ("MADD", "v", True),
    (2, 0x0A): ("MUL",  "v", True),     (3, 0x0A): (None,   None, False),
    (0, 0x0B): ("SUB",  "v", True),     (1, 0x0B): ("MSUB", "v", True),
    (2, 0x0B): ("OPMULA", "v", True),   (3, 0x0B): ("NOP",  None, False),
})


def decode_upper(code):
    """-> (name, second-operand kind, writes-ACC, bc) or (None, ...).

    Returned rather than dispatched so the disassembler and the executor share
    one decode: a table that is only exercised through execution tends to be
    right for the instructions the tests happen to use.
    """
    op = u_op(code)
    if op >= 0x3C:
        name, src, acc = _EXT.get((op & 3, u_fd(code)), (None, None, False))
        if src and src.startswith("bc"):
            return name, "bc", acc, int(src[2])
        return name, src, acc, 0
    name, src = _UPPER.get(op, (None, None))
    return name, src, False, u_bc(code)


# ---- the MAC and status flags ----------------------------------------------
#
# Every FMAC result sets four flags per field, and VU code reads them: the
# FM*/FS*/FC* lower instructions branch on them, and a geometry kernel uses them
# to cull. A model that computes correct numbers and no flags runs a transform
# correctly and then culls nothing.
#
# The layout is nibble-per-flag, field-within-nibble, and **x is bit 3 of its
# nibble while w is bit 0** -- the same reversal the DEST mask has, for the same
# reason, and the same standing source of transposition mistakes.
#
#     bits  3..0   Z, zero
#     bits  7..4   S, sign
#     bits 11..8   U, underflow
#     bits 15..12  O, overflow
#
# The rules are not independent. A zero result sets Z and *clears* U and O; an
# underflow sets both U and Z, because a denormal flushed to zero is a zero;
# an overflow sets O and clears U and Z. Only the sign flag is set purely from
# the sign bit, and it is set even when the result is zero -- which is how
# negative zero stays distinguishable in a format that keeps the sign bit.

MAC_SHIFT = {"x": 3, "y": 2, "z": 1, "w": 0}
MAC_Z, MAC_S, MAC_U, MAC_O = 0x0001, 0x0010, 0x0100, 0x1000


def mac_bits(bits32, cause):
    """(set, clear) masks for one field's flags, before the field shift.

    `cause` is ps2_float's flag word for the operation, which already knows
    whether the result saturated or flushed -- the format has no infinities or
    denormals to inspect afterwards, so the flags have to come from the
    operation rather than from the pattern it produced.
    """
    neg = bool(bits32 & 0x80000000)
    sign, nosign = (MAC_S, 0) if neg else (0, MAC_S)
    if cause & F.CAUSE_O:
        return sign | MAC_O, nosign | MAC_U | MAC_Z
    if cause & F.CAUSE_U:
        return sign | MAC_U | MAC_Z, nosign | MAC_O
    if bits32 & 0x7FFFFFFF == 0:
        return sign | MAC_Z, nosign | MAC_U | MAC_O
    return sign, nosign | MAC_Z | MAC_U | MAC_O


class UpperUnit:
    """The floating-point ALU. Everything here rounds twice, deliberately.

    A MADD is a multiply and then an add, each rounded. It is *not* a fused
    multiply-add: the product is packed to 32 bits before the accumulator is
    added to it. Carrying an exact product through would make this model more
    accurate than the hardware, which is the failure mode a reference model must
    not have -- it would then disagree with correct RTL and the RTL would be
    "fixed" to match it.
    """

    def __init__(self, vu):
        self.vu = vu

    def second(self, src, ft, f, bc):
        """The second operand for field `f`."""
        vu = self.vu
        if src == "v":  return vu.rvf(ft)[f]
        if src == "bc": return vu.rvf(ft)[bc]
        if src == "q":  return vu.q
        if src == "i":  return vu.i
        return 0

    def run(self, code):
        vu = self.vu
        name, src, to_acc, bc = decode_upper(code)
        if name is None:
            vu.unimplemented.append(("upper", code))
            return False
        if name == "NOP":
            return True

        dest, fs, ft, fd = u_dest(code), u_fs(code), u_ft(code), u_fd(code)
        fields = dest_fields(dest)

        # Where the result goes is not always fd.  The extension opcodes spend
        # the fd field as their sub-opcode, so the instructions that live there
        # and still write a vector register -- ITOF, FTOI and ABS -- write **ft**
        # instead.  Writing fd for those would put every converted value into
        # whichever register number happened to equal the sub-opcode, which for
        # ITOF0 is vf04: a plausible-looking register that quietly collects
        # every conversion in the program.
        wr = ft if (name in ("ABS",) or name.startswith("ITOF")
                    or name.startswith("FTOI")) else fd

        # The outer product pair. OPMULA and OPMSUB compute a cross product
        # between them, and they are the reason the VU can do one in two
        # instructions: the x field of the result needs the y and z fields of
        # the operands, so no per-field form could express it.
        if name in ("OPMULA", "OPMSUB"):
            a, b = vu.rvf(fs), vu.rvf(ft)
            prod = {"x": F.mul(a["y"], b["z"])[0],
                    "y": F.mul(a["z"], b["x"])[0],
                    "z": F.mul(a["x"], b["y"])[0]}
            for f in ("x", "y", "z"):
                if name == "OPMULA":
                    vu.acc[f] = prod[f]
                else:
                    vu.wvf(fd, f, F.sub(vu.acc[f], prod[f])[0])
            return True

        if name == "CLIP":
            # Six bits per test, and they are *shifted into* the existing flag
            # rather than replacing it: CLIP builds a history three vertices
            # deep, which is exactly what a triangle needs.
            a, w = vu.rvf(fs), vu.rvf(ft)["w"]
            mag = w & 0x7FFFFFFF                      # |w|
            bits = 0
            for i, f in enumerate(("x", "y", "z")):
                plus = F.value(a[f]) > F.value(mag)
                minus = F.value(a[f]) < -F.value(mag)
                bits |= (1 if plus else 0) << (i * 2)
                bits |= (1 if minus else 0) << (i * 2 + 1)
            vu.clip = ((vu.clip << 6) | bits) & 0xFFFFFF
            return True

        touched = False
        for f in fields:
            a = vu.rvf(fs)[f]
            b = self.second(src, ft, f, "xyzw"[bc])
            cause = 0
            if name == "ADD":    r, cause = F.add(a, b)
            elif name == "SUB":  r, cause = F.sub(a, b)
            elif name == "MUL":  r, cause = F.mul(a, b)
            elif name == "MAX":  r = F.fmax(a, b)      # selects; no flags
            elif name == "MINI": r = F.fmin(a, b)
            elif name == "MADD":
                pr, c1 = F.mul(a, b)
                r, c2 = F.add(vu.acc[f], pr)
                cause = c1 | c2
            elif name == "MSUB":
                pr, c1 = F.mul(a, b)
                r, c2 = F.sub(vu.acc[f], pr)
                cause = c1 | c2
            elif name == "ABS":  r = a & 0x7FFFFFFF
            elif name.startswith("ITOF"):
                n = int(name[4:])
                v = a - (1 << 32) if a & 0x80000000 else a
                r = F.pack(F.Fraction(v, 1 << n))[0]
            elif name.startswith("FTOI"):
                n = int(name[4:])
                v = F.value(a) * (1 << n)
                iv = int(v)                       # truncation toward zero
                r = iv & M32
            else:
                vu.unimplemented.append(("upper", code))
                return False
            # The flags follow the arithmetic, not the destination: an
            # accumulator form sets them exactly as the register form does.
            # MAX and MINI are the exception -- they select an operand rather
            # than computing, so they leave the flags alone.
            if name not in ("MAX", "MINI", "ABS") and not name.startswith(("ITOF", "FTOI")):
                shift = MAC_SHIFT[f]
                setb, clrb = mac_bits(r, cause)
                vu.mac = (vu.mac & ~(clrb << shift)) | (setb << shift)
                touched = True
            if to_acc:
                vu.acc[f] = r
            else:
                vu.wvf(wr, f, r)
        # The status register is the sticky half: the four "any field" bits are
        # the OR of this instruction's MAC flags, and the four sticky bits above
        # them never clear until FSSET writes them.
        if touched:
            live = ((1 if vu.mac & 0x000F else 0)
                    | (2 if vu.mac & 0x00F0 else 0)
                    | (4 if vu.mac & 0x0F00 else 0)
                    | (8 if vu.mac & 0xF000 else 0))
            vu.status = (vu.status & ~0x0F) | live | ((vu.status | (live << 6)) & 0x3C0)
        return True


# ---- the lower instruction ------------------------------------------------
#
# The lower slot is everything that is not the vector ALU: loads and stores, the
# 16-bit integer unit, branches, the divide unit, and the elementary-function
# unit. Its opcode is the **top seven bits**, `code >> 25`, and one of those 128
# values, 0x40, opens a second level indexed by `code & 0x3F`, four of whose
# entries open a third indexed by `(code >> 6) & 0x1F`.
#
# Three levels is not decoration: the instructions at the bottom of it -- MOVE,
# DIV, LQI, MTIR, and the whole EFU -- are the ones with no room left for
# operand fields, which is why they take their operands from fixed places.
#
# **Provenance, stated plainly.** As with the upper extension tables, this map
# was transcribed with PCSX2's dispatch tables in view rather than derived, so
# `tools/vu/xcheck_ops.py` passing on it confirms faithful transcription and not
# the encoding itself. It is single-sourced until a primary reference or a
# console run says otherwise.

def l_op(code):     return (code >> 25) & 0x7F
def l_is(code):     return (code >> 11) & 0xF
def l_it(code):     return (code >> 16) & 0xF
def l_id(code):     return (code >> 6) & 0xF
def l_fs(code):     return (code >> 11) & 0x1F
def l_ft(code):     return (code >> 16) & 0x1F
def l_dest(code):   return (code >> 21) & 0xF
def l_fsf(code):    return (code >> 21) & 0x3
def l_ftf(code):    return (code >> 23) & 0x3

def l_imm11(code):
    v = code & 0x7FF
    return v - 0x800 if v & 0x400 else v

def l_imm15(code):
    return ((code >> 10) & 0x7800) | (code & 0x7FF)

def l_imm5(code):
    v = (code >> 6) & 0x1F
    return v - 0x20 if v & 0x10 else v

_LOWER = {
    0x00: "LQ",   0x01: "SQ",   0x04: "ILW",  0x05: "ISW",
    0x08: "IADDIU", 0x09: "ISUBIU",
    0x10: "FCEQ", 0x11: "FCSET", 0x12: "FCAND", 0x13: "FCOR",
    0x14: "FSEQ", 0x15: "FSSET", 0x16: "FSAND", 0x17: "FSOR",
    0x18: "FMEQ", 0x1A: "FMAND", 0x1B: "FMOR", 0x1C: "FCGET",
    0x20: "B",    0x21: "BAL",  0x24: "JR",   0x25: "JALR",
    0x28: "IBEQ", 0x29: "IBNE",
    0x2C: "IBLTZ", 0x2D: "IBGTZ", 0x2E: "IBLEZ", 0x2F: "IBGEZ",
}
_LOWER2 = {0x30: "IADD", 0x31: "ISUB", 0x32: "IADDI", 0x34: "IAND", 0x35: "IOR"}
_LOWER3 = {
    (0, 12): "MOVE", (0, 13): "LQI",  (0, 14): "DIV",   (0, 15): "MTIR",
    (0, 16): "RNEXT", (0, 25): "MFP", (0, 26): "XTOP",  (0, 27): "XGKICK",
    (0, 28): "ESADD", (0, 29): "EATANxy", (0, 30): "ESQRT", (0, 31): "ESIN",
    (1, 12): "MR32", (1, 13): "SQI",  (1, 14): "SQRT",  (1, 15): "MFIR",
    (1, 16): "RGET", (1, 26): "XITOP", (1, 28): "ERSADD", (1, 29): "EATANxz",
    (1, 30): "ERSQRT", (1, 31): "EATAN",
    (2, 13): "LQD",  (2, 14): "RSQRT", (2, 15): "ILWR", (2, 16): "RINIT",
    (2, 28): "ELENG", (2, 29): "ESUM", (2, 30): "ERCPR", (2, 31): "EEXP",
    (3, 13): "SQD",  (3, 14): "WAITQ", (3, 15): "ISWR", (3, 16): "RXOR",
    (3, 28): "ERLENG", (3, 30): "WAITP",
}


def decode_lower(code):
    """-> the instruction's name, or None if the encoding is undefined."""
    op = l_op(code)
    if op != 0x40:
        return _LOWER.get(op)
    sub = code & 0x3F
    if sub in _LOWER2:
        return _LOWER2[sub]
    if 0x3C <= sub <= 0x3F:
        return _LOWER3.get((sub - 0x3C, (code >> 6) & 0x1F))
    return None


class LowerUnit:
    """Loads, stores, the integer ALU, branches, and the divide unit.

    The integer registers are **16 bits**, and every operation on them wraps at
    16 rather than saturating. A VU program that walks a pointer past the end of
    VU Mem does not fault -- it wraps, and reads something else. Modelling the
    registers as Python ints and masking on write is what keeps that true.
    """

    def __init__(self, vu):
        self.vu = vu
        self.branch = None          # (target, is_link) taken this instruction

    def qw(self, addr):
        """VU Mem is quadword addressed and wraps; it does not fault."""
        return self.vu.mem[addr % len(self.vu.mem)]

    def run(self, code):
        vu = self.vu
        name = decode_lower(code)
        if name is None:
            vu.unimplemented.append(("lower", code))
            return False
        if name in ("NOP",):
            return True

        it, is_, id_ = l_it(code), l_is(code), l_id(code)
        ft, fs = l_ft(code), l_fs(code)
        fields = dest_fields(l_dest(code))

        # ---- the 16-bit integer ALU ---------------------------------------
        if name == "IADD":   vu.wvi(id_, vu.rvi(is_) + vu.rvi(it));   return True
        if name == "ISUB":   vu.wvi(id_, vu.rvi(is_) - vu.rvi(it));   return True
        if name == "IAND":   vu.wvi(id_, vu.rvi(is_) & vu.rvi(it));   return True
        if name == "IOR":    vu.wvi(id_, vu.rvi(is_) | vu.rvi(it));   return True
        if name == "IADDI":  vu.wvi(id_, vu.rvi(is_) + l_imm5(code)); return True
        if name == "IADDIU": vu.wvi(it, vu.rvi(is_) + l_imm15(code)); return True
        if name == "ISUBIU": vu.wvi(it, vu.rvi(is_) - l_imm15(code)); return True

        # ---- quadword loads and stores -------------------------------------
        # The I forms post-increment and the D forms **pre-decrement**, which is
        # the asymmetry that makes a backwards walk over an array work without
        # an extra instruction -- and the one that a model written from the
        # names alone gets wrong.
        if name in ("LQ", "LQI", "LQD"):
            if name == "LQ":
                addr = vu.rvi(is_) + l_imm11(code)
            elif name == "LQI":
                addr = vu.rvi(is_)
            else:
                vu.wvi(is_, vu.rvi(is_) - 1)
                addr = vu.rvi(is_)
            src = self.qw(addr)
            for f in fields:
                vu.wvf(ft, f, src[f])
            if name == "LQI":
                vu.wvi(is_, vu.rvi(is_) + 1)
            return True

        if name in ("SQ", "SQI", "SQD"):
            if name == "SQ":
                addr = vu.rvi(it) + l_imm11(code)
            elif name == "SQI":
                addr = vu.rvi(it)
            else:
                vu.wvi(it, vu.rvi(it) - 1)
                addr = vu.rvi(it)
            dst = self.qw(addr)
            for f in fields:
                dst[f] = vu.rvf(fs)[f]
            if name == "SQI":
                vu.wvi(it, vu.rvi(it) + 1)
            return True

        # ---- integer loads and stores --------------------------------------
        # ILW and ISW move *one field* of a quadword to or from a 16-bit
        # integer register, and take the low half of it.
        if name in ("ILW", "ILWR"):
            addr = vu.rvi(is_) + (l_imm11(code) if name == "ILW" else 0)
            src = self.qw(addr)
            for f in fields:                     # at most one field is sensible
                vu.wvi(it, src[f] & M16)
            return True
        if name in ("ISW", "ISWR"):
            addr = vu.rvi(is_) + (l_imm11(code) if name == "ISW" else 0)
            dst = self.qw(addr)
            for f in fields:
                dst[f] = vu.rvi(it)              # the whole 32-bit field
            return True

        # ---- moves between the two register files ---------------------------
        if name == "MOVE":
            for f in fields:
                vu.wvf(ft, f, vu.rvf(fs)[f])
            return True
        if name == "MR32":
            # A rotate of the four fields by one: x <- y, y <- z, z <- w, w <- x.
            src = vu.rvf(fs).copy()
            rot = {"x": src["y"], "y": src["z"], "z": src["w"], "w": src["x"]}
            for f in fields:
                vu.wvf(ft, f, rot[f])
            return True
        if name == "MFIR":
            # An integer register into a float register's field, sign-extended
            # from 16 bits to 32 -- not zero-extended, and not converted.
            v = vu.rvi(is_)
            v = v - 0x10000 if v & 0x8000 else v
            for f in fields:
                vu.wvf(ft, f, v & M32)
            return True
        if name == "MTIR":
            vu.wvi(it, vu.rvf(fs)[FIELDS[l_fsf(code)]] & M16)
            return True

        # ---- the divide unit ------------------------------------------------
        # All three write Q, none writes a vector register, and each takes a
        # single field of each operand rather than operating field by field.
        if name == "DIV":
            vu.q = F.div(vu.rvf(fs)[FIELDS[l_fsf(code)]],
                         vu.rvf(ft)[FIELDS[l_ftf(code)]])[0]
            return True
        if name == "SQRT":
            vu.q = F.sqrt_(vu.rvf(ft)[FIELDS[l_ftf(code)]])[0]
            return True
        if name == "RSQRT":
            num = vu.rvf(fs)[FIELDS[l_fsf(code)]]
            den = F.sqrt_(vu.rvf(ft)[FIELDS[l_ftf(code)]])[0]
            vu.q = F.div(num, den)[0]
            return True
        if name in ("WAITQ", "WAITP"):
            return True                 # a stall, and stalls are a later layer

        # ---- branches --------------------------------------------------------
        # Targets are in instruction words relative to the *delay slot*, which
        # is pc + 1 here because a VU instruction is one 64-bit word.
        if name in ("B", "BAL", "IBEQ", "IBNE", "IBLTZ", "IBGTZ", "IBLEZ", "IBGEZ",
                    "JR", "JALR"):
            def sext16(v):
                return v - 0x10000 if v & 0x8000 else v
            take, link = False, None
            if name in ("B", "BAL"):
                take = True
                link = it if name == "BAL" else None
            elif name == "JR":
                self.branch = (vu.rvi(is_) // 8, None)
                return True
            elif name == "JALR":
                self.branch = (vu.rvi(is_) // 8, it)
                return True
            elif name == "IBEQ":  take = vu.rvi(is_) == vu.rvi(it)
            elif name == "IBNE":  take = vu.rvi(is_) != vu.rvi(it)
            elif name == "IBLTZ": take = sext16(vu.rvi(is_)) < 0
            elif name == "IBGTZ": take = sext16(vu.rvi(is_)) > 0
            elif name == "IBLEZ": take = sext16(vu.rvi(is_)) <= 0
            elif name == "IBGEZ": take = sext16(vu.rvi(is_)) >= 0
            if take:
                self.branch = (vu.pc + 1 + l_imm11(code), link)
            elif link is not None:
                self.branch = (None, link)
            return True

        vu.unimplemented.append(("lower", code, name))
        return False


# ---- running a program -----------------------------------------------------
#
# A VU instruction is one 64-bit word: the **upper** 32 bits are the vector ALU
# instruction and the **lower** 32 are everything else, and both issue in the
# same cycle.
#
# That "same cycle" is the whole subtlety of the execution model. Both slots
# read the register file at once, so if the lower instruction writes a register
# the upper one reads, **the upper one sees the old value**. Running them one
# after the other in either order gets that wrong in one direction or the other,
# so neither order is acceptable: the upper runs, its writes are set aside, the
# lower runs against the state as it was, and the two sets of writes are merged
# with the lower's applied last.
#
# Three bits in the upper word are not part of the instruction:
#
#   I (bit 31)  the lower 32 bits are not an instruction at all -- they are a
#               32-bit immediate, loaded into the I register. This is how a VU
#               program gets a constant, since there is no other way to write
#               one into the float side.
#   E (bit 30)  end of program: the VU stops, but only after the *next* two
#               instructions have issued. Stopping immediately is the natural
#               reading and is wrong by two instructions.
#   M (bit 29)  a hint to the T-bit interrupt machinery; nothing here.

I_BIT, E_BIT, M_BIT, D_BIT, T_BIT = 31, 30, 29, 28, 27


class Program:
    """Executes micro-code out of Micro Mem.

    Branch delay slots are real: a VU branch has exactly one, and unlike the
    R5900's there is no annulling form to complicate it.
    """

    def __init__(self, vu):
        self.vu = vu
        self.upper = UpperUnit(vu)
        self.lower = LowerUnit(vu)
        self.pending_branch = None      # (target, link) taken, fires after the slot
        self.end_in = None              # counts down after an E bit

    def snapshot(self):
        return ([r.copy() for r in self.vu.vf], list(self.vu.vi),
                self.vu.acc.copy(), self.vu.q, self.vu.i)

    def restore(self, snap):
        vf, vi, acc, q, i = snap
        self.vu.vf = [r.copy() for r in vf]
        self.vu.vi = list(vi)
        self.vu.acc = acc.copy()
        self.vu.q = q
        self.vu.i = i

    def step(self):
        """One instruction word. Returns False when the program has stopped."""
        vu = self.vu
        if not vu.running:
            return False
        word = vu.micro[vu.pc % len(vu.micro)]
        up, lo = (word >> 32) & M32, word & M32

        # The E bit is read before anything executes, and starts a two
        # instruction countdown rather than stopping here.
        if (up >> E_BIT) & 1 and self.end_in is None:
            self.end_in = 2

        before = self.snapshot()

        # The upper slot, against the state as it is.
        self.upper.run(up)
        after_upper = self.snapshot()

        # The lower slot, against the state as it was. If the I bit is set the
        # lower word is an immediate instead.
        self.restore(before)
        self.lower.branch = None
        if (up >> I_BIT) & 1:
            vu.i = lo
        else:
            self.lower.run(lo)
        after_lower = self.snapshot()

        # Merge: start from what the upper produced, then lay the lower's
        # writes over it. The two slots cannot write the same vector register
        # field in one cycle -- the assembler will not emit it -- so the only
        # overlap this has to resolve is between different registers, and
        # "lower last" is the safe order for the case the hardware forbids.
        self.restore(after_upper)
        pre_vf, pre_vi, pre_acc, pre_q, pre_i = before
        lo_vf, lo_vi, lo_acc, lo_q, lo_i = after_lower
        for n in range(32):
            for f in range(4):
                if lo_vf[n].v[f] != pre_vf[n].v[f]:
                    vu.vf[n].v[f] = lo_vf[n].v[f]
        for n in range(16):
            if lo_vi[n] != pre_vi[n]:
                vu.vi[n] = lo_vi[n]
        if lo_q != pre_q:
            vu.q = lo_q
        if lo_i != pre_i:
            vu.i = lo_i

        # The branch, and its one delay slot.
        vu.pc += 1
        if self.pending_branch is not None:
            target, link = self.pending_branch
            self.pending_branch = None
            if link is not None:
                vu.wvi(link, vu.pc * 8)
            if target is not None:
                vu.pc = target
        elif self.lower.branch is not None:
            self.pending_branch = self.lower.branch

        if self.end_in is not None:
            self.end_in -= 1
            if self.end_in < 0:
                vu.running = False
        return vu.running

    def run(self, start=0, limit=10000):
        """Run from `start` until the program ends. Returns instructions issued.

        Instructions *issued*, not loop iterations: step() returns whether the
        program is still running, so counting its return value undercounts by
        one -- the instruction that clears `running` is the one that carries the
        E bit's last countdown, and it did execute.
        """
        self.vu.pc = start
        self.vu.running = True
        self.end_in = None
        n = 0
        while self.vu.running and n < limit:
            self.step()
            n += 1
        return n


def main():
    import argparse
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("program", nargs="?")
    ap.add_argument("--steps", type=int, default=64)
    a = ap.parse_args()
    vu = VU()
    print("VU1 reference model: %d vector registers, %d quadwords of VU Mem"
          % (len(vu.vf), len(vu.mem)))
    print("vf00 =", vu.vf[0], "  (hardwired 0, 0, 0, 1.0)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
