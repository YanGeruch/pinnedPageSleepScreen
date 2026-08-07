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
    src/pinnedPageSleepScreen.qmd >/dev/null
echo "pre-flight: diffs apply cleanly"

scp -q src/pinnedPageSleepScreen.qmd "$DEV:$EXTHOME/"
scp -q assets/pinnedSleepScreen.svg "$DEV:$EXTHOME/pinnedSleepScreen.svg"

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
# batterymanager re-suspend delay env drop-in (see the file header) — must be
# on disk BEFORE the daemon-reload below or the xochitl restart uses a stale
# unit definition. The drop-in dir is xovi's tmpfs mount, absent after a
# reboot until xovi/start runs; then the note fires and a re-deploy fixes it.
scp -q assets/systemd/99-pinsleep-env.conf \
    "$DEV:/etc/systemd/system/xochitl.service.d/" 2>/dev/null || \
    echo "NOTE: xovi drop-in dir missing, UPKEEP env not installed (re-deploy after xovi start)"

scp -q assets/system-sleep/sleep-zz-pinsleep.sh assets/system-sleep/sleep-wifi.sh \
    "$DEV:/tmp/"
ssh "$DEV" 'mount -o remount,rw /
[ -e /usr/lib/systemd/system-sleep/sleep-wifi.sh.stock ] || \
    cp /usr/lib/systemd/system-sleep/sleep-wifi.sh /usr/lib/systemd/system-sleep/sleep-wifi.sh.stock
mv /tmp/sleep-zz-pinsleep.sh /tmp/sleep-wifi.sh /usr/lib/systemd/system-sleep/
chmod +x /usr/lib/systemd/system-sleep/sleep-zz-pinsleep.sh \
    /usr/lib/systemd/system-sleep/sleep-wifi.sh
mount -o remount,ro /
# dead copies from the /etc attempt (that dir is never scanned)
rm -rf /etc/systemd/system-sleep
systemctl daemon-reload
# apply a changed OnCalendar if the timer is currently enabled+running
systemctl try-restart pinsleep-clock.timer 2>/dev/null || true'

ssh "$DEV" '
# systemd allows 4 xochitl starts per 10min (StartLimitBurst); exceeding it
# fails the unit and the recovery watchdog REBOOTS the device (2026-08-06).
# reset-failed clears the rate counter before every restart.
systemctl reset-failed xochitl 2>/dev/null
if [ -d /etc/systemd/system/xochitl.service.d ]; then
    systemctl restart xochitl
else
    echo "xovi drop-in missing (rebooted?) -> running xovi/start"
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
