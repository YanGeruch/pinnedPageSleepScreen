# Pinned-page sleep screen — feasibility notes

Goal: on sleep (button press or idle), show a chosen page of a chosen document/notebook
as the sleep screen on reMarkable Paper Pro Move (OS 3.27, xovi + Vellum ecosystem).

## Verdict: feasible

Recommended architecture: **capture-on-view + swap-at-suspend** (no on-the-fly rendering).

1. User marks a target doc+page (UI similar to link-from-selection's picker).
2. Whenever the target page is on screen and about to leave it (page turn, doc close,
   or suspend while visible), capture the framebuffer via rm-shot to
   `/home/root/sleepScreens/pinned.png`.
3. At suspend, the sleep-window QML sets its image `source` to that PNG
   (exact technique used by randomSleepScreen).

The sleep screen therefore always shows the *last-seen* state of the page — works even
when the doc is closed at sleep time, no doc-open/screenshot/close roundtrip, no .rm
rendering. Staleness only matters with cloud sync from another device (out of scope).

## Evidence from the reference mods (cloned in `research/`)

### randomSleepScreen (ingatellent-xovi-qmd-extensions, 3.27/randomSleepScreen.qmd)
- Sleep window QML is patchable: `/qt/qml/xofm/modules/sleepscreen/qml/{default,tatsu}/sleep-window-opaque.qml`.
- It assigns an arbitrary `file:///home/root/sleepScreens/*.png` URL to the sleep image
  `source` when the sleep window instantiates → our swap point. Covers both eager
  button-sleep and idle-sleep (same sleep window).
- `transparentSleep.qmd` + `visibleSleepScreen.qmd` show the sleep window has access to
  `Settings`, `BatteryManager.displayState`, `EPFramebuffer.scheduleGhostRemoval()` —
  rich hooks around suspend/wake.

### rm-shot (native xovi extension, C)
- Exposes `screenshotHandler` to QML via xovi-message-broker; message format:
  `path.png[,delay_ms[,rotation[,left,top,right,bottom]]]` → writes PNG, broadcasts
  `screenshotComplete`/`screenshotFailed`.
- Reads framebuffer via framebuffer-spy; **explicitly supports Paper Pro Move**
  (detects `chiappa`, displayWidth 954, RGBA path).
- Captures raw framebuffer → includes any visible UI chrome (toolbar). Mitigations:
  capture only when toolbar hidden, or crop (crop rect supported natively).
- `quickSettingsPartialOrFullScreenshot.qmd` is a working example of driving rm-shot
  from QML including region selection.

### link-from-selection (alefaraci-xovi-qmd-extensions, 3.27/linkFromSelection.qmd)
- QML extensions can read/write the doc store directly:
  `file:///home/root/.local/share/remarkable/xochitl/` via XMLHttpRequest GET/PUT.
- Shows how doc UUID + page UUID are addressed, doc/page picker UI, error handling
  ("Document not downloaded", "Page not found"), and writes `.rm` v6 files.
  → gives us persistent target selection + validation.

## Rejected alternatives
- **Open-capture-close at sleep**: too slow, visible flashing, races suspend.
- **Offline .rm v6 → PNG render**: heavy (v6 parser + template/PDF background
  compositing); only wins for cross-device sync, which is out of scope.
- **xochitl page thumbnails** (`<doc>.thumbnails/<page>.png`): too low-res for the
  sleep screen; possible degraded fallback if no capture exists yet.

## On-device recon (2026-08-04, OS 3.27.3-1547, device "reMarkable Chiappa")
- SSH works via key, root@10.11.99.1 (USB).
- xovi installed with qt-resource-rebuilder, xovi-message-broker, appload, literm,
  qt-command-executor, rm-pdfium + ~25 qmd mods incl. linkFromSelection (live reference).
- **Missing deps to install later: rm-shot, framebuffer-spy.** No /home/root/sleepScreens.
- Move uses the **`default`** sleep window: only
  `/qt/qml/xofm/modules/sleepscreen/qml/default/sleep-window-opaque.qml` and
  `SleepWindowBannerWindow.qml` exist in hashtab; no `tatsu` variant on this device.
- Hashtab (662KB, /home/root/xovi/exthome/qt-resource-rebuilder/hashtab) reveals native
  plumbing: `root.isettings.sleepScreenPath`, `isCustomSleepScreenPath`,
  `makeSleepScreenPath`, `Settings.lightSleepEnabled`, `BatteryManager.DeepSleep`.
  → xochitl's own "current screen as sleep screen" feature stores a path in isettings;
  pointing `sleepScreenPath` at our PNG may replace QML image-swapping entirely.
- xochitl.conf: IdleSuspendDelay=300000, LightSleepEnabled=true. No sleepScreenPath key
  yet (feature unused so far), and no custom sleep PNG anywhere under /home/root.

## Sleep-window QML extracted (2026-08-04)
Extracted `/qt/qml/xofm/modules/sleepscreen/qml/default/sleep-window-opaque.qml` from
the xochitl binary (research/rcc_extract.py finds the embedded rcc bundle: names table
0x10a5090, tree 0x10a5180, zstd data 0x10a4b80; extracted files in research/, NOT
committed — proprietary). Findings:
- `logo` Image: `source = isettings.sleepScreenPath`; when `isettings.isCustomSleepScreenPath`
  it renders full-parent (native hidden custom sleep image support).
- `illustration` Image: `source = carousel.imagePath` (the rotating "one of 3" defaults),
  `visible: !isCustomSleepScreenPath`, centered at carouselWidth.
- Observed behavior explained: LightSleepEnabled=true → idle keeps framebuffer (this
  window not drawn); button press → window drawn with carousel default.
- Binary string table confirms `SleepScreenPath` is a xochitl.conf key (next to
  LightSleepEnabled, IdleSuspendDelay, SuspendPowerOffDelay...). `isCustomSleepScreenPath`
  is likely derived from the path being non-default.

**Implication**: display side may need no QML patch at all — set
`SleepScreenPath=/home/root/sleepScreens/pinned.png` in xochitl.conf and the button-press
sleep screen becomes our PNG, while idle light-sleep behavior stays native. Idle picks it
up too if the user disables the built-in option. Matches desired UX exactly.

## Agreed UX (user, 2026-08-04)
- Do NOT touch the native idle "current screen as sleep screen" feature.
- Override only what the sleep window draws as *default* screensaver (button press;
  also idle when native option disabled).
- UI: page actions menu in documents gets "Set as sleep screen"; when the selected page
  is already set, it reads "Remove from sleep screen" (short enough for menu width).

## More references (rmitchellscott/xovi-qmd-extensions, cloned in research/)
- `3.27/quickSettingsScreenshot.qmd` — the QML-side rm-shot recipe:
  `IMPORT net.asivery.XoviMessageBroker`, `XoviMessageBroker { }`,
  `sendSimpleSignal("takeScreenshot", "<path>,<delay_ms>")`; closes the menu first and
  captures after a delay (100ms tap / 5000ms long-press) so UI chrome is gone.
- `3.27/createDocumentFromPages.qmd` — injects a menu item into the pages menu
  (objectName `extractPagesItem`), accesses selected pages' doc UUID / page ids /
  `.content` JSON under `/home/root/.local/share/remarkable/xochitl/`, generates UUIDs,
  uses CommandExecutor (`sh -c`) and the broker FIFO `/run/xovi-mb` from shell.
  → exact template for our "Set as sleep screen" item + page identity plumbing.

## Toolbar avoidance (v1: defer)
v1 leaves whatever is on screen in the capture (user can hide toolbar first).
Future options, in order of promise: capture with delay after UI dismissed
(quickSettingsScreenshot pattern), rm-shot native crop rect, or QML-hiding the
toolbar pre-capture and restoring after.

## ✅ VERIFIED on device (2026-08-04)
Set `SleepScreenPath=/home/root/sleepScreens/pinned.png` under `[General]` in
xochitl.conf (while xochitl stopped — it rewrites conf on exit), restarted xochitl:
**every button-press sleep now shows the PNG fullscreen** (954x1696 test image rendered
edge to edge; `isCustomSleepScreenPath` derives automatically from the key being set).
Backup of original conf: /home/root/xochitl.conf.bak-sleeptest on device.
→ Display side of the mod = manage this one conf key. "Remove from sleep screen" =
delete the key (defaults return; verify once during implementation).

## Capture-timing design (agreed direction)
Debounced capture while the pinned page is on screen: quiet-timer fires ~3-5s after the
last input burst on that page → broker call to rm-shot (bg thread, one ~6.5MB memcpy +
PNG encode; negligible). No navigation blocking, no constant polling. Optional extra:
capture at suspend when pinned page is currently visible.

## Remaining implementation questions
- Where `makeSleepScreenPath` writes: enable the native "set current screen as sleep
  screen" option once on the device, then diff /home/root + xochitl.conf for the new
  file/key. If it's a stable path, our capture can just overwrite that file.
- Toolbar-in-capture: verify capture with toolbar collapsed / crop values on Move (954px wide fb).
- Best capture trigger(s) in QML: page-change signal, doc close, suspend-while-visible —
  dump real QML via qmldiff/hashtab to find signal names.
- Suspend ordering: confirm capture-at-suspend completes before sleep image draws
  (rm-shot runs in a thread; may need its delay param or capture-on-exit only).

## Packaging (later)
Vellum VELBUILD, category ui; deps: `qt-resource-rebuilder`, `rm-shot`,
`xovi-message-broker`, `framebuffer-spy`, `remarkable-os>=3.27 <3.28`.
Reference VELBUILDs: vellum-dev/vellum `packages/{link-from-selection,rm-shot,random-sleep-screen}`.

## Native export / share-by-email as a clean-render source (2026-08-05)
Question: can we trigger the built-in "send page as PNG by email" silently to get a
clean page render instead of a framebuffer capture?

**Silent triggering: no.** Both native entry points are QML-reachable but neither is quiet:
- `SendMail.enqueue(options)` (singleton; metaobject: `enqueue(QVariantMap)`, `isValidEmail`,
  `attemptSending`, `retry`, `onFilesReady(task, paths)`, `attachmentTooLarge`). Options are
  `{id, recipients, filename, message, format: "pdf|png|svg|html", pages, password,
  keepPassword, grayscale, orientation}` (ShareUtils.js + ShareEmailDialog.qml). It POSTs to
  `/share/v1/email`, needs recipients, is gated on `LinkProvider.availability`, reports
  telemetry (`reportExportType`) and shows notifications.
- `exportManager.exportPagesFromDocument(entityId, pagesToExport, targetNavigationId,
  allowConcurrentBatches)` on `NavigationManager.exportManager` (signals `exportCompleted`,
  `exportFailed`, `exportProgress`). Needs a configured storage integration + network; uploads.
- The renderer itself (`Request(ExportDocument), path=%s, type=%d`, `doExportDocument`,
  `PngExporter`, `DocumentExporter` in worker/) has **no QML surface** — C++ only.

**But the same renderer is reachable another way — `ThumbnailProvider`.** QML-creatable type
(`document: QmlDocumentWrapper*`, `page`, `monochrome`, `cache`, `autoRotate`, `source`) used
by `/qml/common/PageThumbnail.qml` as an `Image.source` with `sourceSize` = item size. A
Document object is obtainable anywhere from the `Library` singleton:
`Library.entryForId(docId)` (returns the wrapper assigned to `documentView.document`,
see research/device-qml Pages.qml:143-163).
→ The sleep window could render the **page** rather than replay the **screen**: no overlays
in the image, no capture timing, no pixel-merge helper, never stale-by-capture. This would
retire the whole framebuffer pipeline if it holds up.

### ❌ TESTED ON DEVICE 2026-08-05 — ThumbnailProvider is a DEAD END (resolution)
Probe (`src/probeThumbnailRender.qmd`, gated by `"probe": true` in pinned.json) rendered the
pinned page fullscreen in DeviceSceneView. Logged result:
`PROBE: ready, implicit 288x512 painted 954x1696`.
→ The provider **ignores `Image.sourceSize`/requestedSize** and returns the cached on-disk
thumbnail. Confirmed by PNG IHDR of `<doc>.thumbnails/<page>.png`: 288x512 (grid) and
384x512 (list) — exactly the sizes handed back. Upscaling 288x512 → 954x1696 is visibly
soft against a framebuffer capture (compared side by side; strokes lose all edge definition).
Freshness was not tested — moot once resolution failed.
`Library.entryForId(docId)` DOES work as a Document source from any QML context, so the
route is sound in principle; only the renderer's fixed size kills it. Re-test only if a
future OS renders thumbnails on demand.

**Crash lesson (cost a crash loop):** `ThumbnailProvider` has `cacheChanged`/`autoRotateChanged`
signals in its metaobject but the only assignable properties are `document`, `page`,
`monochrome`, `source`. Assigning `cache: false` → `Cannot assign to non-existent property
"cache"` → "Type DeviceSceneView unavailable" cascade → crash loop (xovi fell back to stock
UI; recovered by triple-tap). Two process fixes:
- `apply-diffs` pre-flight does NOT type-check property assignments or import resolution.
  Never trust it alone for a new API.
- `systemctl is-active xochitl` reports **active** during a restart loop. Health checks must
  grep the journal (deploy.sh does; ad-hoc deploys must too). Deploy anything touching a new
  API with self-rollback:
  `... restart; sleep 14; if journalctl -u xochitl --since "20 sec ago" | grep -qiE "Cannot assign|Cannot load|unavailable|FAILURE"; then rm <qmd>; systemctl restart xochitl; fi`

Still-unknown for any future sleep-window work: whether `com.remarkable` imports resolve
inside `/qt/qml/xofm/modules/sleepscreen/` (never got that far).

Also fixed while investigating: `tools/extract_qml.py` only searched *backwards* for a
bundle's data table; the toolbar/sendmail bundles put it *after* names/tree (found via zstd
magic anchoring). Those files were "data table not found" before.

## Status v0.6 (2026-08-04) — working, user daily-driving dev version
Pin/unpin via pages menu (single selection only), navigate+capture on pin, pen-lift and
page-entry captures, toolbar-hide capture (clean-image escape hatch), "Sleeping" pill,
stock carousel returns on unpin. Verified dead ends: Item.grabToImage crashes the EPD
backend (no offscreen renders); Settings singleton has no sleepScreenPath.
Next: delay tuning (fb capture needs no e-ink settle; try 200-300ms), custom icon SVG,
VELBUILD + vellum local-repo packaging, random-sleep-screen coexistence.
