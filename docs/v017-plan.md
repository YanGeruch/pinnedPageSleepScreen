# v0.17 plan — fixes from the v0.16.2 test matrix (2026-08-06)

User test results (device on v0.16.2, git 7df4ccb):

| Case | Result |
|---|---|
| button + toggle ON + unpinned | BAD: flashes stock carousel, then shows entry capture, capture includes chrome |
| idle + toggle ON | GOOD: clean (chrome-less!) capture |
| unpin, first wake | BAD: shows stock then OLD image briefly at wake, once, then heals |
| pin same page you entered overview from | BAD: sleep shows toolbar (no ch0) — reliable repro |
| pin different page | GOOD |
| button/idle + toggle OFF + unpinned | GOOD: stock carousel |
| idle + pinned (toggle OFF) | GOOD |

## Verified findings (do not re-derive)

- **True suspend confirmed unplugged**: journal shows `Entering DeepSleep forever`
  (= infiniteSleep) → `systemd-sleep` → `PM: suspend entry (deep)` → freeze → wake by
  pwrkey IRQ. **The freeze capture survives real suspend-to-RAM** — display pipeline is
  fully validated. (Kernel log timestamps from the suspended period appear at wake.)
- **Transparency does NOT retain** (v0.16 white-screen repro): app UI beneath the sleep
  window is torn down at deep entry → transparent window composites white backing store.
  Banner retains only because LIGHT sleep freezes the EPD with the app still mapped.
- **At 0→1 (idle) the delay-0 fb grab comes out chrome-less**: inSuspend flips → app
  repaints without chrome → grab catches it. At 0→2 (button) the same grab includes
  chrome (teardown wins / no chrome-less repaint reaches the fb).
- Capture log signature of the same-page-pin bug: chaptered `ch1 rects=4` captures with
  NO preceding `ch0 (held)` line.
- Double captures ~20ms apart occur (settle+late timer overlap) — harmless, same slot.

## Root causes

1. **Same-page pin gets no ch0** (toolbar in sleep image): `toggle()` skips the pre-hold
   when `currentPage === idx`, and no pageChanged fires for same-page `openPage()` → no
   reload/arm/hold ever runs. Captures are chrome'd ch1 with no ch0 beneath. (The pages
   overview merely covers the scene; the page stays "open" — user's hypothesis correct.)
2. **Stale current.png at wake**: freeze decision is late (power.json race) and
   non-sticky; the 600ms recheck can flip freeze ON during the wake transition and paint
   the PREVIOUS sleep's current.png once.
3. **Stock flash before freeze**: illustration/logo paint before decide() lands.
4. **Chrome in button-freeze capture**: fb at 0→2 still has chrome (see findings).

## Fix plan / implementation steps

### F1 — same-page pin (v0.17, src/pinnedPageSleepScreen.qmd)
- PagesActions `toggle()`: drop the `pageActions.documentView.currentPage !== idx`
  condition — ALWAYS pre-hold on pin (overview covers chrome, so it's flash-free).
- DeviceSceneView `pinSleepWatch`: add
  `onChromeHeldChanged: if (chromeHeld) { reload(); arm(); }`
  → ANY hold engagement reloads json (fixes stale watch for same-page pin/repin) and
  arms the settle capture (→ ch0 → release). The 20s cap stays as failsafe. The pages
  overview keeps isLoading true until it closes, so the pending checker times it right.

### F2 — stale/wake glitch (sleep window decide())
- Require the power record to describe a CURRENT sleep: freeze only when `p.next === 2`
  (at wake p.next===0 → freeze off; kills the wake-time flip).
- Freshness: only display current.png when `Date.now() - p.ts < 20000`; use `?v=` + p.ts
  as the nonce (not Date.now()) so the same shot isn't re-decoded needlessly.

### F3 — white flash instead of stock (user-approved fallback)
- New sticky `property bool pinSleepFreezeLikely` — set in decide(): toggle ON && unpinned
  (freeze is then certain regardless of origin). Deliberately NOT set for pinned+ON:
  button→pin must paint instantly; the idle→current repaint ~600ms later is acceptable.
- Gates while freezeLikely && capture not fresh yet: hide illustration + logo +
  errorPlaceholder (white + pill), pill visible. When current.png fresh → logo shows it.
  - logo: INSERT `visible: root.pinSleepPath !== "" || !root.pinSleepFreezeLikely`
  - illustration gate: prepend `!root.pinSleepFreezeLikely && `
  - errorPlaceholder gate: prepend `!root.pinSleepFreezeLikely && `
  - pill: add `|| root.pinSleepFreezeLikely`

### F4 — chrome-less button freeze: PROBED 2026-08-06 → bounce-recapture pipeline

R1 (light-first via lightSleepDelay) is DEAD; replaced by the bounce pipeline below.
Probe: src/probeLightSleepDelay.qmd (left DEPLOYED on device, inert; remove with
`ssh root@10.11.99.1 "rm /home/root/xovi/exthome/qt-resource-rebuilder/probeLightSleepDelay.qmd && systemctl restart xochitl"`).

Probe findings (all verified on device):
- `lightSleepDelay` is the IDLE→light timer, live-mirrors Settings.idleSuspendDelay
  (300000). Setter clamps to `minimumAwakeTime` = **34000 ms floor** (binary string
  confirms). Not a button knob; setting it small doesn't rearm the running timer. Dead end.
- `folioClosed` is READ-ONLY (hall sensor). Dead end.
- **`BatteryManager.onWakeup(reason)` is QML-callable and wakes from deep in ~3ms.**
  WakeupReason enum: 0=Ignored (signals fire, state unchanged), 1=Error, 2=RTC,
  3=Charger, 4=Keyboard, **5=Powerkey** (use 5 — identical to real button wake, routes
  to handleUserWakeup). Works from state 1 and 2.
- **Bounce verified**: calling onWakeup(5) synchronously inside the 0→2 handler returns
  displayState to 0 in **4ms** (0→2 t+0, 2→0 t+4ms), and a later requestSleep() re-enters
  deep normally. Full rehearsal (`buttonsim`): requestSleep → bounce → rm-shot → re-sleep
  → stayed deep → wake:5 → healthy.
- **BUT the sleep window still renders**: the buttonsim fb grab 2.3s post-bounce showed
  the opaque sleep window (pinned page + pill), and the QML event loop stalled ~1.6s
  right after the bounce (= its EPD flush). The bounce cancels the STATE, not the render.
- Connections-order hazard (reproduced): the probe's bounce ran before the mod's
  power.json write, so nested 2→0 writes landed BEFORE the outer 0→2 write → power.json
  ended stale ("in deep") while awake. In v0.17: bounce and write() live in the SAME
  handler, and after the pipeline's final transition, re-write power.json from the
  bounce site (last write wins).
- Timers fired ~1.6s late during the stall — drive pipeline steps with generous margins
  (or fb-stability), never tight delays.

**v0.17 button pipeline (unpinned + toggle ON only; pinned+ON keeps instant pinned page):**
Since the first sleep-window render can't be suppressed, make every transition
pixel-near-identical so the EPD shows nothing but a toolbar dissolve:
1. 0→2 handler (Navigator, same place as write()): entry-instant rm-shot delay-0
   (chrome'd, ≈ screen) as today; write power.json; if unpinned && toggle ON && not
   already in pipeline → set one-shot pipeline flag, onWakeup(5).
2. Sleep window renders freeze = that fresh chrome'd capture → visually ≈ no-op
   (F2 freshness + F3 gates make stock/white impossible).
3. Awake again (app repaint = same pixels). Engage chrome-hold (doc scenes; home/
   settings have no chrome — skip), wait for settle (≥400ms margin), rm-shot delay-0
   → current.png now chrome-less.
4. requestSleep() (flag cleared → no bounce). Window freezes onto identical pixels.
   Watchdog timer: if re-sleep hasn't happened 4s after bounce, requestSleep() anyway.
   Repeat button presses during pipeline: flag prevents double-bounce; C++ has its own
   1s wake debounce for real presses.
- Open wiring question: bounce decision needs pinned-state SYNCHRONOUSLY in the 0→2
  handler → keep a cached pinned flag in Navigator (refresh via XHR on wake, on
  Component.onCompleted, and whenever power.json is written; DeviceSceneView could also
  publish via a bus like the Toolbar chrome bus). Chrome-hold reach from Navigator vs
  letting DeviceSceneView's pinSleepWatch observe the same 2→0 + pipeline flag is an
  implementation choice — pinSleepWatch only exists in doc scenes, Navigator is always
  alive, so Navigator must own the re-sleep watchdog.
- NEEDS USER'S EYES (cannot verify over SSH): does the 2→0 wake mid-pipeline cause a
  full-refresh blink? Test cabled with the deployed probe: `echo "armbounce:5 #1" >
  /tmp/sleeptest.cmd` then press the power button and watch; `buttonsim #1` runs the
  whole pipeline. If wake blinks, the pipeline may still beat the current stock-flash,
  but judge visually.
- R3 (future, big): shadow chapters for the CURRENT page (auto-pin-current) — full
  toolbar-less current screen using the existing chapter machinery.
- Idle capture cleanliness relies on repaint-order luck — works today at delay 0; if it
  ever regresses, consider delay ~100 (banner bar may bake in; miniLightSleep pill small).

### F5 (optional) — dedupe captures <500ms apart with same signature. Low priority.

### Post-fix test matrix
same-page pin → sleep (toolbar-less?); unpin → sleep → wake (no old flash);
button+ON+unpinned (white flash at worst, capture shown, chrome per F4 outcome);
idle+ON (clean, unchanged); pinned+ON asymmetric both origins; toggle OFF cases stock.

## Key interfaces (compaction survival kit)

- `BatteryManager` (QML, com.remarkable; in scope: Navigator, DeviceSceneView, NOT
  sleep window): displayState Normal=0/LightSleep=1/DeepSleep=2, displaySleeping,
  requestSleep() [works, 0→2 and 1→2-in-2ms], goToSleep() [guarded low-level],
  onWakeup(reason) [0=Ignored 1=Error 2=RTC 3=Charger 4=Keyboard 5=Powerkey; wakes
  from 1 or 2 in ~3ms], lightSleepDelay [idle→light, mirrors idleSuspendDelay, floor
  34000=minimumAwakeTime]/deepSleepDelay [writable], infiniteSleep [RO], folioClosed
  [RO, hall sensor], onActivity()/setSuspendEnabled()/requestPowerOff()/setPenClose()
  [untested], onDisplayStateChanged(previous, next) — handler runs BEFORE the sleep
  window renders, but the window render itself CANNOT be prevented by bouncing.
- `Settings` (QML, com.remarkable): lightSleepEnabled (= Display→"Visible content"
  toggle) writable; idleSuspendDelay (Battery→Standby delay), idleToSuspendDelay
  (=light→deep 160min) writable; generic setValue/getValue for any xochitl.conf key.
- Mod plumbing: Navigator `Item#pinSleepPower` writes power.json
  {prev,next,ts,lightSleepEnabled} on every transition, fires rm-shot delay-0 to
  current.png on 0→sleep when toggle ON (BEFORE window renders = wins race).
  Toolbar root bus: pinSleepChromeHold (+ alias on DocumentView root for PagesActions),
  pinSleepChromeQuery (assigned by DocumentView helper; sees floatQuick/layers via
  guarded typeof), pinSleepOwnRects(). DeviceSceneView pinSleepWatch: validate-then-
  captureNow (v0.16.1 anti-resurrection), chapters ring ch0..ch3, chromeHeld binding.
  Sleep window: pinSleepPath (legacy/freeze image), pinSleepModel (chapter layers),
  pinSleepFreeze, decide()/check(), 600ms recheck, decode-retry timers.
- Files: /home/root/.pinnedSleepScreen/{pinned.json,power.json,current.png,ch0-3.png,
  pinned.png(legacy)}.
- deploy.sh pre-flights against research/preflight (ALL installed mods de-hashed;
  SceneSelectionHandler + homescreen CreateMenu AFFECTs stripped — unextractable).
