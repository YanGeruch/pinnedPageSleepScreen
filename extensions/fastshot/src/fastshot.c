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

static int writeFileAtomic(const char *path, const uint8_t *data, size_t size) {
    char tmp[560];
    if (snprintf(tmp, sizeof(tmp), "%s.part", path) >= (int)sizeof(tmp)) return 0;
    mkdirForFile(tmp);
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        fprintf(stderr, "[fastshot]: open %s failed: %s\n", tmp, strerror(errno));
        return 0;
    }
    size_t off = 0;
    while (off < size) {
        ssize_t w = write(fd, data + off, size - off);
        if (w <= 0) { close(fd); unlink(tmp); return 0; }
        off += (size_t)w;
    }
    close(fd);
    if (rename(tmp, path) != 0) { unlink(tmp); return 0; }
    return 1;
}

/* One lock serializes captures: the snapshot buffer is shared, and a sync
 * freeze capture racing an async chapter capture must not interleave. */
static pthread_mutex_t captureLock = PTHREAD_MUTEX_INITIALIZER;

/* param = "<bmpPath>[\n<sidecarPath>\n<sidecarContent>]" — the optional
 * sidecar (the mod's power.json record) is published only after the image,
 * so a reader that sees the record can rely on the image existing. */
static char *fastShotLocked(const char *param) {
    if (!param || !param[0]) return strdup("failed:noparam");
    if (!initOnce()) return strdup("failed:nofb");

    char bmpPath[512];
    const char *sidecarPath = NULL, *sidecarData = NULL;
    const char *nl = strchr(param, '\n');
    size_t plen = nl ? (size_t)(nl - param) : strlen(param);
    if (plen == 0 || plen >= sizeof(bmpPath)) return strdup("failed:path");
    memcpy(bmpPath, param, plen);
    bmpPath[plen] = 0;
    char scPath[512];
    if (nl) {
        const char *scStart = nl + 1;
        const char *nl2 = strchr(scStart, '\n');
        if (!nl2 || nl2 == scStart || !nl2[1]) return strdup("failed:sidecar");
        size_t sclen = (size_t)(nl2 - scStart);
        if (sclen >= sizeof(scPath)) return strdup("failed:sidecar");
        memcpy(scPath, scStart, sclen);
        scPath[sclen] = 0;
        sidecarPath = scPath;
        sidecarData = nl2 + 1;
    }

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

    if (!writeFileAtomic(bmpPath, S.bmp, S.bmpSize))
        return strdup("failed:write");
    if (sidecarPath && !writeFileAtomic(sidecarPath, (const uint8_t *)sidecarData,
                                        strlen(sidecarData)))
        return strdup("failed:sidecarwrite");
    long totalUs = usSince(&t0);

    char ret[640];
    snprintf(ret, sizeof(ret), "ok:%s:copy_us=%ld,total_us=%ld", bmpPath, copyUs, totalUs);
    fprintf(stderr, "[fastshot]: %s\n", ret);
    return strdup(ret);
}

/* Synchronous capture: blocks the caller (QML thread) ~70ms; on "ok:..."
 * everything is on disk. */
char *fastShotHandler(const char *param) {
    pthread_mutex_lock(&captureLock);
    char *r = fastShotLocked(param);
    pthread_mutex_unlock(&captureLock);
    return r;
}

/* Async capture for background chapter shots. param = "<path>[,<delay_ms>]"
 * (rm-shot's format, so call sites migrate by swapping the signal name).
 * Returns "queued" immediately; the write is still atomic (.part + rename),
 * so readers never see a partial file — there is just no completion signal. */
static void *asyncShotThread(void *argp) {
    char *arg = (char *)argp;
    char *comma = strrchr(arg, ',');
    int delay = 0;
    if (comma) { delay = atoi(comma + 1); *comma = 0; }
    if (delay > 0) usleep((useconds_t)delay * 1000);
    pthread_mutex_lock(&captureLock);
    char *r = fastShotLocked(arg);
    pthread_mutex_unlock(&captureLock);
    if (r) {
        if (strncmp(r, "ok:", 3) != 0)
            fprintf(stderr, "[fastshot]: async %s: %s\n", arg, r);
        free(r);
    }
    free(arg);
    return NULL;
}

char *fastShotAsyncHandler(const char *param) {
    if (!param || !param[0]) return strdup("failed:noparam");
    char *arg = strdup(param);
    if (!arg) return strdup("failed:mem");
    pthread_t th;
    if (pthread_create(&th, NULL, asyncShotThread, arg) != 0) {
        free(arg);
        return strdup("failed:thread");
    }
    pthread_detach(th);
    return strdup("queued");
}

/* Synchronous in-thread file read for QML (sendSimpleSignal("fastRead", path)).
 * Unlike QML's "synchronous" XHR this spins no nested event loop, so it is
 * safe at window birth. Returns contents, or "failed:..." (a JSON file can
 * never start with that). Config-file sized reads only. */
char *fastReadHandler(const char *param) {
    if (!param || !param[0]) return strdup("failed:noparam");
    int fd = open(param, O_RDONLY);
    if (fd < 0) return strdup("failed:open");
    enum { CAP = 262144 };
    char *buf = malloc(CAP + 1);
    if (!buf) { close(fd); return strdup("failed:mem"); }
    ssize_t total = 0, r;
    while (total < CAP && (r = read(fd, buf + total, CAP - total)) > 0)
        total += r;
    close(fd);
    buf[total] = 0;
    return buf;
}

void _xovi_construct() {
    fprintf(stderr, "[fastshot]: loaded (" VERSION ")\n");
}
