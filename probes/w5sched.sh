#!/bin/bash
# W5 probe scheduler — vpdd 50 certification (2026-08-11). Same rig as W4:
# pinsleep-clock.service ExecStart for the run, executes at every clock wake.
# Phase A (1-min cadence) answers the WARN question fast: vpdd 50 takes the
# g2194 timer path, structurally unable to hit the vpdd==0 inline-relax
# WARN_ON — verify zero g2194 lines and awake collapsing to the 3s window.
# Phase B (5-min cadence) measures the shipping number directly at production
# cadence — no extrapolation. Self-concludes past 19:00: restores 34/6000.
D=/home/root/.pinnedSleepScreen
CSV=/home/root/w5test.csv
B=/sys/class/power_supply/max77818_battery

hm=$(date +%H%M)
if   [ "$hm" -lt 1300 ]; then W=3;  V=50;   P=A-w3v50-fast
elif [ "$hm" -lt 1900 ]; then W=3;  V=50;   P=B-w3v50-prod
else                          W=34; V=6000; P=end
fi
echo "$W" > "$D/window.conf"
echo "$V" > "$D/vpdd.conf"

[ -e "$CSV" ] || echo "epoch,localtime,phase,window,vpdd,charge_now_uah,capacity_hires,suspend_ok,suspend_fail" > "$CSV"
echo "$(date +%s),$(date +%H:%M:%S),$P,$W,$V,$(cat $B/charge_now),$(cat $B/capacity_hires),$(cat /sys/power/suspend_stats/success 2>/dev/null),$(cat /sys/power/suspend_stats/fail 2>/dev/null)" >> "$CSV"

setcadence() {
	printf '[Timer]\nOnCalendar=\nOnCalendar=*:00/5\n' \
		> /etc/systemd/system/pinsleep-clock.timer.d/cadence.conf
	systemctl daemon-reload
	systemctl restart pinsleep-clock.timer &
}
if [ "$P" = B-w3v50-prod ] && [ ! -e /run/w5-phaseb ]; then
	touch /run/w5-phaseb
	setcadence
fi
if [ "$P" = end ] && [ ! -e /run/w5-concluded ]; then
	touch /run/w5-concluded
	setcadence
fi
exit 0
