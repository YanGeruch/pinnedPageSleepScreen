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

## Measurement protocol

Baseline (quarters, aborts, WiFi reloads, 2026-08-06 night): 0.73%/h.
Test night (v0.25: 5-min cadence, clean suspends, radios gated): device OFF
CHARGER, sleeping, overnight. Numbers from `rm_sleep_monitor` kernel journal
lines (battery % at every suspend entry/exit). Compare %/h; the README gets
the honest per-wake cost. Fallback if worse: cadence lever (#3).
