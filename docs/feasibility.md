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

## Open questions (need the device)
- Toolbar-in-capture: verify capture with toolbar collapsed / crop values on Move (954px wide fb).
- Best capture trigger(s) in QML: page-change signal, doc close, suspend-while-visible —
  find the exact signals in decompiled QML on device (qt-resource-rebuilder hashtable
  names; the hashed `~&…&~` ids in .qmd files come from the on-device hashtable).
- Suspend ordering: confirm capture-at-suspend completes before sleep image draws
  (rm-shot runs in a thread; may need its delay param or capture-on-exit only).
- Verify sleep window variant used on Move (`tatsu` vs `default`).

## Packaging (later)
Vellum VELBUILD, category ui; deps: `qt-resource-rebuilder`, `rm-shot`,
`xovi-message-broker`, `framebuffer-spy`, `remarkable-os>=3.27 <3.28`.
Reference VELBUILDs: vellum-dev/vellum `packages/{link-from-selection,rm-shot,random-sleep-screen}`.
