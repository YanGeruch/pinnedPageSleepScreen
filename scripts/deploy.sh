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

# power hooks (OTA-wiped like the units, reinstalled by re-deploy):
# sleep-zz-pinsleep.sh shrinks the EPD rail hold during sleep so re-suspends
# never abort; sleep-wifi.sh is the STOCK reMarkable hook plus a gate that
# skips the WiFi/BT driver reload on RTC (sleep-clock) wakes. The rootfs is
# READ-ONLY, so they live in /etc/systemd/system-sleep/ — systemd masks the
# stock /usr/lib hook by filename (verify after first suspend: exactly ONE
# "Shutting down Wifi/BT" line per entry). Stock copy in
# assets/system-sleep/sleep-wifi.sh.orig; uninstall = delete the /etc copies.
ssh "$DEV" 'mkdir -p /etc/systemd/system-sleep'
scp -q assets/system-sleep/sleep-zz-pinsleep.sh assets/system-sleep/sleep-wifi.sh \
    "$DEV:/etc/systemd/system-sleep/"
ssh "$DEV" 'chmod +x /etc/systemd/system-sleep/sleep-zz-pinsleep.sh \
    /etc/systemd/system-sleep/sleep-wifi.sh
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
