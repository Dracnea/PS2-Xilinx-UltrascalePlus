#!/usr/bin/env python3
"""Test compare.py without a PlayStation 2.

    hw/ps2probe/selftest.py

compare.py is the half of this probe that can be tested on this machine, and
until 2026-09-11 neither half had ever been run.  The idea is simple: if the
console agreed with the model everywhere, `ps2client` would print exactly what
the model itself produces -- so build that log, feed it to compare.py, and
require a clean match.  Then perturb it and require a complaint.

**This found a real fault the first time it was run.**  `model()` read the depth
buffer back without the block exclusive-or that the depth formats address with,
while the reference had started *writing* with it hours earlier.  1536 of the
probe's 2048 depth pixels came out wrong, and against a console that would have
looked like a hardware discovery rather than a bug on this side -- which is the
exact failure the warning at the top of compare.py describes, arriving by the
exact route it predicts.

Exit status is 0 when every case behaves as it should.
"""
import importlib.util, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "sim", "gs"))
_spec = importlib.util.spec_from_file_location("cmp", os.path.join(HERE, "compare.py"))
C = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(C)


def console_log(perturb=None, clamp="CLAMP"):
    """The log a console that agreed with the model would print."""
    out = []
    g = C.model(C.stream_gouraud(), 0)
    if perturb:
        r, c = perturb
        g[r][c] ^= 0x00010000
    out.append("gsprobe: start")
    out.append("PROBE gouraud %ux%u psm32" % (C.FB_W, C.FB_H))
    for y, row in enumerate(g):
        out.append("ROW %02u %s" % (y, " ".join("%08x" % v for v in row)))
    out.append("PROBE end")
    for name, along_y in (("ygrad", True), ("xgrad", False)):
        # BLK_Z, because the console reads the depth buffer back by asking for
        # PSMZ32 and the transfer therefore undoes the depth swizzle.
        z = C.model(C.stream_zgrad(along_y), C.ZB_PAGE, C.BLK_Z)
        out.append("ZPROBE %s %ux%u psmz32" % (name, C.FB_W, C.FB_H))
        for y, row in enumerate(z):
            out.append("ZROW %02u %s" % (y, " ".join("%08x" % v for v in row)))
        out.append("ZPROBE end")
    read = 0xFFFFFF if clamp == "CLAMP" else (0x01234567 & 0xFFFFFF)
    out.append("ZCPROBE psmz24 wrote 01234567 read %06x -> %s" % (read, clamp))
    for y in range(4):
        out.append("ZCROW %02u %s" % (y, " ".join("%06x" % read for _ in range(8))))
    out.append("ZCPROBE end")
    return "\n".join(out) + "\n"


def run(text):
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
        f.write(text)
        path = f.name
    try:
        p = subprocess.run([sys.executable, os.path.join(HERE, "compare.py"), path],
                           capture_output=True, text=True)
        return p.returncode, p.stdout
    finally:
        os.unlink(path)


def main():
    bad = 0

    rc, out = run(console_log())
    if rc != 0 or "everything the console drew matches" not in out:
        print("FAIL  a console that agrees is reported as a disagreement")
        print(out)
        bad += 1
    else:
        print("agreeing console:   clean match, as it should be")

    rc, out = run(console_log(perturb=(7, 13)))
    if rc == 0 or "1 pixels differ" not in out:
        print("FAIL  one wrong pixel was not noticed")
        print(out)
        bad += 1
    else:
        print("one wrong pixel:    caught, and named by coordinate")

    rc, out = run(console_log(clamp="TRUNCATE"))
    if rc == 0 or "does NOT model" not in out:
        print("FAIL  a console that truncates depth was not noticed")
        print(out)
        bad += 1
    else:
        print("depth truncating:   caught, with the lines to change named")

    print("PASS  compare.py behaves" if not bad else "FAIL  %d cases" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
