# Overnight ghost-isolation test — journal forensics (night 2026-08-11 → 12)

Analyzed 2026-08-12 by Opus subagent from `ghostdata/journal-night.log`
(26,510 lines, `Aug 11 20:00:04` – `Aug 12 08:41:31` EEST, pulled over USB SSH).
Reproducible script: `ghostdata/analyze_night.py`.

Test setup: sleep clock ON, 1-min cadence (`OnCalendar=*:00/1`), stock
vpdd 30000 (vpdd.conf=30000 = the flag value; hook logic live), true stock 34 s
wake window (no clamp loaded). Reverted to vpdd.conf=6000 after the pull.

User's morning visual verdict (before any full refresh): ghosting REPRODUCED at
stock vpdd — most prominent on the bar strip where battery + clock digits were
(both exited into white space); date area cleaned up better because the toolbar
handle rendered on top of it at exit; highlight-strip ghosts from the sleep image
within expectation, ≈ same magnitude as the v50 night. Ghost clock read "8:19"
despite an ~08:28 manual wake.

## HEADLINE (Task 5 answer, up front)

**The per-minute wakes and clock renders did NOT run during 08:20–08:28. The device hibernated at 08:19:45 and slept unbroken until the user's manual wake at 08:28:08.** The ghost reading "8:19" is the **genuinely last-rendered frame**, not stale residue surviving ~9 subsequent repaints. The ghosting investigation must not treat 08:20–08:28 as repaint cycles — there were none.

Cause: xochitl's own power-state module crossed a 4-hour cumulative-sleep threshold and escalated from suspend-to-RAM to suspend-to-disk:

```
08:19:44 xochitl[1066]: rm.powerstate.rm12x  Going straight to hibernate, already slept: 14419282ms last marker event:none (tryAction)
08:19:45 kernel: PM: hibernation: hibernation entry
```

Hibernation powers the SoC down entirely (`sleep-optee.sh: Shutting down OPTEE`, `sleep-hibernate.sh: Enable falcon boot`), so `pinsleep-clock.timer` cannot fire and no RTC alarm is re-armed. Wake came from the pen, not the RTC: `SPLD wakeup-reason (0x10): marker` / `Woke up with reason=MarkerDetached`.

---

## 0. Corrections to the test premise (these change every downstream number)

| Premise | Log says |
|---|---|
| Unplugged 00:30 – 08:29 | **Device was ON CHARGER 01:12:48 → ~02:36.** `SPLD wakeup-reason (0x20): charger_connected` at 01:12:48 (battery 78%); charged to SOC 100% at 02:28:53. |
| 1-min cadence all night | 5-min unit installed 01:00:48; **1-min unit installed 01:45:47–01:45:50** (symlink re-created, `daemon-reload`, "unit file … changed on disk" warning). |
| Night ended 08:29 (manual wake) | **Night ended 08:19:45 (hibernation).** Manual wake 08:28:08. |
| ~480 timer minutes in 8 h | 1-min cadence ran **393.9 min** (01:45:50 → 08:19:45). |

**Clean unattended unplugged window = 02:36:46 → 08:19:45 (20,579 s = 5.72 h).** Boundaries: last power-key press 02:36:07, display → DeepSleep 02:36:08.5, Wi-Fi down for good 02:36:46 (`wlan0: Lost carrier`), battery SOC 100→99 at 02:36:11 then monotonic decline. Zero power-key, Wi-Fi, or network events between 02:36:46 and 08:19:45.

Two parse facts that must be respected (both verified in-file):
- The kernel console is suspended during the freeze, so the whole entry block (`Filesystems sync` … `Enter suspend, battery X%`) is **flushed at resume with the resume timestamp**. Only `PM: suspend entry (deep)` carries a true pre-freeze time. (Proof: entry at 08:16:45, `Enter suspend, battery 64.609%` printed at 08:17:10.)
- **Every vpdd abort produces a matched entry/exit pair**, so 367 entries == 367 exits but only 237 are real sleeps.

Exhaustiveness identities (all hold, nothing unmodelled):
- 237 `Exit SUSPEND` + 123 `Exit FAILED_SUSPEND` = 360 = `Enter suspend, battery` count
- 367 `PM: suspend entry` − 360 = 7 = `Enter autosleep` count
- 369 `Freezing user space processes` = 367 suspends + 2 hibernations

---

## 1. Cycle inventory

Cycle = successful sleep **exit** → next successful sleep **entry** (aborts in between count as awake time inside the cycle).

**Primary — clean unplugged window 02:36:46 → 08:19:45:** 213 successful sleeps, **212 cycles**

| awake (s) | n | | awake (s) | n |
|---|---|---|---|---|
| 34 | 78 | | 87 | 21 |
| 37 | 1 | | 88 | 12 |
| 38 | 1 | | 90 | 2 |
| 39 | 1 | | 100 | 1 |
| 41 | 2 | | 102 | 1 |
| 44 | 2 | | 107 | 1 |
| 48 | 1 | | 144 | 1 |
| 86 | **84** | | 146 | 2 |
| | | | 147 | 1 |

- **mean 66.81 s**, median 86, mode 86 (84×), min 34, max 147
- Strongly **bimodal**: 34 s (36.8%) and 86–88 s (55.2%). Nothing between 48 s and 86 s.

**Secondary — full 1-min cadence window 01:45:50 → 08:19:45:** 230 sleeps, 229 cycles; mean 72.91 s (65.97 s excluding one outlier), median 86, mode 86 (88×), min 34, max 1655, stdev 108.4; p50 86, p75 86, p90 87, p95 88, p99 146. The **1655 s cycle (02:09:11 → 02:37:11) is user activity, not a device anomaly** — power key at 02:10:06, display Normal → LightSleep 02:14:07 → Normal 02:36:06 → DeepSleep 02:36:08.

### Merged cycles
Wake-to-wake interval histogram (1-min window): 58 s ×1, 59 ×27, 60 ×53, 61 ×15 → **96 one-minute**; 119 ×10, 120 ×94, 121 ×24 → **128 two-minute**; 179 ×3, 181 ×1 → **4 three-minute**; 1680 ×1 (user session).

**133 of 229 cycles (58%) skipped at least one timer minute.** With ~86 s awake, the next minute boundary always passes while the device is still up, so that minute's firing is consumed mid-wake and the RTC alarm lands on the following minute.

### Model verdict — the stated model FAILS

`awake = max(34 s, t_last_EPD + 30 s vpdd + ~3 s)` has **no abort term**, and aborts are the dominant driver of every tail value. It cannot produce 86 s.

The floor is right (min = 34 s; 83 cycles are exactly 34 s). The tail is not EPD-driven — it is retry-driven. The empirically exact replacement:

```
awake = 34 s  +  35 s × n_aborts  +  Σ(granted grace delays)
```
(35 s = the 34 s re-arm window + ~1 s failed suspend/resume round trip; each abort re-arms a fresh 34 s window.)

Residual (measured − predicted) over 229 cycles: **0 s for 206, +1 s for 22**, +1583 s for the one user-session cycle. **228/229 within 1 s.** Perfect decomposition:

| cycle class | n | awake |
|---|---|---|
| 0 aborts, 0 delay requests | 83 | **34 s, every one** |
| 0 aborts, ≥1 delay request | 23 | 37–88 s |
| 1 abort | 123 | 86 s (84×), 87 (18), 88 (11), up to 147 |
| ≥2 aborts | 0 | — |

Worked example (03:44:11 wake): +34 s re-arm → suspend entry 03:44:45 → abort 03:44:46 → +34 s re-arm → grace request 17,168 ms at 03:45:20 → suspend entry 03:45:37. Total 86 s = 34 + 35 + 17.

### vs. the prior 25-cycle on-cable sample
| | prior (25) | this night (229) |
|---|---|---|
| modal awake | 34 s (12/25 = 48%) | 34 s (83/229 = 36%) |
| abort rate | 6/25 = 24% | **123/229 = 54%** |
| mean | ~42 s | 66.8 s (clean window) |
| tail | 38, 51–52, 67, 88 | 37–48 (grace only), 86–88, 100–147 |

The prior sample's 51–52 s and 88 s tails are the same abort signature at a shorter grace; the model was misattributing its own cause. The night ran **2.2× the prior abort rate**, which is why mean awake rose 42 → 67 s.

---

## 2. Expected vs actual wake count

**The timer never throttled, stopped, or drifted.** `pinsleep-clock.service` activated **343 times in exactly 343.0 minutes** (clean window) and **394 times in 393.9 minutes** (full cadence window) — 1:1 with every timer minute, no misses.

The 367-vs-480 gap has three separate causes, none of them cadence loss:

1. **The 480 premise is wrong twice.** The 1-min cadence only ran 393.9 min (not 480), and it ended at hibernation 08:19:45 (not 08:29).
2. **Merged cycles absorb 163 minutes.** 394 firings − 230 successful sleeps = 164; merged accounting gives 128×1 + 4×2 + 1×27 = 163 (one off at a window boundary). 184 of the 420 total activations were not adjacent to any resume, i.e. fired mid-wake.
3. **The 367 suspend entries are not 367 wakes.** They decompose as 237 real sleeps + 123 vpdd aborts + 7 autosleep. Aborts are extra *entries*, not extra wakes.

**Actual RTC wakes in the night window:** 230 real resumes (clean window: 213). Kernel resume events total 353 (230 real + 123 abort pseudo-resumes). Wake-source attribution across the file: IRQ 20 `44440000.bbnsm:pwrkey` ×241 — this is the **RTC alarm**, since the BBNSM block hosts both the pwrkey and the RTC (xochitl reports `reason=RTC` for all of these; 359 in file).

---

## 3. Abort analysis

**All 123 aborts are the benign vpdd abort. There is not a single non-vpdd suspend failure in the log.** Every one is the identical four-line signature:

```
g2194-regulator 0-0048: Can't suspend, vpdd timer running
g2194-regulator 0-0048: PM: failed to suspend async: error -11        <- -EAGAIN
rm_sleep_monitor sleep-monitor: Exit FAILED_SUSPEND, battery X%
PM: Some devices failed to suspend, or early wake event detected
```
Exactly **one distinct dpm failure reason** in the entire file (`g2194-regulator 0-0048 … error -11`, 123×).

- **117 of 123 fall in the clean unplugged window**; 123/123 fall in the 1-min cadence window (first 01:54:46, last 08:12:46). Zero aborts before the 1-min cadence was installed.
- **Per hour** (clean window): 02→8, 03→16, 04→20, 05→22, 06→20, 07→25, 08→6. Rising trend across the night.
- **Per cycle:** 106 cycles with 0 aborts, 123 with exactly 1, **0 with ≥2**. Never two in a row.
- **Cost per abort** (abort entry → eventual successful suspend entry): mode **52 s** ×84, then 53 ×18, 54 ×11, 56 ×2, 62/66/68/73 ×1 each, 110 ×1, 112 ×2, 1621 ×1 (user session). Mean 67.1 s, min 52 s. Structurally 52 s = 1 s failed round trip + 34 s re-arm + ~17 s grace.

**Zero-count confirmations (all verified 0 in the whole file):**
`g2194` WARN / `WARN_ON` backtraces **0** ✅ (as expected at vpdd 30000), `BUG:` 0, `Tainted` 0, `Call trace` 0, freezer failures 0, OOM kills 0, watchdog 0, elants touch errors 0.

Not-anomalies, for the record: `OOM killer disabled`/`enabled` (369× each) is normal suspend bookkeeping; `aw99703-bl 1-0036: UVLO flag set (0x4000)` (362×) is normal backlight-driver resume noise on every wake.

### The mechanism worth acting on
83 cycles suspended cleanly at wake+34 s with no hold active; 123 cycles aborted at wake+35 s because a hold *was* active. Same nominal work, opposite outcome, ~37/54 split. **The suspend attempt at wake+34 s races a 30 s rail hold armed by a repaint whose latency jitters across the boundary — only ~4 s of margin.** That 4 s of margin is the tuning target: it converts directly into a 54% abort rate, +52 s awake per abort, and the 2-minute merged cadence.

---

## 4. Grace / delay requests

`PowerStateRm12x requests a delay of Xms` — **173 total, 152 in the clean window, 166 in the cadence window.**

Clean window: min **3,024** ms, max **33,000** ms, mean 18,790, median 17,200.

| bucket (ms) | n | | bucket (ms) | n |
|---|---|---|---|---|
| 2,000–3,999 | 2 | | 20,000–21,999 | 6 |
| 4,000–5,999 | 1 | | 22,000–23,999 | 2 |
| 6,000–7,999 | 2 | | 24,000–25,999 | 2 |
| 8,000–9,999 | 2 | | 26,000–27,999 | 3 |
| 12,000–13,999 | 1 | | 28,000–29,999 | 2 |
| **16,000–17,999** | **93** | | 30,000–31,999 | 5 |
| 18,000–19,999 | 23 | | **32,000–33,999** | **8** |

- **76% cluster tightly in 16.4–19.5 s** (the 17,152–17,220 ms band alone accounts for ~70 values).
- **The hard cap is exactly 33,000 ms = 30,000 (vpdd_length) + 3,000 pad**, hit 8 times. This is direct confirmation of the model's *upper bound*: full rail hold + ~3 s.
- Per cycle: 83 cycles with 0 requests, 131 with 1, 11 with 2, 4 with 3.
- Range vs prior (3,168–27,388 ms): consistent, extended at the top by the 33,000 saturations.

**Caveat:** the *causal* half of the model ("= remaining rail hold + ~3 s") is **not testable from this log** — there are no per-wake EPD-update timestamps. Only the 33,000 = 30,000 + 3,000 cap and the internal consistency of the arithmetic support it.

---

## 5. Morning forensics — 08:10–08:35 EEST

Every suspend/resume, timer firing, abort, and wake reason. All 10 minutes 08:10–08:19 behaved normally; **08:20–08:27 produced nothing at all.**

| Time | Event |
|---|---|
| 08:10:11 | `PM: suspend exit` · RTC wake · `Starting No-op` (timer) · re-arm 34000 ms |
| 08:10:45 | `PM: suspend entry` |
| 08:10:46 | **ABORT** `Can't suspend, vpdd timer running` → `Exit FAILED_SUSPEND` · re-arm 34000 ms |
| 08:11:09 | `Starting No-op` (timer, mid-wake) |
| 08:11:20 | grace request 17,196 ms |
| 08:11:37 | `PM: suspend entry` (success) — awake 86 s |
| 08:12:11 | exit · RTC wake · `Starting No-op` |
| 08:12:45 / 08:12:46 | entry → **ABORT** (vpdd) |
| 08:13:04 | `Starting No-op` (mid-wake) |
| 08:13:20 | grace request 20,532 ms |
| 08:13:41 | `PM: suspend entry` — awake 90 s |
| 08:14:11 | exit · RTC wake · `Starting No-op` |
| 08:14:45 | `PM: suspend entry` — awake **34 s**, clean |
| 08:15:10 | exit · RTC wake · `Starting No-op` |
| 08:15:44 | entry — awake 34 s |
| 08:16:11 | exit · RTC wake · `Starting No-op` · `woken_by_timer=0, remain: 14373661532456ns` |
| 08:16:45 | entry — awake 34 s |
| 08:17:10 | exit · RTC wake · `Starting No-op` |
| 08:17:44 | entry — awake 34 s |
| 08:18:10 | exit · RTC wake · `Starting No-op` |
| 08:18:44 | entry — awake 34 s |
| **08:19:10** | **exit · RTC wake · `Starting No-op` — LAST RTC WAKE OF THE NIGHT** |
| 08:19:44 | `Entering DeepSleep forever` · **`Going straight to hibernate, already slept: 14419282ms`** |
| 08:19:45 | `PM: hibernation: hibernation entry` · OPTEE shut down · falcon boot enabled · mdm-agent + tee-supplicant stopped |
| 08:20–08:27 | **NOTHING. Zero log lines. Zero suspend exits. Zero timer firings. Zero renders.** |
| 08:28:08 | `Exit HIBERNATE, battery 64.292%` · **`SPLD wakeup-reason (0x10): marker`** · `hibernation exit` · `Woke up with reason=MarkerDetached` · display DeepSleep → Normal |
| 08:28:43 → 08:32:10 | autosleep cycles (7), wake IRQs mmc2/elants_spi/bbnsm |
| 08:32:10 | `[fastshot]: ok:/tmp/pinnedSleep/current.bmp` — first genuine capture since 02:36 |
| 08:32:13 | `Power key pressed short` (user) |

**Verified programmatically: `Starting No-op` activations in 08:19:11–08:28:07 = 0.** Eight timer minutes (08:20 … 08:27) fired zero times, because systemd timers cannot run while the SoC is hibernated.

**Why the timer stopped:** not battery (64.3%, healthy), not consecutive aborts (the last 6 cycles were clean 34 s), not a stopped unit. xochitl's `rm.powerstate.rm12x` crossed a **4-hour threshold** and escalated suspend→hibernate. Corroboration that the threshold is 4 h = 14,400 s: every `systemd-sleep` resume logs `remain: ~14,374 s`, which equals 14,400 − that cycle's sleep duration (e.g. 14,400 − 26 = 14,374), i.e. `HibernateDelaySec = 4 h`, reset each cycle because `woken_by_timer=0` on all 231 samples.

**The `already slept` zero point is not determinable from this log.** Measured cumulative suspend+hibernate time up to 08:19:44 is **25,004 s**, well above the reported 14,419 s, so the counter is *not* cumulative-sleep-since-boot and cannot be reconciled with any window boundary in the file. What is certain: it crossed ~14,400 ms×1000 and triggered the escalation.

---

## 6. Render evidence — cannot be confirmed 1:1

| line | count |
|---|---|
| `Starting No-op: the wake itself thaws xochitl and the sleep clock repaints...` | 420 (394 in cadence window, **343 in exactly 343.0 min** clean window) |
| `Finished No-op: …` | 420 |
| `pinsleep-clock.service: Deactivated successfully.` | 420 |
| `[fastshot]: ok:/tmp/pinnedSleep/*.bmp` | 71 |
| `qml pinSleep: capture -> chN.bmp` | 40 |

**420 service activations must NOT be read as 420 confirmed renders.** The unit is a no-op by construction — its own description says the wake itself thaws xochitl and the repaint happens inside unlogged QML. The `fastshot`/`pinSleep: capture` lines cluster exclusively in hands-on sessions (20:0x, 01:0x–01:4x, 02:14, 02:36, 08:32:10) — **not once per wake**. There is no direct per-wake render log line in this firmware build.

**Best available indirect evidence:** e-paper rails were demonstrably held during the wake on **146 of 229 cycles (64%)** — 123 cycles that aborted with `vpdd timer running` (proves an EPD update within the preceding 30 s) plus 23 cycles that requested a grace delay without aborting. **The remaining 83 cycles (the exact-34 s ones) carry no log evidence that a repaint occurred at all.** Whether the clock actually redrew on those 83 minutes cannot be determined from this log; adding one log line at the repaint call site would close this gap and is the single highest-value instrumentation change for the next run.

---

## 7. Night boundaries & anomalies

**Boundaries**
- Charger **connected** 01:12:48 (`SPLD 0x20 charger_connected`, `reason=Charger`, battery 78%) → SOC 100% at 02:28:53.
- 1-min cadence effective **01:45:50**.
- Charger **unplugged ≈ 02:36:11** (SOC 100→99; battery monotonically declines thereafter). Last user touch 02:36:07; Wi-Fi down 02:36:46 → **clean unattended phase 02:36:46 – 08:19:45**.
- Night end **08:19:45** (hibernation). Manual wake **08:28:08** (MarkerDetached). Charger re-connected ≈ 08:32–08:33 (SOC rising 63→71 by 08:40:49).

**Anomalies: none.** Zero reboots (no `Linux version` / `Booting Linux` / `Startup finished` lines). **Zero xochitl restarts** — a single PID 1066 emits all 1,963 `rm.batterymanager` lines across the whole 12.7 h file (the transient `xochitl[NNNNN]` PIDs are short-lived forked helpers logging `[librarian]: extension loaded`). No crashes, no watchdog, no OOM, no taint, no freezer failures.

**Gaps >3 min in the wake sequence:** exactly 2, both explained.
- 1,680 s (02:09:11 → 02:37:11) — **user session**, power key 02:10:06.
- 181 s (06:12:10 → 06:15:11) — an ordinary 147 s cycle: 34 s re-arm → grace 17,216 ms → grace 33,000 ms → suspend at +85 → abort → 34 s re-arm → grace 28,060 ms → suspend at +147.

**Battery / max77818:** 82.25% @20:02 → 78% @01:12 (charger on) → 100% @02:28:53 → unplug ~02:36 → **99.914% @02:37:11 monotonically down to 64.414% @08:19:10**. Discharge over the unplugged cycling phase: **35.5 percentage points in 5 h 42 m = 6.23 pp/h**. Hibernation cost 0.036 pp over 8 m 23 s. No `Failed to read` / fuel-gauge faults except one benign `max77818_battery: Failed t…` at 00:06:58 (during the first hibernation, pre-test).

---

## 8. Awake-time economy

| window | span | asleep | awake | **duty (asleep)** |
|---|---|---|---|---|
| Clean unplugged 02:36:46 – 08:19:45 | 20,579 s | 6,381 s | 14,198 s | **31.0%** |
| …including the 503 s hibernation → 08:28:08 | 21,082 s | 6,884 s | 14,198 s | **32.7%** |
| 1-min cadence 01:45:50 – 08:19:45 | 23,634 s | 6,841 s | 16,793 s | 28.9% |

**The device spent 69% of the unplugged night awake.**

An ideal 1-min cycle at these settings (34 s awake / 26 s asleep) would give **43.3% asleep**. Actual is 31.0% — the entire 12-point shortfall is the merged 2-minute cadence, where 86 s awake buys only 34 s of sleep (28.3% asleep). Aborts are therefore not merely a latency nuisance: **they are the primary consumer of the night's energy budget.** At P_sleep ≈ 2 mA vs ~100+ mA awake, the awake 69% accounts for ~99.9% of charge consumed; eliminating the 54% abort rate would move duty from 31% to ~43% asleep and cut average current by roughly a quarter.

---

## Actionable conclusions

1. **The 08:19 ghost is not a ghosting artifact at all** — it is the last frame the panel was given. Any residue analysis based on "9 repaints after 8:19" is invalid.
2. **A 4-hour cumulative-sleep escalation to hibernate silently ends every long test.** Future overnight runs must either suppress it or budget for it; otherwise the last hours of any test are unmeasured.
3. **The 34 s sleep window vs the 30 s vpdd hold leaves ~4 s of margin**, producing a 54% abort rate, +52 s awake per abort, a 2-minute effective cadence, and a 12-point duty-cycle loss. Widening the window (or shortening `vpdd_length`) is the single highest-leverage change.
4. **The stated awake-time model is wrong** — replace `max(34, EPD+33)` with `34 + 35·n_aborts + Σgrace`, which fits 228/229 cycles within 1 s.
5. **Add one log line at the sleep-screen repaint call site.** Without it, 83 of 229 wakes have no evidence a render happened, and render:wake can never be confirmed.
