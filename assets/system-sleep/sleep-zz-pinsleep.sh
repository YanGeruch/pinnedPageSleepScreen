#!/bin/sh
# pinnedPageSleepScreen: shrink the EPD rail keep-alive (vpdd) while the device
# sleeps ON BATTERY. Stock vpdd_length=30000 holds the panel voltages 30s after
# every EPD update (an interactive-latency optimization); a suspend attempted
# inside that window aborts ("g2194-regulator: Can't suspend, vpdd timer
# running") and costs ~60s extra awake plus a second WiFi driver reload.
# During sleep, clock repaints are minutes apart, so a short hold loses nothing
# and lets the re-suspend land. 50ms = the smallest nonzero entry in the
# driver's vpdd_len table, certified by probes W4/W5 + the linearity probe
# (lindata/): awake = window + vpdd + 3000ms grace, linear — every ms of hold
# is a ms awake, so the floor value wins (6.0s/cycle with the 3s window clamp;
# 104 clean panel-offs, zero WARNs/aborts). The timer only starts when the
# display pipeline RELEASES the regulator (after an update completes), so
# no hold length can clip a running waveform.
# ON USB POWER: stock behavior everywhere (user decision — no optimization
# needed while charging, and stock keeps dev SSH patterns predictable).
# Restored on any non-RTC wake: 0x00 = RTC/timer, 0x04 button, 0x10 pen,
# 0x20 charger. (Waking mid-window with the button skips the "after" phase —
# the mod's Navigator wake handler restores it then.)
VPDD=/sys/bus/i2c/drivers/g2194-regulator/0-0048/vpdd_length
REASON=/sys/devices/platform/soc@0/44000000.bus/44340000.i2c/i2c-0/0-0008/slg46824-wakeup.1.auto/wakeup_reason
CHARGER=/sys/class/power_supply/max77818-charger/online

if [ "$1" = "before" ]; then
	if [ "$(cat "$CHARGER" 2>/dev/null)" = "1" ]; then
		echo 30000 > "$VPDD" 2>/dev/null
	else
		# on-battery hold length is overridable (ms) for probe runs;
		# absent/invalid = the 50 default. 0 stays banned: its inline
		# power-down branch drops VDD before XON (reversed sequencing)
		# and WARNs per panel-off (g2194-regulator.c:347).
		V=$(cat /home/root/.pinnedSleepScreen/vpdd.conf 2>/dev/null)
		case "$V" in (*[!0-9]*|"") V=50;; esac
		[ "$V" -le 30000 ] || V=50
		echo "$V" > "$VPDD" 2>/dev/null
	fi
elif [ "$1" = "after" ]; then
	if [ "$(cat "$CHARGER" 2>/dev/null)" = "1" ] \
			|| [ "$(cat "$REASON" 2>/dev/null)" != "0x00" ]; then
		echo 30000 > "$VPDD" 2>/dev/null
	fi
fi
