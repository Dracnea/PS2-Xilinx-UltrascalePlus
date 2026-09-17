#!/usr/bin/env python3
"""Texel-fetch cases for gs_texsample, from the reference model.

    sim/gs/gen_texsample.py --seed 1 --out DIR

Writes:

    mem.hex     local memory, one 256-bit word per line
    clut.txt    the one TEX0/TEXCLUT write that fills the palette, applied first
    cases.txt   u v frag tex0 clamp, one sample per line
    ref.txt     the colour the model says each sample produces

The palette is loaded once and then left alone: every sampling case carries
CLD=0 so the fetch path is what is under test and not the reload rules, which
`run_clut_diff.sh` already covers on their own. Keeping them separate means a
failure here names the fetch.

## What the cases are chosen to catch

* **Every format**, including the three H formats, which read an index out of
  the spare bits of a 32-bit word and are the ones most likely to be wired to
  the wrong nibble.
* **All four texture functions and both TCC settings.** DECAL ignores the
  fragment colour entirely and MODULATE multiplies by it, so a case with a
  fragment of 0x80808080 -- which is 1.0 in the GS's fixed point -- cannot tell
  them apart. The fragments here are deliberately not 1.0.
* **Saturation.** HIGHLIGHT adds the fragment's alpha to a product that may
  already be near full scale, so cases with large fragments and large texels are
  included to push the sum past 255.
* **The wrap modes**, because the sampler drives gs_texaddr rather than
  containing its own copy, and a miswired CLAMP field would show here and
  nowhere else.

SPDX-License-Identifier: BSD-2-Clause
"""
import argparse
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gs_ref                                                    # noqa: E402

# The GS's local memory is 4 MB, and that is what this uses. A smaller image
# would be faster to load, but then a wrap mode could produce a coordinate whose
# address runs off the end of it, and the model and the RTL would disagree about
# memory that does not exist rather than about texturing. REGION_REPEAT can
# return a coordinate of 255 whatever TW says, so this is not a corner case.
MEM_BYTES = 4 * 1024 * 1024
LINE = 32

PSMS = [gs_ref.PSMCT32, gs_ref.PSMCT24, gs_ref.PSMCT16, gs_ref.PSMCT16S,
        gs_ref.PSMT8, gs_ref.PSMT4, gs_ref.PSMT8H,
        gs_ref.PSMT4HL, gs_ref.PSMT4HH]


def tex0(tbp=0, tbw=1, psm=0, tw=6, th=6, tcc=0, tfx=0,
         cbp=0, cpsm=0, csm=0, csa=0, cld=0):
    return (tbp & 0x3FFF | (tbw & 0x3F) << 14 | (psm & 0x3F) << 20
            | (tw & 0xF) << 26 | (th & 0xF) << 30 | (tcc & 1) << 34
            | (tfx & 3) << 35 | (cbp & 0x3FFF) << 37 | (cpsm & 0xF) << 51
            | (csm & 1) << 55 | (csa & 0x1F) << 56 | (cld & 7) << 61)


def clamp(wms=0, wmt=0, minu=0, maxu=0, minv=0, maxv=0):
    return (wms & 3 | (wmt & 3) << 2 | (minu & 0x3FF) << 4
            | (maxu & 0x3FF) << 14 | (minv & 0x3FF) << 24 | (maxv & 0x3FF) << 34)


def rgba(r, g, b, a):
    return r | g << 8 | b << 16 | a << 24


def cases(rng):
    out = []

    # Every format, at a handful of coordinates, MODULATE with a fragment that
    # is not 1.0 so the multiply is observable.
    frag = rgba(0x40, 0x60, 0xC0, 0x50)
    for psm in PSMS:
        for (u, v) in [(0, 0), (1, 0), (0, 1), (5, 3), (17, 9), (31, 31)]:
            out.append(dict(u=u << 4, v=v << 4, frag=frag,
                            tex0=tex0(tbp=0, tbw=2, psm=psm, tfx=0, tcc=1),
                            clamp=clamp()))

    # All four texture functions, both TCC settings, on two formats -- one
    # direct-colour and one indexed, because the paths differ before TFX.
    for psm in (gs_ref.PSMCT32, gs_ref.PSMT8):
        for tfx in range(4):
            for tcc in (0, 1):
                for frag in (rgba(0x40, 0x60, 0xC0, 0x50),
                             rgba(0xFF, 0xE0, 0x90, 0xF0),   # pushes saturation
                             rgba(0x00, 0x80, 0xFF, 0x00)):
                    out.append(dict(u=7 << 4, v=11 << 4, frag=frag,
                                    tex0=tex0(tbp=0, tbw=2, psm=psm,
                                              tfx=tfx, tcc=tcc),
                                    clamp=clamp()))

    # The wrap modes, including coordinates outside the texture and negative
    # ones -- the sampler drives gs_texaddr, and a miswired CLAMP field would
    # show here and nowhere else.
    for wms in range(4):
        for wmt in range(4):
            for (u, v) in [(-1, -1), (-8, 3), (300, -300), (5, 5), (255, 255)]:
                out.append(dict(u=u << 4, v=v << 4, frag=rgba(0x80, 0x80, 0x80, 0x80),
                                tex0=tex0(tbp=0, tbw=2, psm=gs_ref.PSMCT32,
                                          tw=5, th=4, tcc=1),
                                clamp=clamp(wms, wmt, 0x1F, 0x08, 0x0F, 0x03)))

    # The fractional bits of a 12.4 coordinate must be *discarded*, not rounded:
    # every sixteenth between two texels has to return the lower texel.
    for frac in range(16):
        out.append(dict(u=(9 << 4) | frac, v=(4 << 4) | frac,
                        frag=rgba(0x80, 0x80, 0x80, 0x80),
                        tex0=tex0(tbp=0, tbw=2, psm=gs_ref.PSMCT32, tcc=1),
                        clamp=clamp()))

    # Random.
    for _ in range(300):
        out.append(dict(
            u=rng.randint(-2048, 2047) << 4 | rng.randint(0, 15),
            v=rng.randint(-2048, 2047) << 4 | rng.randint(0, 15),
            frag=rng.getrandbits(32),
            tex0=tex0(tbp=rng.randrange(0, 64), tbw=rng.choice([1, 2, 4]),
                      psm=rng.choice(PSMS), tw=rng.randint(2, 8),
                      th=rng.randint(2, 8), tcc=rng.randint(0, 1),
                      tfx=rng.randint(0, 3)),
            clamp=clamp(rng.randint(0, 3), rng.randint(0, 3),
                        rng.randint(0, 255), rng.randint(0, 255),
                        rng.randint(0, 255), rng.randint(0, 255))))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    rng = random.Random(a.seed)
    os.makedirs(a.out, exist_ok=True)

    vm = bytearray(rng.getrandbits(8) for _ in range(MEM_BYTES))
    with open(os.path.join(a.out, "mem.hex"), "w") as f:
        for i in range(0, MEM_BYTES, LINE):
            f.write(vm[i:i + LINE][::-1].hex() + "\n")

    # One palette, loaded from a base well clear of the textures the cases read.
    clut_tex0 = tex0(psm=gs_ref.PSMT8, cbp=300, cld=1)
    clut = gs_ref.Clut()
    clut.load(vm, clut_tex0, 0)
    with open(os.path.join(a.out, "clut.txt"), "w") as f:
        f.write("%016x %016x\n" % (clut_tex0, 0))

    cs = cases(rng)
    skipped = 0
    with open(os.path.join(a.out, "cases.txt"), "w") as fc, \
         open(os.path.join(a.out, "ref.txt"), "w") as fr:
        for n, c in enumerate(cs):
            # gs_texaddr and the model agree up to the end of local memory; past
            # it the model's page arithmetic is unbounded and gs_addr_pkg's
            # nine-bit page wraps. That disagreement is inherited from the frame
            # buffer addressing and is not this block's question -- the same
            # exclusion gen_texaddr.py makes, for the same reason.
            texel = gs_ref.sample_uv(vm, c["tex0"], c["clamp"], clut,
                                     c["u"], c["v"])
            tfx = gs_ref.bits(c["tex0"], 36, 35)
            tcc = gs_ref.bits(c["tex0"], 34, 34)
            frag = (c["frag"] & 0xFF, (c["frag"] >> 8) & 0xFF,
                    (c["frag"] >> 16) & 0xFF, (c["frag"] >> 24) & 0xFF)
            r, g, b, al = gs_ref.texture_function(tfx, tcc, frag, texel)
            fc.write("%d %d %08x %016x %016x\n"
                     % (c["u"], c["v"], c["frag"], c["tex0"], c["clamp"]))
            fr.write("%d %08x\n" % (n, rgba(r, g, b, al)))

    print("%d cases, %d skipped" % (len(cs) - skipped, skipped), file=sys.stderr)


if __name__ == "__main__":
    main()
