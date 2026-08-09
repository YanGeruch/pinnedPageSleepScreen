# Plan D — idle-gated hibernation (design, 2026-08-10)

Status: DESIGN — awaiting user amendments before build.
Prereqs: docs/power-design.md (measured numbers, wake anatomy),
docs/plan-c-findings.md (why alternatives died, probe results).

## 0. TL;DR

The 5-min sleep clock costs ~0.88 %/h standing — but the bigger, unmeasured
cost is that it **prevents the device from ever hibernating**. Plan D: when
the device has been idle for N consecutive clock wakes, stop our own timer
and get out of the way; stock suspend-then-hibernate then reaches its
deadline and the device drops to near-zero hibernation drain, with the last
clock frozen on the bistable panel. Any user wake restarts the clock.
~30 lines of hook logic, no new display path, no xochitl changes.

Expected effect (8 h overnight-away): today ~7 % → ~1.2–1.6 %.
Weekend 48 h: today ~42 % → ~2–3 %.

## 1. The problem, restated with numbers

Measured (docs/power-design.md):

- deep-sleep (suspend-to-RAM) floor: **0.157 %/h**
- one 34 s wake window: **0.066 %** → 12 wakes/h = ~0.79 %/h
- 5-min cadence standing total: **0.85–0.9 %/h** (~21 %/day)

Two structural facts from the 2026-08-08 journal forensics (raw lines
preserved in power-design.md — journal retention is ~3 days, they're gone
from the device):

1. **Our wakes are ~98 % additive.** Stock's only autonomous wake is
   suspend-then-hibernate's 4 h deadline (0.25 wakes/h vs our 12/h).
   `pinsleep-clock.timer` is the only WakeSystem=yes unit on the device.
2. **The mod prevents hibernation entirely.** Every 5-min wake terminates
   the running suspend-then-hibernate op; logind starts a fresh one with a
   fresh 4 h deadline that is never reached (proof: distinct systemd-sleep
   PIDs per wake vs one PID spanning the pre-mod hibernate). Stock, left
   alone > 4 h, hibernates at near-zero drain; we hold it at suspend-to-RAM
   (measured 1.17 %/h that night) forever. Long idle — overnight-away,
   weekends — is where this bites, and it is NOT in the 0.88 %/h figure.

So there are two separate levers: per-wake cost (small, mostly optimized
already) and **hibernation-defeat** (big, untouched). Plan D targets the
second.

## 2. How we got here — every alternative, and why it lost

Recorded so the reasoning can be re-examined, not just the verdicts.

### 2a. Shrink the 34 s wake window (minimumAwakeTime)

xochitl's batterymanager holds a wakelock for a hardcoded 34 s after every
wake (`handleUpkeepWakeup`, "Re-entering DeepSleep in 34000ms").
**Exhausted:** not QML-exposed, no env var, no conf key (full sweep done;
`UPKEEP_INTERVAL_MS` turned out to be sync/indexing, and the QML-writable
`deepSleepDelay` is the idle light→deep knob — both false leads,
documented in power-design.md). Only remaining route is binary-patching the
34000 immediate — OTA-fragile, riskiest option on the board. PARKED.
*Assumption it rests on: window length is the dominant per-wake cost. True
but capped — even at 0 s windows the 12 resume cycles/h and the
hibernation-defeat remain.*

### 2b. Plan B — forced early suspend at wake+8 s

Proven working (2026-08-07 one-shot: vpdd shortened + forced suspend at
+8 s succeeded). **Why parked:** xochitl's 34 s CLOCK_BOOTTIME_ALARM still
pops the system up for ~3 s afterwards, so every tick costs an extra
resume cycle; net ~11 s awake vs 35 s — roughly halves per-wake cost but
does **nothing** about hibernation-defeat, adds a second wake per tick, and
fights xochitl instead of cooperating. Kept in the drawer in case per-wake
cost ever matters again.

### 2c. Cadence reduction (10/15/30-min clock)

One OnCalendar line; projections 0.55/0.42/0.29 %/h. **Why not the
answer:** still defeats hibernation (any periodic wake < 4 h resets the
deadline), and the user prefers the 5-min clock's look. Remains an
orthogonal knob the user can turn independently of Plan D.

### 2d. Plan C — draw the clock without waking xochitl (or without xochitl at all)

Researched by three independent passes (docs/plan-c-findings.md). Chain of
verdicts that killed it:

- **No kernel-level EPD API exists.** The Move's LCDIF drives the panel
  raw at 365×1700@85 Hz; the "waveform" is the frame sequence itself, and
  the only code that can produce it is xochitl's proprietary
  `libqsgepaper.so`. No fbdev, no custom ioctls. (Confirmed on-device:
  xochitl holds DRM master; waveform files present but the pipeline is
  closed.)
- **Bare-metal fb writes without waking userspace: impossible** — no
  partial resume exists in Linux (thaw costs ~1 ms anyway), and fb writes
  wouldn't flush the EPD regardless.
- **A standalone clock drawer is possible but only via the RE'd
  libqsgepaper ABI (oxide's header), and the panel is process-exclusive**
  (DRM master + /tmp/epframebuffer.lock) → xochitl must be STOPPED for the
  entire sleep phase → cold xochitl restart on every user wake (seconds of
  latency, state loss, possible PIN re-entry), plus ABI breakage risk on
  every OS update. Economics: maybe 0.3–0.4 %/h at 5-min cadence vs 0.9 —
  moderate gain, reverse-engineering-project cost. PARKED.
- **Full launcher replacement (oxide/pluto): loses native note-taking.**
  Out for a daily driver.

*The pivotal realization while closing Plan C:* the hibernation lever
doesn't need any of that. Nothing requires the clock timer to run forever —
and everything needed to gate it (SPLD wake-reason discrimination, sleep
hooks on every resume, kernel-only hibernation resume) already exists and
is verified. That is Plan D.

### 2e. Why Plan D won

It attacks the *largest* measured cost (hibernation-defeat) with the
*smallest* mechanism (stop re-arming our own timer), entirely inside the
architecture we already ship, with zero new display code, zero xochitl
modification, and graceful degradation (worst case: clock freezes, device
behaves exactly like stock).

## 3. Verified foundations (assumptions Plan D stands on)

Each was explicitly verified — none is a guess:

| # | Assumption | Evidence |
|---|-----------|----------|
| F1 | suspend-then-hibernate is stock-active with a 4 h deadline | `/etc/systemd/sleep.conf.d/60-rm-sleep.conf` HibernateDelaySec=4h; pre-mod journal shows `PM: hibernation: Creating image` at exactly +4 h idle |
| F2 | Hibernation resume needs zero userspace | `resume=/dev/dm-1` on cmdline; encrypted swap assembled BY THE KERNEL from an lpgpr bootkey (`dm-mod.create=`) — decryption included |
| F3 | Only our timer defeats it | only WakeSystem=yes unit; distinct systemd-sleep PID per 5-min wake = fresh op each time |
| F4 | Wake reason is discriminable | SPLD `wakeup_reason` sysfs: 0x00 RTC/SoC-side, 0x04 button, 0x10 marker, 0x20 charger — our hooks already read it (the IRQ-20 pwrkey/rtc share is a red herring; SPLD is the truth) |
| F5 | Frozen clock costs nothing | panel is bistable; last image persists at 0 power |
| F6 | Wake-from-hibernate works for the user | it was the device's normal pre-mod idle behavior; the user lived with it daily |
| F7 | Kernel re-suspends on its own when wakelocks clear | `/sys/power/autosleep = mem` active; the 34 s window is just xochitl's wakelock |
| F8 | Timer state is safely volatile | enable symlinks live in real rootfs /etc (v0.25.2 persistence); a runtime `systemctl stop` lasts until something starts it; reboot re-arms — correct, since a reboot implies a human |

## 4. The mechanism

### 4.1 Core loop

```
every resume ("after" sleep hook, already ours):
  reason = SPLD wakeup_reason
  if reason == 0x00 (RTC):                     # clock tick, nobody there
      count = ++/run/pinnedSleep/idle-count
      if count >= N:
          touch /run/pinnedSleep/hibernate-track     # bar reads this
          systemd-run systemctl stop pinsleep-clock.timer   # detached
          # this wake's re-suspend starts a FRESH suspend-then-hibernate;
          # with no timer armed it reaches its deadline -> hibernate
  else (0x04/0x10/0x20 — a human or a cable):
      idle-count = 0; rm hibernate-track
      systemd-run systemctl start pinsleep-clock.timer      # idempotent
```

Plus the same reset in the **Navigator wake handler** (displayState
`!==0 → 0`), which already runs a transient systemd-run for vpdd/WiFi
restore — covers the user waking DURING a 34 s window, when no sleep hook
runs.

### 4.2 Decision rationale, point by point

- **`systemctl stop`, not `disable`.** Stop is runtime-only: the enable
  symlink (persisted in real rootfs /etc) stays, so a reboot or the qmd's
  start-time re-assert naturally restores the clock. Disable would fight
  the install contract (companion install = the opt-in) and add a
  persistence headache for zero benefit.
- **Counter in /run (tmpfs).** Volatile is correct twice over: a reboot
  means a human touched the device (reset is right), and hibernation
  *restores* /run from the RAM image, so the state even survives the one
  transition where we need it to.
- **Detached `systemd-run` for the systemctl calls.** The hook runs inside
  systemd-sleep; stopping an unrelated timer shouldn't deadlock, but
  detaching costs nothing and matches how every other hook action already
  works (journaled, diagnosable).
- **Reset on charger wake (0x20) too.** On USB the hooks stand down anyway
  (user decision, v0.25) and drain is irrelevant while charging — the
  clock should run.
- **The qmd's start-time timer re-assert stays as-is.** It only fires on
  xochitl (re)start. During a hibernate-track phase xochitl never restarts
  (it's frozen in the image), so no conflict. A mid-track xochitl *crash*
  would restart the clock — rare, and a crashed-and-recovered device
  re-entering normal cadence is an acceptable failure mode.
- **All new logic lives in the companion package.** It owns the timer, the
  hooks, and the system footprint; the main package stays pure mod-space
  and fully static, per the package contract. The bar's frozen-clock
  indicator is part of the live layer, which is companion-gated already.

### 4.3 The frozen-clock UX problem (user decision needed)

After the Nth idle wake the clock stops updating, but hibernation is still
HibernateDelaySec away — and after it, the panel keeps showing the frozen
bar indefinitely. A stale time that *looks* live is worse than no time.

Mechanism for an honest display: the hook writes `hibernate-track` BEFORE
the QML 1 s tick fires (~1 s after thaw), so the Nth repaint can read the
flag (fastRead, like the battery sysfs) and render the frozen state.
Options, cheapest first:

- **(a) Moon/zZ suffix** next to the time: "23:40 ☾" — time of freeze
  stays visible, marked as frozen. (Recommended: honest and keeps info.)
- **(b) Blank the minutes**: "23:—" — unambiguous but loses the freeze
  time.
- **(c) Do nothing** — accept stale time. Free, misleading at 3 a.m.

### 4.4 Tuning knobs and profiles

Two knobs: **N** (consecutive RTC wakes before letting go — N×5 min of
live clock after last use) and **HibernateDelaySec** (stock 4 h; we *can*
override with our own drop-in in `/etc/systemd/sleep.conf.d/`, installed
persistently the same way as the units). Important nuance: while the clock
timer runs, the delay is unreachable regardless of its value — so a
shortened delay changes behavior ONLY in the window Plan D creates. It
does affect a main-only/no-companion install? No — the drop-in ships in
the companion, and uninstall removes it.

Suspend floor 0.157 %/h; hibernation floor unknown (call it ~0.03 %/h
until measured — probe P2). 8 h overnight-away / 48 h weekend estimates:

| Profile | N (live clock) | HibernateDelaySec | hibernates after | 8 h cost | 48 h cost | today |
|---------|---------------|-------------------|------------------|----------|-----------|-------|
| Conservative | 24 (2 h) | stock 4 h | ~6 h idle | ~2.5 % | ~4 % | 7 % / 42 % |
| Balanced (proposed) | 12 (1 h) | 1 h | ~2 h idle | ~1.2 % | ~2.5 % | |
| Aggressive | 6 (30 min) | 30 min | ~1 h idle | ~0.8 % | ~2 % | |

The trade is purely UX: how long the live clock survives after you put the
device down, and how often a pickup pays the hibernate-resume latency
(probe P3 will tell us what that latency actually is — if it's ~5 s,
aggressive is fine; if ~20 s, conservative).

N and the delay land in a tiny conf the hook sources
(`/home/root/.pinnedSleepScreen/power.conf`) so tuning never needs a
repackage.

## 5. What goes where

| File | Change |
|------|--------|
| `assets/system-sleep/sleep-zz-pinsleep.sh` | "after" branch: counter + threshold + timer stop/start + flag (§4.1). "before" branch untouched. |
| `src/pinnedPageSleepScreen.qmd` (Navigator wake handler) | extend the existing systemd-run restore command: reset counter, rm flag, start timer (wake-during-window case) |
| `src/pinnedPageSleepScreen.qmd` (bar, live layer) | 1 s tick fastReads `hibernate-track`; render frozen indicator (§4.3 choice) |
| `assets/systemd-sleep.conf.d/90-pinsleep.conf` (new, optional per profile) | `[Sleep] HibernateDelaySec=…` — installed via the same mount-utils real-rootfs window as the units; removed on uninstall |
| `packaging/pinned-sleep-clock/install.sh / uninstall.sh` | ship/remove the conf drop-in; seed default power.conf |
| `scripts/deploy.sh`, `scripts/package.sh`, VELBUILDs | stage the new/changed files, version bump |
| `~/.pinnedSleepScreen/power.conf` (device, user-editable) | `IDLE_WAKES_BEFORE_HIBERNATE=12` etc. |

Not touched: main package contract (stays static), fastshot, capture
pipeline, vpdd/WiFi gates (they keep working per-wake as today).

## 6. Unknowns and the probes that resolve them

All cheap; P1–P5 are one evening on the cable + one battery cycle.

- **P1 — end-to-end proof the timer stop releases hibernation.**
  Temporarily drop HibernateDelaySec to ~15 min, stop the timer manually,
  sleep the device on battery, watch the journal for
  `PM: hibernation: Creating image` at +15 min. Also confirms F3 causally,
  not just correlationally. (Must be off USB — cable inhibits suspend.)
- **P2 — hibernation floor + entry cost.** Battery % before hibernate
  entry, after N hours hibernated, on resume. The image write (LZ4, RAM →
  encrypted eMMC swap) has a one-time cost worth knowing — if entry costs
  0.2 %, hibernating for short idles is counterproductive and N/delay
  should stay conservative.
- **P3 — hibernate resume latency + wake sources.** From button press to
  usable UI (stopwatch + journal). Then repeat wake via pen tap, folio
  open, charger insertion — which SPLD sources actually wake from
  hibernation (vs suspend)? Determines whether a hibernated device in a
  bag wakes on pen contact (counter-reset correctness + UX).
- **P4 — hook invocation pattern across the suspend→hibernate boundary.**
  Does systemd-sleep run our "before"/"after" hooks once around the whole
  suspend-then-hibernate op, or again at the internal hibernate
  transition? Matters for the WiFi flag: after a hibernate resume the
  radio hardware lost power; the restore path must run (it should — a
  human wake is non-0x00 so the gate doesn't skip — but verify the flag
  file logic walks through cleanly). Journal from P1 answers this for
  free.
- **P5 — `systemctl stop` from hook context + alarm disarm.** Confirm no
  hang (use systemd-run detached regardless) and that stopping the timer
  actually disarms its RTC alarm (`/proc/timer_list` /
  `/sys/class/rtc/rtc0/wakealarm` before/after).
- **P6 — /run survives hibernation.** Should by definition (RAM image);
  one `ls` after P1's resume settles it.
- **P7 — PIN × hibernate resume.** Explicitly untested (memory note).
  Currently moot (PIN removed for dev) but must be re-run before ever
  recommending PIN + Plan D together.
- **P8 (side experiment, low stakes) — vpdd 0 vs 6000.** Oxide zeroes the
  panel-rail keep-alive before suspend; we hold 6000 ms. Honest framing:
  at 34 s windows neither value blocks the suspend attempt (both expire
  by +7 s), so the gain is only ~6 s of rail idle draw per wake — likely
  measurement noise. Real value: confirming 0 is artifact-free keeps it
  available if Plan B (8 s windows, where 6000 is tight) ever revives.
  One sysfs write in the hook, A/B across two nights.

## 7. Rollout

1. **Phase 0 — probes P1–P6** (one session, most on cable + one battery
   nap). Amend design if P2/P3 surprise.
2. **Phase 1 — build**: hook logic + Navigator symmetry + bar indicator +
   power.conf, N=12, **stock 4 h delay untouched** (smallest behavioral
   delta; the only change vs today is "clock stops after 1 h idle, device
   hibernates like stock used to"). Overnight-away measurement.
3. **Phase 2 — tune**: pick profile (shorten HibernateDelaySec via
   drop-in) based on measured hibernation floor + resume latency; run P8
   alongside. Package as 0.32.x.

## 8. Failure modes and edges

- **Hook script error →** counter never reaches N → clock just keeps
  running = today's behavior. Fails safe.
- **Timer stopped but user never wakes device for days →** intended:
  hibernation floor, kernel's 6 % SOC hard poweroff still guards (gauge
  alert at 10 % is disabled during suspend — deep-discharge caveat from
  Plan C V4 applies to any long idle, hibernated or not, and hibernation
  makes it *less* likely by draining slower).
- **RTC-wake misclassification** (SPLD 0x00 on a real user wake): can't
  happen for button/pen/charger — those are SPLD-visible by design; the
  Navigator handler catches the residual case (user acts during a wake
  window).
- **Clock frozen but user expects it live** (glance at hour 2): the §4.3
  indicator is the mitigation; profile choice sets how soon it happens.
- **OTA update:** wipes hooks/units/drop-in like everything else;
  post-os-upgrade vellum hook + re-deploy restore, unchanged story.
