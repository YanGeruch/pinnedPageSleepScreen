# Tracing the 34 s window: what actually holds the device awake (2026-08-10)

Question: the 34 s re-suspend window is the per-wake cost driver. Where does
the constant live, what depends on it, which timers are armed alongside —
and what would race if we shortened it?

Evidence is from the on-device binary (`device/xochitl`, gitignored), live
`/proc` + `/sys` state, and the device journal. Nothing is inferred from
community docs.

> **Correction note.** A first pass of this document concluded the window
> was a *timed userspace wakelock* expiring under `autosleep`. The journal
> disproves it (§2). The wakelock is real but it is not the window. The
> corrected mechanism changes which lever works.

## 1. The constant

`34000` appears **exactly once as an instruction operand** in the 22 MB
binary:

```
0x563948:  mov  x2, #0x84d0        // = 34000
```

Scanned for and NOT found: `MOVZ #0x8,lsl#12 + ADD #0x4d0` two-instruction
materialization; µs (`34000000`) or ns (`34000000000`) scaled copies in any
width; aligned `u32`/`u64` copies in `.rodata`/`.data` (the seven byte-level
matches there are all at unaligned addresses = coincidental overlaps inside
other data). So there is **a single source of truth** for the value.

Its enclosing function is battery-manager construction (it registers
`csl::power::Manager::onBatteryPercentageChanged` a few instructions
earlier). The value is placed in a stack descriptor together with a heap
object and a flag, then handed to a registration helper:

```
563944: mov  w3, #1               ; -> [sp+0x348]  flag
563948: mov  x2, #0x84d0          ; -> [sp+0x350]  34000
563964: str  x21, [sp, #0x338]    ; the new'd object (0x108 bytes)
563974: bl   0x48c140             ; (refcount/shared-ptr thunk)
563978: mov  x1, #2               ; -> [sp+0x360]  kind = 2
```

## 2. The window is an explicit suspend REQUEST, not a wakelock lapse

Decisive journal evidence from a real 5-minute cycle:

```
01:35:04 xochitl: Re-entering DeepSleep in 34000ms
                  (handleUpkeepWakeup batterymanager.cpp:583)
01:35:38 kernel:  PM: suspend entry (deep)                    <- exactly +34 s
01:35:38 systemd-sleep[174806]: Performing sleep operation 'suspend'...
01:40:04 systemd-sleep[174806]: System returned from sleep operation
                                'suspend-then-hibernate'.
01:40:04 systemd-sleep[174806]: woken_by_timer=0, remain: 14134640953767ns
01:40:04 xochitl: Re-entering DeepSleep in 34000ms            <- next cycle
01:40:38 systemd-sleep[174904]: Performing sleep operation 'suspend'...
```

`systemd-sleep` performs the suspend, so **logind/systemd is the actor** and
xochitl is the requester. Kernel `autosleep` would never run `systemd-sleep`
— and our own `systemd-sleep` hooks fire on every cycle, which independently
proves the systemd path. Corollaries:

- `34000` is the **delay before requesting suspend**, armed as a timer at
  each wake and printed in the log line.
- The distinct `systemd-sleep` PID per cycle re-confirms the
  hibernation-defeat finding (each cycle = a brand-new
  suspend-then-hibernate whose 4 h deadline never arrives; `remain:` ≈ 3.93 h
  every time).
- `woken_by_timer=0` = the hibernate deadline is not what woke it; our RTC
  timer did.

### What the wakelock actually is

xochitl imports the Android-style wakelock ABI from `csl::power::Manager`
(all PLT-imported dynamic symbols):

```
grabWakeLock(std::string, unsigned long)   releaseWakeLock(std::string)
aboutToSlumber(std::function<void()>)      getInhibitorState() const
onWakeUp(std::function<void(wakeup::WakeUpReason)>)
```

The in-binary helper shows the policy — **2000 ms default**, caller may
override:

```
9156b8: ldr  x2, [sp, #0x40]     ; caller-supplied timeout
9156bc: mov  x0, #0x7d0          ; = 2000 default
9156c4: csel x20, x2, x0, ne
9156fc: bl   grabWakeLock@plt
```

Live device (`/sys/power/wake_unlock`, locks held and released this boot):
`xochitl.batterymanager`, `xochitl.library`,
`xochitl.activemarker.indicator`, `marker-manager-event-dispatcher`,
`sleep.resume`, `wpa_supplicant`; currently held: `udev.charger` (which is
precisely why USB inhibits suspend). `/sys/power/autosleep = mem`.

So the wakelock is a **short death-guard around critical sections**, not the
34 s window. Interposing its timeout would change nothing about window
length — the lever must target the delay timer instead.

## 3. Timer inventory

One `timerfd_create` call site in the whole binary (0xdd1cd0) — a single
shared wrapper; `timerfd_settime` ×2, `timerfd_gettime` ×2. Live fds
(xochitl awake on USB):

| fd | clockid | wakes from suspend? | armed at sample |
|----|---------|---------------------|-----------------|
| 42, 45, 46, 72, 83 | 9 = CLOCK_BOOTTIME_ALARM | **yes** | disarmed |
| 44 | 9 = CLOCK_BOOTTIME_ALARM | **yes** | 3538 s (≈59 min = the 1 h `IdleSuspendDelay` debug setting still set on this device) |
| 32, 47, 86 | 1 = CLOCK_MONOTONIC | no | disarmed |
| 64 | 1 = CLOCK_MONOTONIC | no | **33.04 s** |

**RESOLVED (2026-08-10, probe W3 — log-only `timerfd_settime` interposition,
`probes/w3probe.c`, real button entry).** The 34 s timer is **alarm-class**:
at sleep entry the hook logged `fd=39 clockid=9 (CLOCK_BOOTTIME_ALARM)
value=34.000s flags=0 (relative)`, alongside disarms of two sibling ALARM
fds. It fired at exactly +34 s and — suspend being inhibited by USB —
re-armed itself at **60 s intervals** (the retry cadence behind the ~1 min
abort-retry rhythm in the night logs). fd 64 (MONOTONIC) is a separate 60 s
ABSTIME housekeeping timer, not the upkeep countdown. So the Plan B pop-up
was this same timer waking the suspended system — the "orphan second wake"
risk is real for any lever that does not move this arming, and absent for
the interposition lever, which moves window and wake together. Still
unobserved: the re-arm in the real RTC-wake path (`handleUpkeepWakeup`) on
battery — the probe stays installed (tmpfs lifecycle, 4 MB-capped log at
/tmp/w3probe.log); one unplugged cycle completes the picture.

## 4. Race inventory — what assumes ~34 s of runtime

| Consumer | Own wakelock? | Risk if the window shortens |
|---|---|---|
| `wpa_supplicant`, `udev.charger`, `xochitl.library`, `marker-manager-event-dispatcher`, `sleep.resume` | **yes** | Not cut off: an active wakeup source makes the suspend attempt **abort**, not truncate them. But aborts are expensive — we measured the vpdd abort path costing ~55 s extra awake. Shortening raises abort probability; that is the real cost, not data loss. |
| EPD rail hold (`vpdd_length`, g2194) | n/a — kernel refuses suspend while it runs | **The floor setter.** Window floor = repaint end + vpdd hold. The **8 s is the *driver-default* regime, not the minimum**: it follows from vpdd 6000 (the g2194 upstream default we install), and matches the proven Plan B +8 s success. With vpdd at **0–1 s** the theoretical floor is ~**3 s** — roughly 2 s of draw plus ~1 s of margin and settle. This is where the vpdd experiment earns its keep: it is not a standalone saving, it is what sets how short the window can be. |
| Our sleep-bar repaint | no | Fits in 8 s (1 s QML tick + ~450 ms waveform); tight below ~3 s. |
| Our chapter persistence (detached `systemd-run` copying BMPs to eMMC) | **no** (fixed, pending deploy) | The suspend can freeze it mid-write: the atomic `mv` keeps the persisted file from ever being *corrupt*, but the update is silently skipped — the exact failure persistence exists to prevent — and it becomes the common case once the window shrinks. Fixed by grabbing its own timed wakelock + `sync` before publish. **Cap invariant: copy time < cap < shortest window.** Cap is **2 s** — below even the ~3 s vpdd-0 floor, so the upper bound is safe. The lower bound is **not yet measured**: fastshot's ~65 ms is a framebuffer→tmpfs (RAM) write and says nothing about tmpfs→eMMC, and `sync` makes wall time include the flash flush. Each chapter is 6.5 MB (960×1696×4) and the mtime gate usually copies 0–1 of them. **Measure a 4-chapter batch (probe W0) before trusting the 2 s.** A cap *above* the window would let a wedged script abort the suspend, which costs far more than the skipped update that letting go produces. |
| fastshot capture | n/a (synchronous ~70 ms inside the QML call) | None. |
| xochitl sync/indexing | `xochitl.library` | None — holds its own. |
| `LightSleepDelay` / `PowerOffDelay` setters | n/a | None — they only *clamp* against minimumAwakeTime (binary's own log: "…set lower than minimumAwakeTime. It should be checked in those setters?"). Lowering relaxes the clamp. |

## 5. Candidate lever (one probe from confirmed)

Target the **delay timer**, not the wakelock. `timerfd_settime` is a
glibc PLT import and xovi already LD_PRELOADs into xochitl, so it can be
**interposed** rather than binary-patched:

```c
// hook timerfd_settime: if the requested it_value is ~34.000 s, clamp to N
```

Why this shape:
- The 34 s arming is distinctive and there is only one timerfd wrapper
  class, so the match is precise.
- Whatever clock class the upkeep timer uses, **the same arming call is
  changed** — so window and (if alarm-class) wake move together and no
  orphan second wake is created. That is the property the race question
  demands.
- No binary patch: no RO-rootfs remount, no A/B rollback exposure, no
  offset fragility across OS updates, instantly revertible by dropping the
  extension, runtime-tunable from a conf file.

Alternative if interposition proves awkward: patch the single MOVZ
immediate (§1) — genuinely a one-instruction edit, but OTA-fragile and
riskier.

**Savings, honestly bounded.** Per-wake cost is not purely proportional to
window length: the measured 0.14 % → 0.066 % improvement came from removing
aborts and the WiFi reload, not from shortening, and each cycle carries
fixed transition costs (freeze/thaw, EPD repaint, rail power-up). So a
35 s → 8 s window plausibly lands per-wake around 0.03–0.045 %, i.e. a
5-minute clock at roughly **0.5–0.6 %/h instead of ~0.9 %/h** — a real
improvement with the clock still running, but not the 3× that linear
scaling would suggest. Must be measured, not assumed.

This is complementary to the hibernation lever, not a replacement: it cuts
the cost of *each* wake; idle-gating removes wakes entirely when nobody is
watching.

## 6. Probes (reordered — cheapest decisive first)

- **W0 — DONE (2026-08-10).** 4-chapter batch (26 MB, real files, tmpfs →
  eMMC): cp ~61 ms + one sync ~145 ms = **~205 ms total**, stable across
  runs; 1-file typical case ~65 ms; publish renames 13 ms. The 2 s cap
  holds with ~10× margin, valid down to the 3 s floor. Wakelock round-trip
  from a `systemd-run` transient unit verified: grab shows in
  `/sys/power/wake_lock`, explicit release works, a 2 s timed grab
  auto-expires (probe T1).
  **TRAP found while dry-running (T3): systemd substitutes `${...}` in
  transient-unit command lines itself** (invalid name → empty string,
  journal: "Invalid environment variable name evaluates to an empty
  string"). It broke the persist publish `mv` and had silently no-op'd the
  deployed reboot refill (`${f##*/}` → bare dir path, always exists → cp
  never ran). Bare `$var` forms survive. Both scripts rewritten without
  brace expansions, verified, deployed 2026-08-10.
- **W3 — DONE for the entry path (2026-08-10), wake path pending one
  battery cycle.** See §3: 34 s upkeep = ALARM-class fd, relative arming,
  60 s retry chain; lever shape confirmed. `grabWakeLock` hook proved
  unnecessary — T1 answered the wakelock questions from sysfs.
- **W1 — arm-state during a real RTC wake, on battery.** Sample
  `/proc/<pid>/fdinfo/*` + `/sys/power/wake_lock` at ~+2 s after an RTC
  wake, via a one-shot `systemd-run` from the existing "after" hook.
  Confirms W3 from the kernel side.
- **W2 — wakelock timeout in practice.** In the same window, poll
  `/sys/power/wake_lock` and time when `xochitl.batterymanager` disappears
  (expect ~2 s if it is the death-guard, ~34 s if the first reading was
  right after all).
- **W4 — shortened-window night.** Clamp to 8 s, one battery cycle; watch
  g2194 abort lines (must stay zero), missed bar repaints, truncated
  persisted chapters, extra resume cycles per mark, and measured %/h.
- **W5 — floor search.** Repeat at vpdd 3000/0 with 6 s/4 s/3 s windows to
  find where aborts begin. Theoretical target is ~3 s (~2 s draw + ~1 s
  margin/settle); 8 s is only the vpdd-6000 driver-default regime.
  **Before each step, check the persist wakelock cap still sits under the
  window being tested** (2 s today, valid down to a 3 s window — below that
  it must come down too, or a stalled copy turns into a suspend abort).
