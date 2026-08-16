#!/bin/bash
# Linearity probe scheduler (2026-08-12) — verify awake(w3, vpdd) = 6.0s + vpdd
# (the additive grace law: request = operative-vpdd + 3000ms pad, no free zone).
# Same rig as W4/W5: pinsleep-clock.service ExecStart, runs at every clock wake.
# CYCLE-COUNT phases (short run, ~8 unplugged minutes at 1-min cadence):
#   n 1-3  -> vpdd.conf 490  (operative on cycles 2-4: the sleep hook writes
#   n 4-6  -> vpdd.conf 990   sysfs at the NEXT suspend, so each phase's first
#   n >= 7 -> end: 34/6000    cycle still runs the previous value)
# vpdd_sysfs column = read-back at wake = the value THIS cycle's repaint hold
# actually uses — labels every cycle unambiguously despite the off-by-one.
# Predictions: v490 -> awake ~6.5s, grace request ~3490ms constant;
#              v990 -> awake ~7.0s, grace request ~3990ms constant.
# end writes window.conf=34 (>=34 = clamp PASSes stock) + vpdd 6000.
D=/home/root/.pinnedSleepScreen
CSV=/home/root/lintest.csv
B=/sys/class/power_supply/max77818_battery
G=/sys/bus/i2c/drivers/g2194-regulator/0-0048
CNT=/run/linprobe-count

[ -e "$CSV" ] || echo "epoch,localtime,n,phase,window,vpdd_conf,vpdd_sysfs,vpdd_timeout_ms,charge_now_uah,suspend_ok,suspend_fail" > "$CSV"

# On charger the hook forces sysfs 30000 and firings happen mid-prep — hold
# the count at 0 (phase A preseed stays) until the first unplugged firing.
if [ "$(cat /sys/class/power_supply/max77818-charger/online 2>/dev/null)" = "1" ]; then
	echo "$(date +%s),$(date +%H:%M:%S),0,plugged,3,490,$(cat $G/vpdd_length 2>/dev/null),$(cat $G/vpdd_timeout_ms 2>/dev/null),$(cat $B/charge_now),$(cat /sys/power/suspend_stats/success 2>/dev/null),$(cat /sys/power/suspend_stats/fail 2>/dev/null)" >> "$CSV"
	exit 0
fi

n=$(cat "$CNT" 2>/dev/null); case "$n" in (*[!0-9]*|"") n=0;; esac
n=$((n+1)); echo "$n" > "$CNT"

if   [ "$n" -le 3 ]; then W=3;  V=490;  P=A-v490
elif [ "$n" -le 6 ]; then W=3;  V=990;  P=B-v990
else                      W=34; V=6000; P=end
fi
echo "$W" > "$D/window.conf"
echo "$V" > "$D/vpdd.conf"

echo "$(date +%s),$(date +%H:%M:%S),$n,$P,$W,$V,$(cat $G/vpdd_length 2>/dev/null),$(cat $G/vpdd_timeout_ms 2>/dev/null),$(cat $B/charge_now),$(cat /sys/power/suspend_stats/success 2>/dev/null),$(cat /sys/power/suspend_stats/fail 2>/dev/null)" >> "$CSV"
exit 0
