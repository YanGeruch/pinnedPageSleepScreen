#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/types.h>

#include "xovi.h"

#ifndef VERSION
#define VERSION "dev"
#endif

#define FBSPY_TYPE_RGBA 2

struct FramebufferConfig {
    void *framebufferAddress;
    int width, height, type, bpl;
    _Bool requiresReload;
};

/* Cached at first capture. The fb pointer is captured once by framebuffer-spy
 * and stays valid for xochitl's lifetime (same assumption rm-shot relies on).
 * The Move fb is BGRX32 — byte-identical to 32bpp BI_RGB BMP pixels, so the
 * whole capture is row memcpys under a prebuilt header. */
static struct {
    int ready;
    const uint8_t *fb;
    int rows, cols, stride;
    uint8_t *bmp;            /* header + pixels, reused every shot */
    size_t bmpSize, rowBytes;
} S;

static void putU16(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; }
static void putU32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }

static int initOnce(void) {
    if (S.ready) return 1;
    if (!(void *)framebuffer_spy$getFramebufferConfig) return 0;
    struct FramebufferConfig cfg =
        ((struct FramebufferConfig (*)(void)) framebuffer_spy$getFramebufferConfig)();
    if (!cfg.framebufferAddress || cfg.type != FBSPY_TYPE_RGBA) {
        fprintf(stderr, "[fastshot]: no usable framebuffer (addr=%p type=%d)\n",
                cfg.framebufferAddress, cfg.type);
        return 0;
    }
    S.fb = cfg.framebufferAddress;
    S.rows = cfg.height;
    S.stride = cfg.bpl;
    /* Move buffer is 960 px wide, panel shows 954; other devices uncropped */
    S.cols = (cfg.width == 960) ? 954 : cfg.width;
    S.rowBytes = (size_t)S.cols * 4;
    S.bmpSize = 54 + S.rowBytes * (size_t)S.rows;
    S.bmp = malloc(S.bmpSize);
    if (!S.bmp) return 0;
    memset(S.bmp, 0, 54);
    S.bmp[0] = 'B'; S.bmp[1] = 'M';
    putU32(S.bmp + 2, (uint32_t)S.bmpSize);
    putU32(S.bmp + 10, 54);
    putU32(S.bmp + 14, 40);
    putU32(S.bmp + 18, (uint32_t)S.cols);
    putU32(S.bmp + 22, (uint32_t)(-S.rows));  /* negative height = top-down */
    putU16(S.bmp + 26, 1);
    putU16(S.bmp + 28, 32);
    S.ready = 1;
    fprintf(stderr, "[fastshot]: init %dx%d stride=%d file=%zuB\n",
            S.cols, S.rows, S.stride, S.bmpSize);
    return 1;
}

static long usSince(const struct timespec *t0) {
    struct timespec t1;
    clock_gettime(CLOCK_MONOTONIC, &t1);
    return (t1.tv_sec - t0->tv_sec) * 1000000L + (t1.tv_nsec - t0->tv_nsec) / 1000;
}

static void mkdirForFile(const char *path) {
    char dir[512];
    const char *slash = strrchr(path, '/');
    if (!slash || slash == path) return;
    size_t len = (size_t)(slash - path);
    if (len >= sizeof(dir)) return;
    memcpy(dir, path, len);
    dir[len] = 0;
    for (char *p = dir + 1; *p; p++) {
        if (*p == '/') {
            *p = 0;
            mkdir(dir, 0755);
            *p = '/';
        }
    }
    mkdir(dir, 0755);
}

/* Runs synchronously in the caller's (QML) thread: when sendSimpleSignal
 * returns "ok:...", the file is complete and atomically in place. */
char *fastShotHandler(const char *param) {
    if (!param || !param[0]) return strdup("failed:noparam");
    if (!initOnce()) return strdup("failed:nofb");

    struct timespec t0;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    const uint8_t *src = S.fb;
    uint8_t *dst = S.bmp + 54;
    for (int y = 0; y < S.rows; y++) {
        memcpy(dst, src, S.rowBytes);
        src += S.stride;
        dst += S.rowBytes;
    }
    long copyUs = usSince(&t0);

    char tmp[560];
    if (snprintf(tmp, sizeof(tmp), "%s.part", param) >= (int)sizeof(tmp))
        return strdup("failed:path");
    mkdirForFile(tmp);
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        fprintf(stderr, "[fastshot]: open %s failed: %s\n", tmp, strerror(errno));
        return strdup("failed:open");
    }
    size_t off = 0;
    while (off < S.bmpSize) {
        ssize_t w = write(fd, S.bmp + off, S.bmpSize - off);
        if (w <= 0) { close(fd); unlink(tmp); return strdup("failed:write"); }
        off += (size_t)w;
    }
    close(fd);
    if (rename(tmp, param) != 0) { unlink(tmp); return strdup("failed:rename"); }
    long totalUs = usSince(&t0);

    char ret[640];
    snprintf(ret, sizeof(ret), "ok:%s:copy_us=%ld,total_us=%ld", param, copyUs, totalUs);
    fprintf(stderr, "[fastshot]: %s\n", ret);
    return strdup(ret);
}

void _xovi_construct() {
    fprintf(stderr, "[fastshot]: loaded (" VERSION ")\n");
}
