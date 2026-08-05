# Toolbar-less sleep screen — design (v0.11 target)

Goal: the pinned sleep image shows the page with **no chrome** — no stock toolbar, no
open-trigger handle, no floating-mod bars — without losing stroke freshness and without
gating captures on chrome being closed (rejected: chrome may never close).

Two cooperating mechanisms:

1. **Chrome-hold clean capture** (chapter 0): on entry to the pinned page, keep ALL
   chrome invisible until the page is stable and captured, then release. Zero flash —
   chrome simply appears ~1s later than usual, only on this one page.
2. **Chapters + display-time layering**: subsequent stroke captures include chrome;
   each distinct chrome layout is a "chapter". The sleep window stacks chapter images
   oldest→newest, each newer layer painted with holes at its own chrome rects, so every
   pixel shows the newest chrome-free content available (the user's
   "subtracting layers" model).

## Verified facts this design stands on (2026-08-05)

- **DocumentView.qml `Item#_uiContainer` (lines 1315–2619) contains ALL chrome**:
  the `Toolbar` instance itself (1531), MinimalBatteryIndicator, pageLabel, titleLabel,
  pageSlider, notificationBar, zoomButton — and floating.qmd inserts its two panels
  (`layers`, `floatQuick`) into this same container (`TRAVERSE FocusScope > Item#_uiContainer`).
  The document scene (`DeviceSceneView#sceneView`, line 787) is a *sibling outside* it.
  → hiding `_uiContainer` hides every overlay at once, stock and modded, atomically.
- `_uiContainer.visible` binding is trivially replaceable:
  `visible: !Experimental.pdfPrototype.enabled`. (Do NOT touch `toolbar.visible` — it
  carries a 9-clause stock binding.)
- `toolbar.shown` is `readonly visible && expanded` (defined at instantiation, DocumentView
  1554). Hiding the container flips it → our v0.8 toolbar-close trigger must be gated
  during a hold.
- **Toolbar.qml** (now extracted: research/device-qml/qt/qml/xofm/libs/toolbar/qml/):
  root FocusScope#root; `expanded` is a **plain bool** (line 33) — safe property-bus host,
  same trick floating.qmd uses (it adds `floatbarQuick/floatbarQuickk/floatbarEnabledLayers`
  there). Strip = inner `Item#toolbar` (341; `innerWidth/innerHeight` are aliases to it);
  collapsed open-trigger = `?#hideShowButton` (399); expanded close = `?#closeButton` (467).
  Inner ids are only reachable from inserts INTO Toolbar.qml — export rects as readonly
  properties on its root.
- **floating.qmd** (de-hashed: /tmp/unhashed-floating.qmd): panels are positioned,
  draggable items `floatQuick` (compact pen bar) and `layers`, ids resolvable from
  DocumentView-scope JS **iff floating.qmd is applied** — guard with
  `typeof floatQuick !== "undefined"`. Visibility bools live on the toolbar root.
- collapseToolbarOnOpen.qmd (alefaraci, de-hashed) proves the "suppress before first
  paint" timing works from `onDocumentChanged` + `Qt.callLater`.
- Chrome hold does NOT collapse/move anything: `expanded`, `position`, floating x/y are
  untouched, so restore-exactly-as-was is automatic.

## Capture side

New shared switch, inserted into Toolbar.qml root (the property bus both files can reach):

```
property bool pinSleepChromeHold: false
readonly property rect pinSleepStripRect:  // strip mapped to root coords (root fills screen)
readonly property rect pinSleepHandleRect: // hideShowButton likewise (visible when collapsed)
```

DocumentView.qml: REPLACE `_uiContainer`'s `visible` with
`!Experimental.pdfPrototype.enabled && !toolbar.pinSleepChromeHold`.

DeviceSceneView (existing pinSleepWatch, extended):

- onPageChanged/onDocumentChanged to the pinned page → set
  `root.toolbar.pinSleepChromeHold = true` immediately (before chrome first paints),
  then the existing arm/poll flow; when isLoading settles → capture to **ch0** slot →
  release hold after capture delay + write margin (~capture delay + 500ms).
- Hold safety: a hard cap timer (~20s) releases the hold no matter what, so a stuck
  isLoading can never leave the user chrome-less.
- Gate the toolbar-close trigger (v0.8) with `!pinSleepChromeHold`.
- All other triggers (pen-lift, refresh, wake) capture *with* chrome to the current
  head chapter slot.

### Chrome signature & chapter rotation

At every capture trigger, from DocumentView-scope helper (new `Item#pinSleepChrome`
inserted into DocumentView, where `toolbar`, `sceneView`, and — guarded — `floatQuick`/
`layers` all resolve):

```
rects = []
if toolbar.shown            → toolbar.pinSleepStripRect (+ closeButton area is inside strip)
if toolbar.visible && !expanded → toolbar.pinSleepHandleRect
if typeof floatQuick !== "undefined" && floatQuick.visible → floatQuick.mapToItem(screen)
if typeof layers    !== "undefined" && layers.visible      → layers.mapToItem(screen)
if battery indicator visible (≤10% unplugged)              → its rect
```

Signature = rounded rect list. If it differs from the head chapter's signature →
**rotate**: head slot is frozen, next slot (ring of 4: ch0 reserved clean + ch1..ch3)
becomes head. Same signature → capture overwrites head slot (stroke updates).
No file renames: slots are fixed filenames `ch0.png..ch3.png`; pinned.json records order.

DeviceSceneView requests "capture now"; the DocumentView helper supplies the signature.
Communication: DeviceSceneView already has `root.toolbar` — the helper also lives off the
toolbar bus (`toolbar.pinSleepChromeRects` readonly property on Toolbar root can't see
floating ids, so the DocumentView insert pushes the computed list into a `property var`
on the toolbar root instead; recomputed on the relevant *Changed signals).

### Transform invalidation

Store per chapter: `pageBorderRect` (x,y,w,h) + docId/pageId. On capture, if head
transform ≠ current → all older chapters invalid (scroll/zoom moved the page):
mark them stale in pinned.json; layering then uses only same-transform chapters.
Clean ch0 becomes stale too — it is re-acquired on next page entry (hold-capture);
until then the sleep image just shows chrome again (graceful degradation, today's v0.10
behavior as the floor).

### pinned.json v2

```json
{
  "docId": "...", "pageId": "...",
  "head": 2,
  "chapters": [
    {"file":"ch0.png","chrome":[],"transform":{"x":0,"y":0,"w":954,"h":1696},"ts":...},
    {"file":"ch1.png","chrome":[{"x":0,"y":600,"w":104,"h":496}],"transform":{...},"ts":...},
    {"file":"ch2.png","chrome":[...],"transform":{...},"ts":...}
  ]
}
```

(v1 files stay: sleep window falls back to legacy `pinned.png` if no `chapters` key —
rolling forward without breaking the currently-working mod.)

## Display side (sleep-window-opaque.qml)

QML has no practical layer limit; each layer is an `Item{clip:true}` with an offset
`Image` inside. Count here: ≤4 chapters × ≤(3k+1≈10) complement rects ≈ worst ~30 Images.
Memory: same-URL Images share one decode (use `file://...ch2.png?v=<ts>` cache-buster,
cache left ON — unlike v1's `cache:false`), ~6.5MB × 4 decodes. Fine.

Painter's algorithm, valid chapters oldest→newest:

- Chapter i is drawn as its full-screen image **minus its own chrome rects** (holes).
- Holes = complement decomposition: horizontal-band split of (screen − rects) → list of
  axis-aligned rects, ~15 lines of JS, output feeds one `Repeater` model per chapter:
  `Item{clip:true; x,y,w,h} > Image{x:-rx; y:-ry; source:chapter}`.
- Result per pixel: newest chapter that was chrome-free there — exactly the
  "collapse layers by subtraction" semantics.
- ch0 (clean, chrome:[]) is the base full-screen layer and terminates every hole chain.
- Retry-on-decode-error (v0.10) kept, applied to the newest layer's Image status.

## Known risks / verify on device at implementation time

1. Container-hide semantics: confirm hiding `_uiContainer` doesn't trip stock logic
   reacting to `toolbar.shown` (margins etc. are hidden anyway; check journal for
   binding-loop noise) and that release restores expanded/position exactly.
2. Signature race: chrome state may change between metadata write and rm-shot's delayed
   framebuffer grab (~200ms window). Accepted; next capture heals. Keep delays short.
3. floating.qmd id coupling: `typeof` guards mean uninstalling floating degrades to
   stock-only signatures, no crash. Pre-flight MUST add floating.qmd to the `-c` list in
   deploy.sh (it AFFECTs DocumentView.qml + Toolbar.qml — same files we now patch).
4. `Item#pinSleepChrome` insert into DocumentView must use an anchor that doesn't collide
   with floating.qmd's inserts into `_uiContainer` — insert at FocusScope root level,
   LOCATE relative to a stock element floating.qmd doesn't touch.
5. mapToItem on `floatQuick` while it's mid-drag: signature churn → chapter spam.
   Debounce rotation (rotate only at capture time, not on every geometry signal).

## Out of scope for v0.11 (explicit)

- Mid-session hold-recapture after scroll/zoom (would blink chrome; wait for page
  re-entry instead).
- Thumbnail-based patching (kept as fallback idea; likely unnecessary once ch0 exists).
- Merging chapters into a single PNG on disk (no compositor binary; layering at display
  time is enough because the sleep window is a normal QML scene rendered once).
