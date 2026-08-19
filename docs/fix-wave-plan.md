# Fix-wave plan — v0.41+ (authored 2026-08-19, post-ladder)

Self-contained handoff: everything a fresh session needs to implement the fix
waves. All findings below were made on-device during the 2026-08-19 staged
deploy (v0.33.0 -> v0.40.0 + fastshot 0.8.0 + standalone mods, all batches
green on health checks; the panel findings are what this plan fixes). The
matching one-line entries live in docs/DEFERRED.md; this file carries the full
reasoning and the owner rulings. Protocol: docs/mod-wave-plan.md conventions
apply (one work package = one commit, ask-rather-than-invent, per-file edits,
never push, never amend).

Device state after the ladder: qmd v0.40.0 + fastshot.so 0.8.0 +
hideSidebarGuides v0.1.0 + timezoneLocalePicker v0.1.0 installed and loaded;
v50/w3 power hooks live; companion package still 0.31.2-era (packaging round
is AFTER the fix waves, scripts/package.sh — VELBUILD source/sha512sums stay
deferred to publish time).

---

## v0.41.0 — sleep-entry correctness (PRIORITY 1: the feature is broken)

Diagnosis (journal-proven 2026-08-19, ~20:45 EEST, device time):

**Bug A — tree-vs-framebuffer chrome race.** At a button sleep entry the
native suspend path hides chrome in the QML TREE before
`sleepEntryCapture()` runs, while the FRAMEBUFFER `fastShot` grabs still
shows the toolbars. `chromeNow()` reads the tree, answers `[]`, and the
handler records a chrome-full frame as a clean superseding ch0 — DISCARDING
the genuinely clean chapters (`chapters=1` in the log). Proof: 30s-tick
captures logged `rects=3` while sleep-entry lines seconds later logged
`rects=0 chapters=1`; pulled ch1.bmp showed both toolbars while its book
entry was honest, and the "clean" superseding grabs contained toolbars.
The v0.40 header claim "button entry still has chrome up" is true for the
fb, false for the tree — and rects come from the tree, pixels from the fb.
Fix direction (owner-approved): maintain a last-known chrome snapshot while
displayState is Normal (e.g. refresh it on every captureNow and/or a cheap
property change hook); at sleep entry, when the tree query answers empty but
the snapshot says chrome was up moments ago, record the SNAPSHOT rects, not
[]. A legitimately chrome-free entry (user closed the toolbar, snapshot
already empty) still yields a superseding ch0.

**Bug B — v0.39 x v0.40 interaction: every sleep-entry chapter dropped.**
`sleepEntryCapture()` deliberately grabs BEFORE saving and stamps
`ts = Date.now()` AFTER the grab (src/pinnedPageSleepScreen.qmd ~:1107-1111),
so the chapter file's mtime is always a few ms OLDER than its ts. v0.39's
staleness guard (`applyPinned`, ~:1634) drops any chapter with mtime < ts,
zero tolerance, on the assumption "the write always follows the ts". Result:
every sleep-entry chapter is rejected at read time. Combined with Bug A's
supersede, avail=[] while chapters.length>0 -> `pinned` collapses to FALSE
-> freeze path (current.bmp, chrome and all) — or with lightSleepEnabled
OFF, the STOCK CAROUSEL after any quick sleep (the worst case; the owner's
device has light sleep on, which is why the smoke test looked like a pass:
the freeze image contained the fresh strokes).
Fix: stamp ts BEFORE the grab (capture `var ts0 = Date.now()` first, grab,
then record ts0). One line of reordering; keeps both v0.39 invariants and
v0.40's grab-before-save failure semantics (a failed grab still never
publishes a book pointing at a stale image — the push only happens on "ok:").

Also fold in (same file, same wave, cheap): the transient-chrome capture gap
— PRE-EXISTING, not introduced by the wave: more-tools popup / edge-gesture
quick settings get baked into chapters when open at grab time, because the
chrome query enumerates specific toolbars (`pinSleepOwnRects` + floating.qmd
panels) instead of discovering every visible chrome element. Investigate
enumerating `_uiContainer`'s visible children into the rects at grab time, or
gating captures while transient popups are open. If the investigation grows,
split it out rather than blocking the two P1 fixes.

Smoke test: open toolbar, write strokes, immediately press power ->
sleep image shows the strokes, NO toolbar, patched band from a clean chapter;
journal sleep-entry line shows rects>0; pinned.json chapter survives the
availability check (no freeze fallback — verify by temporarily disabling
light sleep and confirming the pinned page, not the carousel).

## v0.42.0 — black style + settings control fixes (owner rulings 2026-08-19)

1. Settings radios: the Display style radios render as round HTML-style
   circles — use the square native-shaped control the sleep-clock cadence
   setting already uses (same UI control, native shape).
2. OWNER RULING: the black bar's border must be black (match the background,
   or drop the border entirely). Only the white bar needs a visible border —
   there is no natural black page. Same rule for the contacts strip.
3. OWNER RULING (closes the WP4a open question): the black style DOES invert
   the contacts strip (it currently stays white).
4. Battery icon: the black style ships a mod-drawn segmented twin instead of
   inverting the system-wide stock indicator. The header (~:49) claims
   ArkControls.BatteryIndicator is compiled with no color route — VERIFY that
   claim before accepting the asymmetry (owner suspects the agent settled for
   the easy path). If inversion is genuinely impossible, document the proof;
   if possible, use the stock widget everywhere (this also covers v0.43 item
   2 — the white island currently uses the twin too).

Smoke test: black style sleeps with black border (or none), inverted
contacts strip, and — if item 4 lands — the stock battery icon inverted.

## v0.43.0 — translucent polish (frost taste test verdicts 2026-08-19)

Transparency itself WORKS at v0.38+ (the v0.36 opaque-translucent bug was
superseded placeholder code — do not chase it).

1. Text on translucent islands has NO outline (only the custom battery icon
   has one). Owner ruling: the plate stays translucent but the glyph outlines
   must be FULLY OPAQUE white — half-transparent islands don't give the text
   enough contrast.
2. Even the white island uses the discarded prototype battery icon — stock
   indicator wherever possible (shared investigation with v0.42 item 4).
3. fastLuma dark-region detection fires correctly but the response is
   misconfigured: over detected-dark content the text/battery must INVERT to
   white with NO outline (white strokes contrast by themselves); today text
   stays black outline-less and the battery stays black-with-white-outline.
4. Aesthetic note, no ruling yet: islands look bad over pictures/images and
   only pass on primarily-white ink pages ("mid" overall). Revisit after 1-3
   land; may become a design round.

Smoke test: translucent + each sub-mode over a photo page and an ink page;
dark region shows white inverted glyphs; light region shows black cores in
opaque white outlines.

## v0.44.0 — toolbar pin button completion (v0.37 partial implementation)

1. The button only renders when the toolbar sits on the LONG edge of the
   panel: on the short edge the overflow tools collapse into the "more tools"
   popup and the mod never registers there — width-dependent, not
   orientation-dependent. Register in the more-tools popup like stock
   overflow tools.
2. Remove the legacy pin control from the page-selection UI — the intent was
   to REPLACE it with the toolbar button, not keep both.
3. Redesign to the ecosystem pattern used by the installed touch-lock mod:
   state shown by swapping icons (their lock opens/closes) instead of a
   permanent highlight; when the control lands in the more-tools popup,
   render a toggle next to the wider row label.
Long-press sleep-now works correctly as shipped — don't touch it.

Smoke test: button present in both toolbar-edge layouts (directly and via
more-tools), icon swaps with pin state, popup row shows a toggle, legacy
page-selection control gone, long-press still sleeps.

## Closed / settled this session (do not reopen)

- Default clock cadence stays 5 minutes (owner ruling, commit 1773a52).
- Date format `Tue, 19 Aug` accepted — comma after weekday is standard
  written English; revisit only on community feedback.
- Device-sized bar (v0.35) left to community testing on 10"/13" panels.
- v0.36's translucent-renders-as-white: superseded by v0.38, not a bug to fix.
- vpdd 50 + window 3 productionized and deployed (368a08d); w8/v50 rejected.

## Separate sessions (NOT versions in this plan)

- Chromeless capture idea (active chrome-hide + forced repaint inside the
  <150ms 0->2 window; delayed-shot probe 313c35d was NEGATIVE for passive
  shots; the mod-forced variant is untested). NOTE: v0.41's Bug A finding is
  directly relevant — the tree hides chrome at entry ANYWAY; the open
  question is only whether a repaint lands in the fb before the sleep window.
- Navigate-away capture test (DEFERRED owner idea, staleness fix).

## After the fix waves

- Packaging round: scripts/package.sh (builds/installs all 4 packages,
  version single-sourced — already hardened 2026-08-19, commits a210905..
  1773a52; see DEFERRED for the compressed list). Do not package before the
  fix waves are green.
- VELBUILD source/sha512sums: at publish time only.
- Open owner decisions still parked: purge hook design round.
