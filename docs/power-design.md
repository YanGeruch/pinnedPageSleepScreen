# Sleep-clock power design (v0.25, settled 2026-08-07)

The clock on the sleep bar requires waking the SoC to repaint. This doc is the
settled architecture, all timings, every lever we used/discarded/parked, and
the measurement protocol. Kernel-source facts cite reMarkable's GPL tree
(github.com/reMarkable/linux-imx-rm, `drivers/regulator/g2194-regulator.c`).

## The wake cycle (on battery)

```
:00/5   pinsleep-clock.timer (OnCalendar=*:00/5, WakeSystem, AccuracySec=15s)
+0.3s   kernel resume; system-sleep hooks "after":
          wakesources -> runtime set, regulator on,
          sleep-wifi.sh: RTC+battery -> SKIP driver reload (flag /run/pinsleep-wifi-off)
          sleep-zz-pinsleep.sh: vpdd stays 6000 (RTC) / restored 30000 (user/charger wake)
+~1ms   userspace thaws mid-instruction (xochitl never "boots")
+1s     bar's 1s QML Timer fires: repaint dd/MM hh:mm + battery% (only on change)
        = quiet regional B/W update, ~450ms waveform
+34s    batterymanager "Re-entering DeepSleep in 34000ms" (hardcoded
        minimumAwakeTime, handleUpkeepWakeup) -> systemctl suspend
        hooks "before": wifi already down -> skip; vpdd -> 6000; suspend lands
        FIRST TRY (rails released at repaint+6s, long clear)
```

Awake ~35s per wake, radios off, idle CPU. The window never crosses a minute
boundary, so the deep-phase clock only ever shows :00/:05/:10... marks
(wall-clock aligned — OnCalendar is absolute time, not suspend-relative).
No software gating of the displayed time exists: pre-suspend (~3min after
button press) and light sleep tick every real minute because the CPU is up.

User wake (button 0x04 / pen 0x10 / charger 0x20, from SPLD wakeup_reason):
hooks restore vpdd 30000 + reload WiFi/BT. Waking DURING a wake window (no
hooks run): Navigator displayState handler fires a transient systemd-run unit
doing the same. On USB power both hooks stand down entirely — stock behavior
while charging (user decision).

## Why the vpdd hook exists

vpdd_length (sysfs, g2194 PMIC "power-down delay") is a KEEP-ALIVE holding
panel rails after the display pipeline releases the regulator — it starts
only after an update completes, so no hold length can clip a waveform.
`g2194_safe_to_suspend()` returns -EAGAIN while it runs: stock 30000ms vs the
34s upkeep delay made ~30% of re-suspends abort (extra ~60s awake + second
WiFi reload + ugly non-mark minutes on the clock). 6000ms during sleep = the
driver's own upstream default (reMarkable's DT overrides to 30000 for
interactive latency). Values snap to a 256-entry PMIC table (3000 -> 3030).

## Levers: used / discarded / parked

USED: vpdd_length hook; WiFi/BT reload gate on RTC-wake reason; 5-min
OnCalendar cadence; IdleToSuspendDelay 160min -> 15min (xochitl.conf).

DISCARDED (with reasons):
- BatteryManager.deepSleepDelay (QML): writable but it's the idle light->deep
  escalation knob (= Settings.idleToSuspendDelay), NOT the upkeep delay.
- UPKEEP_INTERVAL_MS env: sync/indexing, not batterymanager.
- minimumAwakeTime (the 34s): not QML-exposed, no env var, no conf key —
  compiled-in constant. Community has never documented it (novel finding).
- Bare-metal fb drawing without waking userspace: impossible (no partial
  resume in Linux; thaw costs 1ms anyway) and fb writes don't flush the EPD.
- systemd inhibitor "stay awake on AC": user chose stock-on-charge instead.

PARKED (still viable if measurements disappoint):
1. Plan B — forced early suspend: transient/systemd unit at wake+8s, gated on
   wakeup_reason 0x00 (proven 2026-08-07 17:00: clean 8s window). Cost:
   xochitl's 34s CLOCK_BOOTTIME_ALARM still pops the system up for ~3s
   (+1 extra resume cycle per wake). Net ~11s vs 35s.
2. Binary-patching the 34000 immediate in xochitl's handleUpkeepWakeup
   (OTA-fragile, riskiest).
3. Cadence reduction to 10/15min (one OnCalendar line).
4. enable_nowait sysfs (speculative rail pre-power, 250ms fallback) —
   interactive-latency lever, not a power one.
5. Color battery icon trade-off: color waveforms run 500-1500ms vs 350ms B/W.
   Inside today's 34s window: free. Under Plan B's 8s window: repaint 1.5s +
   vpdd 6s = 7.5s ~= the 8s attempt — would need the forced delay pushed to
   ~10-12s. Decide only if we ever go aggressive.

## Packaging decision (user, 2026-08-07)

Ship TWO mods with separate security profiles:
- pinnedPageSleepScreen (main): pure mod space (qmd + SVG + fastshot
  extension) — reviewable without system-folder caution.
- sleep-clock companion (depends on main): everything touching the system —
  /usr/lib/systemd/system-sleep hooks (RO rootfs, remount rw; the ONLY dir
  this systemd build scans), /etc units + timer (volatile overlay — nothing
  in /etc survives reboot), conf tweaks. Small, auditable footprint.

## Measurement results (night 2026-08-07 -> 08, v0.25.1)

Baseline (15-min quarters, aborts, WiFi reloads, 2026-08-06 night): 0.73%/h.
Test night: ~17h off charger, `rm_sleep_monitor` battery at every suspend
entry/exit. Cycle hygiene was perfect: zero g2194 aborts across ~200 cycles,
every RTC wake logged "skipping Wifi/BT restore", every window exactly
:xx:04 -> :xx:38 (34s, never crossing a minute boundary).

Measured components (clean daytime segment, n=57 cycles):
- deep-sleep floor:          0.157 %/h
- one 34s wake window:       0.066 %  (baseline per-wake was ~0.14% with
                                       aborts + WiFi reload — halved)
- 5-min cadence total:       0.84–0.93 %/h measured (~22%/day standing)
- projections: 10-min 0.55 %/h, 15-min 0.42 %/h, 30-min 0.29 %/h

So per-wake hygiene works, but 5-min cadence (12 wakes/h) costs more total
than the dirty 15-min baseline. The honest trade: pretty 5-min clock ~0.9%/h
vs 15-min clock 0.42%/h. Plan B (11s windows) would put 5-min cadence at
roughly 0.4%/h if per-wake cost scales with window length.

Confound (resolved): ALL full-wake events were real use — user was up until
~05:00 (00:02 pen pickup + sync, 04:28-04:40 pen + power button) and briefly
awake 08:50-09:18 (power button, pen; active use burns ~12%/h). No phantom
disturbances. True standing segments: 05:00-08:50 = 0.847%/h,
09:25-11:00 = 0.885%/h — confirming ~0.85-0.9%/h for 5-min cadence.
Full-night 1.73%/h average is NOT standing drain; it includes real use.

## The hibernation cost (found 2026-08-08 — the big one)

Two structural facts, established by comparing a genuine pre-mod journal
window (boot -1, 2026-08-05, zero pinsleep mentions) against a with-mod
night. The pre-mod window ages out ~2026-08-08 (SystemMaxUse=50M, ~3-day
retention), so the decisive lines are preserved here:

1. **The delta hypothesis is false — our wakes are ~98% additive.** Stock's
   only autonomous wake source is `suspend-then-hibernate` at a 4h period
   (`/etc/systemd/sleep.conf.d/60-rm-sleep.conf`: HibernateDelaySec=4h,
   SuspendState=mem). That is 0.25 wakes/h vs our 12/h. `pinsleep-clock.timer`
   is the ONLY WakeSystem=yes unit. Netting out stock's forgone wakes is
   ~0.017%/h, ~2% of measured cost. Our 5-min alarm does mask stock's 4h RTC
   alarm in the register (earliest-alarm-wins), but there is only one per 4h.

2. **The mod PREVENTS HIBERNATION entirely — a second, separate, unmeasured
   cost.** Each 5-min wake terminates the running suspend-then-hibernate op;
   logind starts a FRESH one with a fresh 4h deadline that is never reached.
   Proof: pre-mod, one PID (14902) spans 03:11 -> 04:23 and hibernates at
   04:23 (`PM: hibernation: Creating image`); with-mod, every 5-min mark has a
   DISTINCT systemd-sleep PID (49902, 50008, 51131 …) and a contiguous 5h25m
   battery suspend shows ZERO hibernation events. So stock, left alone >4h,
   drops to near-zero hibernation drain; the mod holds it in suspend-to-RAM at
   ~1.17%/h (measured 08-08: 90.660% 00:30 -> 84.300% 05:55 = 1.174%/h)
   forever. Long-idle (overnight-away, weekend) is where this bites hardest
   and it is NOT captured in the daytime 0.85-0.9%/h figure.

Decisive raw lines:
```
pre-mod:  23:10:37 systemd-sleep[14790] returned from 'suspend-then-hibernate'
          03:11:13 systemd-sleep[14902] returned  (4h00m36s gap = HibernateDelaySec)
          03:11:13 rm_sleep_monitor Enter 97.191% / Exit 96.542%  = 0.162%/h (4h suspend)
          04:23:06 kernel PM: hibernation: Creating image  (SAME pid 14902)
with-mod: 00:30:05 rm_sleep_monitor Enter 90.660% ... 05:55:05 Exit 84.300% = 1.174%/h
          distinct systemd-sleep PIDs per mark, no hibernation in 5h25m
```

Log-classification trap: IRQ 20 is SHARED (`44440000.bbnsm:pwrkey, rtc alarm`).
An overnight wake logged "IRQ 20 (…pwrkey)" is NOT necessarily a button press;
the discriminator is the SPLD code — 0x04 = real button, 0x00 = "no SPLD
source" (SoC-side: RTC alarm or SDIO), which is the precise meaning of the
"0x00 = RTC" shorthand.

This is the #1 Plan C lever: the kernel's own deep-power state is hibernation,
and the clock defeats it. Reconciling a live clock with letting the device
hibernate after N hours idle is the real optimization, not shorter windows.
