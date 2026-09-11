/* gsprobe.c -- ask the Graphics Synthesizer what it actually does.
 *
 * Draws primitives with known vertex attributes, reads the framebuffer back
 * through the GS's Local->Host path, and prints the pixels over ps2link.  The
 * host diffs those against sim/gs/gs_ref.py, so a disagreement names a pixel
 * rather than a feeling.
 *
 * The readback is the part worth getting right, and it is done as the GS User's
 * Manual describes it: set BITBLTBUF/TRXPOS/TRXREG for the source rectangle,
 * set TRXDIR to 01 (Local->Host), set the privileged BUSDIR register to 1 to
 * turn the interface around, pull the quadwords out through VIF1 in reverse,
 * then put BUSDIR back.  Forgetting the last step leaves the machine unable to
 * accept a normal GIF packet again, which looks like a hang.
 *
 * What this is for: the interpolation rule.  ARMSX2's probes established that
 * the GS steps a block of eight pixels with the step truncated to a 2^-10 grid,
 * and that interpolated depth runs half a grid step short of its plane.  Two
 * questions their captures leave open are the first ones here:
 *
 *   - silicon pairs rows two at a time (rows k and k+2 read identically), and
 *     nothing models the vertical structure that implies;
 *   - the affine texture coordinate is truncated and may carry a block width of
 *     its own, which no capture has swept.
 *
 * Build: make -f Makefile.probe ; run: ps2client -h <ps2-ip> execee host:gsprobe.elf
 */
#include <stdio.h>
#include <string.h>
#include <kernel.h>
#include <dma.h>
#include <dma_tags.h>
#include <gif_tags.h>
#include <gs_gp.h>
#include <gs_privileged.h>
#include <graph.h>

#define FB_W   64          /* small on purpose: every pixel is printed */
#define FB_H   32
#define FB_PSM 0            /* PSMCT32; ps2sdk does not name it */
#define ZB_PAGE 4          /* the Z buffer, clear of the 64x32 frame buffer */
#define ZB_PSM 0x30        /* PSMZ32, for the readback's SPSM */

static u8 gifbuf[16 * 1024] __attribute__((aligned(64)));
static u8 back[FB_W * FB_H * 4] __attribute__((aligned(64)));

/* ---- one A+D register write, appended to a packet ---------------------- */
static u64 *ad(u64 *p, u64 data, u8 addr)
{
    *p++ = data;
    *p++ = (u64)addr;
    return p;
}

static void gif_send(u64 *start, u64 *end)
{
    u32 qwc = (u32)((end - start) / 2);
    FlushCache(0);
    dma_channel_send_normal(DMA_CHANNEL_GIF, start, qwc, 0, 0);
    dma_channel_wait(DMA_CHANNEL_GIF, 0);
}

/* ---- read a rectangle of local memory back into EE RAM ----------------- */
/* fbp is in 8 KB pages, w and h in pixels; psm selects PSMCT32 or PSMZ32,
   which are the same 32-bit-per-pixel layout under two names. */
static void readback_psm(u32 fbp, u32 fbw, u32 psm, u32 w, u32 h, void *dest)
{
    u64 *p = (u64 *)gifbuf;
    u64 *tag = p;

    /* set the source rectangle up, then turn the transfer on */
    p += 2;                                   /* room for the GIFtag */
    p = ad(p, GS_SET_BITBLTBUF(fbp, fbw, psm, 0, 0, 0), GS_REG_BITBLTBUF);
    p = ad(p, GS_SET_TRXPOS(0, 0, 0, 0, 0),   GS_REG_TRXPOS);
    p = ad(p, GS_SET_TRXREG(w, h),            GS_REG_TRXREG);
    p = ad(p, GS_SET_TRXDIR(1),               GS_REG_TRXDIR);  /* 01: Local->Host */
    {
        u32 n = (u32)((p - tag) / 2) - 1;
        tag[0] = GIF_SET_TAG(n, 1, 0, 0, GIF_FLG_PACKED, 1);
        tag[1] = GIF_REG_AD;
    }
    gif_send((u64 *)gifbuf, p);

    /* turn the bus around, pull the data out through VIF1, turn it back */
    *GS_REG_BUSDIR = GS_SET_BUSDIR(1);

    /* VIF1 run backwards is the path the data comes out on */
    dma_channel_receive_normal(DMA_CHANNEL_VIF1, dest,
                               (int)((w * h * 4) / 16), 0, 0);
    dma_channel_wait(DMA_CHANNEL_VIF1, 0);

    *GS_REG_BUSDIR = GS_SET_BUSDIR(0);
}

static void readback(u32 fbp, u32 fbw, u32 w, u32 h, void *dest)
{
    readback_psm(fbp, fbw, FB_PSM, w, h, dest);
}

/* ---- the depth probe --------------------------------------------------- */
/*
 * The depth bias is the least-verified rule in this project.  What is on
 * record, from somebody else's console, is that interpolated depth lands half a
 * grid step -- 1/2048 -- below its own plane; that along x the shortfall is
 * there from the span's first pixel and ignores the gradient's sign; that along
 * y it accumulates, follows the sign, and is exempt on the primitive's first
 * scanline; and that a flat triangle is exact.  sim/gs/gs_ref.py implements
 * exactly that, in one function called _zbias, and nothing here has ever seen a
 * console disagree or agree.
 *
 * Two probes settle it, and they are deliberately different shapes:
 *
 *   ZPROBE ygrad -- a triangle with depth varying only down y and not across
 *     x.  Every pixel on a scanline should read the same value, so the printed
 *     rows collapse to one number each and the y half of the bias is the only
 *     thing that can move them.  It is also the shape that answers the open
 *     question about row pairing: if silicon really does read rows k and k+2
 *     identically, this print shows it as repeated values without any analysis.
 *
 *   ZPROBE xgrad -- depth varying only across x.  A gradient of 1/4 is the
 *     identity under 2^-10 truncation, so a run with that gradient must
 *     reproduce the exact plane; anything else confirms the grid rather than
 *     the bias.  The gradient here is deliberately not 1/4.
 *
 * Both use ZTST = ALWAYS with ZMSK = 0 so that every pixel writes its
 * interpolated depth and nothing is filtered out by the test itself.
 */
static void draw_zgrad(int along_y)
{
    u64 *p = (u64 *)gifbuf;
    u64 *tag = p;
    u32 z0 = 0x00100000, z1 = 0x00100000 + (along_y ? 0 : 0x2000),
        z2 = 0x00100000 + (along_y ? 0x2000 : 0);
    p += 2;

    p = ad(p, GS_SET_FRAME(0, FB_W / 64, FB_PSM, 0),        GS_REG_FRAME_1);
    p = ad(p, GS_SET_XYOFFSET(0, 0),                        GS_REG_XYOFFSET_1);
    p = ad(p, GS_SET_SCISSOR(0, FB_W - 1, 0, FB_H - 1),     GS_REG_SCISSOR_1);
    /* ZTE = 1, ZTST = ALWAYS: every pixel passes and writes its depth */
    p = ad(p, GS_SET_TEST(0, 0, 0, 0, 0, 0, 1, 1),          GS_REG_TEST_1);
    p = ad(p, GS_SET_ZBUF(ZB_PAGE, ZB_PSM & 0xF, 0),        GS_REG_ZBUF_1);
    /* flat shading: the colour is not the subject and must not vary */
    p = ad(p, GS_SET_PRIM(GS_PRIM_TRIANGLE, 0, 0, 0, 0, 0, 0, 0, 0), GS_REG_PRIM);
    {
        u32 n = (u32)((p - tag) / 2) - 1;
        tag[0] = GIF_SET_TAG(n, 1, 0, 0, GIF_FLG_PACKED, 1);
        tag[1] = GIF_REG_AD;
    }
    gif_send((u64 *)gifbuf, p);

    p = (u64 *)gifbuf;
    tag = p;
    p += 2;
    p = ad(p, GS_SET_RGBAQ(64, 64, 64, 128, 0), GS_REG_RGBAQ);
    p = ad(p, GS_SET_XYZ(0 << 4, 0 << 4, z0),                GS_REG_XYZ2);
    p = ad(p, GS_SET_XYZ((FB_W - 1) << 4, 0 << 4, z1),       GS_REG_XYZ2);
    p = ad(p, GS_SET_XYZ(0 << 4, (FB_H - 1) << 4, z2),       GS_REG_XYZ2);
    {
        u32 n = (u32)((p - tag) / 2) - 1;
        tag[0] = GIF_SET_TAG(n, 1, 0, 0, GIF_FLG_PACKED, 1);
        tag[1] = GIF_REG_AD;
    }
    gif_send((u64 *)gifbuf, p);
}

/* ---- the depth clamp probe --------------------------------------------- */
/*
 * A depth too wide for the Z buffer's format: does it clamp to the format's
 * maximum, or does it wrap?
 *
 * This project models clamping, taken from PCSX2, which does it twice over --
 * min_u32 on the vertex and a scanline clamp gated on whether the primitive's
 * maximum depth exceeds the format.  The GS User's Manual gives the three Z
 * formats in 2.3.2 and never says what happens to a value that will not fit.
 * Nothing here has seen a console decide it.
 *
 * The two answers are far apart and need no analysis to tell apart, which is
 * what makes this worth asking directly.  A **sprite** is used rather than a
 * triangle because a sprite's depth is an integer from its second vertex and
 * never interpolates, so the depth bias -- the other unverified rule on this
 * page -- cannot contaminate the answer.
 *
 * PSMZ24 with a PSMCT32 frame buffer is the pair to use: the manual's 2.5.4
 * only allows a frame and Z format from the same group, PSMZ24 is in the same
 * group as PSMCT32, and PSMZ24 is addressed exactly as PSMZ32 is -- so the
 * existing readback reaches it unchanged.
 *
 * With Z = 0x01234567 written into a 24-bit buffer:
 *
 *     clamped   -> 0xFFFFFF
 *     truncated -> 0x234567
 *
 * The top byte of a PSMZ24 word is not part of the value and may read back as
 * anything, so compare only the low 24 bits.
 */
#define ZCLAMP_Z 0x01234567u

static void draw_zclamp(void)
{
    u64 *p = (u64 *)gifbuf;
    u64 *tag = p;
    p += 2;

    p = ad(p, GS_SET_FRAME(0, FB_W / 64, FB_PSM, 0),        GS_REG_FRAME_1);
    p = ad(p, GS_SET_XYOFFSET(0, 0),                        GS_REG_XYOFFSET_1);
    p = ad(p, GS_SET_SCISSOR(0, FB_W - 1, 0, FB_H - 1),     GS_REG_SCISSOR_1);
    /* ZTE = 1, ZTST = ALWAYS, ZMSK = 0: every pixel writes its depth */
    p = ad(p, GS_SET_TEST(0, 0, 0, 0, 0, 0, 1, 1),          GS_REG_TEST_1);
    p = ad(p, GS_SET_ZBUF(ZB_PAGE, 0x31 & 0xF, 0),          GS_REG_ZBUF_1);
    p = ad(p, GS_SET_PRIM(GS_PRIM_SPRITE, 0, 0, 0, 0, 0, 0, 0, 0), GS_REG_PRIM);
    {
        u32 n = (u32)((p - tag) / 2) - 1;
        tag[0] = GIF_SET_TAG(n, 1, 0, 0, GIF_FLG_PACKED, 1);
        tag[1] = GIF_REG_AD;
    }
    gif_send((u64 *)gifbuf, p);

    p = (u64 *)gifbuf;
    tag = p;
    p += 2;
    p = ad(p, GS_SET_RGBAQ(64, 64, 64, 128, 0), GS_REG_RGBAQ);
    /* A sprite takes its depth from the *second* vertex, so the first carries a
       different one: if it were ever used the readback would say so. */
    p = ad(p, GS_SET_XYZ(0 << 4, 0 << 4, 0x00000001),                 GS_REG_XYZ2);
    p = ad(p, GS_SET_XYZ(FB_W << 4, FB_H << 4, ZCLAMP_Z),             GS_REG_XYZ2);
    {
        u32 n = (u32)((p - tag) / 2) - 1;
        tag[0] = GIF_SET_TAG(n, 1, 0, 0, GIF_FLG_PACKED, 1);
        tag[1] = GIF_REG_AD;
    }
    gif_send((u64 *)gifbuf, p);
}

/* ---- the subject: one Gouraud triangle with known vertex colours ------- */
static void draw_gouraud(void)
{
    u64 *p = (u64 *)gifbuf;
    u64 *tag = p;
    p += 2;

    p = ad(p, GS_SET_FRAME(0, FB_W / 64, FB_PSM, 0),        GS_REG_FRAME_1);
    p = ad(p, GS_SET_XYOFFSET(0, 0),                        GS_REG_XYOFFSET_1);
    p = ad(p, GS_SET_SCISSOR(0, FB_W - 1, 0, FB_H - 1),     GS_REG_SCISSOR_1);
    /* ALWAYS with ZMSK set is the manual's own way of saying "no depth test":
       it leaves the Z buffer neither accessed nor updated.  Saying it explicitly
       matters here, because ZBUF_1 is whatever the last program left in it and a
       depth write to an arbitrary page would corrupt memory this probe does not
       own -- including, on an unlucky boot, itself. */
    p = ad(p, GS_SET_TEST(0, 0, 0, 0, 0, 0, 1, 1),          GS_REG_TEST_1);
    p = ad(p, GS_SET_ZBUF(ZB_PAGE, ZB_PSM & 0xF, 1),        GS_REG_ZBUF_1);
    /* IIP = 1 selects Gouraud; the colours below are what gets interpolated */
    p = ad(p, GS_SET_PRIM(GS_PRIM_TRIANGLE, 1, 0, 0, 0, 0, 0, 0, 0), GS_REG_PRIM);
    {
        u32 n = (u32)((p - tag) / 2) - 1;
        tag[0] = GIF_SET_TAG(n, 1, 0, 0, GIF_FLG_PACKED, 1);
        tag[1] = GIF_REG_AD;
    }
    gif_send((u64 *)gifbuf, p);

    /* three vertices, each with a primary colour, so every channel has a
       gradient of its own and one readback answers all four at once */
    p = (u64 *)gifbuf;
    tag = p;
    p += 2;
    p = ad(p, GS_SET_RGBAQ(255, 0, 0, 128, 0), GS_REG_RGBAQ);
    p = ad(p, GS_SET_XYZ(0 << 4, 0 << 4, 0),                 GS_REG_XYZ2);
    p = ad(p, GS_SET_RGBAQ(0, 255, 0, 128, 0), GS_REG_RGBAQ);
    p = ad(p, GS_SET_XYZ((FB_W - 1) << 4, 0 << 4, 0),        GS_REG_XYZ2);
    p = ad(p, GS_SET_RGBAQ(0, 0, 255, 128, 0), GS_REG_RGBAQ);
    p = ad(p, GS_SET_XYZ(0 << 4, (FB_H - 1) << 4, 0),        GS_REG_XYZ2);
    {
        u32 n = (u32)((p - tag) / 2) - 1;
        tag[0] = GIF_SET_TAG(n, 1, 0, 0, GIF_FLG_PACKED, 1);
        tag[1] = GIF_REG_AD;
    }
    gif_send((u64 *)gifbuf, p);
}

int main(void)
{
    u32 x, y;

    dma_channel_initialize(DMA_CHANNEL_GIF, NULL, 0);
    dma_channel_initialize(DMA_CHANNEL_VIF1, NULL, 0);
    dma_channel_fast_waits(DMA_CHANNEL_GIF);

    printf("gsprobe: start\n");
    memset(back, 0, sizeof(back));

    draw_gouraud();
    readback(0, FB_W / 64, FB_W, FB_H, back);

    /* One line per row, so a diff names a row and a column.  The host script
       parses these straight into the same form sim/gs/gs_ref.py prints. */
    printf("PROBE gouraud %ux%u psm32\n", FB_W, FB_H);
    for (y = 0; y < FB_H; y++)
    {
        printf("ROW %02u", y);
        for (x = 0; x < FB_W; x++)
            printf(" %08x", ((u32 *)back)[y * FB_W + x]);
        printf("\n");
    }
    printf("PROBE end\n");

    /* depth, twice: down y, then across x */
    {
        int pass;
        for (pass = 0; pass < 2; pass++)
        {
            memset(back, 0, sizeof(back));
            draw_zgrad(pass == 0);
            readback_psm(ZB_PAGE, FB_W / 64, ZB_PSM, FB_W, FB_H, back);
            printf("ZPROBE %s %ux%u psmz32\n",
                   pass == 0 ? "ygrad" : "xgrad", FB_W, FB_H);
            for (y = 0; y < FB_H; y++)
            {
                printf("ZROW %02u", y);
                for (x = 0; x < FB_W; x++)
                    printf(" %08x", ((u32 *)back)[y * FB_W + x]);
                printf("\n");
            }
            printf("ZPROBE end\n");
        }
    }

    /* the depth clamp: one sprite, one number, two possible answers */
    {
        u32 v;
        memset(back, 0, sizeof(back));
        draw_zclamp();
        readback_psm(ZB_PAGE, FB_W / 64, ZB_PSM, FB_W, FB_H, back);
        v = ((u32 *)back)[0] & 0x00FFFFFFu;
        printf("ZCPROBE psmz24 wrote %08x read %06x -> %s\n",
               ZCLAMP_Z, v,
               v == 0x00FFFFFFu ? "CLAMP"
               : (v == (ZCLAMP_Z & 0x00FFFFFFu) ? "TRUNCATE" : "NEITHER"));
        /* print a few more in case the first pixel is not representative */
        for (y = 0; y < 4; y++)
        {
            printf("ZCROW %02u", y);
            for (x = 0; x < 8; x++)
                printf(" %06x", ((u32 *)back)[y * FB_W + x] & 0x00FFFFFFu);
            printf("\n");
        }
        printf("ZCPROBE end\n");
    }

    SleepThread();
    return 0;
}
