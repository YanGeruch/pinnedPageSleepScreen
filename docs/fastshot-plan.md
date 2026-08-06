# fastshot — sub-50ms framebuffer capture extension (plan)

Goal: replace rm-shot's ~550–620ms PNG pipeline with a purpose-built xovi
extension for the pinnedPageSleepScreen mod, targeting **~15–50ms end-to-end**
and a **truly synchronous** QML call. Sources studied: rm-shot (main),
rm-xovi-extensions (framebuffer-spy, xovi-message-broker), vellum (packaging).

## The one finding that shapes everything

The Move framebuffer (from framebuffer-spy's `rmppmCondition`):
**960×1696, stride 3840, Qt `Format_RGB32`** → memory byte order is
**B,G,R,X** per pixel (confirmed by rm-shot's own `convertBGRAtoRGB`:
`R = src[2], B = src[0]`). Display width is 954 (6 junk columns on the right).

An uncompressed 32bpp `BI_RGB` BMP is **exactly** B,G,R,X per pixel, and a
negative `biHeight` makes it top-down. Qt's BMP handler reads 32bpp top-down
BMPs natively, so QML `Image` loads it directly.

Therefore the entire rm-shot pipeline — BGRA→RGB pass, transform pass,
PNG/zlib encode — collapses to:

```
54-byte header, then per row (1696×): memcpy 3816 bytes (954×4) from
stride-3840 fb rows into the file. 3816 % 4 == 0 → zero BMP row padding.
```

**Zero per-pixel math.** File size 54 + 3816×1696 = 6,471,990 B (~6.2 MiB).
This beats any SIMD/restrict/-O3 rework of the existing loops, because the
loops no longer exist. (For the record, rm-shot today does 4 full-frame
passes + stb PNG: re-reads `/sys/devices/soc0/machine` per shot, 6.5MB
malloc+memcpy, per-pixel BGRA→RGB with index multiplies, a second full copy
in `transformRGB` even for ROT_0/no-crop, then `stbi_write_png` — the
slowest mainstream PNG encoder.)

## Verified plumbing facts

- **framebuffer-spy needs no rewrite.** On the Move it does zero per-shot
  work: the `QImage(uchar*,w,h,bpl,format)` constructor hook captures the fb
  pointer once at boot; `refreshFramebuffer` is a no-op
  (`requiresReload=false`; only rM1's `/dev/fb0` mmap needs `msync`).
  `getFramebufferConfig()` returns a struct copy. Depend on it, don't clone it.
- **`sendSimpleSignal` is a synchronous in-thread call.** QML →
  `XoviMessageBroker::sendSimpleSignal` → `broadcastToNative` → registered C
  handler runs **in the QML thread**; its `char*` return becomes the QML
  return value. rm-shot is only async because its handler spawns a pthread
  and returns "success" immediately. A handler that captures inline gives a
  genuine blocking native call — no nested event loop (unlike QML sync XHR),
  nothing can interleave. This is a structural race eliminator, not a speed
  hack.
- Shell path works identically for a new signal name:
  `echo ">efastShot:/tmp/x.bmp" > /run/xovi-mb`.
- Coexistence: new extension name + new signal name ("fastShot") → rm-shot
  stays installed and untouched.
- Measured baselines (on device, 2026-08-06): rm-shot end-to-end ~550–620ms
  for a 365KB PNG; tmpfs write ~150–250MB/s (coarse 10ms-clock dd bench —
  re-measure properly); CPU is **dual**-core Cortex-A55.

## Extension design (MVP)

Name: `fastshot` (working name; unique signal avoids all conflicts).

Manifest (`fastshot.xovi`):
```
depends-on framebuffer-spy:0.2.0
depends-on xovi-message-broker:0.2.0
import? framebuffer-spy$getFramebufferConfig
export fastShotHandler
with
    xovi-message-broker$simpleSignal = "fastShot"
    xovi-message-broker$version = 1
end
```

Handler (`fastShotHandler(param)`, param = `path[,mode]`):
1. **Init-once statics** (first call): fb config from spy, Move geometry
   hard-coded off the config (no `/sys` read ever), one 6.5MB snapshot
   buffer. No allocations on the request path thereafter.
2. **Snapshot**: memcpy fb → static buffer (~3–6ms). Tearing window is only
   these few ms; no need to pause anything.
3. **Encode+write**: BMP header + row-prefix copies to `<path>.part` on
   tmpfs, then `rename()` to `<path>` (atomic publish: any reader sees
   old-or-complete, never partial).
4. Return the final path string (QML gets it as the call's return value) or
   `"failed"`.
5. `mode=async` variant keeps rm-shot's thread+delay behavior for future
   opportunistic captures; sync is the default.

Build: clone rm-shot's Makefile skeleton, **aarch64 only** (drop armv7 /
rM1/rM2 compat entirely). Flags: `-O3 -mcpu=cortex-a55` (fine but
near-irrelevant — there's no hot loop left; `-ffast-math` is pointless, no
FP anywhere).

### Expected budget

| step | est. |
|---|---|
| memcpy 6.5MB fb → buffer | 3–6ms |
| write 6.2MB BMP to tmpfs | ~10–40ms (bandwidth TBD) |
| rename + broker overhead | <1ms |
| **total** | **~15–50ms** (vs ~550–620ms today; ≥10×, likely ~20–30×) |

QML-thread block of 15–50ms once per sleep entry is invisible next to the
~2s firmware sweep.

## Integration into the mod (v0.19 sketch)

- Navigator 0→2 handler: `sendSimpleSignal("fastShot",
  "/tmp/pinnedSleep/current.bmp")` **synchronously first**, then write
  power.json. Capture is complete before the record is even written — the
  capture/record race ceases to exist.
- Freeze artifacts move to tmpfs (`/tmp/pinnedSleep/`): freeze validity is
  <20s, reboot-persistence is unnecessary, and tmpfs avoids eMMC latency and
  wear. Pinned/chapter PNGs stay on eMMC (persistent, rarely written).
- Sleep window: BMP is on disk before the window instantiates → first
  `decide()` read succeeds immediately → the freeze image is in the window's
  **first painted frame** and rides the initial full refresh, exactly like
  the pinned path does today (pinned rides the first refresh because its PNG
  is up-front; freeze currently pays black-placeholder → ≤300ms poll →
  second render). Retry/recheck timers stay as pure fallback. BMP decode is
  ~memcpy, far cheaper than PNG inflate.
- Chrome-in-capture is unchanged by speed (the pixels at 0→2 include
  chrome). What speed changes is the *economics* of capturing before sleep —
  see parked items.

## Answers to explored side-ideas (keep for the record)

- **Parallel fb read (dual core)**: memcpy is memory-bandwidth-bound, not
  core-bound; after deleting conversion+compression there is no CPU work
  left to parallelize. Measure first; expected win small.
- **"Suspend the entire system" during capture**: unnecessary — the tear
  window is the 3–6ms memcpy, and at sleep entry the screen is static.
- **Racing a parallel reader ("write faster than it reads")**: Linux has no
  mandatory file locks; readers can observe partial files; Qt image readers
  fail on truncation (that's what our retry timers absorb today).
  Deterministic fix is `rename()` atomicity + the sync call ordering — never
  racing at all beats winning the race.
- **Write into memory the reader reads**: the clean Qt version is a
  `QQuickImageProvider` (`image://fastshot/current`) handing a QImage to the
  engine with zero disk I/O. Needs a route to the QQmlEngine to register —
  park as v2; a 15–50ms file is already ~40× under budget.
- **Line-skip / checkerboard partial reads, partial-region caching**:
  unnecessary at these numbers.
- **16-color/palette quantization, RGB565 BI_BITFIELDS BMP (halves bytes),
  non-sRGB**: only if the tmpfs write turns out to be the wall; quantization
  risks shader-produced tones. Park.
- **restrict/vector shifts/mask tricks**: moot on the Move path (no
  per-pixel loops). Would only matter if we kept rM2/565 compat, which we
  drop.

## Prerequisites & risks

- **xovigen**: the ABI glue (`import$`/`export` tables) is generated by
  `xovigen.py` from the **asivery/xovi repo** — not in the uploaded zips;
  clone it.
- **Cross-toolchain on macOS**: `aarch64-linux-gnu-gcc` via Docker (e.g.
  debian/ubuntu arm64 cross image) or messense/homebrew-macos-cross-toolchains.
  Device glibc baseline is old (spy links `mmap@GLIBC_2.17`) — build against
  a conservative glibc.
- **Qt top-down 32bpp BMP decode**: high confidence; verify on device on day
  one. Fallback: write rows bottom-up (still just memcpys, reversed order).
- **fb pointer lifetime**: spy locks onto the first matching QImage forever;
  if xochitl ever recreated its buffer the pointer would go stale — but
  rm-shot lives with the identical assumption today. Inherited, known-good.
- **Extension install loop**: scp .so → `/home/root/xovi/extensions.d/` →
  restart via `/home/root/xovi/start` (tmpfs drop-in trap applies, same as
  qmd deploys). Journal-verify the constructor log line. Bench standalone via
  `/run/xovi-mb` + `/proc/uptime` before touching the qmd.
- Packaging via vellum (`packages/` tree) is optional/later — local scp
  install is the dev loop.

## Sequencing

1. **Phase 0**: clone asivery/xovi, stand up aarch64 cross-build (Docker),
   re-measure tmpfs bandwidth properly.
2. **Phase 1**: fastshot MVP (sync BMP), install, standalone bench + Qt BMP
   decode check (`literm`/qmd probe with an `Image`).
3. **Phase 2**: v0.19 qmd integration (sync call in Navigator, tmpfs paths,
   first-frame freeze), user-visible test: freeze should now render like
   pinned (image inside the first refresh, no black placeholder frame).
4. **Phase 3 (optional)**: opportunistic chrome-less captures
   (toolbar-close/page-turn) using the async mode → retires the
   chrome-in-capture compromise for the common case; revisit R3 shadow
   chapters; image-provider zero-disk variant.
