# pinnedPageSleepScreen

A [xovi](https://github.com/asivery/rmpp-xovi-extensions) mod for the
reMarkable Paper Pro Move: pin any document page — or keep the live screen —
as your sleep screen, with an optional clock/date/battery bar that updates
every five minutes while the device sleeps.

Built and tested on the **Paper Pro Move, OS 3.27.x**.

## Two packages, two security profiles

The mod ships as two vellum packages so you can review exactly what touches
your system:

| Package | Touches | What it does |
| ------- | ------- | ------------ |
| **pinned-page-sleep-screen** | mod space only (`/home/root/xovi/`) | The mod itself: qmd, wallpaper SVG, and the bundled `fastshot` xovi extension (synchronous ~70 ms framebuffer captures). Fully functional standalone — the clock bar ticks while the device is awake or in light sleep. |
| **pinned-sleep-clock** (optional, depends on the above) | system folders | The deep-sleep clock machinery: a 5-minute `WakeSystem` timer, plus two `systemd-sleep` hooks that make each wake cheap (see below). All system writes happen in lifecycle scripts and are fully reverted by `vellum del`. |

Install with [vellum](https://github.com/vellum-dev/vellum):

```
vellum add pinned-page-sleep-screen        # the mod
vellum add pinned-sleep-clock              # + deep-sleep clock (optional)
```

## What the sleep screen does

- **Pin a page**: the Pages foldout gains a "pin as sleep screen" action.
- **Live screen**: with the native *Visible content* toggle on, the screen you
  left is snapshotted at the instant sleep begins (chrome-free where the
  platform allows) and shown as the sleep image.
- **Clock bar**: full-width bar on every sleep screen — date+time left,
  "Sleeping" centered, battery icon+% right. Deep-sleep updates land exactly
  on :00/:05/:10… wall-clock marks while the `pinned-sleep-clock` companion
  is installed — installing it is the opt-in (there is no Settings toggle).

## The power engineering (and two findings we believe are novel)

A sleeping tablet that repaints a clock must wake the SoC. Stock OS makes
each wake expensive; the companion package fixes that:

- **`minimumAwakeTime` is hardcoded at 34 s.** After any RTC wake,
  xochitl's batterymanager stays up 34 s before re-suspending
  ("Re-entering DeepSleep in 34000ms"). We found no env var, no conf key,
  and no QML property that changes it — it is a compiled-in constant
  (novel finding, previously undocumented in the community).
- **The EPD PMIC keep-alive (`vpdd_length`) collides with that 34 s.**
  The g2194 PMIC holds the panel rails 30 s after every display update
  (interactive-latency optimization). 30 s hold vs 34 s re-suspend left no
  margin: ~30 % of re-suspends aborted (`g2194-regulator: Can't suspend,
  vpdd timer running`), costing ~60 s extra awake each. Our hook drops the
  hold to **6 s during battery sleep** — the g2194 driver's own upstream
  default (reMarkable's device tree overrides it to 30 s). Per the GPL
  kernel source, the hold starts only after the display pipeline releases
  the regulator, so **no hold length can clip a running waveform**.
- **WiFi/BT reload gate.** Stock reloads the whole WiFi driver on *every*
  resume. For RTC clock wakes on battery (SPLD `wakeup_reason` 0x00) the
  radios stay down; any user wake (button/pen/charger) restores stock
  behavior, as does USB power entirely.

Measured on device (17 h, OS 3.27.3):

| Quantity | Value |
| -------- | ----- |
| Deep-sleep floor | 0.157 %/h |
| One 34 s clock wake | 0.066 % (~half the stock wake cost) |
| 5-min cadence total | ~0.9 %/h (~22 %/day standing) |
| 15-min cadence (one `OnCalendar` edit) | ~0.42 %/h |

Full architecture, timeline and the discarded/parked levers:
[docs/power-design.md](docs/power-design.md).

## System footprint of pinned-sleep-clock

- `/usr/lib/systemd/system-sleep/sleep-zz-pinsleep.sh` — new hook (vpdd).
- `/usr/lib/systemd/system-sleep/sleep-wifi.sh` — **replaces** the stock
  hook (adds the RTC gate). The genuine stock copy is kept at
  `/home/root/.pinnedSleepScreen/sleep-wifi.sh.stock` and restored on
  uninstall; after an OS update the vellum `post-os-upgrade` hook
  re-captures the *new* stock before re-gating it.
- `/etc/systemd/system/pinsleep-clock.{service,timer}` — written to the
  persistent rootfs `/etc` (the `/etc` overlay upper is tmpfs and dies on
  reboot). The service is `/bin/true`: the wake itself repaints the clock.
- The timer is enabled at package install (installing the companion is the
  opt-in); the main mod re-asserts enablement on every xochitl start (the
  enable symlink lands in volatile `/etc`, which dies on reboot).

Everything is reverted by `vellum del pinned-sleep-clock`
(`vellum purge` also removes the stock backup and saved state).

## Building from source

- `scripts/package.sh` — builds both `.apk`s **on the device** (its apk
   3.0.3 provides `mkpkg`; packages are signed with vellum's local key),
  pulls them to `dist/`, installs, restarts xochitl with a health check.
- `packaging/*/VELBUILD` — the upstream recipes, kept in sync with the
  script.
- `extensions/fastshot/` — C source for the capture extension; cross-built
  from macOS with `zig cc -target aarch64-linux-gnu.2.36` (see Makefile).
- `scripts/deploy.sh` — the raw dev loop (scp + restart + journal check),
  no packaging.

## Compatibility notes

- qmd hashes target OS 3.27 QML; the packages pin
  `remarkable-os>=3.27 <3.28`.
- `fastshot` derives geometry (width/height/stride) from framebuffer-spy at
  runtime — nothing device-specific is hardcoded except cropping the Move's
  6 dead framebuffer columns (960-px buffer, 954-px panel). It does require
  a 32 bpp BGRX framebuffer (byte-identical to BMP pixels, which is what
  makes the ~70 ms zero-conversion capture possible): both Paper Pros
  qualify; the reMarkable 2's RGB565 framebuffer does not and would need a
  conversion pass.
- The hooks' sysfs paths (g2194 EPD PMIC, slg46824 wakeup reason) are
  Paper Pro Move specific (`rmppmove`). Ports to other Paper Pro devices
  likely need only path changes.

## License

[GPL-3.0-or-later](LICENSE). The power hooks build on findings from
reMarkable's GPL kernel sources.
