# GhostBuster & the EPD ghost-removal API

Recon 2026-08-12, from `strings` on the xochitl binary (OS 3.27.3, local copy
`research/xochitl-bin`) plus the extracted QML tree (`research/device-qml`).
Motivating investigation: `ghostdata/analysis.md` (overnight isolation test —
vpdd exonerated, screen updates alone cause the sleep-bar ghosting).

## The two layers

### 1. `EPFramebuffer` singleton — the weapons

Engine-wide QML singleton (already used by stock QML for `hasCapability`,
and by our mod's luma work). Reachable from **any** QML context, including the
sleep window. Ghost-related surface from the Qt metaobject:

| member | kind | notes |
|---|---|---|
| `clearGhosting` | method | immediate ghost clear; presumed to take a `GhostControlMode` |
| `scheduleGhostRemoval` | method | deferred/queued ghost removal |
| `GhostControlMode` | enum | `BlinkNow`, `BlinkLater`, `BleachNow`, `FactoryReset` |
| `framebufferUpdated` | signal | |
| `temperature`, `backend`, `capabilities`, `width`, `height`, `format` | properties | `Backend`: Tcon / **Swtcon** / Desktop / Test; `Capability`: None / Color / FastGrayscale |

- **Blink** = the flashing full refresh (what the five-finger gesture produces).
- **Bleach** = presumed quiet white-drive cleanup with no flash. Matches the
  user-observed stock behavior: a settings-overlay ghost square on the home
  screen self-faded ~1–2 minutes later with no visible refresh.
- The render layer logs `incompatible ghost control mode` — mode validity is
  backend-dependent (validate on device; Move = Gallery 3 color panel).
- **No QML file in the firmware calls any of these** — they are exercised only
  from C++ (GhostBuster). Free for mod use.
- **Signatures/arity are unverified** — strings give names, not parameter
  lists. A live introspection probe must run before building on them.

### 2. `GhostBuster` — the stock policy brain

C++ module, no QML files (`qrc:/qt/qml/xofm/modules/ghostbuster` registers
types only). Interface `xofm::libs::ghostbuster::IGhostBuster`, implementations
`GhostBuster_Default` and `GhostBuster_Gallery3` (Move uses Gallery3; logs
`GhostBuster_Gallery3 created!` at startup). QML-uncreatable; the instance is
dependency-injected and handed to QML as `required property GhostBuster
ghostBuster` on DocumentView — reachable from our existing DocumentView
AFFECTs (and from SceneViewGestures scope).

| member | notes |
|---|---|
| `forceClearNow(reason)` | full clear now; the five-finger tap calls `forceClearNow("5-finger gesture")` at `SceneViewGestures.qml:203` (`TouchAreaClickFilter#ghostbusterFilter`, `fingers: 5`, gated on `Experimental.gestures.enabled`) |
| `viewChange(mode)` | navigation hint; GhostBuster decides internally if/when/how to clean |
| `retailRefresh` | retail-demo related |
| `ViewChangeMode` enum | `SettingsOpened`, `SettingsClosed`, `SetupStarted`, `SetupCompleted`, `ShareByEmailOpened`, `ShareByEmailClosed`, `SplashScreenClosed`, `PincodeClosed`, `Rotation`, `DocumentViewDialogOpened`, `DocumentViewDialogClosed` |

Stock callers found: `Settings.qml:50` (`viewChange(GhostBuster.SettingsOpened)`),
`DocumentView.qml` `handleDialogGhosting()` (dialog open/close). The
architecture = UI hints navigation events, GhostBuster counts/schedules
cleanup — confirming the "full refresh after N navigations + silent timed
cleanup" pattern observed on stock.

Community prior art: the installed `ghostbuster.qmd` (rmitchellscott, MIT)
only REPLACEs the gesture filter's `enabled` to drop the experimental-flag
gate. No one has touched the API itself.

## Related machinery (same recon)

- **ScreenDriver** (devicesceneview): mono/tile state machine with dirty
  tracking — logs `clean the screen, dirty=%f`, `full update..`; env knobs
  `SCREENDRIVER_HOLD_TIMEOUT`, `SCREENDRIVER_YIELD_TIMEOUT`,
  `SCREENDRIVER_MONOTEXT_TIMEOUT` (UPKEEP_INTERVAL_MS-style overrides).
- **DeviceSceneViewport** QML type: `requestRepaint(area)`,
  `requestRepaintDirty`, `markDirty` — regional repaint plumbing.
- **Logging categories**: `rm.framebuffer`, `rm.framebuffer.updates`,
  `rm.renderloop` — a `QT_LOGGING_RULES` drop-in would journal every EPD
  update/clear, i.e. we can *measure* stock GhostBuster behavior live.
- **Waveforms**: `/usr/share/remarkable/ct33_{std,best,pen,fast}.bin`;
  "Using user defined waveform file" override path exists.
- Panel sysfs: `/sys/devices/platform/cumulus-panel` exposes
  `vpos1-3`, `vneg1-3`, `vcom`, `vpdd`.

## Planned use (ghostbusting feature — direction settled 2026-08-12)

Ghost verdict: accumulation of hundreds of quiet band updates during sleep;
the exit's own full refresh doesn't fully rebalance long-standing residue, but
regions that get EXTRA drives (toolbar handle over the date area) come back
clean. Double full-flash at exit rejected (annoying). Candidates, in order:

1. **In-sleep periodic bleach**: hourly (at the :00 rollover, right after the
   repaint) call `scheduleGhostRemoval`/`clearGhosting` with `BleachNow` from
   the sleep window. Prevents accumulation; expected invisible-or-nearly on
   the mostly-white sleep page. Optional UX mask: dress the hour rollover as a
   deliberate visual cue (animation) hiding any shimmer.
2. **Exit-side stock mimicry**: on wake, from DocumentView, fire
   `ghostBuster.viewChange(...)` or `scheduleGhostRemoval(BlinkLater/BleachNow)`
   — deferred quiet pass lands 1–2 min into reading, like stock.
3. **Pure-QML fallback**: manually render the bar white → re-render content
   periodically (a hand-rolled regional refresh using only what the repaint
   pipeline already does).

Gate before building: (a) introspection probe — enumerate the live instances'
properties/methods from QML (`for (var k in EPFramebuffer)`, `.length` for
arity), (b) one `BleachNow` taste-test for visibility, (c) optional
`rm.framebuffer.updates` logging run to measure stock cleanup timing.
