#!/bin/sh
# pinnedPageSleepScreen: shrink the EPD rail keep-alive (vpdd) while the device
# sleeps. Stock vpdd_length=30000 holds the panel voltages 30s after every EPD
# update (an interactive-latency optimization); a suspend attempted inside that
# window aborts ("g2194-regulator: Can't suspend, vpdd timer running") and costs
# ~60s extra awake plus a second WiFi driver reload. During sleep, clock repaints
# are minutes apart, so a 3s hold loses nothing and lets the re-suspend land.
# Restored on any non-RTC wake: 0x00 = RTC/timer, 0x04 button, 0x10 pen,
# 0x20 charger. (Waking mid-window with the button skips the "after" phase —
# the mod's Navigator wake handler restores it then.)
VPDD=/sys/bus/i2c/drivers/g2194-regulator/0-0048/vpdd_length
REASON=/sys/devices/platform/soc@0/44000000.bus/44340000.i2c/i2c-0/0-0008/slg46824-wakeup.1.auto/wakeup_reason

if [ "$1" = "before" ]; then
	echo 3000 > "$VPDD" 2>/dev/null
elif [ "$1" = "after" ]; then
	if [ "$(cat "$REASON" 2>/dev/null)" != "0x00" ]; then
		echo 30000 > "$VPDD" 2>/dev/null
	fi
fi
