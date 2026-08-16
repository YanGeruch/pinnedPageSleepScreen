# Deploy handoff — v0.33.0 → v0.40.0, staged

Paste the "PROMPT" section below into a fresh session. Everything above it is
context for a human; everything inside it is what the agent needs.

---

## PROMPT

You are deploying an accumulated set of changes to a reMarkable Paper Pro Move
tablet. The code is written, reviewed and committed; **nothing has been
deployed**. Your job is the deploy, staged so a breakage can be pinpointed to
one version.

Repo: `/Users/geruch/repos/Configurator/reMarkable` (branch `main`, clean).
Device: `root@10.11.99.1` over USB (password saved). The battery rig is
finished — the device is free, no measurement is in flight.

### Verified device state (checked 2026-08-16, re-verify before you start)

- Installed qmd: **v0.33.0** — everything from v0.34.0 on is undeployed.
- Installed `fastshot.so`: **predates 0.6.0** (no `fastLuma` string in it).
- `vpdd_length`: **30000** (stock; the rig restored it).
- xochitl: active. 26 third-party qmds installed.
- `research/preflight/` is in sync with the device (26 files, `ghostbuster.qmd`
  present in both) — the local coexistence gate is trustworthy.

### What ships, and the hard ordering constraint

`fastshot` must be installed **first**. Versions 0.38.0+ of the qmd call native
handlers that the installed `.so` does not have, and v0.39.0's capability
checks **fail closed** — with an old `.so` the pinned sleep screen silently
degrades to the stock carousel and the clock becomes a static "Sleeping". A
0.8.0 `.so` is a superset (`fastShot`, `fastRead`, `fastWrite`,
`fastAsyncShot`, `fastLuma`, `fastStat`, `fastAbortShots`), so it is safe under
the currently-installed v0.33.0 qmd.

Ladder, in order. Each qmd version is a commit on `main`; deploy by checking
out that file version, not by branching:

| Step | What | Needs |
| --- | --- | --- |
| 0 | vpdd hook 6000 → 50 (see below) | — |
| 1 | `fastshot.so` rebuilt at 0.8.0 | — |
| 2 | qmd v0.34.0 — bar follows capture orientation | — |
| 3 | qmd v0.34.1 — date format `Wed, 11 Aug` | — |
| 4 | qmd v0.35.0 — device-sized bar (no visible change on Move) | — |
| 5 | qmd v0.36.0 — white/black/translucent style radios | `pinnedSleepBoltInv.svg` |
| 6 | qmd v0.37.0 — toolbar pin button + long-press sleep-now | — |
| 7 | qmd v0.38.0 — translucent islands + cascading | fastLuma |
| 8 | qmd v0.39.0 — audit fixes (fails closed without fastStat) | fastStat |
| 9 | qmd v0.40.0 — fresh chapter at sleep entry + abort | fastAbortShots |
| 10 | `hideSidebarGuides.qmd`, `timezoneLocalePicker.qmd` (new standalone mods) | — |

Steps 2–4 are pure rendering and low risk; you may collapse them into one
deploy if you prefer, but do not collapse 5–9.

### Fix `scripts/deploy.sh` BEFORE step 1 — it cannot ship this release as-is

Three gaps, all confirmed:

1. It **never ships `fastshot.so`** (`:37-56` copy only the qmd, two SVGs, the
   systemd units and the sleep hooks). Add the `.so` to
   `/home/root/xovi/extensions.d/`, and rebuild it from source first
   (`make VERSION=0.8.0` in `extensions/fastshot`) rather than trusting the
   working-copy binary.
2. It ships only `pinnedSleepBolt.svg`, not `pinnedSleepBoltInv.svg` — step 5's
   black style needs both.
3. It stages only `pinnedPageSleepScreen.qmd`; the two new standalone mods need
   their own copy lines for step 10.

Also note `deploy.sh:74-76` re-asserts `timedatectl set-timezone Europe/Kyiv` on
every deploy. Once the timezone mod (step 10) is installed, that line fights the
UI setting. Decide what to do with it before step 10 — do not silently leave both.

### The vpdd change (step 0)

Edit `assets/system-sleep/sleep-zz-pinsleep.sh`: the on-battery hold becomes
**50 ms** (currently `6000`, three places: the comment at `:8`, the default at
`:33`, the clamp fallback at `:34`). Keep the on-USB branch at stock 30000.

**Read `w5data/analysis.md` §13 before you do this, and surface one decision to
the user.** W5 certifies "ship **window 3 + vpdd 50**", and is explicit that at
vpdd 50 the repaint window becomes the *binding* term rather than being masked
by the rail hold. The vpdd half is a one-line hook change. The **window-3 half
was a test rig** — a temporary `LD_PRELOAD` drop-in clamping `timerfd_settime`
— and has never been productionized. So shipping vpdd 50 alone gives you part
of the certified configuration. Ask the user whether they want vpdd-50 only now
with window 3 deferred, or the pair productionized together. Do not decide this
yourself. Also from §13: **do not ship w8/v50** (predicted worse than both), and
the next real gain is cadence (5 min → 15 min ≈ 0.21 %/h), which is a default
value, not engineering.

### Traps that have bitten this project before

- **`StartLimitBurst` = 4 xochitl starts per 10 minutes.** A 5th fails the unit
  and the recovery watchdog **reboots the device**. `deploy.sh` runs
  `systemctl reset-failed xochitl` before each restart, which is why staged
  deploys are survivable — but do not hand-restart in tight loops. Pace the
  ladder; if you see "Start request repeated too quickly", stop and wait.
- **A reboot wipes `/etc`** (volatile overlay): timezone, the clock timer's
  enable symlink and its cadence drop-in all die. The qmd re-asserts the timer
  on xochitl start; the timezone does not re-assert itself.
- **After any `mount-utils` package operation, test the MOUNT not the path**
  before restarting xochitl: `grep " /etc/systemd/system/xochitl.service.d "
  /proc/mounts`. `mount-rw` does `umount -R /etc`, which rips out xovi's
  preload tmpfs while the directory stays visible through the overlay — a plain
  restart then silently boots **stock** xochitl with no mods. `deploy.sh`
  already handles this by running `xovi/start` instead.
- **Health-check on the journal, not on `systemctl is-active`** — the service
  reports "active" mid-crash-loop. `deploy.sh` already greps for
  `Loading file pinnedPageSleepScreen` and for `Type ... unavailable|FAILURE`,
  and prints a rollback command when it finds breakage. Trust that output.
- **Never write `*/` inside a qmd comment** — qmldiff re-emits `//` comments as
  `/* */` blocks and a literal `*/` terminates the block early, producing a
  crash loop. (Not a risk if you only deploy committed versions.)

### Per-step procedure

1. `git show <commit>:src/pinnedPageSleepScreen.qmd > /tmp/x.qmd` (or check out
   the file), run the local preflight gate against all three qmds:
   `research/qmldiff/target/release/qmldiff apply-diffs research/device-qml
   /tmp/pf -c research/preflight src/pinnedPageSleepScreen.qmd
   src/hideSidebarGuides.qmd src/timezoneLocalePicker.qmd` — must exit 0.
2. Deploy that version.
3. Read the health output. If `mod loaded: 0`, xovi is not active and your
   change is NOT live — fix that before continuing.
4. Smoke test on the device (below), then move to the next step.

### Smoke test after each step

Minimum: pin a page, press power, wake, confirm the sleep screen showed the
pinned page with the bar. Then the version-specific check:

- v0.34.0 — rotate to landscape, capture, sleep: the bar must sit on the
  content-top edge, not the portrait top.
- v0.34.1 — the date reads `Wed, 11 Aug`, not `Wed 11/08`.
- v0.36.0 — Settings → Display → the new style radios; switch to Black and
  sleep; the bar inverts including the battery icon and the charging bolt.
- v0.37.0 — the pin button is on the page toolbar; tap toggles pin, long-press
  sleeps immediately showing the current screen.
- v0.38.0 — set Translucent, cycle Full / Outline / Cascading, sleep after each.
  **This is the frost taste test** — the user wants to judge these on the panel.
- v0.39.0 — pin a page and confirm `pinned.json` actually updates (mtime +
  content); confirm the sleep screen still shows chapters and has NOT fallen
  back to the stock carousel (that would mean fastStat is missing).
- v0.40.0 — write a few strokes and immediately press power: the sleep image
  must contain those strokes.

### After the ladder

The remaining work is in `docs/DEFERRED.md` (packaging gaps: VELBUILD pkgver
still 0.31.2, asset staging, the `!mini-light-sleep` conflict, no purge hook)
and in `audit/main-db2cc08/DISPOSITION.md` (audit findings scheduled for the
deploy round, including one cheap on-device check: capture `apk info -a` for
the virtual packages to settle whether the recipes should say `rmppmove` or
`rmppm` — do not change the recipes without that output, three non-forced
`vellum add` installs currently succeed with `rmppmove`).

Do not package (`scripts/package.sh`) until the ladder is green — packaging
also needs the version single-sourced, which is separate work.

### Context files worth reading

- `docs/mod-wave-plan.md` — the plan every change was built against, including
  dated errata with the design rulings.
- `docs/DEFERRED.md` — 20+ findings, each tagged with the task that owns it.
- `audit/main-db2cc08/DISPOSITION.md` — status of an external adversarial audit.
- `w5data/analysis.md` — the battery certification behind the vpdd change.

Ask the user before anything destructive or anything the notes above flag as a
decision. Report what you deployed, what the health check said, and what the
smoke tests showed.
