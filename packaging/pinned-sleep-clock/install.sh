#!/bin/sh
# Install/refresh every system piece. Idempotent — shared by post-install,
# post-upgrade and the vellum post-os-upgrade hook.
set -e
SHARE=/home/root/.vellum/share/pinned-sleep-clock
HOOKDIR=/usr/lib/systemd/system-sleep
STOCK_BACKUP=/home/root/.pinnedSleepScreen/sleep-wifi.sh.stock

# rootfs rw + /etc overlay down: writes go to the persistent lower layer
/home/root/.vellum/bin/mount-rw

# Back up the stock WiFi hook ONCE, and only while the file is genuinely
# stock — a backup taken after our replacement landed would poison the
# uninstall restore (the gate mentions "pinsleep"; stock does not).
if [ ! -e "$STOCK_BACKUP" ] && ! grep -q pinsleep "$HOOKDIR/sleep-wifi.sh" 2>/dev/null; then
	mkdir -p "$(dirname "$STOCK_BACKUP")"
	cp "$HOOKDIR/sleep-wifi.sh" "$STOCK_BACKUP"
fi

cp "$SHARE/sleep-zz-pinsleep.sh" "$HOOKDIR/sleep-zz-pinsleep.sh"
cp "$SHARE/sleep-wifi.sh"        "$HOOKDIR/sleep-wifi.sh"
chmod 0755 "$HOOKDIR/sleep-zz-pinsleep.sh" "$HOOKDIR/sleep-wifi.sh"

# Units to the REAL /etc so they survive reboot; then drop any stale copies
# from the volatile upper layer, which would shadow these until reboot.
cp "$SHARE/pinsleep-clock.service" "$SHARE/pinsleep-clock.timer" /etc/systemd/system/
chmod 0644 /etc/systemd/system/pinsleep-clock.service /etc/systemd/system/pinsleep-clock.timer
rm -f /var/volatile/etc/systemd/system/pinsleep-clock.service \
      /var/volatile/etc/systemd/system/pinsleep-clock.timer

/home/root/.vellum/bin/mount-restore
systemctl daemon-reload
# pick up a changed OnCalendar if the user has the clock toggle enabled
systemctl try-restart pinsleep-clock.timer 2>/dev/null || true
