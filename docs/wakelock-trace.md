# Tracing the 34 s window: what actually holds the device awake (2026-08-10)

Question: the 34 s re-suspend window is the per-wake cost driver. Where does
the constant live, which syscalls depend on it, which internal timers are
armed alongside it — and what would race if we shortened it?

All findings below are from the on-device binary (`device/xochitl`,
gitignored) and live device state. Nothing here is inferred from community
docs.

## 1. The constant

`34000` appears **exactly once** in the entire 22 MB binary:

```
0x563948:  mov  x2, #0x84d0        // = 34000
```

(file offset 0x163948; single LOAD segment, vaddr = off + 0x400000). No
second copy, no duplicated literal, no `.rodata` table entry. It is built
into a stack struct alongside a heap object and a flag, then handed to a
registration helper:

```
563940: movi v0.4s, #0            ; zero the descriptor
563944: mov  w3, #1               ; -> [sp+0x348]  flag
563948: mov  x2, #0x84d0          ; -> [sp+0x350]  34000
563964: str  x21, [sp, #0x338]    ; the new'd object (0x108 bytes)
563974: bl   0x48c140
563978: mov  x1, #2               ; -> [sp+0x360]  kind/type = 2
```

The enclosing function registers power callbacks
(`csl::power::Manager::onBatteryPercentageChanged` a few instructions
earlier) — i.e. this is battery-manager construction wiring up its upkeep
task with a 34000 ms parameter.

**Consequence: any change is a one-instruction edit** (a MOVZ immediate),
or — better, see §5 — no edit at all.

## 2. The mechanism is a *timed userspace wakelock*, not a sleep loop

xochitl does not implement the awake window itself. It imports these from
a shared library (all PLT-imported dynamic symbols, `csl::power::Manager`):

```
grabWakeLock(std::string, unsigned long)      <- name + timeout
releaseWakeLock(std::string)
aboutToSlumber(std::function<void()>)
onWakeUp(std::function<void(wakeup::WakeUpReason)>)
getInhibitorState() const
```

The in-binary wakelock helper (entry 0x9155d0) shows the timeout policy:

```
9156b8: ldr  x2, [sp, #0x40]     ; caller-supplied timeout
9156bc: mov  x0, #0x7d0          ; = 2000  (default)
9156c4: csel x20, x2, x0, ne     ; use caller's value if flag set, else 2000
9156f0: mov  x2, x20
9156fc: bl   grabWakeLock@plt
```

Only two `grabWakeLock` call sites exist in xochitl: one passes a literal
2000, the other this computed value. The helper is invoked indirectly
(through `std::function`), so static flow from the constructor stops here —
but the device confirms the endpoint.

**Live device evidence** (`/sys/power/wake_unlock` = locks that have been
held and released this boot):

```
marker-manager-event-dispatcher  sleep.resume  wpa_supplicant
xochitl.activemarker.indicator   xochitl.batterymanager   xochitl.library
```

`/sys/power/wake_lock` right now (on USB): `udev.charger`.

So the architecture is the Linux/Android **userspace wakelock API**:
`write("/sys/power/wake_lock", "name <timeout_ns>")`, with
`/sys/power/autosleep = mem` active — the kernel suspends by itself the
moment the *last* wakelock clears. `xochitl.batterymanager` is the lock
that holds the 34 s window; the kernel auto-expires it.

**The syscall surface that depends on the constant is therefore a single
sysfs `write()`** — not a suspend ioctl, not an RTC program, not a logind
DBus call. Shortening the value cannot corrupt any kernel state machine;
it only makes one wakelock expire sooner.

Charging behaves the same way: `udev.charger` is itself a wakelock, which
is exactly why USB inhibits suspend (previously observed, now explained).

## 3. Internal timers armed alongside it

`timerfd_create` has **one** call site in the binary (0xdd1cd0) — a single
shared wrapper class; `timerfd_settime` two, `timerfd_gettime` two. Live
inventory (`/proc/<pid>/fdinfo`, xochitl awake on USB):

| fd | clockid | wakes from suspend? | armed now |
|----|---------|---------------------|-----------|
| 42, 45, 46, 72, 83 | 9 = CLOCK_BOOTTIME_ALARM | **yes** | disarmed |
| 44 | 9 = CLOCK_BOOTTIME_ALARM | **yes** | 3538 s (≈59 min — matches the 1 h `IdleSuspendDelay` debug setting still on this device) |
| 32, 47, 86 | 1 = CLOCK_MONOTONIC | no | disarmed |
| 64 | 1 = CLOCK_MONOTONIC | no | **33.04 s** |

Two things matter here:

1. **The ~34 s countdown currently armed is CLOCK_MONOTONIC (fd 64), not
   alarm class.** A MONOTONIC timerfd cannot wake a suspended system and
   does not advance across suspend. If this is the upkeep tick, then
   shortening the wakelock leaves **no orphan alarm** — no second wake per
   cycle. This is the single most important question for the race analysis
   and it needs confirmation *during a real RTC wake window on battery*
   (probe W1 below); today's sample is an awake-on-USB device.
2. Six alarm-class fds exist, so xochitl *can* schedule wake-capable
   timers; only the idle/suspend escalation one is armed while awake.

## 4. What depends on the 34 s window (race inventory)

Anything that assumes "userspace gets ~34 s of runtime after a wake":

| Consumer | Holds its own wakelock? | Races if window shortens? |
|---|---|---|
| Other subsystems (`wpa_supplicant`, `udev.charger`, `xochitl.library`, `marker-manager-event-dispatcher`, `sleep.resume`) | **yes, each independently** | **No.** autosleep suspends only when *all* locks clear; ours expiring early cannot cut short someone else's critical section. This is the key safety property. |
| EPD rail hold (`vpdd_length`, g2194) | n/a — kernel refuses suspend while it runs | **Yes, and it's the hard floor.** A suspend attempt during the hold returns -EAGAIN and we measured the abort path costing ~55 s extra awake. Window floor = repaint end + vpdd hold ≈ **8 s** at vpdd 6000 (matches the proven Plan B +8 s success), ~3–5 s if vpdd goes to 0/3000. |
| Our sleep bar repaint | no | Fits in 8 s (1 s QML tick + ~450 ms waveform); would be tight below ~3 s. |
| Our chapter persistence (detached `systemd-run` copying BMPs to eMMC at sleep entry) | **no** | **Yes — real risk of a truncated persisted chapter.** Mitigation is one line: the persist script grabs its own timed wakelock (`echo "pinsleep.persist 5000000000" > /sys/power/wake_lock`) and releases it when done. Correct regardless of this work. |
| fastshot capture | n/a (synchronous, ~70 ms, completes inside the QML call) | No. |
| xochitl sync/indexing | `xochitl.library` | No — it holds its own. |
| `LightSleepDelay` / `PowerOffDelay` setters | n/a | No — they only *clamp* against minimumAwakeTime (the binary's own log: "…set lower than minimumAwakeTime. It should be checked in those setters?"). Lowering it relaxes the clamp. |

## 5. The intervention this enables (no binary patching)

`grabWakeLock` is a **PLT-imported dynamic symbol**, and xovi already
LD_PRELOADs into xochitl. So the timeout can be changed by *interposition*
rather than patching:

```c
// hook csl::power::Manager::grabWakeLock(std::string, unsigned long)
// if name == "xochitl.batterymanager" && timeout == 34000 -> substitute
```

Advantages over patching the MOVZ immediate:
- survives OS updates (no offset dependence, symbol name is stable ABI);
- no read-only-rootfs remount, no A/B rollback exposure, no risk of a
  bad binary bricking a boot;
- runtime-tunable from a conf file, instantly revertible (drop the
  extension);
- lives in the same extension mechanism the mod already ships (fastshot).

This attacks the **per-wake cost directly, with the clock still running** —
which is what Plan D does not do. Expected: 35 s → ~8 s windows, per-wake
cost ~0.066 % → roughly 0.02 %, i.e. a 5-min clock at roughly 0.3–0.4 %/h
instead of ~0.9 %/h. It is complementary to (not a replacement for) the
hibernation lever.

Note this is exactly where the **vpdd experiment finally earns its keep**:
vpdd is not a standalone saving, it is the *floor setter* for how short the
window can safely be.

## 6. Probes needed before building

- **W1 (decisive) — arm-state during a real RTC wake, on battery.** Sample
  `/proc/<pid>/fdinfo/*` (clockid + it_value) and `/sys/power/wake_lock`
  at ~+2 s after an RTC wake. Answers: is the upkeep countdown MONOTONIC
  (no second wake) or ALARM (orphan wake → must be handled)? Is the
  batterymanager lock's remaining time consistent with 34 s?
  Implementation: a one-shot `systemd-run` unit triggered from the
  existing "after" sleep hook, dumping to a log file.
- **W2 — the wakelock timeout is really 34000.** Same window: read
  `/sys/power/wake_lock` repeatedly and time when `xochitl.batterymanager`
  disappears. Confirms the constant → lock linkage empirically (static
  flow is indirect through `std::function`).
- **W3 — interposition smoke test.** Hook `grabWakeLock`, log
  `(name, timeout)` for one cycle *without changing values*. Proves the
  hook fires and confirms the caller's parameters before we alter them.
- **W4 — shortened-window cycle.** Substitute 8000, one battery night,
  watch for: g2194 abort lines (must stay zero), missed bar repaints,
  truncated persisted chapters, extra resume cycles per mark.
- **W5 — floor search with vpdd.** Repeat W4 at vpdd 3000/0 with windows
  6 s/4 s to find where aborts start.
