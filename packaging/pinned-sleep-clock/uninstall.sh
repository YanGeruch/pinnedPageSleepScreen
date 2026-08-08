#!/bin/sh
# Revert every system change (pre-deinstall). Best-effort — no set -e:
# a partial system should still end up as close to stock as possible.
HOOKDIR=/usr/lib/systemd/system-sleep
STOCK_BACKUP=/home/root/.pinnedSleepScreen/sleep-wifi.sh.stock

# overlay still up: this stops the timer and clears the runtime (volatile)
# enable symlink the settings toggle created
systemctl disable --now pinsleep-clock.timer 2>/dev/null

/home/root/.vellum/bin/mount-rw
if [ -e "$STOCK_BACKUP" ]; then
	cp "$STOCK_BACKUP" "$HOOKDIR/sleep-wifi.sh"
	chmod 0755 "$HOOKDIR/sleep-wifi.sh"
fi
rm -f "$HOOKDIR/sleep-zz-pinsleep.sh"
rm -f /etc/systemd/system/pinsleep-clock.service \
      /etc/systemd/system/pinsleep-clock.timer
rm -f /var/volatile/etc/systemd/system/pinsleep-clock.service \
      /var/volatile/etc/systemd/system/pinsleep-clock.timer \
      /var/volatile/etc/systemd/system/timers.target.wants/pinsleep-clock.timer
[ "$VELLUM_PURGE" = "1" ] && rm -f "$STOCK_BACKUP"
/home/root/.vellum/bin/mount-restore
systemctl daemon-reload

# undo the sleep-state runtime tweaks in case we're mid-cycle
echo 30000 > /sys/bus/i2c/drivers/g2194-regulator/0-0048/vpdd_length 2>/dev/null
rm -f /run/pinsleep-wifi-off
lsmod | grep -q iw61x_sdw61x || modprobe iw61x_sdw61x 2>/dev/null
exit 0
