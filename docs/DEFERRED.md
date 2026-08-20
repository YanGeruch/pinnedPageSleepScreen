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
  VELBUILD can build. Deploy wiring, owned by task #9. DONE 2026-08-19 (7a9d30a).
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
  DONE 2026-08-19 (7a9d30a): staged by deploy.sh/package.sh, installed by the VELBUILD.
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
  owned by task #9. Deploy half DONE 2026-08-19 (7a9d30a): the timedatectl fallback now
  fires only when timezoneLocalePicker.qmd is absent on the device. README half DONE
  2026-08-19: the picker mod is the primary route, the mount-rw fallback carries the
  xovi-detach warning.
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
  DONE 2026-08-19 (618e07e): exact name mini-light-sleep-1.0.5-r3 confirmed on-device,
  conflict declared in the main VELBUILD and package.sh. Same apk query settled
  rmppmove vs rmppm: rmppmove-1.0.0-r0 is real and PROVIDES rmppm — recipes stay.
- WP9: `docs/power-design.md:130-138` and `docs/wakelock-trace.md:69` still assert the
  disproved "clock prevents hibernation / 4 h deadline never arrives" premise (plan-d now
  carries a dated erratum, those two do not). Reconciling all power docs around xochitl's
  cumulative already-slept controller is doc work owned by task #9. DONE 2026-08-19:
  both files now carry matching dated errata pointing at ghostdata/analysis.md.
- WP9: xochitl's `already slept` counter cannot be reconciled with any window boundary in
  the ghost-night log (`ghostdata/analysis.md:223` — measured 25,004 s cumulative vs 14,419 s
  reported), so its zero point, reset rule and cadence dependence are unknown. Until a
  controlled repeat (clock off / 1 / 5 / 15 min) pins them down, no doc may state a
  time-to-hibernate. Device probe, task #10.
- WP9: `packaging/*/VELBUILD` pkgver is 0.31.2 against a v0.39.0 tree — already named in the
  plan's Out of scope as task #9's; noted here only so the two lists agree.
  DONE 2026-08-19 (2b59ba6): pkgvers bumped to 0.40.0 and package.sh now derives versions
  from the qmd headers + fastshot.xovi and fails the build on any recipe mismatch.
- OWNER IDEA 2026-08-16 (not a defect — a staleness fix): strokes written and then
  navigated away from before the pen-lift capture fires are never captured, so the sleep
  image silently lags the page. Proposal: on navigate-away (page change / document close),
  if the page is dirty since the last capture, take a SYNCHRONOUS shot — the view is being
  torn down anyway, so a ~70ms hitch is invisible there, unlike during writing. Pairs with
  the parked self-capture merge (sleep-time screen grab + chapter data to patch out the
  toolbar). Distinct from the audit's chapter-freshness race, which was metadata published
  ahead of pixels.
- OWNER QUESTION 2026-08-16 (open, low risk): v0.39.0 made the capture-time `pinned.json`
  write synchronous, so a small unfsynced write now sits on the interactive path (every
  pen-lift capture). writeFileAtomic has no fsync (page cache only, microseconds), but if
  any writing-latency hitch shows up on device, the conservative variant is sync write for
  the pin/unpin tap only and async for capture-time saves. Watch for it in task #10.
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
  verify the embedded version against `fastshot.xovi`. DONE 2026-08-19 (7a9d30a): both
  scripts clean-build at fastshot.xovi's version and verify the embedded loaded-banner.
- WP10, task #10 (low risk, cost only): the sleep-entry capture's "skip when forced"
  test reads `Values.pinSleepForceFreeze` WITHOUT clearing it, and the Navigator's handler
  for the same emission clears it — if that slot runs first (its Connections is older, so
  it likely does) the test reads 0 and a long-press sleep pays one extra ~70ms grab on top
  of the freeze grab. Never a wrong pixel: both shots capture the same pre-render frame and
  serialize on fastshot's captureLock. If task #10 measures the entry and wants the 70ms
  back, the fix is a Navigator-published one-shot marker, not a second read of the flag.
- WP10 / DEPLOY BLOCKER, task #9 (extends the WP8 entry above): v0.40.0 wants fastshot
  >= 0.8.0 for `fastAbortShots`. This one fails OPEN — an older `.so` just answers nothing
  and the in-flight async shot is not cancelled, i.e. the pre-v0.40 behaviour — but the
  same deploy/package gap applies: rebuild with `make VERSION=0.8.0` and ship the `.so`.
  DONE 2026-08-19 (7a9d30a), same fix as the WP8 entry above.

- LADDER 2026-08-19 (v0.36.0 on-panel review, owner): four items for the post-ladder fix
  wave (v0.41): (1) the Display style radios render as round HTML-style circles — must use
  the square native-shaped control the sleep-clock cadence setting already uses; (2) OWNER
  RULING closing the WP4a contacts-strip question above: the black style DOES invert the
  contacts strip, and the black bar's border must be black (match background, or drop the
  border entirely) — only the white bar needs a visible border since there is no natural
  black page; (3) the black style ships its own battery SVG instead of inverting the
  system-wide indicator — investigate whether the stock widget/canvas can be inverted
  before accepting the asymmetry; (4) BUG: v0.36.0's Translucent option renders identical
  to White (no transparency at all) — v0.38.0 rebuilds translucent on fastLuma islands, so
  judge at Batch 5: if still opaque there, transparency support itself is the blocker
  (background may need to not render at all).
- LADDER 2026-08-19 (v0.37.0 on-panel review, owner): pin button is a partial
  implementation for the v0.41 fix wave. (1) It only renders when the toolbar sits on the
  LONG edge of the panel; on the short edge the toolbar's overflow tools collapse into the
  "more tools" popup and the mod never adds itself there — so it is toolbar-width
  dependent, not orientation dependent, and the button silently disappears. Fix: register
  in the more-tools popup like stock overflow tools. (2) The legacy pin control on the page
  selection UI was supposed to be REMOVED and replaced by the toolbar button — it still
  exists; remove it. (3) Redesign the control to the ecosystem pattern used by the
  installed touch-lock mod: state shown by swapping icons (their lock opens/closes) rather
  than a permanent highlight, and when it lands in the more-tools popup render a toggle
  next to the wider row label. Long-press sleep-now works correctly as shipped.
- LADDER 2026-08-19 (v0.38.0 frost taste test, owner): transparency itself WORKS at
  v0.38.0 — the v0.36.0 opaque-translucent entry above is superseded (placeholder code).
  Verdicts for the v0.41 fix wave: (1) islands look bad over pictures/images and only pass
  on primarily-white ink pages where the plate covers strokes — overall "mid"; (2) even the
  white island uses the discarded prototype battery icon — the stock battery canvas/image
  must be used wherever rendering it is possible (same investigation as the v0.36.0 black
  style entry); (3) text on translucent islands has NO outline at all (only the unwanted
  custom battery icon has one) — the half-transparent island is decent but the text needs a
  FULLY OPAQUE white outline for contrast, as originally planned: plate stays translucent,
  glyph outlines opaque; (4) the fastLuma dark-region detection fires correctly but the UI
  response is misconfigured — over detected-dark content the text/battery must INVERT to
  white (no outline needed then: white strokes contrast by themselves), instead today text
  stays black outline-less and the battery stays black-with-white-outline.
- LADDER 2026-08-19 (owner, pre-existing — NOT introduced by this wave): the pinned image
  sometimes captures transient chrome — the more-tools popup, or the edge-gesture quick
  settings — if open when the chapter was grabbed. The patch-out logic handles each known
  toolbar rect separately instead of discovering every chrome element present at capture
  time; those overlays may sit on a different layer or miss the chapter's chrome-rect
  metadata due to timing. Investigate: enumerate ALL visible chrome (e.g. every
  _uiContainer child) into the chapter rects at grab time, or gate capture while transient
  popups are open.
- LADDER 2026-08-19 (v0.40.0 on-device diagnosis, journal-proven): TWO stacked bugs make
  the sleep-entry feature misfire; both are v0.41 priority-1. (A) At button entry the
  native suspend path hides chrome in the QML TREE before sleepEntryCapture runs, while
  the FRAMEBUFFER the grab reads still shows the toolbar — chromeNow() answers [] (journal:
  30s-tick captures log rects=3, the sleep-entry lines seconds later log "rects=0
  chapters=1"), so a chrome-full frame is recorded as a clean superseding ch0 and the
  book's genuinely clean chapters are DISCARDED. Fix direction: keep a last-known chrome
  snapshot maintained while displayState is Normal and use it when the entry-time tree
  query answers empty. (B) sleepEntryCapture stamps ts AFTER the synchronous grab
  (grab-before-save, ~:1107-1111), so the chapter file's mtime is always a few ms OLDER
  than its ts — v0.39's zero-tolerance staleness guard ("the write always follows the ts")
  then drops EVERY sleep-entry chapter at read time. With the book superseded by (A),
  avail=[] while chapters.length>0, pinned collapses to FALSE and the window falls to the
  freeze path (current.bmp, chrome and all) — or, with lightSleepEnabled OFF, to the STOCK
  CAROUSEL after any quick sleep. Fix: stamp ts before the grab. Note the two bugs mask
  each other: (B) prevented (A)'s poisoned ch0 from ever rendering via the pinned path, and
  the freeze image made the v0.40 fresh-strokes smoke test look like a pass.

- 2026-08-19 (v0.41): transient-chrome capture gap (more-tools popup / edge quick-settings baked into chapters) SPLIT OUT of v0.41 per the fix-wave plan allowance — closing it needs device object-tree probing to find the popup/overlay items (they are not children of the toolbar GridLayout that pinSleepOwnRects enumerates); the two P1 sleep-entry fixes shipped without it.

- 2026-08-20 (v0.44): light->deep freeze clobber — the awake->light entry writes a good
  captured:true record, but the later 1->2 transition takes the generic
  pinSleepPower.write(previous, next, false) fall-through and overwrites it with
  captured:false, so the deep window's fromLight arm (built exactly for this path) never
  fires and an idle nap that passed through light sleep falls to the STOCK carousel
  (observed on device 02:36->02:38 cycle). Fix direction: the 1->2 write must carry the
  prior record's captured flag (or fastRead-verify current.bmp) and its orient. DEFERRED
  at owner request — they will reproduce with idle capturing for concrete data first.

- 2026-08-20 (v0.44): owner observation "outline mode only worked after reloading the UI"
  — never root-caused; the tier-3 selector it was observed on is now deleted (translucent
  is always dynamic), so re-test whether a LIVE white<->translucent style flip in Settings
  renders on the next sleep without a UI reload before chasing anything.

- 2026-08-20 (v0.44.4): luma sampling accuracy — the white-bar test samples only
  the two gap slices flanking the center text run (~20% of the bar), so edge
  content is ignored and near-center strokes decide the whole bar (owner-observed
  with highlighter placement tests). Owner ruling: works well enough to evaluate
  in LIVE USE first; refine only if day-to-day misreads show up. Candidate
  revisions, both within the existing 24x2 cell machinery: whole-bar single vote,
  or 2-of-3 region votes.

- 2026-08-20 (v0.44.4): battery outline plate — dynamic bar's stock battery
  widget gets an opposite-color rectangular plate UNDER it (widget pixel size
  plus a few px of visible outline; the widget itself stays untouched). Widget
  crop + measured dimensions (78x63 on the Move bar, charging bolt included)
  in docs/battery-widget/. Contacts-strip text outline rides the same
  stylistic round. Post-compaction work — needs no flash-hunt context beyond
  what fix-wave-plan.md's v0.44.2–v0.44.4 section records.
