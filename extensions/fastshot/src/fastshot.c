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
#include <pthread.h>
#include <stdatomic.h>

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

/* Abort generation (0.8.0). A queued async shot that fires AFTER a sleep entry
 * grabs the caller's own sleep window, not the document, and its fixed path
 * would overwrite the fresh synchronous capture taken at entry. fastAbortShots
 * bumps this; a thread compares its spawn-time value UNDER captureLock, so the
 * decision is strictly ordered against every other capture: a thread that has
 * not grabbed yet returns without grabbing or writing, and one already mid-grab
 * finishes (the abort caller's own synchronous grab is then later, fresher, and
 * lands on the same path). Late arrivals are DISCARDED, never deferred. */
static _Atomic unsigned shotGen = 0;

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
struct asyncShotArg {
    char *param;
    unsigned gen;
};

static void *asyncShotThread(void *argp) {
    struct asyncShotArg *a = (struct asyncShotArg *)argp;
    char *arg = a->param;
    char *comma = strrchr(arg, ',');
    int delay = 0;
    if (comma) { delay = atoi(comma + 1); *comma = 0; }
    if (delay > 0) usleep((useconds_t)delay * 1000);
    pthread_mutex_lock(&captureLock);
    /* re-checked INSIDE the lock, immediately before the grab: an abort that
     * lands while a previous capture holds the lock must still cancel us */
    if (atomic_load(&shotGen) != a->gen) {
        pthread_mutex_unlock(&captureLock);
        fprintf(stderr, "[fastshot]: async %s: aborted\n", arg);
        free(arg);
        free(a);
        return NULL;
    }
    char *r = fastShotLocked(arg);
    pthread_mutex_unlock(&captureLock);
    if (r) {
        if (strncmp(r, "ok:", 3) != 0)
            fprintf(stderr, "[fastshot]: async %s: %s\n", arg, r);
        free(r);
    }
    free(arg);
    free(a);
    return NULL;
}

char *fastShotAsyncHandler(const char *param) {
    if (!param || !param[0]) return strdup("failed:noparam");
    struct asyncShotArg *a = malloc(sizeof(*a));
    if (!a) return strdup("failed:mem");
    a->param = strdup(param);
    /* captured BEFORE the thread exists: an abort racing the spawn must be
     * seen as a mismatch, never be missed by starting from a re-read value */
    a->gen = atomic_load(&shotGen);
    if (!a->param) { free(a); return strdup("failed:mem"); }
    pthread_t th;
    if (pthread_create(&th, NULL, asyncShotThread, a) != 0) {
        free(a->param);
        free(a);
        return strdup("failed:thread");
    }
    pthread_detach(th);
    return strdup("queued");
}

/* Cancels every async shot queued so far that has not yet reached its grab.
 * Called by the mod at sleep entry, before its own synchronous capture: a shot
 * grabbed after the switch contains the sleep window itself (the v0.15
 * feedback-loop class), so it is discarded rather than kept. Param ignored. */
char *fastAbortShotsHandler(const char *param) {
    (void)param;
    unsigned g = atomic_fetch_add(&shotGen, 1) + 1;
    char ret[32];
    snprintf(ret, sizeof(ret), "ok:%u", g);
    return strdup(ret);
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

/* Existence + freshness probe (sendSimpleSignal("fastStat", path)), returning
 * "ok:<size>,<mtime_ms>" or "failed:...". The sleep window uses it to refuse a
 * chapter whose pixels predate the metadata that describes them: captureNow()
 * publishes pinned.json BEFORE the detached grab lands, so the reused ch1..ch3
 * name can still hold the previous occupant's image (another document's, right
 * after a re-pin). Reading the whole BMP through fastRead just to learn it
 * exists was the old test — this one is two syscalls and carries the mtime.
 * stat, not lstat: a symlinked chapter should answer for its target.
 * mtime_ms FLOORS (like Date.now()), so the QML's `mtime >= ts` comparison is
 * exact rather than rounding a fresh file into the past. */
char *fastStatHandler(const char *param) {
    if (!param || !param[0]) return strdup("failed:noparam");
    struct stat st;
    if (stat(param, &st) != 0) return strdup("failed:stat");
    long long ms = (long long)st.st_mtim.tv_sec * 1000LL
        + (long long)st.st_mtim.tv_nsec / 1000000LL;
    char ret[96];
    snprintf(ret, sizeof(ret), "ok:%lld,%lld", (long long)st.st_size, ms);
    return strdup(ret);
}

/* param = "<path>\n<x>,<y>,<w>,<h>[\n<nx>,<ny>[,<step>]]" — Rec.601 luma
 * (0-255) over that rectangle of a fastshot BMP. Without the grid line:
 * "ok:<mean>", the single whole-rect mean (pre-0.9.0 form, unchanged). With
 * it: "ok:l:c,l:c,..." — per-cell mean luma AND mean chroma (max(R,G,B) -
 * min(R,G,B), 0.10.0) of an nx-by-ny grid over the rect, row-major. Chroma
 * exists because luma alone cannot tell WHITE from LIGHT (a uniform light
 * blue means ~205 and passed the white-page test); white/grey chroma is ~0,
 * any tint is not. <step> samples every step-th ROW only (each row is one
 * pread — skipping rows is where the I/O actually goes; columns are cheap
 * once a row is in memory), so a 120-row band at step 8 reads ~15 rows and
 * stays sub-ms even on a Pro-sized frame. The grid rides the SAME signal
 * because broker matching is registered-name-PREFIX based: a "fastLumaGrid"
 * name would be swallowed by "fastLuma". An old .so ignores the extra line
 * (sscanf stops after the rect) and answers the single mean — callers treat
 * a comma-less reply as every cell at once, degrading to the average, and a
 * 0.9.0 reply carries no ":c" — callers treat missing chroma as 0.
 * Must be SYNCHRONOUS and cheap: no decode exists (our own BMPs are 32bpp
 * BI_RGB, one pread per row of interest).
 * Legacy rm-shot PNG chapters are not BMPs and deliberately fail here
 * ("failed:format") — the QML falls back to the fail-safe treatment rather
 * than guessing. The rect is CLAMPED to the image, never validated: the
 * caller derives it from window geometry, which may differ from the captured
 * framebuffer by the Move's 960->954 crop. Reads the file, not S.fb: the
 * pixels that matter are the ones in the shot being displayed, which by
 * decide time is no longer what the framebuffer holds. */
#define LUMA_GRID_MAX 64
char *fastLumaHandler(const char *param) {
    if (!param || !param[0]) return strdup("failed:noparam");
    const char *nl = strchr(param, '\n');
    if (!nl || nl == param || !nl[1]) return strdup("failed:param");
    char path[512];
    size_t plen = (size_t)(nl - param);
    if (plen >= sizeof(path)) return strdup("failed:path");
    memcpy(path, param, plen);
    path[plen] = 0;
    long rx, ry, rw, rh;
    if (sscanf(nl + 1, "%ld,%ld,%ld,%ld", &rx, &ry, &rw, &rh) != 4)
        return strdup("failed:rect");
    long nx = 1, ny = 1, step = 1;
    int gridForm = 0;
    const char *nl2 = strchr(nl + 1, '\n');
    if (nl2 && nl2[1]) {
        int got2 = sscanf(nl2 + 1, "%ld,%ld,%ld", &nx, &ny, &step);
        if (got2 < 2)
            return strdup("failed:grid");
        if (got2 < 3) step = 1;
        if (nx < 1 || ny < 1 || nx * ny > LUMA_GRID_MAX
                || step < 1 || step > 64)
            return strdup("failed:grid");
        gridForm = 1;
    }

    int fd = open(path, O_RDONLY);
    if (fd < 0) return strdup("failed:open");

    uint8_t hdr[54];
    ssize_t got = pread(fd, hdr, sizeof(hdr), 0);
    if (got != (ssize_t)sizeof(hdr) || hdr[0] != 'B' || hdr[1] != 'M') {
        close(fd);
        return strdup("failed:format");
    }
    uint32_t off = (uint32_t)hdr[10] | ((uint32_t)hdr[11] << 8)
        | ((uint32_t)hdr[12] << 16) | ((uint32_t)hdr[13] << 24);
    int32_t iw = (int32_t)((uint32_t)hdr[18] | ((uint32_t)hdr[19] << 8)
        | ((uint32_t)hdr[20] << 16) | ((uint32_t)hdr[21] << 24));
    int32_t ih = (int32_t)((uint32_t)hdr[22] | ((uint32_t)hdr[23] << 8)
        | ((uint32_t)hdr[24] << 16) | ((uint32_t)hdr[25] << 24));
    uint16_t bpp = (uint16_t)((uint16_t)hdr[28] | ((uint16_t)hdr[29] << 8));
    uint32_t comp = (uint32_t)hdr[30] | ((uint32_t)hdr[31] << 8)
        | ((uint32_t)hdr[32] << 16) | ((uint32_t)hdr[33] << 24);
    /* our own writer's shape only — anything else is not ours to interpret */
    if (bpp != 32 || comp != 0 || iw <= 0 || ih == 0) {
        close(fd);
        return strdup("failed:format");
    }
    /* negative height = top-down (what fastShot writes); positive = the
     * classic bottom-up order, where image row y lives at file row H-1-y */
    int topDown = ih < 0;
    long rows = topDown ? -(long)ih : (long)ih;
    size_t rowBytes = (size_t)iw * 4;

    if (rx < 0) { rw += rx; rx = 0; }
    if (ry < 0) { rh += ry; ry = 0; }
    if (rx + rw > iw) rw = iw - rx;
    if (ry + rh > rows) rh = rows - ry;
    if (rw <= 0 || rh <= 0) { close(fd); return strdup("failed:rect"); }

    /* a grid finer than the clamped rect would leave starved cells — the
     * caller's rects are tens of px at minimum, so this only fires on a
     * rect that was mostly off-image, which IS a caller error. The step
     * must leave every cell ROW at least one sampled line. */
    if (nx > rw || ny > rh || step > rh / ny) {
        close(fd);
        return strdup("failed:grid");
    }

    uint8_t *line = malloc((size_t)rw * 4);
    if (!line) { close(fd); return strdup("failed:mem"); }

    uint64_t sumL[LUMA_GRID_MAX] = {0}, sumC[LUMA_GRID_MAX] = {0},
             n[LUMA_GRID_MAX] = {0};
    for (long y = 0; y < rh; y += step) {
        long fileRow = topDown ? (ry + y) : (rows - 1 - (ry + y));
        off_t at = (off_t)off + (off_t)fileRow * (off_t)rowBytes
            + (off_t)rx * 4;
        if (pread(fd, line, (size_t)rw * 4, at) != (ssize_t)rw * 4) {
            free(line);
            close(fd);
            return strdup("failed:read");
        }
        long cyBase = (y * ny / rh) * nx;
        /* BGRX byte order (the Move framebuffer's, copied verbatim by
         * fastShot); Rec.601 in fixed point, 77/150/29 over 256 */
        for (long x = 0; x < rw; x++) {
            const uint8_t *p = line + x * 4;
            long c = cyBase + x * nx / rw;
            sumL[c] += (77u * p[2] + 150u * p[1] + 29u * p[0]) >> 8;
            uint8_t hi = p[0] > p[1] ? p[0] : p[1], lo = p[0] < p[1] ? p[0] : p[1];
            if (p[2] > hi) hi = p[2];
            if (p[2] < lo) lo = p[2];
            sumC[c] += (uint64_t)(hi - lo);
            n[c]++;
        }
    }
    free(line);
    close(fd);

    /* no grid line keeps the exact pre-grid reply shape ("ok:<mean>") */
    char ret[16 + 8 * LUMA_GRID_MAX];
    size_t at = (size_t)snprintf(ret, sizeof(ret), "ok:");
    for (long c = 0; c < nx * ny; c++) {
        if (!n[c]) return strdup("failed:rect");
        if (gridForm)
            at += (size_t)snprintf(ret + at, sizeof(ret) - at, "%s%d:%d",
                                   c ? "," : "", (int)(sumL[c] / n[c]),
                                   (int)(sumC[c] / n[c]));
        else
            at += (size_t)snprintf(ret + at, sizeof(ret) - at, "%d",
                                   (int)(sumL[c] / n[c]));
        if (at >= sizeof(ret)) return strdup("failed:mem");
    }
    return strdup(ret);
}

/* param = "<path>\n<content>" — synchronous atomic write (.part + rename),
 * no capture. Lets QML publish a power.json record with the same
 * first-read-guaranteed ordering as fastShot's sidecar when the screen
 * itself must NOT be captured (passcode lock). */
char *fastWriteHandler(const char *param) {
    if (!param || !param[0]) return strdup("failed:noparam");
    const char *nl = strchr(param, '\n');
    if (!nl || nl == param || !nl[1]) return strdup("failed:param");
    char path[512];
    size_t plen = (size_t)(nl - param);
    if (plen >= sizeof(path)) return strdup("failed:path");
    memcpy(path, param, plen);
    path[plen] = 0;
    if (!writeFileAtomic(path, (const uint8_t *)(nl + 1), strlen(nl + 1)))
        return strdup("failed:write");
    return strdup("ok");
}

void _xovi_construct() {
    fprintf(stderr, "[fastshot]: loaded (" VERSION ")\n");
}
