# Mod wave plan — post-W5 improvements

Ground truth for implementation agents. Where this plan and any design doc
disagree, this plan wins. Owner rulings land here as dated `ERRATUM:` blocks.

## Protocol

- One work package (WP) = one commit = one review round. Implement THIS WP only.
- Unrelated findings become one-line notes in `docs/DEFERRED.md` — never fixes.
- On ambiguity, a gate that won't go green for outside reasons, or a suspected
  design gap: STOP, write a `## QUESTIONS` section (the precise question plus
  the two answers you considered), end the turn, and WAIT. Do not invent.
- Per-file edits only. No regex bulk surgery. Never push, never amend.

## Conventions register

None of these is a bug or a gap; do not fix, soften, or add alternatives.

1. **QMD syntax** is qmldiff's: `AFFECT / TRAVERSE / LOCATE / INSERT / REPLACE
   / REBUILD`. Spec: `research/qmldiff/README.MD`. Resource paths are absolute
   with leading `/`, no `qrc:` prefix.
2. **Dense rationale comments are house style.** Comments in the qmd state
   device-verified constraints and traps, often with version history. Match
   that density and register; never strip them; never add narration comments.
3. **All identifiers injected into stock QML carry the mod prefix**
   (`pinSleep*` for the main mod). New mods pick their own short prefix and
   use it on every id/property/function they add.
4. **Synchronous XHR is banned** (nested event loop reads files mid-write —
   v0.18.1 regression). Synchronous reads go through
   `XoviMessageBroker.sendSimpleSignal("fastRead", path)`; async XHR is the
   fallback when fastshot is absent.
5. **The bar exists twice** — deep-sleep window (`sleep-window-opaque.qml`
   AFFECT) and light-sleep banner (`SleepWindowBannerWindow.qml` AFFECT).
   Intentional duplication; a change to one usually needs mirroring. State in
   the WP report whether you mirrored and why/why not.
6. `antialiasing: false` on bar text is deliberate (EPD rendering).
7. **Icon loaders are opposites**: ark `Icon` wants a bare filesystem path and
   colorizes; plain `Image` wants `file:///` and renders as-is
   (`src/pinnedPageSleepScreen.qmd:76-78`, `src/probeIconSource.qmd`).
8. **Settings panels must `LOCATE BEFORE Repeater`** in settings ColumnLayouts
   (`src/pinnedPageSleepScreen.qmd:1898-1900`). Same rule in `General.qml`.
9. **Hide, don't delete, stock elements.** `Sidebar.qml:22 navigationModel`
   references children by id; physically removing one breaks the file. Every
   removal mod in the corpus flips `visible`/`shown` instead.
10. **`/etc` is a volatile overlay.** Anything written there dies on reboot.
    Persistence = the `mount-rw`/`mount-restore` window (README.md:105-118)
    or a boot re-assert from QML (the sleep-clock pattern,
    `src/pinnedPageSleepScreen.qmd:260-291`).
11. **Persisted mod settings** use the `Values.qml` alias pattern:
    `AFFECT /qml/common/Values.qml`, `IMPORT QtCore 6.5`, backing Item +
    `Settings { category: "<modname>" }` (`src/pinnedPageSleepScreen.qmd:1872-1892`).
12. **Packaging** is vellum (APKBUILD-style `VELBUILD`). Pure-mod packages
    install only under `/home/root/xovi/`; anything touching system dirs is a
    separate package with install hooks. Assets live next to the qmd in
    `/home/root/xovi/exthome/qt-resource-rebuilder/`.
13. **Only the Paper Pro Move (OS 3.27.x) is certified.** VELBUILD pins
    `rmppmove` + `remarkable-os>=3.27 <3.28`. Other-device support is written
    to be plausible but is not testable now.
14. Commit messages follow the repo's style: long descriptive subject that
    states the change AND the load-bearing rationale (see `git log`).

## Environment facts and gates

- Working directory: `/Users/geruch/repos/Configurator/reMarkable`, branch
  `main`. Verify `git status --short` clean and note HEAD before starting.
- **THE TABLET IS OFF LIMITS.** A battery-measurement rig (W5) runs until
  ~19:00 today; any SSH wakes the device and corrupts the data. No
  `deploy.sh`, no `package.sh` (both SSH), no `ssh`/`scp` of any kind.
- **Gate ladder (run before every commit):**
  1. `git status --short` — only intended files.
  2. Preflight (the compile gate, fully local):
     ```
     research/qmldiff/target/release/qmldiff apply-diffs research/device-qml \
       /tmp/qml-preflight -c research/preflight \
       src/pinnedPageSleepScreen.qmd <plus any new .qmd this WP adds>
     ```
     Baseline: GREEN with the current tree. New qmds are appended to the same
     invocation so cross-mod conflicts surface locally.
  3. If the WP adds a package: VELBUILD is syntax-checkable only by eye —
     match an existing one field-for-field.
- Reference material (all local, all gitignored — read freely, never commit):
  `research/device-qml/` (stock QML dump, extendable via
  `python3 tools/extract_qml.py device/xochitl research/device-qml /qml/...`),
  `device/hashtab` (strings-searchable index of all 508 stock QML paths),
  `research/preflight/` (28 third-party qmds — coexistence examples),
  `research/qmldiff/README.MD` (diff-language spec).
- On-device validation of everything is deferred to task #10 (post-rig).

## Out of scope — ASK before touching if you think you must

- `probes/`, `w4data/`, `packaging/pinned-sleep-clock/` system scripts, vpdd
  values anywhere (task #9 owns those).
- The VELBUILD bolt-asset gap and pkgver staleness (task #9 owns it).
- The light-sleep banner's lack of orientation handling (it composites over
  the live frame and inherits app rotation — by design).
- Any refactor of existing working code, however tempting.
- WP6/WP7 must not touch `src/pinnedPageSleepScreen.qmd` at all.

---

## WP1 — Sleep-bar orientation follows the capture (task #1)

Bug: with a landscape capture, the pinned-path bar still renders portrait.
The freeze path already rotates: `pinSleepOrient` drives x/y/width/rotation on
`Rectangle#pinSleepIndicator` (`:1464-1471`) and `#pinSleepContacts`
(`:1616-1624`). The image itself is NEVER rotated (raw framebuffer grabs).

Scope, three edits in `src/pinnedPageSleepScreen.qmd`:

1. **Record orientation in the chapter book.** `pinned.json`'s top-level
   write (`:600-610`) gains one field, `orient`, read the same way
   `orientNow()` does (`:120-124`) but from the DocumentView context
   (`DeviceSceneView.qml:38` has `property Orientation orientation` in
   scope). Top-level, NOT per-chapter: `tfEq` (`:618-622`) invalidates the
   whole book on rotation (`:690`, `:854`), so at most one orientation is
   live. Before:
   ```js
   { "docId": docId, "pageId": ..., "pageIdx": ..., "ts": ..., "chapters": [...] }
   ```
   After:
   ```js
   { "docId": docId, "pageId": ..., "pageIdx": ..., "ts": ..., "orient": pinSleepWatch.orientNow(), "chapters": [...] }
   ```
   (helper added next to the write site, same try/catch→0 shape as `:120-124`).
2. **Apply it on the pinned path.** Today `:1083-1084` forces 0 unless freeze:
   ```js
   root.pinSleepOrient =
       (root.pinSleepFreeze && p.orient !== undefined) ? (p.orient | 0) : 0;
   ```
   After: freeze keeps priority (its orient is entry-instant); otherwise the
   pinned path uses the chapter book's orient. `applyPinned` (`:1111-1178`)
   parses `pinned.json` and must pass/set the value in the same settling
   update as the gates (no frame may see mixed state — see `:1075-1081`).
   Records without the field (pre-upgrade) behave exactly as today (orient 0).
3. **Guard comment** at the freeze decision (`:1072`): document that any
   `check()` >20s into a nap flips freeze→false and swaps in the already-built
   chapter model (`applyPinned` populates `pinSleepModel` regardless of
   freeze; only `!pinSleepFreeze` at `:1376` hides it) — so no new code path
   may call `check()` mid-nap.

TRAP: never rotate `pinSleepLayerHost`; `complement()` (`:1005-1036`) works in
the pre-rotation physical frame. Do not touch the banner (out of scope above).
Bump the qmd header version (minor).

## WP2 — Date format `ddd, d MMM` (task #2)

`fmtDate` exists in both copies (`:1418-1423` deep, `:1714-1719` banner).
Before:
```js
var mFirst = ("" + Qt.locale().dateFormat(Locale.ShortFormat)).indexOf("M")
    < ("" + Qt.locale().dateFormat(Locale.ShortFormat)).indexOf("d");
var s = Qt.formatDateTime(d, mFirst ? "ddd MM/dd" : "ddd dd/MM");
```
After (same mFirst logic, new patterns, keep the first-char uppercase step):
```js
var s = Qt.formatDateTime(d, mFirst ? "ddd, MMM d" : "ddd, d MMM");
```
Mirror to the banner copy. `Qt.formatDateTime` with `MMM`/`ddd` localizes
month/day names via the default locale — no new API. Both copies must stay
byte-identical in logic (convention #5). Bump qmd header version (patch).

## WP3 — Device-sized strip (task #3)

Bar height derives from text: `height: time.height + 17` (`:1414`, `:1711`);
fonts are `Values.fontSizeBody1 * {2, 1.5, 1}`. Add one root-level scale
property per window (prefix `pinSleep`):
```qml
// 7.8" Move keeps current sizing; 10"/13" panels get a larger bar sized
// against the stock (non-floating) toolbar. Portrait width is the stable
// device discriminator (Move fb 954 visible; larger panels >1400).
property real pinSleepBarScale: (Screen.width >= 1400 || width >= 1400) ? 1.35 : 1.0
```
and multiply it into the three font-size expressions of the bar (+ battery
icon scale factor `:1522-1524`) in BOTH copies. Margins (24/8) stay. Exact
discriminator expression may be adjusted to whatever the window reliably
exposes (check what `root.width` is at bar-construction time; the 954/1696
fallbacks at `:1147-1148` are chapter-only — do not reuse them blindly).
Visual verification is deferred (convention #13). Bump version (patch).

## WP4 — Style modes (task #4) — split into WP4a + WP4b

Both edit `src/pinnedPageSleepScreen.qmd` (same-mod feature, existing
`pinnedSleep` Settings category). Mockups: `research/halo-poc/`
(strip-treatments.png, frost-levels.png). WP4b does not start until WP4a is
reviewed and landed.

### WP4a — monochrome styles + settings radios + mod-drawn battery icon

1. **Persisted state** (convention #11, existing store):
   `Values.pinSleepBarStyle` — string `"white" | "black" | "translucent"`,
   default `"white"`; `Values.pinSleepTranslucentStyle` — string
   `"full" | "outline" | "cascading"`, default `"full"`.
2. **Settings UI**: a second mod panel in Display.qml (same
   `LOCATE BEFORE Repeater` slot as the sleep-clock panel), radio rows built
   from illustration-less `ArkControls.Selector`s (the WP6 pattern —
   coexistence with the tzLoc panel and the sleep-clock panel in the same
   column is preflight-provable). Tier-2 row: White / Black / Translucent.
   Tier-3 row (visible ONLY while translucent): Full / Outline / Cascading.
   Tier-3 semantics land in WP4b; in WP4a picking translucent renders as
   WHITE with a header comment saying WP4b owns it (radio persists).
3. **Black style rendering**, both bar copies mirrored (convention #5):
   Rectangles flip color/border; every bar Text gains a `color` binding
   (`style==="black" ? "white" : "black"`); the stock
   `ArkControls.BatteryIndicator` (no color route, compiled) is REPLACED by a
   mod-drawn segmented icon — QML Rectangles matching the stock geometry
   (body outline, 4 cells filled by percentage quarters, tip nub), colorable
   by the style. Bolt: ship `pinnedSleepBoltInv.svg` (colors swapped) next to
   the existing asset and select per style. The white style must render
   BIT-IDENTICAL to v0.35.0 (same trick as WP3: neutral values are exact
   no-ops).
4. Version bump minor. VELBUILD asset staging for the new SVG is task #9's
   wiring (DEFERRED already covers package.sh) — but ADD the install line to
   packaging/pinned-page-sleep-screen/VELBUILD for both bolt SVGs since that
   file is being touched for the icon anyway? NO — VELBUILD belongs to task
   #9; qmd + assets/ only. Note it in the report.

### WP4b — translucent styles (ENTRY DRAFT — QUESTIONS round mandatory)

Islands (squarish radius-18 white pills behind date/clock/battery groups)
replace the full-width bar when style is translucent. Sub-styles per the
2026-08-11 erratum: full (opaque islands), outline (no plate), cascading
(full → half-frost → outline by background darkness; outline is the dark
arm). Glyphs over islands: black + 2px white outline (`Text.style: Outline`);
icon outlines via layered mod-drawn geometry (bolt technique — REQUIRED,
stock icons blur into the background).
OPEN — the implementing agent must raise these in QUESTIONS before coding:
(a) standalone-outline glyph polarity (black core/white outline as the
    general-purpose scheme vs white core/black outline as mocked for dark);
(b) cascading's luminance source — QML cannot read image pixels
    synchronously; candidate: a `fastLuma` region-mean handler added to the
    fastshot xovi extension (native, C), vs deferring cascading to its own
    WP; do NOT implement a Canvas-based sampler (async paint breaks the
    first-latched-frame invariant);
(c) whether the light-sleep banner pill gets islands or keeps its solid pill.

ERRATUM 2026-08-11 (owner): settings UI is RADIO GROUPS (the same select
pattern as the timezone/locale mod), three tiers:
1. Clock cadence — the existing 1/5/15 control, unchanged.
2. Bar style radio: **white** (current: white bar, black glyphs) /
   **black** (inverted: black bar, white glyphs) / **translucent**
   (island treatment, no full-width bar).
3. Translucent sub-style radio, visible ONLY while translucent is selected —
   THREE styles (owner ruling 2026-08-11, supersedes the frost-percentage
   list): **full** (opaque islands), **outline** (no plate, outlined glyphs),
   **cascading** (adaptive fallback full → half-frost → outline chosen by the
   background under the island; outline is the dark/black-background arm).
   The on-device taste test (task #10) happens by flipping this radio live
   instead of redeploying builds. The cascading arm needs a luminance read of
   the capture region — design its trigger thresholds in the WP4 QUESTIONS
   round, not ad hoc. The outline arm (standalone or as cascading's dark arm)
   REQUIRES outlined glyph icons — every icon must be mod-drawn with the
   bolt's layered-outline technique (black core, white inner outline; see
   assets/pinnedSleepBolt.svg) or it blurs into the background; the stock
   BatteryIndicator cannot be used in outline mode at all.

## WP5 — Pin button → toolbar + sleep-now (task #5) — ENTRY NOT YET AUTHORED

Blocked on WP1-4. Needs a toolbar recon pass first.

## WP6 — Timezone + locale picker mod (task #6) — separate worktree

New standalone mod (own qmd, own prefix, own VELBUILD package). The stock UI
has NO timezone setting (device runs UTC; README.md:99-101) and no stock
locale/region picker — this mod fills that hole.

- UI reference (owner ruling, 2026-08-11): the Accessibility page's select
  pattern — `ArkControls.Panel` with `showAttachment: true` and an attachment
  `RowLayout` of selection controls, as used for Readability/Handedness
  (`research/device-qml/qml/device/view/settings/Accessibility.qml:106-184`,
  `HandednessChooser.qml`). Two such panels-worth of controls on ONE row:
  timezone select + locale select side by side. For the long timezone list an
  illustrated `Selector` card per option can't scale 1:1 — but the CONTROL
  to use is the Accessibility `ArkControls.Selector` (owner ruling
  2026-08-11, supersedes the earlier ContextualMenu suggestion): keep the
  Selector look and adapt it for list length (e.g. Selector opening a
  scrollable list of Selector-styled entries). Propose the exact adaptation
  in QUESTIONS. The systemclock Tumbler spinners are NOT the reference.
- Placement: settings panel via the `LOCATE BEFORE Repeater` pattern
  (convention #8); propose the page (General.qml vs Display.qml) in your
  first QUESTIONS round with a one-line rationale each.
- Timezone apply: `CommandExecutor` (`IMPORT net.asivery.CommandExecutor
  1.0`) running `timedatectl set-timezone <tz>`; persistence across reboot
  via the boot re-assert pattern (convention #10) driven by a persisted
  Settings value (convention #11) — do NOT depend on the mount-rw window.
- Timezone list: curated static list (~40 common zones covering all UTC
  offsets) shipped in the qmd; full IANA enumeration is out of scope for v1.
- Locale: the deliverable is that `Qt.locale()` inside xochitl reflects the
  chosen locale. HOW to set it (LANG/LC_ALL in a systemd drop-in for
  xochitl.service + restart, or another mechanism) is the WP's first
  research step — verify against the local corpus, then STOP and present
  the mechanism in QUESTIONS before implementing.
- Soft-dependency contract: other mods read the same persisted Settings
  values; the mod's absence must leave script-based configuration working.

ERRATUM 2026-08-11 (question-round rulings):
- Host page: **Display.qml**, same `LOCATE BEFORE Repeater` slot as the
  sleep-clock panel. General.qml rejected: its only legal slot lands above
  the user's account block; Accessibility rejected as miscategorised. Panel
  order vs Sleep clock follows exthome alphabetical load order — accepted.
- Locale mechanism: **systemd drop-in on xovi's tmpfs**
  (`/etc/systemd/system/xochitl.service.d/zz-tzLoc-locale.conf`,
  `Environment=LANG=<code>.UTF-8`) + convention-#10 boot re-assert. MANDATORY
  caps, both: (1) grep `/proc/mounts` for the xochitl.service.d tmpfs before
  any write/restart — absent tmpfs means a restart launches STOCK xochitl, so
  do nothing; (2) restart only on normalised mismatch of `Qt.locale().name`
  (form `en_GB`, no encoding suffix) vs the persisted value, plus a `/run`
  one-shot marker — an unguarded compare loops restarts into StartLimitBurst
  and the recovery watchdog REBOOTS the device. The `mount-rw /etc/locale.conf`
  route is BANNED (umount -R /etc rips out the live xovi preload drop-in).
- Timezone apply: `timedatectl set-timezone <tz> || ln -sfn
  /usr/share/zoneinfo/<tz> /etc/localtime` (D-Bus-free fallback; both are
  volatile-overlay writes re-asserted per boot). Whether a live change
  reaches running xochitl is unknown — at most ONE xochitl restart per
  explicit user commit, never automatic; if tz-only changes turn out to need
  a restart, that's a task #10 finding, not a v1 loop.
- Control shape: approved as proposed — row of two value-Selectors
  (timezone | locale, autoExclusive) + fixed-height ~6-row clipped ListView
  of illustration-less Selector entries below. NO illustration SVGs in v1;
  whether an empty `illustration` collapses cleanly is a task #10 check.
- Names approved: `src/timezoneLocalePicker.qmd`, prefix `tzLoc`,
  `packaging/timezone-locale-picker/VELBUILD`, v0.1.0.

## WP7 — Hide Guides in the sidebar (task #7) — separate worktree

New standalone mod, smallest possible diff. Target:
`/qml/device/view/navigator/Sidebar.qml`, `IconButton#quickHelp` (`:507-528`
in the dump). Option A only (convention #9):
```
AFFECT /qml/device/view/navigator/Sidebar.qml
    TRAVERSE DeviceKeyboardNavigationHandler > ColumnLayout#filterColumn > IconButton#quickHelp
        REPLACE visible WITH { visible: false }
        # + Layout.preferredHeight: 0 so the hidden item reserves no space
    END TRAVERSE
END AFFECT
```
(exact qmldiff verbs for the height edit per the spec — `REPLACE` an existing
binding or `INSERT` a new one; check `research/preflight/
hidePageLabelsInFullscreen.qmd` for the working precedent). `navigationModel`
stays untouched — `quickHelp` id must remain valid. Own VELBUILD (pure-mod
package). The separator at `:497-505` lands above Settings; visual check
deferred to task #10. Coexistence: preflight must stay green with
`research/preflight/` (four of those qmds insert into `filterColumn`).

## DEFERRED log

Agents append one-liners to `docs/DEFERRED.md` (create if missing).
