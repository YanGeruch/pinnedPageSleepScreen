# Deferred findings

One line per finding, appended by WP agents. Findings only — never fixes.

- WP1: unverified — chapter chrome rects come from `mapToItem(DocumentView root)`
  (`src/pinnedPageSleepScreen.qmd:358-372`) while `complement()` clips against the
  sleep window's `root.width/height` (physical portrait, 954x1696 fallback at
  `:1147-1148`). If DocumentView's root is logical-landscape in landscape, the
  chapter holes are computed on swapped axes for exactly the captures WP1 now
  rotates the bar for. Needs a device check (task #10); `complement()` is TRAP-fenced.
- WP7: scripts/package.sh:31 stages only pinnedPageSleepScreen.qmd + SVG into $srcdir —
  hideSidebarGuides.qmd (and any future standalone qmd) needs a staging line before its
  VELBUILD can build. Deploy wiring, owned by task #9.
- WP2: date stamp ("Wed, 6 Aug") is wider than the old numeric form; stamp has no elide/width
  and is left-anchored beside the centered time — check clearance on the narrowest bar. WP3 owns sizing.
- WP3: the plan's directive to multiply the scale into the battery icon factor `f` was NOT followed —
  `f = BattPct.height / battery.implicitHeight` already tracks the scaled text, so a second multiply
  would give 1.35^2 = 1.8225x and overflow the enclosing Item (height stays BattPct.height). Fonts only.
- WP3: `Screen` resolution inside the two sleep-window QML files is unverified on device (stock precedent
  is systemclock/SpinnersContainer.qml:42 under the same bare `import QtQuick`); a try/catch falls back to
  Move sizing, so the worst case is "no upsizing anywhere". Confirm on a 10"/13" panel in task #10.
- WP4a: `assets/pinnedSleepBoltInv.svg` is not staged or installed anywhere — scripts/package.sh:31
  stages only pinnedPageSleepScreen.qmd + the two existing SVGs, and packaging/pinned-page-sleep-screen/
  VELBUILD has no install line for it. Without that wiring the black style's charging bolt is a missing
  file (Image renders nothing; the icon and % still draw). Packaging, owned by task #9.
- WP4a: the black style stops at the clock bar — `pinSleepContacts` (owner name/contact strip) and the
  `pinSleepBroken` failure page stay white-on-black-text. The failure page must (it sits on the stock
  white InputBlocker), the contacts bar is an owner design call: WP4 names only "the bar" and the setting
  is `pinSleepBarStyle`.
- WP4a: the battery icon's mod-drawn geometry is the strip mockup's (research/halo-poc/strips.py:22-37),
  not a measurement of ark's compiled BatteryIndicator — its metrics are unreadable off-device. Compare
  the two arms side by side in task #10; only the black arm uses the mod-drawn one.
- WP4a: the comment at both battery Rows ("user-specified order: percentage, bolt, ... icon rightmost")
  has described the wrong order since the children were [icon, percentage]; left as found.
- WP6: README.md:83-118 still presents the mount-rw `/etc/locale.conf` + `timedatectl`
  window as the ONLY way to set locale/timezone, and deploy.sh:74-76 hardcodes a
  `timedatectl set-timezone Europe/Kyiv` re-assert — both now have an in-UI equivalent
  (Settings > Display) that would silently fight a hand-set value. Docs/deploy wiring,
  owned by task #9.
- WP4b: Qt's `Text.Outline` draws a fixed-width outline (no `styleWidth` route in this
  Qt), so the island glyphs get whatever it paints rather than the mockup's 2px halo;
  the mod-drawn battery halo IS 2px-equivalent (grown by 2u). Whether the two read as
  the same weight on the panel is a task #10 visual check.
- WP4b: fastshot 0.6.0 adds the `fastLuma` handler, so the built `.so` shipped in the
  package changes; VELBUILD/package.sh wiring for it is task #9's, untouched here.
- WP9: no package removes `/home/root/.pinnedSleepScreen/` — the main VELBUILD ships no
  lifecycle script and the companion's uninstall.sh:22 drops only `sleep-wifi.sh.stock`
  under `VELLUM_PURGE=1`. README now documents the truth; a real purge hook needs its own
  design round (apk runs deinstall hooks on upgrade paths too, so a naive `rm -rf` would
  eat user pins on every upgrade). Packaging, owned by task #9.
- WP9: the `!mini-light-sleep` conflict declaration is not in either VELBUILD — the README
  compatibility note is advisory only, nothing stops a user installing the incompatible
  pair. Needs the ecosystem's exact package name. Packaging, owned by task #9.
- WP9: `docs/power-design.md:130-138` and `docs/wakelock-trace.md:69` still assert the
  disproved "clock prevents hibernation / 4 h deadline never arrives" premise (plan-d now
  carries a dated erratum, those two do not). Reconciling all power docs around xochitl's
  cumulative already-slept controller is doc work owned by task #9.
- WP9: xochitl's `already slept` counter cannot be reconciled with any window boundary in
  the ghost-night log (`ghostdata/analysis.md:223` — measured 25,004 s cumulative vs 14,419 s
  reported), so its zero point, reset rule and cadence dependence are unknown. Until a
  controlled repeat (clock off / 1 / 5 / 15 min) pins them down, no doc may state a
  time-to-hibernate. Device probe, task #10.
- WP9: `packaging/*/VELBUILD` pkgver is 0.31.2 against a v0.39.0 tree — already named in the
  plan's Out of scope as task #9's; noted here only so the two lists agree.
- WP8 / DEPLOY BLOCKER, task #9: v0.39.0 REQUIRES fastshot >= 0.7.0 (`fastStat`), and the
  new capability checks fail CLOSED — against an older `.so` every chapter reads as
  unavailable (pinned sleep screen degrades to the stock carousel) and `pinSleepHasClock`
  reads false (static "Sleeping" instead of the clock). Both are safe, both look like a
  total feature regression. `scripts/deploy.sh` ships ONLY the qmd, SVGs, units and sleep
  hooks — it never ships `fastshot.so` at all (:37-56) — and `scripts/package.sh:34` copies
  a PRE-BUILT `extensions/fastshot/fastshot.so` without running `make`. So the native
  extension MUST be rebuilt (`make VERSION=0.7.0`) and installed on the device in the same
  operation as the v0.39.0 qmd, or the mod visibly breaks. Fix both scripts before the next
  deploy: add the `.so` to deploy.sh's payload, and make package.sh build from source and
  verify the embedded version against `fastshot.xovi`.
