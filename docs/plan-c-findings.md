# Plan C findings — xochitl-less operation on the Paper Pro Move (2026-08-08)

Question researched: can we mask/replace xochitl — fully, or during sleep —
to escape its 34 s minimum-awake window and let suspend-then-hibernate work?
Sources: oxide @ HEAD, reMarkable kernel 6.12.49 (tag "Paper Pro/Pure
3.27.2.1"), official chiappa 3.27 SDK sysroot, community (pluto,
gitman-101111/chiappa + remarkable-nixos, KOReader, rmkit fork, vellum).
Three independent research passes; where they overlap they agree.

## Verdicts

**V1 — xochitl-less *boot* is off the table; xochitl-less *runtime* is
legitimate.** reMarkable's own docs: xochitl is required at startup on
encrypted devices (PIN entry + /home decryption). Oxide's whole design
respects this: stock xochitl boots, draws the PIN screen, and on unlock
`_Exit(0)`s itself (LD_PRELOAD hook on PasscodeHandler), then the launcher
starts. Switching back is `launcherctl switch-launcher none --start`, with a
systemd `OnFailure` unit that auto-restores xochitl.

**V2 — there is no kernel-level EPD API to draw against.** The Move (i.MX93)
has NO display controller with e-ink smarts: LCDIF drives the panel's
source/gate drivers directly over parallel RGB565 at 365×1700@85 Hz (the
CRTC mode — not 954×1696). No custom ioctls, no DRM properties, no fbdev
(`CONFIG_DRM_FBDEV_EMULATION` off). The waveform IS the frame sequence:
userspace must stream the correct temporal sub-frames (~6 bits/panel-pixel
packing, exact format unknown) or the panel shows nothing. All of that
lives only in xochitl's proprietary `libqsgepaper.so` QPA plugin — not in
the kernel, not in the SDK sysroot (verified: SDK ships only
vnc/offscreen/minimal QPA plugins and stock libdrm). Ferrari (11" PP) is
different — it has an FPGA bridge; do not port display findings between
them.

**V3 — non-xochitl painting is proven, but only through libqsgepaper.**
Oxide's display server and the NixOS-on-chiappa project both link the vendor
plugin (reverse-engineered header `epframebuffer.h`, hardcoded aarch64
offsets, dlsym'd mangled symbols; ABI-sensitive across OS versions). The
panel is a process-exclusive singleton (`/tmp/epframebuffer.lock` +
DRM master). Minimal non-xochitl clock drawer = standalone QtCore/QtGui
binary linking `-lqsgepaper`: paint QImage → `swapBuffers(rect, Mono,
PartialUpdate)`. No QML, but not Qt-free, and it can never run while
xochitl lives (xochitl holds DRM master; a *stopped* xochitl is required).

**V4 — power safety without xochitl exists but weakens in sleep.** The
kernel itself powers off at SOC < 6 % (`maxim,critical-soc=<6>` →
max77818_battery → `hw_protection_shutdown`, 10 s forced backup, PSCI
poweroff). xochitl's ~10 % is just a softer userspace layer. Caveats: the
1 %-SOC alert is deliberately disabled during suspend (no gauge-driven wake
in long sleep), the alert self-disables after firing until next resume, and
the g2194 `min-battery=6` only refuses to light the panel rails (no
shutdown). So: awake = protected at 6 %; multi-day suspend = deep discharge
plausible. Community corroboration: a real chiappa hit the "HARDWARE
PROTECTION shutdown (Battery critical capacity)" cliff and needed NXP SDP
recovery after a 500 mA-charger overnight drain. `capacity_alert_min` is
sysfs-writable and kernel-restored on every resume — cheap extra margin.

**V5 — hibernation needs nothing from xochitl; masking xochitl trips no
watchdog.** `CONFIG_HIBERNATION=y` (LZ4), resume path has zero userspace
dependencies (reMarkable's suspend_event/sleep_monitor are notify-only).
wdog3 (40 s) is petted by the kernel indefinitely until someone opens
/dev/watchdog; a cleanly *stopped* xochitl triggers neither `Restart=` nor
`OnFailure=`, and the A/B rollback counter (3 strikes → slot switch) counts
boot-time failures only. `PM_AUTOSLEEP=y` — with wakelocks clear the kernel
re-suspends by itself; g2194 holds a wakelock during panel updates, so a
draw-and-exit clock gets the re-suspend for free.

**V6 — full launcher replacement costs note-taking.** Oxide's own
compatibility table: xochitl running *under* the oxide display server
cannot update the display. Pluto (Flutter, verified on Move, drop-in
replacing xochitl's ExecStart) replaces the UI outright. For a daily-driver
notes device, full replacement is out.

## What this means for us

**The tiny-clock-drawer version of Plan C is a reverse-engineering project,
not a weekend patch.** The economics: our measured per-wake cost is 0.066 %
at 34 s; a ~3 s drawer wake might reach ~0.3–0.4 %/h at 5-min cadence
(vs 0.9). But it requires stopping xochitl for the whole sleep phase →
xochitl cold start on every user wake (seconds of latency, state loss,
possibly PIN re-entry), libqsgepaper ABI risk on every OS update, and a
solved-only-by-xochitl waveform pipeline. High cost, moderate gain. PARKED.

**The hibernation lever does NOT need Plan C at all ("Plan D").** The
forensics finding stands: our 5-min timer resets suspend-then-hibernate's
4 h deadline forever. But nothing requires the timer to run forever:

> After N consecutive RTC-only wakes with no user activity (wakeup_reason
> 0x00 chain, tracked by our existing sleep hooks), stop re-arming: disable
> pinsleep-clock.timer (volatile) and let the running suspend-then-hibernate
> op reach its 4 h deadline → device hibernates at near-zero drain, clock
> freezes on the bistable panel (last image persists at 0 power). Any user
> wake (0x04/0x10/0x20) re-enables the timer — the qmd already re-asserts
> enablement on xochitl start, and hooks see every resume.

Effect: recently-used device keeps the pretty 5-min clock at ~0.9 %/h;
a device idle > ~4–6 h (overnight-away, weekend) drops to hibernation
floor. All within the current architecture — no xochitl changes, no new
display path, ~30 lines of hook logic. This captures the single biggest
power lever found by the forensics with none of Plan C's risk.

Bonus finding, independent of everything above: oxide cancels the vpdd
hold entirely (writes 0) before suspend; the g2194 driver treats the timer
as "keep rails warm for reuse". At 5-min cadence a warm PDD is long cold
anyway; whether 0 beats our 6000 by letting re-suspend complete faster is
a cheap measurable experiment.

## Corrections to earlier notes

- Fuel gauge is **MAX77818** (charger+gauge combo), not max1726x. Kernel
  low-battery floor is **6 %** (DT), community-observed cliff ~5 %.
- The passcode story needs re-verification before the lock test: official
  docs tie boot-time xochitl to "/home decryption" on this family. Our
  device today has plain-ext4 everywhere (no passcode set). Before setting
  a PIN: check whether that enables any dm-crypt/home encryption — it
  changes the SSH lockout-recovery story.

## Device probes proposed (all read-only; awaiting approval)

```sh
# A. display ownership + vendor plugin surface
fuser -v /dev/dri/card0; ls /dev/fb* 2>/dev/null; cat /sys/class/drm/card0-*/modes 2>/dev/null
ls -la /usr/lib/plugins/scenegraph/
strings /usr/lib/plugins/scenegraph/libqsgepaper.so | grep -iE "waveform|ct33|colortable|/dev/dri|epframebuffer" | head -n 20
ls /usr/share/remarkable/ | grep -iE "eink|ct33|colortable|GAL3"
ls -la /tmp/epframebuffer.lock 2>/dev/null
# B. battery protection state
cat /sys/class/power_supply/*/capacity_alert_min /sys/class/power_supply/*/present 2>/dev/null
grep -iE "max77818|fuelgauge" /proc/interrupts
journalctl -k | grep -iE "critical capacity|HARDWARE PROTECTION" | tail -n 5
# C. watchdog / pm / hibernate plumbing
cat /sys/class/watchdog/watchdog0/state /sys/class/watchdog/watchdog0/timeout 2>/dev/null
fuser -v /dev/watchdog 2>&1 | head -n 3
cat /proc/cmdline; cat /sys/power/autosleep 2>/dev/null; grep -i resume /proc/cmdline
systemctl cat suspend-then-hibernate.target 2>/dev/null | head -n 20
# D. encryption ground truth before any passcode test
cat /proc/mounts | grep -E "home|data|crypt"; ls /dev/mapper/; dmsetup ls 2>/dev/null
```

## Probe results (run 2026-08-08, all read-only)

**A — display: research confirmed 1:1.** xochitl holds DRM master on
/dev/dri/card0; no /dev/fb*; the only connector is LVDS-1 at 365x1700.
`/usr/lib/plugins/scenegraph/libqsgepaper.so` (533 KB) exports
`EPFramebuffer` (Move class name — oxide's header says EPFramebufferSwtcon,
ferrari's name; symbol set otherwise matches: swapBuffers both overloads,
ghostControl, checkLockFile, setBuffers, handleCrash) plus
`EPFramebufferAcep2` (ACeP2 = Gallery 3 color path). Waveforms are plain
files: 34x `GAL3_*.eink` + ct33_{fast,std,best,pen}.bin +
colortable_*.bin in /usr/share/remarkable/. /tmp/epframebuffer.lock exists.

**B — battery: both thresholds explained.** `capacity_alert_min=10` in
sysfs — so "xochitl powers off at 10%" is real and driven by the gauge
alert; the kernel's own `hw_protection_shutdown` floor at 6% (DT
critical-soc) sits below it. max77818 interrupts wired and firing.

**C — PM: hibernation-friendly beyond expectations.**
- `resume=/dev/dm-1` in cmdline + `dm-mod.create="swap-encrypted-disk,...
  :32:logon:lpgpr:bootkey ..."` — the encrypted swap is assembled BY THE
  KERNEL at early boot from an lpgpr-held bootkey; hibernation resume needs
  zero userspace, decryption included.
- `/sys/power/autosleep = mem` — PM_AUTOSLEEP is ACTIVE now. The kernel
  re-suspends whenever wakelocks clear; xochitl's 34 s window is just its
  batterymanager holding a wakelock. Plan D's "let go and the kernel
  sleeps" mechanism is already the device's normal operating mode.
- `panic=2` (auto-reboot on panic).

**D — ENCRYPTION: earlier claim corrected.** `/home` IS dm-crypt
(`/dev/mapper/home-encrypted-disk`, also carrying /var/log/journal,
/var/lib/bluetooth and **/etc/dropbear — the SSH host keys**), plus
`persist` (ro, /var/lib/remarkable). No /etc/crypttab, no systemd unit
references it → unlocked in the initrd, key TEE/hardware-derived
(tee-supplicant running; passcode backend is `pincode-rs`; OpenSC
smartcard tools present → secure element). Today (no PIN set) it unlocks
automatically at boot — SSH works from boot.

**Open question that now gates the passcode test:** does setting a PIN
re-wrap the /home key so the initrd DEFERS unlocking until PIN entry
(matching the official "xochitl required at startup for /home decryption")?
If yes, a reboot with a forgotten PIN = no /home = no dropbear keys = no
SSH. Safe protocol: set the PIN with a live SSH session, test the lock
behavior, REMOVE the PIN before any reboot; only after inspecting the
initrd (future probe: read-only dump of the boot partition) allow a reboot
with PIN set.
