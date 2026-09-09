// hbm_dma_stage.c -- put a disc image into the card's HBM at PCIe speed.
//
//   hbm_dma_stage <image> [-d /dev/litepcie0] [-b <hbm base>] [-o <byte offset>]
//                         [-n <bytes>] [-v]
//
// The other staging tool, tools/ps2iop/hbm_stage.py, writes through the HBM
// probe: about ten CSR round trips per 32-byte beat, which is right for a few
// sectors and hopeless for a game -- a 4 GiB image would take most of a day.
// This one hands the image to LitePCIe's host-to-card DMA, which lands it in
// HBM with no CSR in the data path at all.
//
// It is C rather than Python because the DMA is a ring of mmap'd buffers driven
// through ioctls; liblitepcie already does that properly and there is no reason
// to reimplement it badly.  Everything else in tools/ps2iop stays Python.
//
// Build:  make -C build/<image>/software/user  (this file is added by
//         tools/ps2iop/build-dma-stage.sh, which points gcc at that tree's
//         liblitepcie and csr.h -- the addresses must match the bitstream on
//         the card, which is the same rule as everywhere else here.)

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <signal.h>

#include "liblitepcie.h"
#include "csr.h"

#ifndef CSR_HBM_DMA_BASE_ADDR
#error "this bitstream has no HBM DMA writer; rebuild boards/c1100_ps2_iop.py"
#endif

// Matches dma_buffering_depth in boards/c1100_ps2_iop.py, which is also the
// gateware's reset value for this register (32'h400).
#define DMA_READER_BUFFERING_DEPTH 1024

static volatile int keep_running = 1;
static void on_int(int s) { (void)s; keep_running = 0; }

static int64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

// The writer reports which AXI phase it is sitting in.  "busy" alone cannot
// tell AW from W from B, and those three fail for entirely different reasons,
// which is the whole point of the instrumented build.
static const char *dma_state_name(uint32_t stat)
{
    switch ((stat >> CSR_HBM_DMA_STAT_STATE_OFFSET) & 0xf) {
    case 0:  return "IDLE";
    case 1:  return "AW";
    case 2:  return "W";
    case 3:  return "B";
    default: return "?";
    }
}

// A LiteX CSR wider than 32 bits is several words, most significant first, and
// a CSRStorage latches when its last word is written -- so write low address to
// high.  Getting this wrong is invisible: the register simply keeps half of
// whatever it held, which is exactly how the HBM probe first looked like a
// memory that ignores its address lines.
static void write_csr64(int fd, uint32_t addr, int words, uint64_t v)
{
    for (int i = 0; i < words; i++)
        litepcie_writel(fd, addr + 4 * i, (uint32_t)(v >> (32 * (words - 1 - i))));
}

static uint64_t read_csr64(int fd, uint32_t addr, int words)
{
    uint64_t v = 0;
    for (int i = 0; i < words; i++)
        v = (v << 32) | litepcie_readl(fd, addr + 4 * i);
    return v;
}

int main(int argc, char **argv)
{
    const char *device = "/dev/litepcie0";
    const char *image  = NULL;
    uint64_t base   = 0;               // HBM byte address; 0 is the disc region
    uint64_t offset = 0;               // byte offset into the image
    uint64_t want   = 0;               // 0 = to the end of the file
    int verbose = 0;

    for (int i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "-d") && i + 1 < argc) device = argv[++i];
        else if (!strcmp(argv[i], "-b") && i + 1 < argc) base   = strtoull(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "-o") && i + 1 < argc) offset = strtoull(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "-n") && i + 1 < argc) want   = strtoull(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "-v")) verbose = 1;
        else if (argv[i][0] != '-' && !image) image = argv[i];
        else { fprintf(stderr, "usage: %s <image> [-d dev] [-b base] [-o offset] [-n bytes] [-v]\n", argv[0]); return 1; }
    }
    if (!image) { fprintf(stderr, "no image given\n"); return 1; }

    FILE *f = fopen(image, "rb");
    if (!f) { perror(image); return 1; }
    if (fseeko(f, 0, SEEK_END)) { perror("seek"); return 1; }
    off_t size = ftello(f);
    if (offset > (uint64_t)size) { fprintf(stderr, "offset past the end of the image\n"); return 1; }
    uint64_t total = want ? want : (uint64_t)size - offset;
    if (offset + total > (uint64_t)size) total = (uint64_t)size - offset;
    // The engine writes whole 32-byte beats in bursts of 16, so round the
    // request down to a burst and say so, rather than writing a partial burst
    // whose tail would be undefined.
    uint64_t granule = 16 * 32;
    if (total % granule) {
        uint64_t t = (total / granule) * granule;
        fprintf(stderr, "note: %llu bytes rounded down to %llu (a 512-byte burst)\n",
                (unsigned long long)total, (unsigned long long)t);
        total = t;
    }
    if (!total) { fprintf(stderr, "nothing to stage\n"); return 1; }
    if (fseeko(f, offset, SEEK_SET)) { perror("seek"); return 1; }

    struct litepcie_dma_ctrl dma = { .use_reader = 1 };
    // Zero-copy: the mmap'd ring rotates one buffer at a time, so every buffer
    // is filled once and sent once.  The copy-through path hands the driver the
    // whole user buffer on each call and restarts from its beginning, so any
    // round where write() accepts less than all of it re-sends stale bytes --
    // invisible at 1 MiB, corruption at disc sizes.
    if (litepcie_dma_init(&dma, device, 1)) return 1;
    int fd = dma.fds.fd;

    // Restore the DMA Reader buffering depth, which litepcie_dma_init() has
    // just silently zeroed.
    //
    // The driver writes its loopback-enable flag to a fixed offset 0x40 from the
    // DMA base (PCIE_DMA_LOOPBACK_ENABLE_OFFSET in its config.h).  That offset
    // only holds the loopback CSR in a design built with `with_dma_loopback`.
    // This design sets it False, so no loopback register exists and
    // `buffering_reader_fifo_control` occupies base+0x40 instead -- and
    // litepcie_dma_init() calls litepcie_dma_set_loopback(fd, 0) every time.
    //
    // A depth of zero is not merely a smaller buffer: the buffering FIFO accepts
    // a word only while `level < depth`, so zero means it never accepts one, the
    // DMA Reader's output stream is backpressured forever and no data reaches
    // HBM.  Descriptors still retire and the table still drains, because
    // retirement follows the PCIe completions rather than the data being
    // consumed -- which is what makes the failure look like a stuck HBM writer.
#ifdef CSR_PCIE_DMA0_BUFFERING_READER_FIFO_CONTROL_ADDR
    litepcie_writel(fd, CSR_PCIE_DMA0_BUFFERING_READER_FIFO_CONTROL_ADDR,
                    DMA_READER_BUFFERING_DEPTH);
    uint32_t bufctl = litepcie_readl(fd, CSR_PCIE_DMA0_BUFFERING_READER_FIFO_CONTROL_ADDR);
    if ((bufctl & 0xffffff) != DMA_READER_BUFFERING_DEPTH) {
        fprintf(stderr, "FAIL: reader buffering depth reads %u, wanted %u\n",
                bufctl & 0xffffff, DMA_READER_BUFFERING_DEPTH);
        return 1;
    }
#endif

    printf("staging %.2f MiB of %s at HBM 0x%09llx\n",
           total / 1048576.0, image, (unsigned long long)base);

    signal(SIGINT, on_int);

    uint64_t sent = 0;
    int      eof  = 0;
    int64_t  t0, last;

    // Stage in ring-sized chunks, with the reader stopped while the ring is
    // filled.
    //
    // The DMA Reader runs its descriptor table in loop mode: once enabled it
    // streams the ring continuously and never waits for software.  reader_sw_count
    // is advisory bookkeeping, not a gate -- hw_count outruns it -- so no
    // fill-ahead loop can be relied on to win that race, and losing it puts real
    // disc data at the wrong offsets rather than producing anything that looks
    // like damage.
    //
    // So do not race.  Stopping the reader resets the data FIFO, the converter
    // and the buffering FIFO (each is held in reset by ~enable), and the packer
    // is flushed by `start`, so nothing survives a chunk boundary.  Fill the
    // whole ring, arm the writer for exactly those bytes, then let it run: the
    // reader walks descriptors 0..N-1 in order over data that is already in
    // place, which is ordered by construction rather than by timing.
    const uint64_t CHUNK = (uint64_t)DMA_BUFFER_COUNT * DMA_BUFFER_SIZE;
    struct litepcie_ioctl_mmap_dma_update upd;
    int64_t hw = 0, sw = 0;

    t0 = now_ms(); last = t0;

    while (keep_running && sent < total) {
        uint64_t chunk = total - sent;
        if (chunk > CHUNK) chunk = CHUNK;
        int64_t nbuf = (chunk + DMA_BUFFER_SIZE - 1) / DMA_BUFFER_SIZE;

        // Reader off: every downstream FIFO is flushed and the counts reset.
        litepcie_dma_reader(fd, 0, &hw, &sw);

        for (int64_t i = 0; i < nbuf; i++) {
            char  *buf   = dma.buf_wr + i * DMA_BUFFER_SIZE;
            size_t want  = DMA_BUFFER_SIZE;
            if (chunk - i * DMA_BUFFER_SIZE < want) want = chunk - i * DMA_BUFFER_SIZE;
            size_t got   = eof ? 0 : fread(buf, 1, want, f);
            if (got < want) { eof = 1; memset(buf + got, 0, DMA_BUFFER_SIZE - got); }
            else if (want < DMA_BUFFER_SIZE) memset(buf + want, 0, DMA_BUFFER_SIZE - want);
        }

        // Arm the writer for this chunk, at its own place in HBM.
        write_csr64(fd, CSR_HBM_DMA_BASE_ADDR, CSR_HBM_DMA_BASE_SIZE, base + sent);
        litepcie_writel(fd, CSR_HBM_DMA_LENGTH_ADDR, (uint32_t)chunk);
        litepcie_writel(fd, CSR_HBM_DMA_CTRL_ADDR, 1);

        // Go.  The ring already holds the data the descriptors point at.
        litepcie_dma_reader(fd, 1, &hw, &sw);
        upd.sw_count = nbuf;
        checked_ioctl(fd, LITEPCIE_IOCTL_MMAP_DMA_READER_UPDATE, &upd);

        int64_t deadline = now_ms() + 5000;
        uint32_t st = 0, w = 0, wlast = 0xffffffff;
        while (now_ms() < deadline) {
            st = litepcie_readl(fd, CSR_HBM_DMA_STAT_ADDR);
            if ((st >> CSR_HBM_DMA_STAT_DONE_OFFSET) & 1) break;
            w = litepcie_readl(fd, CSR_HBM_DMA_WRITTEN_ADDR);
            if (w != wlast) { wlast = w; deadline = now_ms() + 1000; }
        }
        if (!((st >> CSR_HBM_DMA_STAT_DONE_OFFSET) & 1)) {
            litepcie_dma_reader(fd, 0, &hw, &sw);
            fprintf(stderr, "\nFAIL: chunk at %llu stalled: %s written=%u of %llu\n",
                    (unsigned long long)sent, dma_state_name(st),
                    litepcie_readl(fd, CSR_HBM_DMA_WRITTEN_ADDR),
                    (unsigned long long)chunk);
            litepcie_dma_cleanup(&dma); fclose(f);
            return 1;
        }
        sent += chunk;

        int64_t t = now_ms();
        if (verbose && t - last > 500) {
            printf("\r  %.0f%%  %.0f MiB  %.2f GB/s   ", 100.0 * sent / total,
                   sent / 1048576.0, sent / ((t - t0) / 1000.0) / 1e9);
            fflush(stdout);
            last = t;
        }
    }
    litepcie_dma_reader(fd, 0, &hw, &sw);
    dma.reader_sw_count = sw; dma.reader_hw_count = hw;
    int64_t t1 = now_ms();

    uint32_t stat    = litepcie_readl(fd, CSR_HBM_DMA_STAT_ADDR);
    uint32_t written = litepcie_readl(fd, CSR_HBM_DMA_WRITTEN_ADDR);
    uint32_t bursts  = litepcie_readl(fd, CSR_HBM_DMA_BURSTS_ADDR);
    uint32_t stalled = (stat >> CSR_HBM_DMA_STAT_STALLED_OFFSET) & 1;
    double   secs    = (t1 - t0) / 1000.0;

    printf("\r%-72s\n", "");
    printf("host sent   %llu bytes in %.2f s  (%.2f GB/s)\n",
           (unsigned long long)sent, secs, sent / secs / 1e9);
    printf("card wrote  %llu bytes to HBM in %llu chunks (last chunk %u bytes)\n",
           (unsigned long long)sent,
           (unsigned long long)((total + CHUNK - 1) / CHUNK), written);
    printf("dma reader  sw_count=%lld hw_count=%lld\n",
           (long long)dma.reader_sw_count, (long long)dma.reader_hw_count);
    printf("busy=%u done=%u axi_resp=%u state=%s bursts=%u stalled=%u\n",
           stat & 1, (stat >> 1) & 1, (stat >> 2) & 3,
           dma_state_name(stat), bursts, stalled);

    // Say what those numbers mean while the failure is in front of the person
    // reading them, rather than leaving it to be worked out from the source.
    if ((stat & 1) && sent != total) {
        if (!bursts)
            printf("  -> stuck in %s with no burst accepted: HBM never answered an address.\n",
                   dma_state_name(stat));
        else if (stalled)
            printf("  -> stuck in W after %u bursts: HBM answered, the host is not feeding beats.\n",
                   bursts);
        else
            printf("  -> stuck in %s after %u bursts: the write channel or its B response is not completing.\n",
                   dma_state_name(stat), bursts);
    }
    (void)read_csr64;

    litepcie_dma_cleanup(&dma);
    fclose(f);

    if (sent != total) {
        fprintf(stderr, "FAIL: the card wrote %llu of %llu bytes\n",
                (unsigned long long)sent, (unsigned long long)total);
        return 1;
    }
    if (((stat >> 2) & 3) != 0) {
        fprintf(stderr, "FAIL: AXI response %u\n", (stat >> 2) & 3);
        return 1;
    }
    printf("PASS\n");
    return 0;
}
