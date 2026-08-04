#!/bin/sh
# Deploy the mod to the tablet for development and restart xochitl.
# Pre-flight: apply our diff together with the coexisting mods that patch the same
# files (createDocumentFromPages, linkFromSelection) against QML extracted from the
# device binary — same engine the device runs, catches diff errors before deploy.
set -e
cd "$(dirname "$0")/.."

QMLDIFF=research/qmldiff/target/release/qmldiff

$QMLDIFF apply-diffs research/device-qml /tmp/qml-preflight -c \
    research/unhashed/createDocumentFromPages.qmd \
    /tmp/lfs-test.qmd \
    src/pinnedPageSleepScreen.qmd >/dev/null
echo "pre-flight: diffs apply cleanly"

scp -q src/pinnedPageSleepScreen.qmd root@10.11.99.1:/home/root/xovi/exthome/qt-resource-rebuilder/
ssh root@10.11.99.1 '
systemctl restart xochitl
sleep 10
systemctl is-active xochitl
journalctl -u xochitl --since "30 sec ago" | grep -ciE "Cannot load|Type .* unavailable|FAILURE" || true'
