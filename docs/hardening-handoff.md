# Hardening handoff — failure modes, packaging debt, deferred findings

Companion to `docs/deploy-handoff.md`. That one ships code that exists; this
one is a **hardening session** — failure modes, install/uninstall integrity,
packaging debt, and the backlog in `docs/DEFERRED.md`. Not new features.

Paste the "PROMPT" section into a fresh session.

---

## PROMPT

You are hardening a published reMarkable Paper Pro Move mod. The feature work
is done and reviewed; this session is about the ways it can *break a user's
device* and about packaging debt. Prefer removing failure modes over adding
capability.

Repo: `/Users/geruch/repos/Configurator/reMarkable` (branch `main`, clean).
Device: `root@10.11.99.1` over USB. Check with the user before touching it —
another session may be running a staged deploy (`docs/deploy-handoff.md`).

Read first, in this order:
- `docs/DEFERRED.md` — 22 findings, each tagged with the task that owns it.
- `audit/main-db2cc08/DISPOSITION.md` — status of an external adversarial
  audit (7 resolved, 1 disproved, 3 partial, 8 deferred here).
- `docs/mod-wave-plan.md` — the conventions register and the dated errata that
  record every design ruling. Its Protocol section governs how you work.

### Analysis already done — do not re-derive this

The `install.sh` / `mount-rw` failure mode was traced end to end this session.
Conclusions, with the evidence, so you can **evaluate** them rather than start
from zero:

**What `mount-rw` costs even on success.** It remounts the rootfs rw and runs
`umount -R /etc`. The `-R` also unmounts xovi's `LD_PRELOAD` drop-in, which
lives on a tmpfs over `/etc/systemd/system/xochitl.service.d`, and
`mount-restore` does NOT put it back — the directory stays visible through the
overlay, so the path test lies and only `/proc/mounts` tells the truth. Net
effect: after any successful `vellum add pinned-sleep-clock`, the device is one
xochitl restart away from booting **stock**, with every mod gone — not just
ours. `scripts/package.sh:95-108` compensates by running `xovi/start` instead
of a plain restart; `packaging/pinned-sleep-clock/install.sh` does NOT, so the
package-manager path arms that landmine silently.

**What a failed install costs.** `install.sh` sets `-e`, calls `mount-rw`, does
several fallible operations, and reaches `mount-restore` only on the success
path, with no exit trap. Any failure between them leaves the rootfs writable
and `/etc`'s overlay down until reboot.

**The WiFi consequence, precisely.** The modified `sleep-wifi.sh` lives on the
persistent rootfs, so it keeps running under stock xochitl. It skips the radio
restore only when `wakeup_reason` is `0x00` **and** the device is on battery;
a button wake is `0x04` and restores normally. So the outage is narrow but
real: wake on `0x00`, skip the restore, then the user picks the device up and
uses it *during that awake window* — no new suspend/resume cycle runs, so
nothing restores the radio. That gap is exactly what the mod's Navigator wake
handler covers, and under stock xochitl that handler does not exist. Result: a
working tablet, stock UI, no WiFi, until the next non-`0x00` sleep/wake cycle.
vpdd is NOT part of this — stock xochitl re-asserts 30000 at startup and on
every non-RTC wake, so it self-heals.

**The worse trap.** If the install got as far as `systemctl enable --now
pinsleep-clock.timer` and xovi then detaches, stock xochitl wakes the device
every 5 minutes forever — and the Settings → Display → Sleep clock panel that
would turn it off is part of the qmd, which is no longer loaded. No in-UI
recovery; the user sees unexplained drain with nothing on screen implicating a
mod, because the sleep screen looks stock too.

**Proposed mitigations, ranked by leverage.** Evaluate, do not assume correct:

1. *Make the WiFi gate self-disable when the mod is not in control.* In the
   `async-after` branch of `assets/system-sleep/sleep-wifi.sh`, skip the
   restore only if `pinsleep-clock.timer` is present and active; otherwise
   behave exactly like stock. Makes a stranded hook harmless by construction,
   and moves toward the audit's point that `0x00` proves only "no SPLD latch",
   not "our timer fired". Two lines. Do this one first.
2. *Let the mod, not the installer, enable the timer.* Drop `systemctl enable
   --now` from `install.sh`. The qmd already re-asserts the timer at every
   xochitl start from the persisted cadence (it must — `/etc` is volatile), so
   the enable is redundant, and dropping it means the timer can only ever be
   switched on by code that runs when the mod is live. Kills the runaway-wakes
   scenario outright and puts ownership in one place. Verify the claim about
   the qmd's re-assert before relying on it.
3. *Exit trap in `install.sh`* so `mount-restore` always runs, preserving the
   original exit status.
4. *Re-establish xovi's mount before the installer exits* — after the window,
   check `/proc/mounts` for `xochitl.service.d` and re-run `xovi/start` if it
   is gone, the same check `package.sh` already performs.

1 and 2 make the bad state benign; 3 and 4 make it rarer. Roughly fifteen
lines total. None of it fires during the staged deploy (that uses the raw
`deploy.sh` loop), but all of it must land before the next package build.

### The rest of the backlog, grouped

**Packaging integrity (task #9)** — these block a clean release:
- Both VELBUILDs say `pkgver=0.31.2` against a v0.40.0 tree. Single-source the
  version across VELBUILDs, `package.sh`, the qmd header and `fastshot.xovi`,
  and fail the build when they disagree.
- No recipe declares `source` or `sha512sums`, and `fastshot.so` is gitignored
  yet installed directly — a clean checkout cannot reproduce a release and a
  reviewer cannot tie the shipped ELF to the C source. `package.sh:34` copies a
  pre-built `.so` without running `make`.
- `deploy.sh` never ships `fastshot.so` at all; `package.sh` stages only the
  main qmd and two SVGs — `pinnedSleepBoltInv.svg` and both standalone qmds
  (`hideSidebarGuides`, `timezoneLocalePicker`) are installed by nothing.
- The companion depends on `pinned-page-sleep-screen` with **no version pin**,
  so a v0.40 companion can sit against a v0.33 core.
- No package removes `/home/root/.pinnedSleepScreen/`. A purge hook needs its
  own design round: apk runs deinstall hooks on upgrade paths too, so a naive
  `rm -rf` would eat user pins on every upgrade.
- `!mini-light-sleep` conflict is not declared in either VELBUILD (the README
  note is advisory only); needs the ecosystem's exact package name.
- `deploy.sh:74-76` re-asserts `timedatectl set-timezone Europe/Kyiv` every
  deploy, which now fights the timezone mod's UI setting.
- Settle `rmppmove` vs `rmppm` with one on-device `apk info -a` capture before
  changing any recipe — three non-forced `vellum add` installs currently
  succeed with `rmppmove`, so the audit's doc-derived claim is unproven here.

**Docs still carrying disproved claims (task #9):**
- `docs/power-design.md:130-138` and `docs/wakelock-trace.md:69` still assert
  "the clock prevents hibernation / the 4 h deadline never arrives".
  `ghostdata/analysis.md` disproves it; `docs/plan-d-design.md` already carries
  the erratum, these two do not. Plan D's whole rationale needs
  re-justification before any of it is built.

**Device-only verification (task #10)** — needs hardware, not analysis:
- Landscape chapter chrome rects may be computed on swapped axes
  (`mapToItem(DocumentView root)` vs `complement()` clipping against the
  portrait sleep window) — exactly the captures v0.34 now rotates the bar for.
- Whether `Screen` resolves inside the two sleep-window QML files (worst case
  is "no upsizing on big panels", never a broken Move).
- Whether an empty `illustration` collapses `ArkControls.Selector` cleanly in
  the timezone list.
- Whether the clipped six-row list's inner drag fights Display.qml's outer
  Flickable.
- Keyboard tabbing past the hidden Guides row and past the mod-inserted
  Settings panels (they are deliberately outside stock `navigationModel`).
- Whether `Text.Outline`'s fixed width reads as the same weight as the
  mod-drawn 2px battery halo.
- The idle 0→1 path: does the framebuffer still hold the document when the
  sleep-entry capture runs, or is the native inSuspend repaint racing it.
- xochitl's `already slept` counter: zero point, reset rule and cadence
  dependence are unknown (measured 25,004 s cumulative vs 14,419 s reported).
  Until a controlled repeat pins them down, **no doc may state a
  time-to-hibernate**.

**Open design questions (owner decides):**
- Should the black bar style also invert the bottom contacts strip? Currently
  it stays white; the failure page must stay white regardless.
- v0.39 made the capture-time `pinned.json` write synchronous, putting a small
  unfsynced write on the interactive path (every pen-lift capture).
  `writeFileAtomic` has no `fsync`, so it should be invisible — but if any
  writing-latency hitch shows up, the conservative variant is sync for the
  pin/unpin tap only, async for capture-time saves.
- Owner idea, not a defect: strokes written and then navigated away from
  before the pen-lift capture fires are never captured, so the sleep image
  lags. Proposal is a synchronous shot on navigate-away when the page is dirty
  — the view is being torn down anyway, so a ~70 ms hitch is invisible there.
  Caveat: `onPageChanged` fires *after* `root.page` moves, and whether the
  framebuffer still holds the outgoing page at that instant is a race that
  needs device measurement. Pairs with the parked self-capture merge.
- Package structure was reviewed this session and the split (mod-space core +
  system-touching companion) was **kept deliberately**. The boundary is
  "installs into `/home/root/xovi/` only" vs "needs lifecycle scripts to put
  your system back" — visible as `install=` being present in exactly one
  recipe. Do not merge them without revisiting that discussion; the version
  pin (above) is the cheap fix for the skew risk it introduces.

**Cosmetic / known-and-accepted:**
- The battery-icon geometry is the mockup's, not a measurement of ark's
  compiled `BatteryIndicator` (unreadable off-device); only the black arm uses
  the mod-drawn one, so compare the arms side by side.
- A comment at both battery Rows describes the child order backwards; left as
  found.
- The v0.40 "skip when forced" test may read the flag after the Navigator
  clears it, costing one extra ~70 ms grab on a long-press sleep. Never a wrong
  pixel — both shots capture the same pre-render frame and serialize on
  fastshot's `captureLock`. Fix only if measurement says it matters, and then
  with a Navigator-published marker, not a second read.
- Date stamp clearance: `Wed, 11 Aug` is wider than the old numeric form and
  the stamp has no elide, sitting beside the centred clock.

### How to work

`docs/mod-wave-plan.md`'s Protocol applies: one work package per commit, ask
rather than invent, findings go to `docs/DEFERRED.md` instead of becoming
scope creep. Gates are local and the tablet may be busy: qmldiff preflight
against all three qmds must exit 0, and `make` in `extensions/fastshot` must be
clean. Never `git add -A` — `audit/`, `w5data/`, `ghostdata/` are untracked or
ignored and must stay that way.

When you finish an item, mark it in `docs/DEFERRED.md` and, if it came from the
audit, update `audit/main-db2cc08/DISPOSITION.md` so the two stay in sync.
