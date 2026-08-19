#!/bin/sh
# Build all four vellum packages ON THE DEVICE (its apk 3.0.3 provides mkpkg and
# the vellum-generated local signing key), pull the .apks into dist/, and
# install them via `vellum add`. The VELBUILD files in packaging/ are the
# upstream (packages.vellum.delivery CI) recipes; this script is the local
# equivalent and must be kept in sync with them.
#
# NOTE: does not restart xochitl — a qmd change needs the usual
# reset-failed + restart afterwards (see deploy.sh's health check).
set -e
cd "$(dirname "$0")/.."

DEV=root@10.11.99.1
QMLDIFF=research/qmldiff/target/release/qmldiff

# Versions are single-sourced: the qmd header (line 1) owns the release
# version, fastshot.xovi owns the extension's. The VELBUILDs are
# hand-maintained upstream copies — refuse to build when they disagree
# (both packages shipped as 0.31.2 against a v0.40.0 tree once).
VER=$(sed -n '1s/^; pinnedPageSleepScreen v\([0-9][0-9.]*\)$/\1/p' src/pinnedPageSleepScreen.qmd)
[ -n "$VER" ] || { echo "cannot read version from src/pinnedPageSleepScreen.qmd:1" >&2; exit 1; }
FSVER=$(awk '$1=="version"{print $2; exit}' extensions/fastshot/fastshot.xovi)
[ -n "$FSVER" ] || { echo "cannot read version from extensions/fastshot/fastshot.xovi" >&2; exit 1; }
GUIDESVER=$(sed -n '1s/^; hideSidebarGuides v\([0-9][0-9.]*\)$/\1/p' src/hideSidebarGuides.qmd)
[ -n "$GUIDESVER" ] || { echo "cannot read standalone qmd versions" >&2; exit 1; }
for pair in \
	"packaging/pinned-page-sleep-screen/VELBUILD $VER" \
	"packaging/pinned-sleep-clock/VELBUILD $VER" \
	"packaging/hide-sidebar-guides/VELBUILD $GUIDESVER"; do
	vb=${pair% *}; want=${pair#* }
	grep -q "^pkgver=$want\$" "$vb" || {
		echo "$vb pkgver disagrees with its qmd header v$want — fix the recipe first" >&2; exit 1; }
done
echo "versions: main/clock $VER, fastshot $FSVER, guides $GUIDESVER"

# same pre-flight as deploy.sh: never package a qmd that doesn't apply.
# Both qmds together — cross-mod conflicts must surface locally.
$QMLDIFF apply-diffs research/device-qml /tmp/qml-preflight -c \
    research/preflight \
    src/pinnedPageSleepScreen.qmd \
    src/hideSidebarGuides.qmd >/dev/null
echo "pre-flight: diffs apply cleanly"

# fastshot is BUILT, never trusted from the working copy: a stale gitignored
# .so is invisible to review and to git status. Clean build (an incremental
# one skips relink on a VERSION-only change), then check the banner string
# actually embedded in the ELF against fastshot.xovi's version.
make -C extensions/fastshot clean all VERSION="$FSVER" >/dev/null
strings extensions/fastshot/fastshot.so | grep -qx "\[fastshot\]: loaded ($FSVER)" || {
	echo "built fastshot.so does not embed version $FSVER" >&2; exit 1; }
echo "fastshot built from source: $FSVER"

# ---- stage -----------------------------------------------------------------
STAGE=build/velbuild
rm -rf "$STAGE"
MAIN=$STAGE/main/root
CLOCK=$STAGE/clock/root

GUIDES=$STAGE/guides/root

mkdir -p "$MAIN/home/root/xovi/exthome/qt-resource-rebuilder" \
         "$MAIN/home/root/xovi/extensions.d"
# both bolt SVGs: the black bar style selects pinnedSleepBoltInv.svg — a
# missing file renders an empty Image where the charging bolt should be
cp src/pinnedPageSleepScreen.qmd assets/pinnedSleepScreen.svg \
    assets/pinnedSleepBolt.svg assets/pinnedSleepBoltInv.svg \
    "$MAIN/home/root/xovi/exthome/qt-resource-rebuilder/"
cp extensions/fastshot/fastshot.so "$MAIN/home/root/xovi/extensions.d/"

mkdir -p "$GUIDES/home/root/xovi/exthome/qt-resource-rebuilder"
cp src/hideSidebarGuides.qmd "$GUIDES/home/root/xovi/exthome/qt-resource-rebuilder/"

SHARE="$CLOCK/home/root/.vellum/share/pinned-sleep-clock"
mkdir -p "$SHARE" "$CLOCK/home/root/.vellum/hooks/post-os-upgrade"
cp packaging/pinned-sleep-clock/install.sh \
   packaging/pinned-sleep-clock/uninstall.sh \
   assets/system-sleep/sleep-zz-pinsleep.sh \
   assets/system-sleep/sleep-wifi.sh \
   assets/systemd/pinsleep-clock.service \
   assets/systemd/pinsleep-clock.timer "$SHARE/"
cp packaging/pinned-sleep-clock/post-os-upgrade \
   "$CLOCK/home/root/.vellum/hooks/post-os-upgrade/pinned-sleep-clock"
cp packaging/pinned-sleep-clock/post-install.sh \
   packaging/pinned-sleep-clock/pre-deinstall.sh "$STAGE/clock/"
chmod 0755 "$SHARE"/*.sh "$CLOCK/home/root/.vellum/hooks/post-os-upgrade/pinned-sleep-clock"

# ---- build on device -------------------------------------------------------
ssh "$DEV" 'rm -rf /tmp/velbuild && mkdir -p /tmp/velbuild'
# COPYFILE_DISABLE: macOS tar otherwise embeds AppleDouble ._* entries and
# apk faithfully installs them into / (learned from a failed first build)
find "$STAGE" \( -name '._*' -o -name '.DS_Store' \) -delete
COPYFILE_DISABLE=1 tar -czf - -C "$STAGE" . | ssh "$DEV" 'tar -xzf - -C /tmp/velbuild
# tar carried the Mac build uid; packages must own their files as root
chown -R root:root /tmp/velbuild'

ssh "$DEV" 'set -e
V=/home/root/.vellum/bin/vellum
KEY=/home/root/.vellum/etc/apk/keys/local.rsa
cd /tmp/velbuild
$V mkpkg \
  --info "name:pinned-page-sleep-screen" \
  --info "version:'"$VER"'-r0" \
  --info "description:Pin a document page - or the live screen - as the sleep screen; optional clock/battery bar" \
  --info "arch:aarch64" --info "license:GPL-3.0-or-later" \
  --info "origin:pinned-page-sleep-screen" \
  --info "depends:!mini-light-sleep qt-resource-rebuilder xovi-message-broker qt-command-executor framebuffer-spy rm-shot rmppmove remarkable-os>=3.27 remarkable-os<3.28" \
  --files main/root --sign-key $KEY \
  --output pinned-page-sleep-screen-'"$VER"'-r0.apk
$V mkpkg \
  --info "name:pinned-sleep-clock" \
  --info "version:'"$VER"'-r0" \
  --info "description:System hooks + 5-min wake timer for the pinned-page-sleep-screen clock bar" \
  --info "arch:aarch64" --info "license:GPL-3.0-or-later" \
  --info "origin:pinned-sleep-clock" \
  --info "depends:pinned-page-sleep-screen>='"$VER"' mount-utils rmppmove remarkable-os>=3.27 remarkable-os<3.28" \
  --script "post-install:clock/post-install.sh" \
  --script "post-upgrade:clock/post-install.sh" \
  --script "pre-deinstall:clock/pre-deinstall.sh" \
  --files clock/root --sign-key $KEY \
  --output pinned-sleep-clock-'"$VER"'-r0.apk
$V mkpkg \
  --info "name:hide-sidebar-guides" \
  --info "version:'"$GUIDESVER"'-r0" \
  --info "description:Hide the Guides entry in the xochitl navigator sidebar" \
  --info "arch:aarch64" --info "license:GPL-3.0-or-later" \
  --info "origin:hide-sidebar-guides" \
  --info "depends:qt-resource-rebuilder rmppmove remarkable-os>=3.27 remarkable-os<3.28" \
  --files guides/root --sign-key $KEY \
  --output hide-sidebar-guides-'"$GUIDESVER"'-r0.apk
ls -la /tmp/velbuild/*.apk'

mkdir -p dist/aarch64
scp -q "$DEV:/tmp/velbuild/*.apk" dist/aarch64/
echo "packages pulled to dist/aarch64/"

# ---- install ---------------------------------------------------------------
ssh "$DEV" 'cd /tmp/velbuild && /home/root/.vellum/bin/vellum add \
    ./pinned-page-sleep-screen-'"$VER"'-r0.apk \
    ./pinned-sleep-clock-'"$VER"'-r0.apk \
    ./hide-sidebar-guides-'"$GUIDESVER"'-r0.apk'

# ---- restart + health check ------------------------------------------------
# TRAP: mount-utils` mount-rw does `umount -R /etc`, which also rips out
# xovi's tmpfs drop-in mount (xochitl.service.d) and mount-restore does NOT
# put it back — the DIRECTORY still exists through the overlay, so test the
# MOUNT, not the path. A plain `systemctl restart xochitl` after any
# mount-utils package install silently starts STOCK xochitl.
ssh "$DEV" '
systemctl reset-failed xochitl 2>/dev/null
if grep -q " /etc/systemd/system/xochitl.service.d " /proc/mounts; then
    systemctl restart xochitl
else
    echo "xovi drop-in tmpfs unmounted (mount-utils) -> running xovi/start"
    nohup setsid /home/root/xovi/start >/tmp/xovi-start.log 2>&1 < /dev/null &
fi' || true

sleep 25
until ssh -o ConnectTimeout=10 "$DEV" 'echo up' >/dev/null 2>&1; do sleep 5; done

ssh "$DEV" '
loaded=$(journalctl -u xochitl --since "90 sec ago" | grep -c "Loading file pinnedPageSleepScreen")
broke=$(journalctl -u xochitl --since "90 sec ago" | grep -ciE "Type .* unavailable|FAILURE")
echo "xochitl: $(systemctl is-active xochitl)  mod loaded: $loaded  breakage: $broke"'
