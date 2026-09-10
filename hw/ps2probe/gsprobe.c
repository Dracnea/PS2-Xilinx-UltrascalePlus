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
/* fbp is in 8 KB pages, w and h in pixels, PSMCT32 only. */
static void readback(u32 fbp, u32 fbw, u32 w, u32 h, void *dest)
{
    u64 *p = (u64 *)gifbuf;
    u64 *tag = p;

    /* set the source rectangle up, then turn the transfer on */
    p += 2;                                   /* room for the GIFtag */
    p = ad(p, GS_SET_BITBLTBUF(fbp, fbw, FB_PSM, 0, 0, 0), GS_REG_BITBLTBUF);
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

/* ---- the subject: one Gouraud triangle with known vertex colours ------- */
static void draw_gouraud(void)
{
    u64 *p = (u64 *)gifbuf;
    u64 *tag = p;
    p += 2;

    p = ad(p, GS_SET_FRAME(0, FB_W / 64, FB_PSM, 0),        GS_REG_FRAME_1);
    p = ad(p, GS_SET_XYOFFSET(0, 0),                        GS_REG_XYOFFSET_1);
    p = ad(p, GS_SET_SCISSOR(0, FB_W - 1, 0, FB_H - 1),     GS_REG_SCISSOR_1);
    p = ad(p, GS_SET_TEST(0, 0, 0, 0, 0, 0, 1, 1),          GS_REG_TEST_1);
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

    SleepThread();
    return 0;
}
