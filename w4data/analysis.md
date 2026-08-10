# W4 battery-drain test — analysis

reMarkable Paper Pro Move (`imx93-chiappa`), kernel `6.12.49+git-imx93-chiappa-g68b95e858a0a`.
Run date 2026-08-10, device TZ Europe/Kyiv (EEST, +03:00). All times below are EEST.

Data: `w4test.csv` (191 wake rows), `w4clamp.log` (172 armings), `journal-boot.log`
(19,295 lines, boot 11:00:31 → pull 18:56:29), `battery-state-now.txt`, `rig-state-now.txt`.

## Headline

| | |
|---|---|
| Best measured config | **window 8 + vpdd 2000** — 683 µAh/wake |
| Saving vs mod baseline (w34/v6000, 1618 µAh/wake) | **935 µAh/wake = 0.462 %/h at 5-min cadence** (assumption-free) |
| vpdd 0 verdict | **Do not ship.** Trips `WARN` in `g2194_vcom_disable` on the panel power-down path, every cycle. |
| window 3 verdict | **Buys nothing.** Identical measured awake time (8 s) and identical drain to window 8 at vpdd 2000. |
| Suspend failure (fail=1) | Pre-existed the run — 11:18:57, power-key wake racing a suspend. Not caused by W4. |

---

## 1. Data integrity

| Check | Result |
|---|---|
| Row count | 191 data rows + header. Header present. |
| Epoch monotonic | Yes, strictly increasing. |
| `suspend_fail` | **1 in every row, including the first (15:08:03)** — the failure predates the run. |
| Wake cadence | 60 s ± 1 s for all 171 in-run cycles. |
| Gaps > 70 s | 10, all at ≥ 18:06 — the rig's self-restore to 5-min cadence. None inside P1–P5. |
| Gaps < 50 s | 3, all inside 15:08:03–15:09:01 (rig start-up burst). |
| Phase boundaries | Exactly on schedule: P2 @16:30:07, P3 @17:00:08, P4 @17:30:08, P5 @18:00:07, `end` @18:06:08. |
| `suspend_ok` increments | +1 per row across the whole run **except** the two windows below. |

### Excluded windows

**A. 15:08:03 – 15:18:08 — no suspends, fuel gauge pinned.** `suspend_ok` sits at 18 for
nine consecutive rows and `charge_now` is frozen at exactly 2,429,000 µAh
(`capacity_hires` 99.972). Three independent reasons this window is unusable:

1. The device never slept — first `PM: suspend entry` after the rig start is 15:15:37,
   first RTC-driven cycle 15:18:08.
2. `xochitl` was restarted at 15:08:06 (pid 9337 → 11588) to pick up the `w4clamp.so`
   preload; `w4clamp.log` records no arming until 15:16:33.
3. **WiFi was still associated** (`bssid=08:bf:b8:e5:7a:cc`) until 15:17:37 — the wifi-skip
   hook only tore the link down then. So this window is not even wifi-skipped.

The gauge was holding at ~full after a charge and had not begun tracking; the 3,000 µAh
step at 15:16:06 and 3,500 µAh at 15:17:01 are catch-up, not instantaneous drain.
**P1 is therefore measured from 15:18:08.** Including the excluded window pulls P1 down to a
spurious 3.765 %/h.

**B. ≥ 18:15:08 — charging.** `charge_now` rises monotonically from 18:20:05 (+30,000 µAh)
and `suspend_ok` freezes at 191. The last discharge cycle ended between 18:15:08 and
18:20:05; USB was attached around **18:16**, not ~18:50 — the mod's disable script ran at
18:16:30 (`rm -f /run/pinsleep-wifi-off; modprobe iw61x_sdw61x; echo 30000 > …/vpdd_length`).
All rows from 18:20:05 on are excluded from drain math.

### Fuel-gauge resolution

`charge_now` moves in **500 µAh quanta** (observed step multiset: 500/1000/1500/2000, plus the
two catch-up steps). At 1 % = 24,275 µAh, one quantum = 0.0206 %. Endpoint quantization is the
dominant error term; it is negligible for P1–P4 and *dominant* for P5:

| phase | Δq (µAh) | ±500 µAh as % of Δq |
|---|---|---|
| P1 | 116,500 | 0.4 % |
| P2 | 27,500 | 1.8 % |
| P3 / P4 | 20,500 | 2.4 % |
| P5 | 3,000 | **17 %** |
| `end` (5-min) | 3,000 | **17 %** |

Note: `capacity_hires` is not an independent measurement — it is `charge_now` divided by a
full-charge reference of ≈ 2,429,450 µAh (implied consistently across all rows), 0.08 % away
from the 24,275 µAh/% the brief specifies from `CHARGE_FULL=2427500` at pull time. It
therefore cross-checks arithmetic, not physics. Both are reported below and agree to ±0.04 %/h.

---

## 2. Measured awake time — the key correction

The `window` knob only clamps the **arming** of the 34 s `BOOTTIME_ALARM`. The real awake
duration is `PM: suspend exit` → next `PM: suspend entry`, extracted from the journal for all
192 suspend cycles:

| phase | window | vpdd | **measured awake** | n | distribution |
|---|---|---|---|---|---|
| P1 | 34 | 6000 | **34.0 s** | 72 | {34, 40} |
| P2 | 8 | 6000 | **13.0 s** | 30 | {13, 25} |
| P3 | 8 | 2000 | **8.0 s** | 30 | {8, 9, 13} |
| P4 | 3 | 2000 | **8.0 s** | 30 | **{8} — exactly 8 s, all 30 cycles** |
| P5 | 3 | 0 | **3.0 s** | 6 | {3, 8} |
| `end` | 34 | 6000 | **34.0 s** | 3 | {34, 35} |

**The vpdd rail hold, not the window setting, sets the awake floor.** At vpdd 6000 the floor
is ~13 s; at vpdd 2000 it is ~8 s; only vpdd 0 lets the window value (3 s) actually bind.
Consequences:

- The window 8 → 3 change in P4 was **inert** — awake stayed at exactly 8 s for all 30 cycles.
- The 13 s → 8 s reduction between P2 and P3 came entirely from vpdd, not window.
- The one 40 s / 25 s / 13 s / 9 s outliers are single transition cycles at phase boundaries.

**Cadence-invariance of awake time — validated, not assumed.** The `end` phase ran the P1
config (w34/v6000) at 5-min cadence and measured 34 s and 35 s awake, matching P1's 34 s at
1-min cadence. The repaint workload does not depend on how long the device slept beforehand.
This is the load-bearing assumption of every extrapolation in §4 and it is directly confirmed.

---

## 3. Per-phase drain (measured, 1-min cadence)

Attribution convention: a row is written at wake time and its config governs the interval
that *follows*, so a phase's charge delta is `q(first row of phase) − q(first row of next
phase)`. Cycle count is the `suspend_ok` delta over the same interval.

| phase | w | vpdd | awake | span | s | cycles | Δq µAh | µAh/h | **%/h** | %/h (`capacity_hires`) | %/h (OLS) | **µAh/wake** |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| P1-base | 34 | 6000 | 34 s | 15:18:08–16:30:07 | 4319 | 72 | 116,500 | 97,106 | **4.000** | 3.998 | 4.004 | **1618** |
| P2-w8 | 8 | 6000 | 13 s | 16:30:07–17:00:08 | 1801 | 30 | 27,500 | 54,969 | **2.264** | 2.249 | 2.255 | **917** |
| P3-w8v2 | 8 | 2000 | 8 s | 17:00:08–17:30:08 | 1800 | 30 | 20,500 | 41,000 | **1.689** | 1.710 | 1.693 | **683** |
| P4-w3v2 | 3 | 2000 | 8 s | 17:30:08–18:00:07 | 1799 | 30 | 20,500 | 41,023 | **1.690** | 1.657 | 1.685 | **683** |
| P5-w3v0 | 3 | 0 | 3 s | 18:00:07–18:06:08 | 361 | 6 | 3,000 | 29,917 | **1.232** | 1.207 | 1.234 | **500** |
| `end` (5-min) | 34 | 6000 | 34 s | 18:06:08–18:15:08 | 540 | 2 | 3,000 | 20,000 | 0.824 | 0.993 | 0.820 | 1500 |

Endpoint-delta, `capacity_hires`, and ordinary-least-squares slope agree to within ±0.04 %/h
in every phase.

### Drift controls

`vpdd.conf` is read by the sleep hook, so a vpdd change binds one cycle late (visible in the
awake data: the 17:00:08 cycle still ran 13 s). Trimming the first cycle of the vpdd-changing
phases moves nothing: P3 → 1.705 %/h (690 µAh/wake), P5 → 1.236 %/h (500 µAh/wake).
`window.conf` is re-read per arming, so window changes bind immediately (16:30:07 already
awake 13 s).

Split-half within each phase — no intra-phase trend:

| phase | first half | second half |
|---|---|---|
| P1 | 3.984 %/h (1611 µAh/wake) | 4.016 %/h (1625) |
| P2 | 2.222 (900) | 2.307 (933) |
| P3 | 1.730 (700) | 1.648 (667) |
| P4 | 1.650 (667) | 1.730 (700) |
| P5 | 1.229 (500) | 1.236 (500) |

**P3 ≡ P4 is a free drift control.** The two phases are one hour apart, differ only in a
setting the awake-time data shows had no effect, and returned identical energy
(20,500 µAh / 30 cycles in both, to the µAh). Any monotone measurement artifact over the
17:00–18:00 hour — gauge relaxation, temperature, SOC-dependent efficiency — would have made
P4 differ from P3. None did.

---

## 4. Decomposition and extrapolation

### Model

Per wake cycle at period `T`:

```
E_cycle(T) = E_active(config) + P_sleep · (T − t_awake)
```

`E_active` bundles resume, repaint, EPD rail hold, panel power-down and re-suspend; it is a
property of the config. `t_awake` is the **measured** value from §2, not the nominal window.
Because `t_awake` is cadence-invariant (§2), moving from 60 s to 300 s adds exactly
`P_sleep · 240` per cycle:

```
E_cycle(300) = E_cycle(60) + 240 · P_sleep
%/h at 5-min = 12 · E_cycle(300) / 24275
```

### Marginal awake power, from consecutive-phase differences

| comparison | isolates | Δ awake | Δ µAh/wake | implied `P_active − P_sleep` |
|---|---|---|---|---|
| P1 → P2 | window 34→8 @ vpdd 6000 | −21 s | −701 | 33.4 µAh/s ≈ **120 mA** |
| P2 → P3 | vpdd 6000→2000 @ window 8 | −5 s | −233 | 46.7 µAh/s ≈ **168 mA** |
| P3 → P4 | window 8→3 @ vpdd 2000 | 0 s | 0 | — (no awake change, no saving) |
| P4 → P5 | vpdd 2000→0 @ window 3 | −5 s | −183 | 36.7 µAh/s ≈ **132 mA** |

Physically coherent: the seconds removed by shortening the *window* are plain idle-awake
seconds with the EPD rails already down (≈120 mA). The seconds removed by shortening *vpdd*
are rail-held seconds with the ±6/12/24 V EPD boost still running (≈168 mA) — the most
expensive seconds in the cycle. That is why vpdd is the higher-leverage knob per second
removed, and why window 3 is worthless once vpdd already gates the floor.

### `P_sleep` — bounded, not resolved

Two anchors are available and they disagree in sign:

- **In-run**: the `end` phase ran the P1 config at 5-min cadence, giving 1500 µAh/wake vs
  P1's 1618 at 1-min. Taken literally that yields `P_sleep = (1500−1618)/240 = −0.49 µAh/s`,
  which is unphysical. It is quantization-limited: 3,000 µAh total across 2 cycles with
  ±500 µAh endpoints bounds the 5-min drain only to ≈ **0.55 – 1.10 %/h**.
- **Prior reference**: 0.9 %/h at 5-min for this config implies
  `E_cycle(300) = 1821 µAh` → `P_sleep = 0.844 µAh/s` ≈ 3.0 mA ≈ **0.125 %/h** suspended floor.

The two are consistent (0.90 sits inside 0.55–1.10); the in-run measurement is simply nine
minutes long and cannot resolve a 3 mA term. **All absolutes below are therefore reported as a
range over `P_sleep ∈ [0, 0.844] µAh/s`**, with the upper end reproducing the prior by
construction. Note the upper-bound row for w34/v6000 is an *input*, not a prediction.

### Extrapolation to 5-minute production cadence

| config | measured awake | µAh/wake @1-min | **%/h @1-min (measured)** | **%/h @5-min (range)** |
|---|---|---|---|---|
| w34 / v6000 (mod baseline) | 34 s | 1618 | 4.00 ± 0.02 | **0.80 – 0.90** |
| w8 / v6000 | 13 s | 917 | 2.26 ± 0.04 | **0.45 – 0.55** |
| **w8 / v2000** | 8 s | 683 | 1.69 ± 0.04 | **0.34 – 0.44** |
| w3 / v2000 | 8 s | 683 | 1.69 ± 0.04 | **0.34 – 0.44** |
| w3 / v0 | 3 s | 500 | 1.23 ± 0.21 | **0.25 – 0.35** |
| (suspend floor, no clock) | — | — | — | 0 – 0.13 |

**The saving is exact and independent of `P_sleep`**, because the sleep term cancels in a
difference at fixed cadence:

- w34/v6000 → w8/v2000: **935 µAh/wake → 935 × 12 / 24275 = 0.462 %/h saved at 5-min cadence.**
  Roughly a halving of total drain, and ~80 % of the clock's *marginal* (above-floor) cost.
- w8/v2000 → w3/v0: 183 µAh/wake → 0.090 %/h further. This is the entire prize for vpdd 0.

Assumptions, stated: (i) awake time is cadence-invariant — *verified* in §2; (ii) `E_active` is
independent of cadence, i.e. the repaint does the same work whether it slept 60 s or 300 s;
(iii) `P_sleep` is constant across configs — all configs enter the same `deep` suspend with
identical device state (§9), so this is safe; (iv) battery SOC 99.9 → 91.9 % and 25.4 °C
throughout, so no SOC- or temperature-dependent efficiency correction is applied.

---

## 5. P5 / vpdd 0 verdict — **do not ship**

**vpdd 0 caused zero suspend failures but a kernel WARNING on every cycle.**

Suspends: `suspend_ok` 182 → 188 across P5 — all six cycles suspended successfully.
`suspend_fail` stayed at 1. No `Freezing … aborted`, no `Can't suspend`, no `PM: suspend`
error, no device probe or i2c/regulator error in the window. On the suspend-path metric,
vpdd 0 is clean.

**But** the panel power-down path warns, every cycle:

```
2026-08-10T18:02:08+03:00 kernel: ------------[ cut here ]------------
2026-08-10T18:02:08+03:00 kernel: WARNING: CPU: 1 PID: 11626 at /drivers/regulator/g2194-regulator.c:347 g2194_vcom_disable+0xb4/0xc4
2026-08-10T18:02:08+03:00 kernel: CPU: 1 UID: 0 PID: 11626 Comm: vsync-flip Not tainted 6.12.49+git-imx93-chiappa-g68b95e858a0a #1
2026-08-10T18:02:08+03:00 kernel: Call trace:
2026-08-10T18:02:08+03:00 kernel:  g2194_vcom_disable+0xb4/0xc4
2026-08-10T18:02:08+03:00 kernel:  _regulator_do_disable+0x90/0xac
2026-08-10T18:02:08+03:00 kernel:  _regulator_disable+0x1a8/0x25c
2026-08-10T18:02:08+03:00 kernel:  regulator_bulk_disable+0x7c/0x174
2026-08-10T18:02:08+03:00 kernel:  rm_cumulus_unprepare+0x54/0x6c
2026-08-10T18:02:08+03:00 kernel:  drm_panel_unprepare+0xbc/0x11c
2026-08-10T18:02:08+03:00 kernel:  panel_bridge_atomic_post_disable+0x50/0x60
2026-08-10T18:02:08+03:00 kernel:  drm_atomic_bridge_chain_post_disable+0x5c/0xfc
2026-08-10T18:02:08+03:00 kernel:  disable_outputs+0x114/0x32c
2026-08-10T18:02:08+03:00 kernel:  lcdifv3_drm_atomic_commit_tail_vblank_no_wait+0x24/0x68
2026-08-10T18:02:08+03:00 kernel:  drm_atomic_commit+0xb8/0xf4
2026-08-10T18:02:08+03:00 kernel:  drm_mode_setcrtc+0x384/0x7f4
2026-08-10T18:02:08+03:00 kernel:  drm_ioctl+0x210/0x4bc
```

This is xochitl's `vsync-flip` thread (pid 11626) issuing the `DRM_IOCTL_MODE_SETCRTC` that
blanks the EPD after the clock repaint. `rm_cumulus_unprepare` bulk-disables the panel
regulators; `g2194_vcom_disable` trips a `WARN` at `g2194-regulator.c:347`. It fired at
18:02:08, 18:03:08, 18:04:08, 18:05:08 and 18:06:08 — and the second and later occurrences
report `Tainted: G W`, i.e. the kernel is now flagged as having warned.

### Attribution — vpdd 0 is the cause, not the short window

| evidence | |
|---|---|
| Occurrences in the entire 7.5-hour journal | **5 — all inside the 6-cycle vpdd-0 probe.** Zero before 18:02:08, zero after 18:06:08. |
| **window 3 alone, 30 consecutive cycles (P4, vpdd 2000)** | **Zero WARNs. Awake distribution exactly {8} — all 30 cycles.** |
| First cycle after restore (18:10:07, vpdd back to 6000) | No WARN. |
| Whole prior boot 11:00–18:00 incl. earlier test rounds | No `g2194`, no `vcom`, no `WARNING` of any kind. |

The P4 control kills the "short window caused it" confounder outright: window 3 ran thirty
times with vpdd 2000 and never warned.

Causal chain confirmed by timing. `vpdd_length`
(`/sys/bus/i2c/drivers/g2194-regulator/0-0048/vpdd_length`) is written by the sleep hook
immediately before each suspend, so a `vpdd.conf` change binds one cycle late. The rig set
vpdd 0 at the 18:00:07 wake; the first suspend to carry it began 18:01:11; the first panel-off
to run with `vpdd_length=0` was at 18:02:08 — the first WARN. The rig restored vpdd 6000 at
18:06:08, so the last vpdd-0 panel-off was that same 18:06:08 wake — the last WARN.
**Five vpdd-0 panel-off events, five WARNs.**

### Mechanism — the saving and the WARN are the same event

The 3 s awake time at vpdd 0 is not "a clean short cycle." The rail-discharge path returned
early instead of waiting out the power-down delay — that early return *is* what trips the
`WARN`, and it is *also* what removes the 5 s and the 183 µAh. There is no way to capture the
183 µAh/wake saving without the WARN; they are one and the same event. A VCOM/rail collapse
that skips its specified discharge sequence, repeated every 5 minutes for the life of the
device, is a panel-longevity risk (image retention / VCOM drift) that this 6-minute probe
cannot bound.

### Unexplained anomaly — flagged, not resolved

**The 18:01:08 cycle shows the collapsed 3 s awake time but produced no WARN.** Five WARNs
across six P5 cycles, not six. There is no `cut here` at 18:01:08 in the journal. Under the
one-cycle-lag chain above, the 18:01:08 panel-off should have run with the old `vpdd_length`
(and hence 8 s awake) — instead it ran short *and* silent. The measured awake distribution for
P5 is `{3, 8}`, so one cycle in the phase did run 8 s; the ordering in the 1-second-resolution
journal cannot be pinned down further. This does not change the verdict — 5 WARNs in 5 vpdd-0
panel-offs, 0 in 30 window-3 cycles at vpdd 2000 — but the off-by-one is real in the data and
is not explained here.

### P5 vs P4 drain

500 vs 683 µAh/wake — a 27 % per-wake reduction, 1.23 vs 1.69 %/h at 1-min cadence. But
**every single P5 cycle measured exactly 500 µAh, i.e. exactly one gauge quantum**, so the
per-cycle figure is quantization-floored and the 6-cycle aggregate carries ±17 %:
P5 ∈ 1.02 – 1.44 %/h. Extrapolated, vpdd 0 buys 0.090 %/h at 5-min cadence over vpdd 2000
(range 0.05 – 0.13). That is the entire prize, for a per-cycle kernel WARN. Not worth it.

---

## 6. Clamp log

172 armings, all from pid 11588 (the single xochitl instance started 15:08:06). No value
outside the valid 3..33 range was ever written; no arming was left at 34 s while a phase
wanted it clamped.

| span | n | action | matches schedule |
|---|---|---|---|
| 15:16:33 – 16:29:07 | 73 | `PASS 34s (conf off)` | ✓ P1 = stock 34 s |
| 16:30:07 – 17:29:08 | 60 | `CLAMP 34s -> 8s` | ✓ P2 + P3, both window 8 |
| 17:30:08 – 18:05:08 | 36 | `CLAMP 34s -> 3s` | ✓ P4 + P5, both window 3 |
| 18:06:09 – 18:15:08 | 3 | `PASS 34s (conf off)` | ✓ self-restore |

Counts: 76 PASS, 96 CLAMP (60 × `8s`, 36 × `3s`). Transitions land on the first arming after
each boundary — `window.conf` is re-read per arming as designed, so window changes bind with
no lag (unlike vpdd, §5).

Inter-arming gaps: 60 s throughout, with three explained exceptions — 95 s at 15:16:33→15:18:08
(rig start-up, `pinsleep.persist` wake-lock held), and 238 s / 301 s after 18:06:09 (5-min
cadence restored).

172 armings vs ~174 in-run CSV rows over the same span: the shim only sees armings issued after
it loaded (first at 15:16:33) and the arming for a cycle whose wake is the last logged row has
no successor. No unexplained or missing arming.

---

## 7. The single suspend failure — predates the run

`suspend_fail` is **1 in the very first CSV row (15:08:03)** and never changes. The run
contributed no failures. Located in the journal at **11:18:57**, nearly four hours before W4
started:

```
2026-08-10T11:18:57+03:00 kernel: PM: suspend entry (deep)
2026-08-10T11:18:57+03:00 kernel: Filesystems sync: 0.007 seconds
2026-08-10T11:18:57+03:00 kernel: Freezing user space processes
2026-08-10T11:18:57+03:00 kernel: Freezing user space processes aborted after 0.000 seconds (51 tasks refusing to freeze, wq_busy=0):
2026-08-10T11:18:57+03:00 kernel: OOM killer enabled.
2026-08-10T11:18:57+03:00 kernel: Restarting tasks ... done.
2026-08-10T11:18:57+03:00 kernel: PM: suspend exit
2026-08-10T11:18:57+03:00 xochitl[1806]: rm.batterymanager  Woke up with reason=Powerkey and battery level=99
2026-08-10T11:18:57+03:00 xochitl[1806]: rm.batterymanager  Woke-up with display sleeping false
```

Root cause: a **power-key press raced the suspend request**. The freeze started, a `Powerkey`
wake event arrived in the same second, and the freezer bailed out with 51 tasks refusing to
freeze — the normal, benign outcome of a user wake landing inside the freeze window. Not a
driver fault. Note the immediately preceding lines: USB carrier lost at 11:18:22 and
`fusb303b: Adjusting USB current to 100mA` at 11:18:23, i.e. the cable had just been pulled and
the power key pressed. The very next suspend (11:20:08) completed normally.

Only one `Freezing … aborted` in the whole journal, and **zero** inside 15:08–18:16.

---

## 8. Wifi-skip — confirmed silent

Between **15:17:37 and 18:16:30** there is no wifi driver load, no association, no
`wpa_supplicant` activity, no `link becomes ready`, no `wlan0` state change. Grep over
`brcmfmac|wlan0|wpa_supplicant|cfg80211|link becomes ready|prepare_wifi|iw61x` returns exactly
10 hits in the run window, and none of them is wifi activity:

- 5 at **15:17:37** — the teardown itself: `wlan0: CTRL-EVENT-DISCONNECTED bssid=08:bf:b8:e5:7a:cc reason=3 locally_generated=1`, then `Link DOWN`, `Lost carrier`, `DHCP lease lost`, `DHCPv6 lease lost`.
- 5 at **18:02:08–18:06:08** — the string `cfg80211` appearing inside the `Modules linked in:` line of the g2194 backtraces (§5), not an event.

Positive confirmation the driver was actually gone: every backtrace's module list ends
`[last unloaded: iw61x_sdw61x]`, and `iw61x_sdw61x` is absent from the loaded list while
`cfg80211` / `iw61x_mlan` remain. It was re-`modprobe`d only at 18:16:30 by the disable script.

**Caveat on the brief.** The brief states wifi-skip was active in *all* phases including P1.
The journal shows wlan0 was **associated to an AP from boot until 15:17:37** — roughly the
first ten minutes of the CSV. Since P1 is measured from 15:18:08 (§1), this does not
contaminate any reported number, but it is an additional reason the 15:08–15:18 window is
unusable and P1 as reported is genuinely wifi-skipped.

---

## 9. Stability — clean

Over 15:08 – 18:16:

| check | result |
|---|---|
| xochitl restarts | 1, at **15:08:06** — the deliberate rig start (preload injection). Zero after. Same pid 11588 held the whole run and still owned the `vsync-flip` thread at 18:06. |
| coredumps / segfaults / SIGSEGV | **0** |
| OOM kills (`Out of memory`, `oom-kill`, `Killed process`) | **0** — the only `OOM killer` lines are the routine `disabled`/`enabled` pair each suspend cycle. |
| watchdog / hung task / RCU stalls | **0** |
| systemd `Failed to start` / `Failed with result` | **0** |
| memfault crash uploads / coredumps | **0** (only `WARN Error in Memfaultd main loop: Network error` — expected, wifi is down) |
| thermal / throttle / brownout | **0**; `POWER_SUPPLY_TEMP=254` → 25.4 °C at pull |
| wake reasons, 15:18–18:16 | **171 / 171 `reason=RTC`**. Zero `Powerkey`. `SPLD wakeup-reason (0x00)` on all 171. |
| suspend type | **171 / 171 `PM: suspend entry (deep)`**, all via `suspend-then-hibernate`, all `sleep-monitor: Enter suspend` |
| journal timezone | All 19,295 lines `+03:00`. Verified against the CSV: the rig's conclusion at 18:06 appears as `Reloading requested from client PID 30092 (unit pinsleep-clock.service)` at `18:06:08+03:00`, matching CSV row `1786374368,18:06:08`. **Journal and CSV clocks agree exactly.** |

Recurring benign noise, present identically in every phase: `aw99703-bl 1-0036: UVLO flag set
(0x4000)` once per resume (backlight regulator undervoltage-lockout latch, cleared on read —
appears in all 171 cycles including P1, so it is not a W4 artifact), `rm.sys.timer … timed out`
debug chatter, and QML property warnings from the mod's own sleep-screen overlay.

---

## 10. Anomalies and caveats, collected

1. **15:08:03–15:18:08 unusable** (no suspends, gauge pinned at full, wifi still associated,
   xochitl restarting). Excluded. Using it would report P1 as 3.765 %/h instead of 4.000 %/h.
2. **USB attached ~18:16, not ~18:50.** The disable script ran 18:16:30 and `charge_now` rises
   from 18:20:05. Eight rows excluded.
3. **P5 is quantization-floored.** All six cycles read exactly 500 µAh = one gauge quantum.
   ±17 % on the aggregate. The vpdd-0 drain figure is indicative only.
4. **The `end`-phase 5-min anchor cannot resolve `P_sleep`** — 2 cycles, 3,000 µAh, and it
   yields an unphysical negative value taken literally. Absolutes in §4 are ranges as a result.
   Only the *differences* are exact.
5. **18:01:08: 3 s awake but no WARN** — unexplained off-by-one in the vpdd-0 causal chain (§5).
6. **`window` does not mean awake time.** Nominal 3 s produced 8 s of real awake time for 30
   consecutive cycles. Any future test must report measured awake, not the config value.
7. **vpdd changes bind one cycle late** (sleep-hook-applied); window changes bind immediately
   (re-read per arming). Trimmed variants confirm the effect is < 1 % on 30-cycle phases.
8. **"Stock vpdd" is 30000, not 6000.** xochitl writes `pmic: setting PDD duration to 30000ms`
   at every startup (observed at 11:00:37, 11:00:50, 11:04:02, 11:05:15, 12:02:58, 14:16:48,
   15:08:08) and the mod's own uninstall script restores `30000`. The 6000 used in P1/P2 is
   already the mod's optimised baseline, not the factory value. This means the sleep-screen mod
   was *already* saving power before W4 began — P1 is not a stock baseline in this respect
   either.
9. **P1 is not a stock baseline** for a second reason: wifi-skip was active throughout it.
10. **Single-run, single-device, ~8 % of SOC traversed (99.9 → 91.9 %).** No repeat, no
    randomised phase ordering. The P3 ≡ P4 identity argues strongly against time-ordered
    artifacts, but phase order and config are still nominally confounded.

---

## 11. Recommendation

**Ship window 8 + vpdd 2000.** It is the best-supported point in the matrix: 683 µAh per wake
against the mod's current 1618 at w34/v6000, a saving of 935 µAh/wake, which at the 5-minute
production cadence is **0.462 %/h — an exact figure, independent of the unresolved sleep-power
term** — taking total drain from 0.80–0.90 %/h to **0.34–0.44 %/h**, roughly a halving, and
capturing about 80 % of the clock's entire above-floor cost (the suspended floor itself is
0.13 %/h at most). The recommendation holds at either end of the `P_sleep` range, which is what
makes it safe to ship without resolving that term first. Do **not** take window below 8: the
measured awake time was exactly 8 s for all 30 cycles at both window 8 and window 3, because
the EPD rail hold and not the window sets the floor — window 3 is pure risk surface for zero
gain, and it is also the setting most likely to break on a slower repaint. Do **not** ship
vpdd 0: it buys only a further 0.09 %/h and pays for it with a `WARN` in `g2194_vcom_disable`
on the panel power-down path on every single cycle (5 WARNs in 5 vpdd-0 panel-offs, 0 in 30
window-3 cycles at vpdd 2000, 0 elsewhere in 7.5 hours of journal) — and because the early
return from the rail-discharge path *is* the mechanism of the saving, there is no way to keep
the µAh and drop the WARN. Two points in favour of vpdd 2000 specifically: `vpdd_length` is
written per-suspend by the sleep hook and xochitl re-asserts 30000 on every restart, so
interactive and pen use are untouched by this change; and 2000 ms is the shortest hold observed
to complete the discharge sequence cleanly across 60 consecutive cycles (P3 + P4). If a further
increment is wanted later, **vpdd 1000 is the only untested point that could yield anything** —
the question is whether awake drops below 8 s without tripping the WARN — and it deserves a
proper multi-hour run at production cadence rather than a 6-minute probe.

---

## 12. Source review (post-hoc correction) — g2194-regulator.c read against §5

The kernel source (`research/linux-imx-rm/src/linux-imx-rel-5.7-wd-3.27.2.1-f21cbcc9ed9a/
drivers/regulator/g2194-regulator.c`) was read after this report. It **overturns the §5
mechanism story and part of the verdict**, and corrects caveat 8.

**What line 347 actually is.** `WARN_ON(!data->wakesrc->active)` immediately before
`__pm_relax()` in `g2194_vcom_disable`'s vpdd==0 branch — a **wakeup-source accounting
assertion** (the suspend-blocker taken at `g2194_vcom_enable` should still be held when the
inline release runs), not a rail-discharge or sequencing trap. `__pm_relax` on an inactive
source is a no-op, and the branch's GPIO writes are idempotent. The observable harm is kernel
taint + per-cycle log spam, plus the fact that the accounting imbalance itself is unexplained
(a relax reached this point with the source already released). The exact interleave producing
the double-relax could not be derived from source — the panel driver (`panel-rm-cumulus.c`)
guards against double-unprepare with a `prepared` flag, and only VCOM carries
enable/disable ops — it remains an open vendor bug in a path production never exercises.

**"The saving and the WARN are inseparable" is FALSE.** The branch condition is
`if (data->vpdd_timer_val_ms)` — *any* nonzero hold uses the timer path, whose deferred relax
never trips the assertion. The hardware delay table (`vpdd_len[256]`) starts `0, 50, 110,
160…` — **vpdd 50 is a first-class table entry** that keeps the timer path (no WARN possible
by construction), keeps hardware PDD mode enabled, and gives up only 50 ms of rail hold vs
vpdd 0. It should capture nearly all of the 183 µAh/wake while structurally unable to warn.
**vpdd 50 replaces vpdd 1000 as the W5 candidate.**

**"Skipped discharge / panel longevity" was overstated.** vpdd (PDD, "power-down delay") is a
keep-alive: how long VPDD is held after EN drops, existing to absorb rail re-enables between
close-together draws (the enable path reuses held rails: `del_timer_sync` + "keep wakesrc
active", skipping the 30.8 ms `off_on_delay` + soft-start + up-to-200 ms pgood wait). It is
not a discharge step; power-on ramp sequencing lives in the PWRON_DELAY registers and VCOM
active-discharge is register-configured independently. Moreover **rail cycle count is
identical across all tested configs** — one full up/down per wake regardless of vpdd (2 s ≪
60 s gap) — so vpdd choice changes hold duration, not wear cycles. The one residual hardware
caveat: the vpdd==0 branch drops VDD then XON back-to-back, the reverse order and zero delay
vs the timer path (XON at +50 ms, VDD at +vpdd), and the vendor's own shutdown handler waits
150–200 ms "for VPDD to discharge to 0V" after aborting a PDD — so instant-drop behavior at 0
is not obviously equivalent to the delayed path. vpdd 50 sidesteps this too.

**The awake floor is now explained from source.** The vpdd≠0 disable holds the wakeup source
(blocking opportunistic sleep) until the vpdd timer fires, and `g2194_safe_to_suspend`
returns -EAGAIN while the timer is pending. Floor ≈ repaint + vpdd hold + suspend-retry
latency: 13 s at v6000, 8 s at v2000, window-bound 3 s at v0 — all consistent.

**Caveat 8 corrected.** The *driver* default (DT `gmt,enable-pdd` path) is **6000 ms**;
the 30000 is **xochitl's userspace choice**, written through the `vpdd_length` sysfs at every
startup (30000 is also `vpdd_len[255]`, the table maximum). "Stock" therefore properly means
"what xochitl runs" = 30000, while 6000 is the vendor driver's own default — the mod's 6000
was never a novel optimization, it matches the driver default. The plausible reason xochitl
runs 30000: pen-stroke latency (keep-alive across strokes avoids the full power-on sequence
per stroke) — irrelevant between minutes-apart clock repaints, which further supports a small
sleep-time hold.

**Revised bottom line.** Ship w8 + v2000 stands as the safe immediate choice. But the further
0.09 %/h is *not* forfeit: W5 should probe **vpdd 50** (multi-hour, production cadence,
journal watch on `g2194`) — expected to match vpdd-0 drain with zero WARNs.
