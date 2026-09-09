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

static volatile int keep_running = 1;
static void on_int(int s) { (void)s; keep_running = 0; }

static int64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
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
    if (litepcie_dma_init(&dma, device, 0)) return 1;
    int fd = dma.fds.fd;

    printf("staging %.2f MiB of %s at HBM 0x%09llx\n",
           total / 1048576.0, image, (unsigned long long)base);

    write_csr64(fd, CSR_HBM_DMA_BASE_ADDR, CSR_HBM_DMA_BASE_SIZE, base);
    litepcie_writel(fd, CSR_HBM_DMA_LENGTH_ADDR, (uint32_t)total);
    litepcie_writel(fd, CSR_HBM_DMA_CTRL_ADDR, 1);        // start

    dma.reader_enable = 1;
    signal(SIGINT, on_int);

    uint64_t sent = 0;
    int64_t  t0 = now_ms(), last = t0;
    int      eof = 0;

    while (keep_running && sent < total) {
        litepcie_dma_process(&dma);
        while (sent < total) {
            char *buf = litepcie_dma_next_write_buffer(&dma);
            if (!buf) break;
            size_t chunk = DMA_BUFFER_SIZE;
            if (total - sent < chunk) chunk = total - sent;
            size_t got = eof ? 0 : fread(buf, 1, chunk, f);
            if (got < chunk) {
                // Pad rather than stop: the engine was told `total` bytes and
                // will not finish a burst it never receives.
                memset(buf + got, 0, DMA_BUFFER_SIZE - got);
                eof = 1;
            }
            if (chunk < DMA_BUFFER_SIZE) memset(buf + chunk, 0, DMA_BUFFER_SIZE - chunk);
            sent += chunk;
        }
        int64_t t = now_ms();
        if (verbose && t - last > 500) {
            uint32_t w = litepcie_readl(fd, CSR_HBM_DMA_WRITTEN_ADDR);
            printf("\r  %.0f%%  host %.0f MiB  card %.0f MiB  %.2f GB/s   ",
                   100.0 * sent / total, sent / 1048576.0, w / 1048576.0,
                   sent / ((t - t0) / 1000.0) / 1e9);
            fflush(stdout);
            last = t;
        }
    }

    // Let the ring drain into the card before reading the counter.
    for (int i = 0; i < 200; i++) { litepcie_dma_process(&dma); usleep(1000); }
    int64_t t1 = now_ms();

    uint32_t stat    = litepcie_readl(fd, CSR_HBM_DMA_STAT_ADDR);
    uint32_t written = litepcie_readl(fd, CSR_HBM_DMA_WRITTEN_ADDR);
    double   secs    = (t1 - t0) / 1000.0;

    printf("\r%-72s\n", "");
    printf("host sent   %llu bytes in %.2f s  (%.2f GB/s)\n",
           (unsigned long long)sent, secs, sent / secs / 1e9);
    printf("card wrote  %u bytes to HBM\n", written);
    printf("busy=%u done=%u axi_resp=%u\n", stat & 1, (stat >> 1) & 1, (stat >> 2) & 3);
    (void)read_csr64;

    litepcie_dma_cleanup(&dma);
    fclose(f);

    if (written != (uint32_t)total) {
        fprintf(stderr, "FAIL: the card wrote %u of %llu bytes\n",
                written, (unsigned long long)total);
        return 1;
    }
    if (((stat >> 2) & 3) != 0) {
        fprintf(stderr, "FAIL: AXI response %u\n", (stat >> 2) & 3);
        return 1;
    }
    printf("PASS\n");
    return 0;
}
