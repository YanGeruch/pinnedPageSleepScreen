#!/bin/sh
# Deploy the mod to the tablet for development and restart xochitl.
#
# Pre-flight: apply our diff together with ALL installed mods (research/preflight —
# every device qmd de-hashed, with the two AFFECTs on files we can't extract from the
# binary stripped: SceneSelectionHandler, homescreen CreateMenu) against QML extracted
# from the device binary — same engine the device runs, catches diff errors before
# deploy. Regenerate the set after installing/updating mods on the tablet:
#   scp 'root@10.11.99.1:/home/root/xovi/exthome/qt-resource-rebuilder/*.qmd' research/device-installed/
# then re-run the de-hash + strip step (see git log for the python snippet, v0.11).
# NOTE it does NOT type-check property assignments or import resolution: assigning a
# non-existent property still applies cleanly here and crash-loops the device.
#
# Restart: xovi injects LD_PRELOAD through a *tmpfs* systemd drop-in
# (/etc/systemd/system/xochitl.service.d), so it does NOT survive a reboot — and after a
# reboot `systemctl restart xochitl` silently starts STOCK xochitl with no mods at all.
# So if the drop-in is missing, re-run xovi's own start script, detached: restarting
# xochitl kills our SSH session, which would otherwise SIGHUP the script mid-mount.
#
# Health check: `systemctl is-active` reports "active" even during a crash-restart loop,
# and stock xochitl is always healthy — neither proves anything on its own. So verify our
# qmd was actually LOADED, and look for the compile-failure cascade. Other mods on this
# device log their own "Cannot assign" noise, so gate on "Type X unavailable"/FAILURE,
# which is what a real breakage in our file produces anyway.
set -e
cd "$(dirname "$0")/.."

QMLDIFF=research/qmldiff/target/release/qmldiff
DEV=root@10.11.99.1
EXTHOME=/home/root/xovi/exthome/qt-resource-rebuilder

$QMLDIFF apply-diffs research/device-qml /tmp/qml-preflight -c \
    research/preflight \
    src/pinnedPageSleepScreen.qmd \
    src/hideSidebarGuides.qmd >/dev/null
echo "pre-flight: diffs apply cleanly"

# fastshot ships WITH the qmd, rebuilt from source at fastshot.xovi's version:
# qmd >=0.39 fails CLOSED against an older .so (chapters read unavailable,
# clock degrades to "Sleeping") — a qmd-only deploy looks like a total feature
# regression. Never trust the gitignored working-copy binary.
FSVER=$(awk '$1=="version"{print $2; exit}' extensions/fastshot/fastshot.xovi)
make -C extensions/fastshot clean all VERSION="$FSVER" >/dev/null
strings extensions/fastshot/fastshot.so | grep -qx "\[fastshot\]: loaded ($FSVER)" || {
    echo "built fastshot.so does not embed version $FSVER" >&2; exit 1; }
echo "fastshot built: $FSVER"

scp -q src/pinnedPageSleepScreen.qmd src/hideSidebarGuides.qmd "$DEV:$EXTHOME/"
# timezoneLocalePicker v0.1.0 scrapped (owner ruling 2026-08-20: wrong Settings
# section, wrong controls — rebuild from scratch later). Idempotent removal so
# any device that got the v0.1.0 wave is cleaned by its next deploy.
ssh "$DEV" "rm -f $EXTHOME/timezoneLocalePicker.qmd"
scp -q assets/pinnedSleepScreen.svg "$DEV:$EXTHOME/pinnedSleepScreen.svg"
scp -q assets/pinnedSleepBolt.svg "$DEV:$EXTHOME/pinnedSleepBolt.svg"
scp -q assets/pinnedSleepBoltInv.svg "$DEV:$EXTHOME/pinnedSleepBoltInv.svg"
# stage + rename: the running xochitl has the old .so mapped — an in-place
# scp truncates the mapped inode, mv swaps the directory entry atomically
scp -q extensions/fastshot/fastshot.so "$DEV:/tmp/fastshot.so.new"
ssh "$DEV" 'mv /tmp/fastshot.so.new /home/root/xovi/extensions.d/fastshot.so'

# sleep-clock wake units (idempotent; /etc is wiped by OTA updates, same as the
# xovi setup — a re-deploy after OTA reinstalls them). The settings toggle owns
# enable/disable; we only make the units available and reload.
scp -q assets/systemd/pinsleep-clock.timer assets/systemd/pinsleep-clock.service \
    "$DEV:/etc/systemd/system/"

# power hooks. This systemd build scans ONLY /usr/lib/systemd/system-sleep
# (single dir string in the binary — /etc/systemd/system-sleep is dead), and
# the rootfs is read-only, so: remount rw, install, remount ro.
# sleep-zz-pinsleep.sh shrinks the EPD rail hold during sleep so re-suspends
# never abort; sleep-wifi.sh REPLACES the stock hook, adding a gate that skips
# the WiFi/BT driver reload on RTC (sleep-clock) wakes. Stock copy kept on
# device as sleep-wifi.sh.stock and in assets/system-sleep/sleep-wifi.sh.orig.
# An OTA update replaces the rootfs partition wholesale -> stock returns,
# re-deploy reinstalls. Uninstall: restore sleep-wifi.sh.stock, rm zz hook.
scp -q assets/system-sleep/sleep-zz-pinsleep.sh assets/system-sleep/sleep-wifi.sh \
    "$DEV:/tmp/"
ssh "$DEV" 'mount -o remount,rw /
# stock backup goes OUTSIDE the hook dir: systemd-sleep executes EVERY
# executable there, backups included (learned the hard way — the .stock
# copy ran alongside the gate and defeated it). Only taken once, before
# our replacement ever landed, so it is genuinely stock.
# backup must SUCCEED before the replacement lands: no set -e in this block,
# and on a fresh device the parent directory does not exist yet — a failed
# cp used to exit 0 and the gate replaced stock with no restore path. Also
# never back up a file that already carries the gate (grep pinsleep), or a
# re-deploy after partial state would poison the uninstall restore.
mkdir -p /home/root/.pinnedSleepScreen
if [ ! -e /home/root/.pinnedSleepScreen/sleep-wifi.sh.stock ] \
        && ! grep -q pinsleep /usr/lib/systemd/system-sleep/sleep-wifi.sh 2>/dev/null; then
    cp /usr/lib/systemd/system-sleep/sleep-wifi.sh /home/root/.pinnedSleepScreen/sleep-wifi.sh.stock \
        || { echo "stock sleep-wifi.sh backup FAILED — not replacing the hook"
             mount -o remount,ro /; exit 1; }
fi
mv /tmp/sleep-zz-pinsleep.sh /tmp/sleep-wifi.sh /usr/lib/systemd/system-sleep/
chmod +x /usr/lib/systemd/system-sleep/sleep-zz-pinsleep.sh \
    /usr/lib/systemd/system-sleep/sleep-wifi.sh
mount -o remount,ro /
# dead copies from the /etc attempt (that dir is never scanned)
rm -rf /etc/systemd/system-sleep
systemctl daemon-reload
# apply a changed OnCalendar if the timer is currently enabled+running
systemctl try-restart pinsleep-clock.timer 2>/dev/null || true
# /etc is volatile: a reboot silently reverts the timezone to UTC
# (user-visible as a 3h-slow clock). The timezone mod that owned this was
# scrapped (2026-08-20), so the deploy fallback is back in charge until its
# rebuild lands; the [ -e ] guard stays so the rebuild takes over silently.
[ -e /home/root/xovi/exthome/qt-resource-rebuilder/timezoneLocalePicker.qmd ] \
    || timedatectl set-timezone Europe/Kyiv 2>/dev/null || true'

ssh "$DEV" '
# systemd allows 4 xochitl starts per 10min (StartLimitBurst); exceeding it
# fails the unit and the recovery watchdog REBOOTS the device (2026-08-06).
# reset-failed clears the rate counter before every restart.
systemctl reset-failed xochitl 2>/dev/null
# test the MOUNT, not the path: mount-utils (vellum) does `umount -R /etc`
# which rips out the xovi tmpfs while the dir stays visible via the overlay
if grep -q " /etc/systemd/system/xochitl.service.d " /proc/mounts; then
    systemctl restart xochitl
else
    echo "xovi drop-in tmpfs missing (reboot or mount-utils) -> running xovi/start"
    nohup setsid /home/root/xovi/start >/tmp/xovi-start.log 2>&1 < /dev/null &
fi' || true

# the restart drops the USB SSH session; wait for it to come back
sleep 20
until ssh -o ConnectTimeout=10 "$DEV" 'echo up' >/dev/null 2>&1; do sleep 5; done

ssh "$DEV" '
loaded=$(journalctl -u xochitl --since "90 sec ago" | grep -c "Loading file pinnedPageSleepScreen")
broke=$(journalctl -u xochitl --since "90 sec ago" | grep -ciE "Type .* unavailable|FAILURE")
echo "xochitl: $(systemctl is-active xochitl)  mod loaded: $loaded  breakage: $broke"
if [ "$loaded" -eq 0 ]; then
    echo "WARNING: mod never loaded — xovi not active, changes are NOT live"
fi
if [ "$broke" -gt 0 ]; then
    echo "BROKEN — roll back with:"
    echo "  ssh root@10.11.99.1 \"rm /home/root/xovi/exthome/qt-resource-rebuilder/pinnedPageSleepScreen.qmd && systemctl restart xochitl\""
    journalctl -u xochitl --since "90 sec ago" | grep -iE "non-existent|is not a type|Unable to assign" | tail -n 3
fi'
