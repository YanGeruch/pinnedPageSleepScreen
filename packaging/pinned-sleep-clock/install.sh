#!/bin/sh
# Install/refresh every system piece. Idempotent — shared by post-install,
# post-upgrade and the vellum post-os-upgrade hook.
set -e
SHARE=/home/root/.vellum/share/pinned-sleep-clock
HOOKDIR=/usr/lib/systemd/system-sleep
STOCK_BACKUP=/home/root/.pinnedSleepScreen/sleep-wifi.sh.stock

# Everything after mount-rw runs with the rootfs rw and /etc's overlay down;
# the EXIT trap unwinds that on EVERY path (set -e failures included),
# preserving the original exit status — before it, any mid-install failure
# left the device writable and /etc down until reboot.
finish() {
	status=$?
	/home/root/.vellum/bin/mount-restore || true
	# mount-rw's `umount -R /etc` also rips out xovi's LD_PRELOAD drop-in
	# tmpfs mounts and mount-restore does NOT put them back — the paths stay
	# visible through the overlay, so test the MOUNT, not the path (the same
	# trap scripts/package.sh checks for). Left unrepaired, the next xochitl
	# restart silently boots STOCK xochitl with every mod gone. Re-establish
	# exactly what xovi/start mounts, minus its service restarts: the running
	# xochitl already carries the preload; the drop-in matters for the NEXT
	# start only.
	for source_dir in /home/root/xovi/services/*/; do
		[ -d "$source_dir" ] || continue
		target_dir="/etc/systemd/system/$(basename "$source_dir").d"
		if ! grep -q " $target_dir " /proc/mounts; then
			mkdir -p "$target_dir"
			mount -t tmpfs tmpfs "$target_dir"
			cp -ra "$source_dir/." "$target_dir"
			printf '[Service]\nEnvironment="LD_PRELOAD=/home/root/xovi/xovi.so"\nEnvironment="XOVI_ROOT=%s"\n' \
				"$source_dir" > "$target_dir/00-xovi.conf"
		fi
	done
	systemctl daemon-reload
	exit "$status"
}
trap finish EXIT

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

# Deliberately NO `systemctl enable --now` here: the timer is armed ONLY by
# the main mod's xochitl-start re-assert (qmd Component.onCompleted, default
# cadence 5 min — it must re-assert anyway, /etc's enable symlink is volatile).
# An installer-armed timer outlives the mod: if xovi detaches (mount-rw's
# umount -R /etc) the device wakes every 5 min forever with the Settings
# panel that could stop it no longer loaded. Arming only from live mod code
# makes that state unreachable; installing still opts in, one restart later.
