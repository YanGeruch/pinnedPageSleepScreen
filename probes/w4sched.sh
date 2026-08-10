#!/bin/bash
# W4 probe scheduler — installed as pinsleep-clock.service ExecStart for the
# test run, so it executes at every clock wake. Logs the fuel gauge and
# switches window/vpdd config on a wall-clock schedule; every CSV row carries
# the active config, so analysis groups by config and boundary jitter is
# irrelevant. Self-concludes: past the end time it restores stock-ish values
# and drops the cadence back to 5 minutes.
D=/home/root/.pinnedSleepScreen
CSV=/home/root/w4test.csv
B=/sys/class/power_supply/max77818_battery

hm=$(date +%H%M)
if   [ "$hm" -lt 1630 ]; then W=34; V=6000; P=P1-base
elif [ "$hm" -lt 1700 ]; then W=8;  V=6000; P=P2-w8
elif [ "$hm" -lt 1730 ]; then W=8;  V=2000; P=P3-w8v2
elif [ "$hm" -lt 1800 ]; then W=3;  V=2000; P=P4-w3v2
elif [ "$hm" -lt 1806 ]; then W=3;  V=0;    P=P5-w3v0-short
else                          W=34; V=6000; P=end
fi
echo "$W" > "$D/window.conf"
echo "$V" > "$D/vpdd.conf"

[ -e "$CSV" ] || echo "epoch,localtime,phase,window,vpdd,charge_now_uah,capacity_hires,suspend_ok,suspend_fail" > "$CSV"
echo "$(date +%s),$(date +%H:%M:%S),$P,$W,$V,$(cat $B/charge_now),$(cat $B/capacity_hires),$(cat /sys/power/suspend_stats/success 2>/dev/null),$(cat /sys/power/suspend_stats/fail 2>/dev/null)" >> "$CSV"

if [ "$P" = end ] && [ ! -e /run/w4-concluded ]; then
	touch /run/w4-concluded
	printf '[Timer]\nOnCalendar=\nOnCalendar=*:00/5\n' \
		> /etc/systemd/system/pinsleep-clock.timer.d/cadence.conf
	systemctl daemon-reload
	systemctl restart pinsleep-clock.timer &
fi
exit 0
