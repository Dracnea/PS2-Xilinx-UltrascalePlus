#!/usr/bin/env python3
"""A small MIPS I (R3000) assembler for the IOP bring-up ROMs.

    asm_r3000.py input.s output.hex [--base 0xBFC00000] [--size WORDS]

Two-pass, one instruction per line, `label:` on its own line or before an
instruction, `#` comments, `.org ADDR`, `.word`, `.align N`.  Delay slots are
the programmer's (write the nop).  Pseudo-ops: li, la, move, b, nop.  Output is
one hex word per line covering [base, base+size), which is what the
testbench's $readmemh and iop_ram's ROM port expect.  No macros, no relocation:
this exists so the test programs need no cross toolchain on the build box.
"""
import re, sys

REGS = {f"${i}": i for i in range(32)}
REGS.update({"$zero":0,"$at":1,"$v0":2,"$v1":3,"$a0":4,"$a1":5,"$a2":6,"$a3":7,
             "$t0":8,"$t1":9,"$t2":10,"$t3":11,"$t4":12,"$t5":13,"$t6":14,"$t7":15,
             "$s0":16,"$s1":17,"$s2":18,"$s3":19,"$s4":20,"$s5":21,"$s6":22,"$s7":23,
             "$t8":24,"$t9":25,"$k0":26,"$k1":27,"$gp":28,"$sp":29,"$fp":30,"$s8":30,"$ra":31})

R_OPS = {"addu":0x21,"subu":0x23,"and":0x24,"or":0x25,"xor":0x26,"nor":0x27,"slt":0x2A,"sltu":0x2B,
         "add":0x20,"sub":0x22}
SH_OPS = {"sll":0x00,"srl":0x02,"sra":0x03}
I_OPS = {"addiu":0x09,"addi":0x08,"andi":0x0C,"ori":0x0D,"xori":0x0E,"slti":0x0A,"sltiu":0x0B}
MEM_OPS = {"lb":0x20,"lh":0x21,"lw":0x23,"lbu":0x24,"lhu":0x25,"sb":0x28,"sh":0x29,"sw":0x2B}
BR_OPS = {"beq":0x04,"bne":0x05}

def reg(t):
    t = t.strip()
    if t not in REGS: raise ValueError(f"bad register {t}")
    return REGS[t]

def imm(t, labels):
    t = t.strip()
    if t in labels: return labels[t]
    if t.startswith("%hi(") and t.endswith(")"):
        v = imm(t[4:-1], labels); return ((v + 0x8000) >> 16) & 0xFFFF
    if t.startswith("%lo(") and t.endswith(")"):
        return imm(t[4:-1], labels) & 0xFFFF
    return int(t, 0) & 0xFFFFFFFF

def parse_mem(t):
    m = re.match(r"\s*(-?\w+)?\s*\(\s*(\$\w+)\s*\)\s*$", t)
    if not m: raise ValueError(f"bad memory operand {t}")
    return (m.group(1) or "0"), m.group(2)

def encode(op, args, pc, labels):
    out = []
    a = [x.strip() for x in args.split(",")] if args.strip() else []
    if op == "nop": return [0]
    if op in R_OPS:
        rd, rs, rt = reg(a[0]), reg(a[1]), reg(a[2]); return [(rs<<21)|(rt<<16)|(rd<<11)|R_OPS[op]]
    if op in SH_OPS:
        rd, rt, sa = reg(a[0]), reg(a[1]), int(a[2],0); return [(rt<<16)|(rd<<11)|(sa<<6)|SH_OPS[op]]
    if op in ("sllv","srlv","srav"):
        rd, rt, rs = reg(a[0]), reg(a[1]), reg(a[2]); fn = {"sllv":4,"srlv":6,"srav":7}[op]; return [(rs<<21)|(rt<<16)|(rd<<11)|fn]
    if op in I_OPS:
        rt, rs, v = reg(a[0]), reg(a[1]), imm(a[2], labels) & 0xFFFF; return [(I_OPS[op]<<26)|(rs<<21)|(rt<<16)|v]
    if op == "lui":
        rt, v = reg(a[0]), imm(a[1], labels) & 0xFFFF; return [(0x0F<<26)|(rt<<16)|v]
    if op in MEM_OPS:
        rt = reg(a[0]); off, base = parse_mem(a[1]); v = imm(off, labels) & 0xFFFF
        return [(MEM_OPS[op]<<26)|(reg(base)<<21)|(rt<<16)|v]
    if op in BR_OPS:
        rs, rt, target = reg(a[0]), reg(a[1]), imm(a[2], labels)
        off = ((target - (pc + 4)) >> 2) & 0xFFFF; return [(BR_OPS[op]<<26)|(rs<<21)|(rt<<16)|off]
    if op in ("bgez","bltz","blez","bgtz","bgezal","bltzal"):
        rs, target = reg(a[0]), imm(a[1], labels); off = ((target - (pc + 4)) >> 2) & 0xFFFF
        if op == "blez": return [(0x06<<26)|(rs<<21)|off]
        if op == "bgtz": return [(0x07<<26)|(rs<<21)|off]
        rt = {"bltz":0,"bgez":1,"bltzal":0x10,"bgezal":0x11}[op]; return [(0x01<<26)|(rs<<21)|(rt<<16)|off]
    if op == "b":
        target = imm(a[0], labels); off = ((target - (pc + 4)) >> 2) & 0xFFFF; return [(0x04<<26)|off]
    if op in ("j","jal"):
        target = imm(a[0], labels); return [((2 if op=="j" else 3)<<26)|((target>>2)&0x3FFFFFF)]
    if op == "jr":  return [(reg(a[0])<<21)|0x08]
    if op == "jalr":
        if len(a) == 1: return [(reg(a[0])<<21)|(31<<11)|0x09]
        return [(reg(a[1])<<21)|(reg(a[0])<<11)|0x09]
    if op == "mfc0": return [(0x10<<26)|(0<<21)|(reg(a[0])<<16)|(int(a[1].lstrip("$"),0)<<11)]
    if op == "mtc0": return [(0x10<<26)|(4<<21)|(reg(a[0])<<16)|(int(a[1].lstrip("$"),0)<<11)]
    if op == "rfe":  return [(0x10<<26)|(1<<25)|0x10]
    if op in ("mult","multu","div","divu"):
        rs, rt = reg(a[0]), reg(a[1]); fn = {"mult":0x18,"multu":0x19,"div":0x1A,"divu":0x1B}[op]; return [(rs<<21)|(rt<<16)|fn]
    if op == "mflo": return [(reg(a[0])<<11)|0x12]
    if op == "mfhi": return [(reg(a[0])<<11)|0x10]
    if op == "break": return [0x0D | ((int(a[0],0) if a else 0) << 6)]
    if op == "syscall": return [0x0C]
    if op == "move": return encode("addu", f"{a[0]},{a[1]},$zero", pc, labels)
    if op in ("li","la"):
        rt, v = reg(a[0]), imm(a[1], labels)
        if op == "li" and -32768 <= (v if v < 0x80000000 else v - 0x100000000) < 32768 and (v >> 16) in (0, 0xFFFF):
            return [(0x09<<26)|(rt<<16)|(v & 0xFFFF)]
        hi, lo = (v >> 16) & 0xFFFF, v & 0xFFFF
        w = [(0x0F<<26)|(rt<<16)|hi]
        if lo: w.append((0x0D<<26)|(rt<<21)|(rt<<16)|lo)
        return w
    raise ValueError(f"unknown op {op}")

def length(op, args, labels):
    if op in ("li","la"):
        a = [x.strip() for x in args.split(",")]
        try: v = imm(a[1], labels)
        except Exception: return 2
        if op == "li" and (v >> 16) in (0, 0xFFFF) and (v < 0x8000 or v >= 0xFFFF8000): return 1
        return 2 if (v & 0xFFFF) else 1
    return 1

def assemble(src, base):
    lines = []
    for raw in src.splitlines():
        line = raw.split("#")[0].strip()
        if not line: continue
        while ":" in line:
            lab, _, rest = line.partition(":")
            lines.append(("label", lab.strip(), None)); line = rest.strip()
            if not line: break
        if not line: continue
        parts = line.split(None, 1); lines.append(("op", parts[0].lower(), parts[1] if len(parts) > 1 else ""))
    # pass 1: labels (li/la sized conservatively when the label is forward)
    labels, pc = {}, base
    for kind, op, args in lines:
        if kind == "label": labels[op] = pc; continue
        if op == ".org": pc = int(args, 0); continue
        if op == ".word": pc += 4 * len(args.split(",")); continue
        if op == ".align": n = 1 << int(args, 0); pc = (pc + n - 1) & ~(n - 1); continue
        pc += 4 * length(op, args, labels)
    # pass 2
    mem, pc = {}, base
    for kind, op, args in lines:
        if kind == "label": continue
        if op == ".org": pc = int(args, 0); continue
        if op == ".word":
            for w in args.split(","): mem[pc] = imm(w, labels); pc += 4
            continue
        if op == ".align": n = 1 << int(args, 0); pc = (pc + n - 1) & ~(n - 1); continue
        words = encode(op, args, pc, labels)
        if len(words) != length(op, args, labels):
            words = words + [0] * (length(op, args, labels) - len(words))   # pad a short li to its reserved size
        for w in words: mem[pc] = w & 0xFFFFFFFF; pc += 4
    return mem, labels

if __name__ == "__main__":
    args = sys.argv[1:]
    base, size = 0xBFC00000, 4096
    if "--base" in args: base = int(args[args.index("--base")+1], 0); del args[args.index("--base"):args.index("--base")+2]
    if "--size" in args: size = int(args[args.index("--size")+1], 0); del args[args.index("--size"):args.index("--size")+2]
    src, dst = args
    mem, labels = assemble(open(src).read(), base)
    with open(dst, "w") as f:
        for i in range(size):
            f.write("%08x\n" % mem.get(base + 4*i, 0))
    top = max(mem) - base + 4 if mem else 0
    print(f"{dst}: {top//4} words used of {size}; labels: " + ", ".join(f"{k}=0x{v:08X}" for k, v in labels.items()))
