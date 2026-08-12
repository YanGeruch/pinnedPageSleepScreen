# W5 battery-drain test — analysis (vpdd 50 certification)

reMarkable Paper Pro Move (`imx93-chiappa`), kernel `6.12.49+git-imx93-chiappa-g68b95e858a0a`.
Run date 2026-08-11, device TZ EEST (+03:00). All times below are EEST. Device **not rebooted**
since W4 (kernel taint 512 from yesterday's vpdd-0 WARNs persists and is ignored throughout).

Data: `w5test.csv` (129 wake rows), `w5clamp.log` (127 armings), `journal-run.log`
(10,073 lines, 11:55:08 → 19:09:20), `battery-state-now.txt` (pull at 19:09, charging).
Reference: `../w4data/analysis.md`.

## Headline

| | |
|---|---|
| **vpdd 50 kernel verdict** | **CLEAN. 104 battery vpdd-50 panel-offs, 0 WARNs, 0 `cut here`, 0 `vcom`, 0 `Call trace`, 0 `Can't suspend` — over the entire 7 h 14 min journal.** (W4: 5 vpdd-0 panel-offs, 5 WARNs.) |
| Measured awake time | **6.0 s** — 99 of 104 cycles exactly 6 s. Between v2000's 8 s and v0's 3 s. |
| **Shipping number, w3/v50 @ 5-min cadence** | **0.400 %/h** — *directly measured*, 5 h 15 min, 63 cycles, no extrapolation. 809.5 µAh/wake. |
| µAh/wake @ 1-min cadence | 675.0 (1.668 %/h) |
| **`P_sleep` — resolved** | **0.560 µAh/s ≈ 2.0 mA ≈ 0.083 %/h** suspended floor. W4 could only bound this at 0–0.13 %/h. |
| Standby runtime implied | **≈ 250 h ≈ 10.4 days** full→empty on the clock alone (vs ≈ 4.8 days at the w34/v6000 baseline) |
| Post-run `suspend_fail` 2→3 | 19:07:16, **stock autosleep path**, touch controller (`IRQ 40 elants_spi`) racing a freeze, 17 min after the last rig cycle and after the clock timer was disabled. Not the rig, not vpdd 50. |
| Recommendation | **Ship window 3 + vpdd 50.** Do **not** ship w8/v50 — at vpdd 50 the window becomes load-bearing and w8 would cost ~5 s of extra awake time. |

---

## 1. Data integrity

| Check | Result |
|---|---|
| Row count | 129 data rows + header. Header present. |
| Epoch monotonic | Yes, strictly increasing. |
| `window` / `vpdd` columns | `3` / `50` in **every** row. No mid-run config change. |
| Phase labels | `A-w3v50-fast` 58 rows, `B-w3v50-prod` 71 rows. Boundary exactly at 13:00:08. |
| `suspend_fail` | **2 in every row, first to last.** The 1→2 event predates the run (05:24 today, known mwlan race). The run contributed nothing. |
| Cadence, phase A | 60 s ± 1 s for all in-run rows, with two rig-startup exceptions: 12:03:00→12:03:02 (2 s) and 12:07:00→12:08:06 (66 s). |
| Cadence, phase B | 300 s ± 1 s for all 70 intervals. The 12:59:08→13:00:08 interval is 60 s — correct, that interval is still phase A's. |
| `suspend_ok` increments | +1 per row throughout **except** inside the two excluded windows below. |
| Gauge quantum | **500 µAh** (all in-window steps are multiples of 500). At 24,275 µAh/% one quantum = 0.0206 %. |
| Journal ↔ CSV clock | Agree exactly. Every CSV `localtime` has a matching `PM: suspend exit` in the journal at the same second. |
| Temperature | 26.3 °C at pull (W4: 25.4 °C). No thermal events. |

### Charger timeline — derived from the data, not the brief

The brief estimated the unplug at 12:15–12:25. The journal pins it precisely, and there were
**two** unplugs:

| time | event |
|---|---|
| 12:06:22 / 12:06:23 | `usb1: Lost carrier`, `fusb303b: Adjusting USB current to 100mA` — **first unplug** |
| 12:11:43 / 12:11:44 | `usb1: Gained carrier`, `Adjusting USB current to 1500mA` — **replugged** |
| **12:17:40 / 12:17:41** | `usb1: Lost carrier`, `Adjusting USB current to 100mA` — **final unplug** |
| 12:18:06 | `charge_now` peaks at 1,348,500 µAh (26 s of gauge lag), falls from 12:19:06 on |
| 18:54:33 | `SPLD wakeup-reason (0x20): charger_connected` — user plugs in (wall charger; no `usb1`) |
| 18:57:28 | `Adjusting USB current to 100mA` — detached again |
| 19:07:47 | `usb1: Gained carrier` + 1500 mA — attached to the host for the data pull |

**The device was on battery continuously from 12:17:40 to 18:54:33.** The whole analysed window
sits inside that span.

### Excluded windows

**A. 12:03:00 – 12:19:06 (18 rows) — charger + user session.** Unusable for four independent
reasons: (i) on charger for most of it, `charge_now` non-monotone and rising to a 1,348,500 µAh
peak; (ii) `suspend_ok` frozen at 693 for six rows and at 697 for nine rows — the device simply
was not sleeping; (iii) two user unlocks at 12:10:37 and 12:11:35, each firing the mod's restore
transient (`echo 30000 > …/vpdd_length`), so those cycles ran **vpdd 30000, not 50**; (iv) wifi
was still associated until 12:19:38.

**B. 18:15:08 → end of file (last 7 rows) — user session, vpdd restored to 30000.** A `Powerkey`
wake at 18:18:37 ended the clean run. Six restore transients fire (18:18:37, 18:19:34, 18:19:53,
18:20:27, 18:26:12, 18:28:34), each writing `vpdd_length=30000`; wifi reloads at 18:18:37;
`suspend_ok` jumps +3 and +5 in single 5-min intervals; the 18:15:08→18:20:06 interval alone
loses 9,500 µAh. Aggregate for the tail: **2.719 %/h, 2,962 µAh per suspend** — six times the
clean rate, and worthless as a vpdd-50 measurement. All excluded.

The run never reached its scheduled 19:00 `end` phase: the user disabled the clock at 18:54:56
(`systemctl disable --now pinsleep-clock.timer`, deactivated 18:54:57). There are no restore rows
and no `/run/w5-concluded`. **18:50:08 is the last row; 18:15:08 is the last clean row.**

### Clean windows

| window | span | s | wakes | suspends | cadence |
|---|---|---|---|---|---|
| **A battery** | 12:20:07 – 13:00:08 | 2401 | 41 | **40** | 60 s |
| **B battery** | 13:00:08 – 18:15:08 | 18900 | 64 | **63** | 300 s |
| combined | | 21301 | | **104 vpdd-50 battery cycles** | |

Independent cross-check: `w5clamp.log` contains **exactly 104 armings** in 12:20:07–18:15:08.
Note the two denominators — 63 suspends is the divisor for µAh/wake in phase B; 64 wakes is the
sample size for the awake-time distribution. Both are correct for their purpose.

### Fuel-gauge scale

`battery-state-now.txt` reports `CHARGE_FULL=2425000` → 24,250 µAh/%. The brief cited 2,427,500
→ 24,275. The `capacity_hires` column implies a divisor of ≈ 24,277 µAh/% consistently across all
129 rows. **This report uses 24,275 µAh/%** for continuity with W4 and agreement with
`capacity_hires`; the 0.1 % discrepancy against the pull-time `CHARGE_FULL` is below every other
error term. As in W4, `capacity_hires` is not an independent measurement — it cross-checks
arithmetic, not physics.

---

## 2. THE VERDICT — vpdd 50 produces no kernel warnings

This was the question W5 existed to answer. **The answer is unambiguous.**

Greps over the **entire** `journal-run.log` (11:55:08 → 19:09:20, 7 h 14 min — not just the run
window, so the negative result is not window-dependent):

| pattern | hits | |
|---|---|---|
| `WARNING` | **0** | |
| `cut here` | **0** | |
| `Call trace` | **0** | |
| `Tainted` | **0** | |
| `vcom` (case-insensitive) | **0** | |
| `Can't suspend` | **0** | no `-EAGAIN` suspend abort, ever |
| `vpdd timer` | **0** | |
| `Freezing … aborted` / `refusing to freeze` | **0** | |
| kernel `regulator`/`i2c` errors | **0** | |
| `g2194` | 11 | **all 11 are systemd transient-unit command lines**, not kernel messages |

The 11 `g2194` hits are every occurrence of the mod's restore script being launched:

```
systemd[1]: Started /bin/sh -c "rm -f /run/pinsleep-wifi-off; lsmod | grep -q iw61x_sdw61x ||
  modprobe iw61x_sdw61x; echo 30000 > /sys/bus/i2c/drivers/g2194-regulator/0-0048/vpdd_length".
```

They occur at 11:58:05, 12:10:37, 12:11:35, 18:18:37, 18:19:34, 18:19:53, 18:20:27, 18:26:12,
18:28:34, 18:54:33, 19:03:16 — i.e. **on every non-RTC wake and never inside a clean window**.
The string `g2194` appears because it is part of the sysfs path being written. These are benign
and are exactly the events that mark the excluded windows.

**Score: 104 vpdd-50 battery panel-offs, 0 WARNs.** Against W4's **5 vpdd-0 panel-offs, 5 WARNs.**
This is the result W4 §12 predicted from source: the branch condition in `g2194_vcom_disable` is
`if (data->vpdd_timer_val_ms)`, so any nonzero hold takes the deferred-relax timer path, which
cannot reach the `WARN_ON(!data->wakesrc->active)` assertion at line 347. W5 confirms the source
reading empirically over 104 cycles.

Zero `Can't suspend, vpdd timer running` is the second half of the verdict: `g2194_safe_to_suspend`
never blocked a suspend hard enough to fail one. The 50 ms hold is absorbed entirely inside the
awake window (§3), never inside the suspend path.

---

## 3. Measured awake time — 6.0 s, and it decomposes cleanly

`PM: suspend exit` → next `PM: suspend entry`, per cycle, battery + RTC only:

| window | window | vpdd | **measured awake** | n | distribution |
|---|---|---|---|---|---|
| A (1-min) | 3 | 50 | **6.0 s** | 40 | **{6} — exactly 6 s, all 40 cycles** |
| B (5-min) | 3 | 50 | **6.0 s** (mean 6.12) | 64 | {6 × 59, 7 × 4, 10 × 1} |
| combined | 3 | 50 | **6.0 s** | 104 | 99 × 6, 4 × 7, 1 × 10 |

The four 7 s readings (13:00:08, 13:10:08, 14:10:08, 15:10:08) are 1-second journal rounding of the
same 6.05 s event. The single 10 s outlier at 16:00:08 is explained: it is the only cycle with
**two** `requests a delay of 3050ms` entries, and the journal shows
`PM: active wakeup source: xochitl.batterymanager` at 16:00:16 — the first re-suspend attempt was
blocked by xochitl's own wake source and retried once.

**Cadence-invariance of awake time — verified again.** 6.0 s at 60 s period and 6.0 s at 300 s
period, 104 cycles. This is the load-bearing assumption of §6's decomposition and it is measured,
not assumed.

### Decomposition (cycle at 13:05:08, representative of all 104)

```
13:05:08  PM: suspend exit ; Woke up with reason=RTC ; "Re-entering DeepSleep in 34000ms"
13:05:11  rm.sys.timer  sleepDelayTimer timed out              <- the shim's CLAMP 34s -> 3s
13:05:11  suspenddelay  PowerStateRm12x requests a delay of 3050ms
13:05:14  rm.sys.timer  sleepDelayTimer timed out ; "Entering DeepSleep forever"
13:05:14  PM: suspend entry (deep)
```

**awake = 3 s (clamped repaint window) + 3.05 s (one suspend-delay grace) = 6.05 s.**
103 of 104 cycles request exactly one 3050 ms grace; one requests two.

This identifies the 3050 ms grace as the mechanism behind W4's "vpdd sets the awake floor". At
vpdd 0 the wakeup source is released inline, `g2194_safe_to_suspend` returns immediately, no grace
is requested, and awake collapses to the 3 s window — which is exactly W4's measured 3.0 s at P5.
At vpdd 50 the 50 ms hold is enough to trigger one full 3.05 s grace. **50 ms of rail hold costs
3 s of awake time.**

**Open item, inherited.** This decomposition does not reproduce W4's 8.0 s at vpdd 2000: neither
3 + 3.05 nor 3 + 3.05 + 3.05 equals 8. W4 recorded 8 s across 60 consecutive cycles, so the figure
is solid; the extra ~2 s at v2000 is not accounted for by the grace structure visible here. Flagged,
not resolved. Nothing below depends on it (see §7 for why).

---

## 4. Phase B — the shipping number, measured at production cadence

W4's 5-min figures were all extrapolations from 1-min data. **This is the direct measurement.**
Battery only, 5-min cadence, w3/v50, 13:00:08 → 18:15:08.

| span | s | suspends | Δq µAh | µAh/h | **%/h** | %/h (`capacity_hires`) | %/h (OLS) | **µAh/wake** | quantization |
|---|---|---|---|---|---|---|---|---|---|
| 13:00:08 – 18:15:08 | 18,900 | **63** | **51,000** | 9,714 | **0.400** | 0.400 | 0.400 | **809.5** | ±1.0 % |

Endpoint-delta, `capacity_hires` and OLS slope agree to **three decimal places** — the tightest
agreement of any phase in either run.

### Drift controls

| split | %/h | µAh/wake |
|---|---|---|
| first half (13:00–15:35, 31 cycles) | 0.399 | 806.5 |
| second half (15:35–18:15, 32 cycles) | 0.402 | 812.5 |

| hour block | Δq µAh | %/h |
|---|---|---|
| 13:00–14:00 | 10,000 | 0.412 |
| 14:00–15:00 | 9,500 | 0.391 |
| 15:00–16:00 | 9,500 | 0.391 |
| 16:00–17:00 | 10,000 | 0.412 |
| 17:00–18:00 | 9,500 | 0.391 |

The hourly figures alternate between exactly 9,500 and exactly 10,000 µAh — that is one gauge
quantum of jitter around 9,714 µAh/h, i.e. pure quantization with **no trend**. Over 5¼ hours
spanning 54.21 % → 52.11 % SOC there is no measurable drift.

Runtime implied: 100 / 0.400 = **250 h ≈ 10.4 days** from full to empty on the sleep clock alone.

---

## 5. Phase A — 1-minute cadence

Battery only, w3/v50, 12:20:07 → 13:00:08.

| span | s | suspends | Δq µAh | µAh/h | **%/h** | %/h (`hires`) | %/h (OLS) | **µAh/wake** | quantization |
|---|---|---|---|---|---|---|---|---|---|
| 12:20:07 – 13:00:08 | 2,401 | **40** | **27,000** | 40,483 | **1.668** | 1.664 | 1.655 | **675.0** | ±1.9 % |

Split halves give **675.0 and 675.0 µAh/wake** — identical to the µAh, 20 cycles each. This is the
same kind of free drift control W4 got from P3 ≡ P4.

Post-charge relaxation robustness (the charger came off 2 min 27 s before this window opens):

| start | suspends | µAh/wake | %/h |
|---|---|---|---|
| 12:20:07 (as reported) | 40 | 675.0 | 1.668 |
| 12:25:08 (drop 5) | 35 | 671.4 | 1.660 |
| 12:30:08 (drop 10) | 30 | 666.7 | 1.648 |

A ≤ 1.2 % downward drift, consistent with a small residual gauge catch-up. It is carried into §6
as an uncertainty band rather than corrected away. Including the 12:19:06 row (the tail of the
user's session) inflates the figure to 695 µAh/wake — hence the 12:20:07 start.

---

## 6. `P_sleep` — resolved, which W4 could not do

**Why this run can resolve it and W4 could not.** Phases A and B are the *same configuration*
(w3/v50, verified per-row in the CSV and per-cycle in the awake data), on the same day, on the
same battery at 55 % vs 52–54 % SOC, with **no configuration change anywhere inside either
window**. The 13:00:08 boundary is a *cadence change only*. There is therefore no vpdd bind-lag
to trim, no contaminated boundary cycle, and no config confound — the two arms differ in exactly
one variable, the thing the model is solving for. W4's only 5-min anchor was 9 minutes long, 2
cycles, and yielded an unphysical negative value; §4 of that report had to fall back on a range.

```
E_cycle(T) = E_active + P_sleep · (T − t_awake)          t_awake = 6.0 s, measured, both arms

E_cycle(60)  = 675.0 µAh   (40 cycles)
E_cycle(300) = 809.5 µAh   (63 cycles)

P_sleep = (809.5 − 675.0) / 240 = 0.560 µAh/s
E_active = 675.0 − 0.560 × 54 = 644.8 µAh
```

| quantity | value |
|---|---|
| **`P_sleep`** | **0.560 µAh/s** = 2.02 mA |
| **suspended floor** | **0.083 %/h** (0.560 × 3600 / 24275) |
| `E_active` (resume + repaint + rail hold + panel-off + re-suspend) | **644.8 µAh** |
| `E_active` as a share of `E_cycle(300)` | **80 %** |

Uncertainty, stated honestly:

- **Quantization**: ±500 µAh on each phase's Δq gives ±12.5 µAh/wake on phase A and ±7.9 on
  phase B → `P_sleep = 0.560 ± 0.062 µAh/s` → **0.083 ± 0.009 %/h**.
- **Phase-A relaxation**: using the drop-5 / drop-10 variants instead pushes `P_sleep` *up* to
  0.577 / 0.595 µAh/s → 0.086 / 0.088 %/h. So the plausible band is **0.56 – 0.60 µAh/s ≈
  0.083 – 0.088 %/h**.
- **Phase A is short** — 40 minutes, 40 cycles, 27,000 µAh. That is the weakest leg. But it is 9×
  the Δq and 20× the cycle count of W4's 5-min anchor, and unlike W4 it is not quantization-floored
  (675 µAh/wake is 1.35 quanta per cycle, and the split-halves agree exactly).
- **SOC is *not* a confound here.** Both arms sit at 52–55 %. This is the one comparison in either
  report that is free of the cross-run voltage problem discussed in §7.

### Independent validation of the model

Feeding `P_sleep = 0.560` back into W4's baseline config, which W5 never ran:

```
w34/v6000:  E_cycle(300) = 1618 + 240 × 0.560 = 1752.5 µAh  →  12 × 1752.5 / 24275 = 0.866 %/h
```

The independent prior for that configuration at 5-min cadence is **0.9 %/h**. Agreement to 4 %,
from a term W4 could only bound at 0–0.13 %/h and whose in-run anchor came out negative. This
validates the `E_cycle(T)` model as a whole, not just this one coefficient.

---

## 7. Comparison against the W4 configuration matrix

All rows use the *same* `P_sleep = 0.560 µAh/s`. W4's `µAh/wake @1-min` are its measured values;
its 5-min column is now a much tighter extrapolation than W4 could produce. **The w3/v50 row is
measured at both cadences.**

| config | measured awake | µAh/wake @1-min | %/h @1-min | `E_cycle(300)` µAh | **%/h @5-min** | source |
|---|---|---|---|---|---|---|
| w34 / v6000 (mod baseline) | 34 s | 1618 | 4.00 | 1752 | **0.866** | W4 measured @1-min |
| w8 / v6000 | 13 s | 917 | 2.26 | 1051 | **0.520** | W4 measured @1-min |
| w8 / v2000 (W4's ship pick) | 8 s | 683 | 1.69 | 817 | **0.404** | W4 measured @1-min |
| w3 / v2000 | 8 s | 683 | 1.69 | 817 | **0.404** | W4 measured @1-min |
| **w3 / v50** | **6.0 s** | **675** | **1.668** | **809.5** | **0.400** | **W5 measured @ both** |
| w3 / v0 (WARNs — do not ship) | 3 s | 500 | 1.23 | 634 | **0.314** | W4 measured @1-min, 6 cycles |
| suspend floor, no clock | — | — | — | — | **0.083** | W5 measured (§6) |

Re-running the table at the top of the `P_sleep` band (0.595) moves every figure by < 0.005 %/h.
The extrapolations are no longer the weak link.

### Reading this table honestly — the cross-run SOC confound

Taken at face value the table says **v50 (0.400) ≈ v2000 (0.404)** — indistinguishable. But the
comparison is not apples-to-apples, and the bias runs against v50:

`charge_now` is a coulomb count. W4's µAh/wake were measured at **92–100 % SOC**; W5's at
**52–54 %**. At lower state of charge the terminal voltage is lower, so the *same* energy costs
*more* µAh. W4's numbers are therefore systematically flattered relative to W5's.

**The size of this effect cannot be measured from the available data** — both
`battery-state-now.txt` files were captured while charging (W4: 4.391 V at 100 %; W5: 4.073 V at
53.9 %) and no in-run battery voltage appears anywhere in either journal. From the cell's OCV
curve the factor is plausibly **5–10 %**, but that is a model, not a measurement, so it is kept
out of the table above.

*Sensitivity, clearly labelled as such.* Scaling W4's `E_active` terms by +8 % to a mid-SOC basis
gives w34/v6000 → 0.930, w8/v6000 → 0.556, w8/v2000 → **0.431**, w3/v0 → **0.334**, against W5's
measured 0.400. On that basis v50 beats v2000 by ≈ 0.031 %/h and trails v0 by ≈ 0.066 %/h.

**A charge-free cross-check that does not need the factor at all.** Awake time is measured in
seconds in both runs, so it is immune to the voltage problem. W4's own within-run marginal rate for
rail-down idle-awake seconds is 33.4 µAh/s. Interpolating from its v0 anchor: 500 + 3 × 33.4 =
**600 µAh/wake at 1-min**, or 610 by linear interpolation between v0 (3 s, 500) and v2000 (8 s,
683). W5 measured 675 at mid-SOC; divided by 1.08 that is **625**. Predicted 600–610, observed 625
— agreement within 2–4 %, which is roughly the quantization floor of W4's 6-cycle v0 probe.

**Conclusion, stable under either treatment.** vpdd 50 lands where its 6 s awake time says it
should: about **40 % of the way from v2000 to v0** (2 of the 5 available seconds). It is *at least*
as good as v2000 and probably ~0.03 %/h better; it does **not** reproduce v0's drain. W4 §12's
hope that v50 would "capture nearly all of the 183 µAh/wake" is **not borne out** — it captures
roughly two fifths. But it captures that fraction with zero kernel warnings, which is the whole
point, and the ship decision does not turn on the correction.

### Why vpdd 50 is the end of the road for this knob

The hardware delay table `vpdd_len[256]` begins `0, 50, 110, 160, …` (W4 §12, from
`g2194-regulator.c`), so **50 ms is the smallest nonzero hold the hardware can be asked for**.
Awake time is monotone nondecreasing in hold length. Therefore **no nonzero vpdd value can beat
50**, and the only setting that can is 0 — which W4 established trips a kernel `WARN` on every
panel-off. **w3/v50 is the optimum over the entire WARN-free vpdd domain.** This argument needs
only monotonicity and the table's first entry; it does not depend on the unexplained v2000 8 s
(§3).

---

## 8. Cadence is now the dominant remaining lever

Resolving `P_sleep` makes a calculation possible that neither prior run could do, and it reframes
the whole optimisation. `E_active = 644.8 µAh` is **80 %** of `E_cycle(300) = 809.5 µAh`. The
per-wake fixed cost — resume, repaint, panel-off, re-suspend — dominates; the sleep term is only
20 %. *This is precisely why vpdd and window tuning has hit diminishing returns:* those knobs shave
seconds off an awake window that is already down to 6 s, while the fixed cost of waking at all is
untouched.

The knob that attacks `E_active` is **how often you wake**:

| cadence | wakes/h | `E_cycle(T)` µAh | **%/h** | runtime full→empty |
|---|---|---|---|---|
| 1 min | 60 | 675.0 | 1.668 | 2.5 days |
| **5 min (current production)** | 12 | 809.5 | **0.400** | **10.4 days** |
| **15 min** | 4 | 1145 | **0.189** | **22.0 days** |
| (suspend floor, no clock) | 0 | — | 0.083 | 50 days |

`E_cycle(900) = 644.8 + 0.560 × 894 = 1145 µAh`; at the top of the `P_sleep` band it is 1175 µAh
→ 0.194 %/h. Either way, **≈ 0.19 %/h**.

Moving 5-min → 15-min saves **0.21 %/h** — more than the entire vpdd journey from stock 30000 down
to 50, and more than double what the v50→v0 step would buy. It also lands within 0.11 %/h of the
hard suspended floor, i.e. it captures ~66 % of the clock's remaining above-floor cost. Since
`v0.33.0` already ships a 1/5/15 menu (see repo history), this costs nothing to offer — it is a
user-facing default question, not an engineering one.

---

## 9. Clamp log — 127 armings, all clamped

| | |
|---|---|
| Total armings | **127**, 12:09:11 → 18:55:32 |
| Action | **`CLAMP 34s -> 3s` in all 127.** Zero `PASS`. Zero values outside the valid 3..33 range. |
| pid | **91275 in all 127** — the single xochitl instance started at the 12:02:45 rig install |
| Armings inside the clean window (12:20:07–18:15:08) | **104 — exactly matching the 104 clean cycles** |
| Inter-arming gaps | 60 s × 38, 300 s × 64, plus the exceptions below |

Every non-{60,300} gap is accounted for:

| gap span | s | explanation |
|---|---|---|
| 12:09:11 → 12:20:07 (5 gaps) | 58–254 | rig start-up, charger on/off, two user unlocks |
| 12:20:07 → 12:21:08 | 61 | 1-second rounding |
| 12:59:08 → 13:00:09 | 61 | last phase-A arming |
| 13:00:09 → 13:05:08 | 299 | cadence change to 5-min, first phase-B interval |
| 18:15:08 → 18:40:08 (12 gaps, 0–397 s) | | the excluded user session (§1B) |
| 18:50:08 → 18:55:32 | 324 | the 18:54:33 charger wake, after which the timer was disabled |

The first arming is at 12:09:11 and not 12:03 because the device did not suspend at all between the
rig install and 12:08:26 (`suspend_ok` frozen at 693 across those six rows) — there was nothing to
arm. `window.conf` is re-read per arming, so the constant window 3 needed no transitions.

**W4's "window 3 is pure risk surface" objection is now answered with evidence.** 104 consecutive
battery cycles at window 3: awake 6.0 s in 99 of them, one 10 s outlier with a documented cause,
zero missed repaints, zero suspend failures, zero armings left unclamped. The concern that a slow
repaint would break a 3 s window has 104 counter-examples — and see §13 for why window 3 is now
not merely safe but *required*.

---

## 10. The post-run `suspend_fail` 2→3 — attributed, and not the rig's

The CSV holds `suspend_fail = 2` in all 129 rows; `battery-state-now.txt` reports `fail = 3` and
`success = 818` at 19:09. The CSV's last row (18:50:08) reads `suspend_ok = 814`. Five suspend
attempts follow it — 18:50:14, 18:58:05, 19:04:50, 19:07:14, 19:07:16 — and 814 + 4 = 818 with
2 + 1 = 3. **Exactly one of those five failed.** It is the last:

```
19:07:16 kernel: PM: suspend entry (deep)
19:07:16 kernel: Freezing user space processes completed (elapsed 0.002 seconds)
19:07:16 kernel: rm_sleep_monitor sleep-monitor: Enter autosleep, battery 52.757%
19:07:16 kernel: PM: Triggering wakeup from IRQ 40 (elants_spi)
19:07:16 kernel: Disabling non-boot CPUs ...
19:07:16 kernel: Wakeup pending. Abort CPU freeze
19:07:16 kernel: Non-boot CPUs are not disabled
19:07:16 kernel: PM: suspend exit
19:07:16 kernel: PM: active wakeup source: spi0.0
```

`elants_spi` / `spi0.0` is the Elan touch controller. A touch event arrived while the freeze was in
flight and the kernel aborted at the CPU-offline step. It is the **only** `Wakeup pending` in the
entire journal. The two immediately preceding cycles (19:07:13, 19:07:15) woke from the same IRQ 40
and did complete — three touch wakes in four seconds, the third lost the race. Six seconds later
(19:07:47) the host cable went in.

Four independent discriminators put this outside the run:

1. **Wrong code path.** The sleep-monitor line reads `Enter autosleep`, the stock kernel autosleep
   path. All 116 in-window suspends read `Enter suspend` (the mod's `suspend-then-hibernate`
   route). The journal contains 123 `Enter suspend` and 7 `Enter autosleep`; **zero** of the
   autosleep entries fall inside a clean window.
2. **The mod was already off.** `pinsleep-clock.timer` was disabled at 18:54:56 and deactivated
   18:54:57 — 12 minutes earlier.
3. **vpdd was already 30000**, restored by the 18:54:33 charger-wake transient.
4. **Timing.** 17 minutes after the last rig cycle (18:50:08), with the user handling the device.

**Not attributable to vpdd 50, to window 3, or to the rig.** It is the same class of benign
user-input-races-a-freeze event as W4's pre-existing `fail = 1` (a power-key press at 11:18:57) and
this run's inherited `fail = 2` (the 05:24 mwlan race).

---

## 11. Stability and wifi — clean

Over the on-battery span 12:17:40 – 18:54:33:

| check | result |
|---|---|
| xochitl restarts | **1**, at 12:02:45 — the deliberate rig install (pid 33191 → **91275**). Zero after. pid 91275 issued all 127 clamp armings and was still alive at 19:09. |
| coredumps / segfaults / SIGSEGV | **0** |
| OOM kills | **0** — the only `OOM killer` lines are the routine disabled/enabled pair per cycle |
| watchdog / hung task / RCU stalls / soft lockup | **0** |
| systemd `Failed to start` / `Failed with result` | **0** |
| thermal / throttle / brownout / undervoltage | **0** |
| i2c / regulator / probe errors | **0** |
| memfault crash uploads | **0** |
| wake reasons, whole journal | 123 × `0x00` (RTC), 5 × `0x04` (powerbutton), 2 × `0x20` (charger_connected). xochitl: 119 RTC, 5 Powerkey, 2 Charger, 4 Ignored. **All 104 clean-window cycles are `0x00` / RTC.** |
| suspend type | **129 / 129 `PM: suspend entry (deep)`** |
| **wifi activity, 12:19:39 – 18:18:36** | **0 hits** on `brcmfmac\|wlan0\|wpa_supplicant\|cfg80211\|link becomes ready\|iw61x\|bssid`. The clean window is fully wifi-skipped — a stronger result than W4, whose P1 was contaminated. |
| wifi-skip hook | 116 × `RTC wake on battery, skipping Wifi/BT restore` + 116 × `Wifi/BT already down (RTC wake), nothing to stop` — one pair per in-window suspend. Reloads at 12:19:38 (teardown) and 18:18:37 (Powerkey full wake) are the expected boundary events. |

Recurring benign noise, identical in every cycle and identical to W4: `aw99703-bl 1-0036: UVLO flag
set (0x4000)` once per resume (**116 in-window occurrences**, the backlight regulator's
undervoltage-lockout latch clearing on read — present in all of W4's 171 cycles too, so not a W5
artifact), `rm.sys.timer … timed out` debug chatter, `[xovi-message-broker]: Failed to open pipe`
(the mod's own IPC, harmless), and QML property warnings from the sleep-screen overlay.

Device left in a safe state: vpdd 30000 (written by the 18:54:33 charger-wake restore), clock timer
disabled, wifi up.

---

## 12. Anomalies and caveats, collected

1. **Run ended ~10 min early and the scheduled `end` phase never ran.** No self-restore rows, no
   `/run/w5-concluded`. Costs nothing: the phase-B window was already 5¼ hours and the `end` phase
   would only have re-measured a known configuration.
2. **Two unplugs, not one.** The charger came off at 12:06:22, went back on at 12:11:43, and came
   off for good at **12:17:40**. Detected from `usb1` carrier + `fusb303b` current-negotiation
   lines, confirmed by the `charge_now` peak at 12:18:06.
3. **18 rows at the head and 7 at the tail excluded** (§1). The tail is not merely noisy — it ran
   **vpdd 30000**, not 50, because six restore transients fired during the user's session. Using it
   would report 2.719 %/h.
4. **Cross-run µAh comparisons with W4 carry an unmeasurable 5–10 % SOC/voltage bias** in W4's
   favour (§7). Not correctable from the available data; both `battery-state-now.txt` snapshots
   were taken while charging. Mitigated by the awake-time cross-check, which is charge-free.
   Note the direction of the framing: because `%` is charge-based, a mid-SOC measurement is closer
   to the whole-discharge-curve average — **0.400 %/h is the more representative figure, and W4's
   high-SOC numbers were the optimistic ones**, not the reverse.
5. **`P_sleep` rests on a 40-minute, 40-cycle phase A.** The weakest leg of §6. Robustness band
   0.56–0.60 µAh/s; a longer 1-min arm would tighten it. It is nevertheless 9× the Δq of W4's
   anchor and not quantization-floored.
6. **The awake decomposition does not explain W4's 8 s at vpdd 2000** (§3). Open item inherited
   from W4, alongside W4's own unresolved 18:01:08 off-by-one in the vpdd-0 chain. Nothing here
   depends on either.
7. **`vpdd 50` was never independently read back from sysfs.** It is inferred from `vpdd.conf` (the
   CSV's `vpdd` column), the sleep hook's documented write-at-suspend-entry behaviour, and — the
   strong evidence — the 6.0 s awake time, which is neither v0's 3 s nor v2000's 8 s and is stable
   across all 104 cycles. A future rig should log the sysfs read-back per cycle.
8. **`CHARGE_FULL` at pull is 2,425,000** (24,250 µAh/%), not the brief's 2,427,500. This report
   uses 24,275 for W4 continuity and `capacity_hires` agreement (implied ≈ 24,277). 0.1 %
   discrepancy, below every other error term.
9. **Single run, single device, ~4 % of SOC traversed** (55.3 → 50.5 %), no repeat, no randomised
   ordering. The A/B split-half identities and the flat hourly profile argue against time-ordered
   artifacts, but cadence and phase order remain nominally confounded (phase A always precedes
   phase B).
10. **w8/v50 was not tested.** §13's prediction against it is reasoning from the §3 decomposition,
    not measurement.

---

## 13. Recommendation

**Ship window 3 + vpdd 50.**

The certification goal is met without qualification. **104 consecutive vpdd-50 panel-offs on
battery produced zero kernel warnings** — no `WARNING`, no `cut here`, no `Call trace`, no `vcom`,
no `Tainted`, and zero `Can't suspend, vpdd timer running` aborts — across a 7 h 14 min journal
grepped end to end, against W4's 5 WARNs in 5 vpdd-0 panel-offs. W4 §12 predicted this from the
`if (data->vpdd_timer_val_ms)` branch condition in `g2194_vcom_disable`; W5 confirms it empirically.
The suspend path is equally clean: 104/104 suspends succeeded, `suspend_fail` held at 2 through
every row, and the one later increment is a stock-autosleep touch race 17 minutes after the rig
stopped (§10).

The performance number is **0.400 %/h at the 5-minute production cadence — measured, not
extrapolated**, over 5 h 15 min and 63 cycles, with endpoint-delta, `capacity_hires` and OLS
agreeing to three decimals and split-halves agreeing to 0.003 %/h. That is ~10.4 days of standby
against ~4.8 days at the w34/v6000 baseline the mod shipped before W4.

**vpdd 50 is the optimum over the entire WARN-free domain of this knob, and the knob is now
exhausted.** `vpdd_len[]` starts `0, 50, 110, 160, …`, so 50 is the smallest nonzero hold the
hardware accepts; awake time is monotone in hold length; therefore nothing nonzero can beat it, and
only vpdd 0 can — at the price W4 documented. Be clear-eyed about the size of the prize forgone:
v50's 6 s awake time puts it about **two fifths** of the way from v2000 to v0, not "nearly all" as
W4 §12 hoped. The remaining v0 gap is ≈ 0.07 %/h, and it still costs a per-cycle kernel WARN plus
the back-to-back VDD/XON drop the vendor's own shutdown handler waits 150–200 ms to avoid. Not
worth it. There is no further vpdd experiment worth running.

**Do not ship w8/v50 — and this reverses W4 §11.** W4 concluded "do not take window below 8…
window 3 is pure risk surface for zero gain," correct *at vpdd 2000*, where the 2 s rail hold set
an 8 s floor that made the window inert. **At vpdd 50 that floor is gone and the window becomes the
binding term.** The §3 journal decomposition is explicit: awake = 3 s clamped repaint window +
3.05 s suspend-delay grace = 6.05 s, with both terms individually visible in every one of the 104
cycles. Raising the window to 8 lengthens the first term by 5 s, so **w8/v50 should measure ~11 s
awake — worse than w8/v2000's 8 s, and ~200 µAh/wake ≈ 0.10 %/h worse than w3/v50.** Untested, so
treated as a prediction; but the direction is not in doubt, and the safety argument that motivated
w8 no longer applies: window 3 now has 104 consecutive clean cycles behind it, 99 of them at
exactly 6.0 s, with the single 10 s outlier explained by an unrelated xochitl wake source and zero
missed repaints (§9).

**The next real gain is cadence, not vpdd.** With `P_sleep` resolved at 0.560 µAh/s, `E_active` is
644.8 µAh — **80 % of the entire 5-minute cycle**. The per-wake fixed cost dominates, which is
exactly why the rail-hold knobs have run out of room. Moving 5 min → 15 min yields **≈ 0.19 %/h
(≈ 22 days standby)**, a **0.21 %/h** saving: more than the whole vpdd journey from stock 30000
down to 50, more than twice what vpdd 0 could add, and within 0.11 %/h of the hard 0.083 %/h
suspended floor. `v0.33.0` already ships the 1/5/15 menu, so this is a default-value decision
rather than engineering work — recommend making 15 min the default, or at minimum surfacing the
battery cost of 1-minute (1.67 %/h, 2.5 days) in the UI.

Two secondary points carried forward from W4 and unchanged by W5: `vpdd_length` is written
per-suspend by the sleep hook and xochitl re-asserts 30000 at every startup and on every non-RTC
wake (observed 11 times in this journal), so interactive and pen latency are untouched by this
change; and the mod's restore path leaves the device at stock 30000, verified in the pull-time
state. Finally, a rig improvement for any future run: log a sysfs read-back of `vpdd_length` per
cycle. W5 infers the applied value from `vpdd.conf` plus a distinctive 6.0 s awake signature —
convincing, but a direct read would make it unfalsifiable (caveat 7).
