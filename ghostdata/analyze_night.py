#!/usr/bin/env python3
"""Cycle/abort/duty-cycle analysis of journal-night.log (rMPP Move ghost test).

Key parsing facts (verified in-file):
  * The kernel console is suspended during the freeze, so the whole
    suspend-entry block (Filesystems sync ... Enter suspend, battery X%)
    is FLUSHED AT RESUME and carries the resume timestamp.
    Only "PM: suspend entry (deep)" has a true pre-freeze timestamp.
  * Every vpdd abort still produces a matched entry/exit pair, so
    367 entries == 367 exits but only 237 are real sleeps.
"""
import re, sys, os, statistics as st
from collections import Counter, defaultdict
from datetime import datetime

PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'journal-night.log')
YEAR = 2026
MON = {'Jan':1,'Feb':2,'Mar':3,'Apr':4,'May':5,'Jun':6,'Jul':7,'Aug':8,
       'Sep':9,'Oct':10,'Nov':11,'Dec':12}
TS = re.compile(r'^(\w{3}) (\d{2}) (\d{2}):(\d{2}):(\d{2}) ')


def parse_ts(line):
    m = TS.match(line)
    if not m:
        return None
    mo, d, H, M, S = m.groups()
    return datetime(YEAR, MON[mo], int(d), int(H), int(M), int(S))


lines = open(PATH, errors='replace').read().splitlines()
ev = []                                   # (dt, index, line)
for i, l in enumerate(lines):
    t = parse_ts(l)
    if t:
        ev.append((t, i, l))

print(f'lines={len(lines)}  timestamped={len(ev)}')
print(f'log span: {ev[0][0]} .. {ev[-1][0]}')

# ---------------------------------------------------------------- identities
def count(pat):
    r = re.compile(pat)
    return sum(1 for _, _, l in ev if r.search(l))

ident = {
    'PM: suspend entry (deep)':      count(r'PM: suspend entry \(deep\)'),
    'PM: suspend exit':              count(r'PM: suspend exit'),
    'Enter suspend, battery':        count(r'Enter suspend, battery'),
    'Exit SUSPEND':                  count(r'Exit SUSPEND'),
    'Exit FAILED_SUSPEND':           count(r'Exit FAILED_SUSPEND'),
    'Enter autosleep':               count(r'Enter autosleep'),
    'Exit AUTOSLEEP':                count(r'Exit AUTOSLEEP'),
    'hibernation entry':             count(r'PM: hibernation: hibernation entry'),
    'Freezing user space processes$': count(r'Freezing user space processes$'),
    "Can't suspend, vpdd":           count(r"Can't suspend, vpdd timer running"),
    'requests a delay':              count(r'requests a delay of'),
    'Starting No-op':                count(r'Starting No-op'),
    'Woke up with reason=RTC':       count(r'Woke up with reason=RTC'),
    'Re-entering DeepSleep':         count(r'Re-entering DeepSleep in'),
}
print('\n=== identity counts ===')
for k, v in ident.items():
    print(f'{v:6d}  {k}')
print('  check 237+123 =', ident['Exit SUSPEND'] + ident['Exit FAILED_SUSPEND'],
      '== Enter suspend', ident['Enter suspend, battery'])
print('  check entries-360 =', ident['PM: suspend entry (deep)'] - 360,
      '== autosleep', ident['Enter autosleep'])
print('  check freeze =', ident['Freezing user space processes$'],
      '== entries+hib', ident['PM: suspend entry (deep)'] + ident['hibernation entry'])

# ---------------------------------------------- build suspend attempt records
# An attempt = "PM: suspend entry (deep)"  ...  "PM: suspend exit"
entries = [(t, i) for t, i, l in ev if 'PM: suspend entry (deep)' in l]
exits   = [(t, i) for t, i, l in ev if re.search(r'PM: suspend exit', l)]
hib_in  = [(t, i) for t, i, l in ev if 'hibernation: hibernation entry' in l]
hib_out = [(t, i) for t, i, l in ev if 'hibernation: hibernation exit' in l]

attempts = []
for k, (t_in, i_in) in enumerate(entries):
    nxt = entries[k + 1][1] if k + 1 < len(entries) else len(lines)
    ex = next(((t, i) for t, i in exits if i > i_in and i < nxt), None)
    if ex is None:
        attempts.append(dict(t_in=t_in, i_in=i_in, t_out=None, i_out=None,
                             kind='NO_EXIT'))
        continue
    t_out, i_out = ex
    body = '\n'.join(lines[i_in:i_out + 1])
    if 'Exit FAILED_SUSPEND' in body:
        kind = 'ABORT'
    elif 'Exit AUTOSLEEP' in body:
        kind = 'AUTOSLEEP'
    elif 'Exit SUSPEND' in body:
        kind = 'SLEEP'
    else:
        kind = 'UNKNOWN'
    wr = re.search(r'SPLD wakeup-reason \((0x[0-9a-f]+)\): (\S*)', body)
    irq = re.search(r'Triggering wakeup from (IRQ \d+ \([^)]*\))', body)
    bat = re.search(r'Enter (?:suspend|autosleep), battery ([\d.]+)%', body)
    attempts.append(dict(t_in=t_in, i_in=i_in, t_out=t_out, i_out=i_out,
                         kind=kind, spld=wr.group(2) if wr else None,
                         irq=irq.group(1) if irq else None,
                         bat=float(bat.group(1)) if bat else None,
                         dur=(t_out - t_in).total_seconds()))

print('\n=== attempt classification ===')
print(' ', dict(Counter(a['kind'] for a in attempts)))

# ------------------------------------------------------------- night windows
# 1-min cadence installed 01:45:47-01:45:50; night ends at hibernation 08:19:45
CAD1 = datetime(YEAR, 8, 12, 1, 45, 50)
HIB  = hib_in[-1][0]                      # 08:19:45
PREV_HIB_OUT = hib_out[0][0]              # 00:20:53
print(f'\n1-min cadence start {CAD1}   hibernation (night end) {HIB}')
print(f'previous hibernation exit {PREV_HIB_OUT}')

# ------------------------------------------------------- CYCLES (task 1)
# cycle = successful sleep exit -> next successful sleep entry
sleeps = [a for a in attempts if a['kind'] == 'SLEEP']


def cycles(lo, hi):
    sel = [a for a in sleeps if lo <= a['t_in'] < hi]
    out = []
    for k in range(len(sel) - 1):
        a, b = sel[k], sel[k + 1]
        awake = (b['t_in'] - a['t_out']).total_seconds()
        aborts = [x for x in attempts
                  if x['kind'] == 'ABORT' and a['i_out'] < x['i_in'] < b['i_in']]
        gap_min = (b['t_out'] - a['t_out']).total_seconds() / 60.0 if b['t_out'] else None
        out.append(dict(exit=a['t_out'], nxt=b['t_in'], awake=awake,
                        naborts=len(aborts), aborts=aborts,
                        sleep=(b['t_out'] - b['t_in']).total_seconds() if b['t_out'] else None,
                        wake_iv=(b['t_out'] - a['t_out']).total_seconds() if b['t_out'] else None))
    return sel, out


sel, cyc = cycles(CAD1, HIB)
print(f'\n=== TASK 1: cycles in 1-min window {CAD1}..{HIB} ===')
print(f'successful sleeps entered: {len(sel)}   cycles (exit->next entry): {len(cyc)}')
aw = [c['awake'] for c in cyc]
print('awake distribution (s):')
for v, n in sorted(Counter(aw).items()):
    print(f'   {v:7.0f}s  x{n:4d}  {"#"*min(n,60)}')
print(f'  mean={st.mean(aw):.2f} median={st.median(aw)} mode={Counter(aw).most_common(1)}')
print(f'  min={min(aw)} max={max(aw)} stdev={st.pstdev(aw):.2f}')
qs = [50, 75, 90, 95, 99]
sa = sorted(aw)
for q in qs:
    print(f'  p{q} = {sa[min(len(sa)-1,int(round(q/100*len(sa)))-1)]}')

# merged cycles: wake-to-wake interval >= 2 min
wi = [c['wake_iv'] for c in cyc if c['wake_iv']]
print('\nwake-to-wake interval histogram (s):')
for v, n in sorted(Counter(wi).items()):
    print(f'   {v:7.0f}s  x{n:4d}')
merged = [c for c in cyc if c['wake_iv'] and c['wake_iv'] >= 105]
print(f'merged cycles (wake interval >=105s, i.e. a timer minute skipped): {len(merged)}')
for c in merged[:40]:
    print(f'   exit {c["exit"]} -> next exit +{c["wake_iv"]:.0f}s  awake={c["awake"]:.0f}s aborts={c["naborts"]}')

# awake vs abort correlation
print('\nawake time by abort count:')
byab = defaultdict(list)
for c in cyc:
    byab[c['naborts']].append(c['awake'])
for k in sorted(byab):
    v = byab[k]
    print(f'   aborts={k}: n={len(v):4d} mean={st.mean(v):7.2f} min={min(v):5.0f} max={max(v):5.0f} '
          f'values={sorted(Counter(v).items())[:8]}')

# --------------------------------------------------- TASK 2: wake accounting
print('\n=== TASK 2: wake accounting ===')
span = (HIB - CAD1).total_seconds()
print(f'1-min window span = {span:.0f}s = {span/60:.1f} min  -> {span/60:.0f} timer minutes available')
print(f'successful RTC sleeps/resumes in window: {len(sel)}')
for k in ('SLEEP', 'ABORT', 'AUTOSLEEP'):
    print(f'  attempts kind={k} in window: '
          f'{sum(1 for a in attempts if a["kind"]==k and CAD1 <= a["t_in"] < HIB)}')
noop = [t for t, i, l in ev if 'Starting No-op' in l and CAD1 <= t < HIB]
print(f'  pinsleep-clock.service activations in window: {len(noop)}')
print(f'  total in file: {ident["Starting No-op"]}')
# is No-op resume-driven or timer-driven?
orphan = 0
for t, i, l in ev:
    if 'Starting No-op' not in l:
        continue
    near = '\n'.join(lines[max(0, i - 60):i])
    if not re.search(r'PM: suspend exit|hibernation exit', near):
        orphan += 1
print(f'  No-op activations with NO suspend/hibernation exit in preceding 60 lines: {orphan}')

# --------------------------------------------------------- TASK 3: aborts
print('\n=== TASK 3: aborts ===')
ab = [a for a in attempts if a['kind'] == 'ABORT']
abn = [a for a in ab if CAD1 <= a['t_in'] < HIB]
print(f'total aborts in file {len(ab)}, in 1-min night window {len(abn)}')
print('aborts per hour (whole file):')
for h, n in sorted(Counter(a['t_in'].strftime('%m-%d %H') for a in ab).items()):
    print(f'   {h}  {n:3d}  {"#"*n}')
print('aborts per cycle histogram (night window):', dict(Counter(c['naborts'] for c in cyc)))
# cost of an abort: abort entry -> eventual successful entry
costs = []
for a in ab:
    nxt = next((s for s in sleeps if s['i_in'] > a['i_in']), None)
    if nxt and CAD1 <= a['t_in'] < HIB:
        costs.append((nxt['t_in'] - a['t_in']).total_seconds())
if costs:
    print(f'abort->eventual successful suspend entry (s): n={len(costs)} '
          f'mean={st.mean(costs):.2f} min={min(costs)} max={max(costs)} '
          f'hist={sorted(Counter(costs).items())}')
print('non-vpdd failure signatures:')
for pat, lab in [(r'g2194-regulator .*WARN|WARN_ON', 'g2194 WARN_ON'),
                 (r'\bBUG:', 'BUG'), (r'Tainted', 'taint'),
                 (r'Call trace', 'call trace'),
                 (r'Freezing .*abort|Freezing of tasks failed', 'freezer fail'),
                 (r'oom-kill|Out of memory', 'OOM'),
                 (r'watchdog', 'watchdog'),
                 (r'mwlan|iw61x.*(fail|error|reset)', 'wifi err'),
                 (r'elants.*(fail|error|timeout)', 'elants err'),
                 (r'Power key pressed', 'powerkey'),
                 (r'Some devices failed to suspend', 'devices failed')]:
    hits = [(t, l) for t, i, l in ev if re.search(pat, l, re.I)]
    inw = [1 for t, l in hits if CAD1 <= t < HIB]
    print(f'   {lab:16s} total={len(hits):4d} in-night={len(inw):4d}')
# every "failed to suspend async" reason
print('  distinct dpm failure reasons:',
      dict(Counter(re.sub(r'^.*kernel: ', '', l)[:70]
                   for t, i, l in ev if 'failed to suspend async' in l)))

# ------------------------------------------------------- TASK 4: delay reqs
print('\n=== TASK 4: grace/delay requests ===')
d = [(t, int(m.group(1))) for t, i, l in ev
     if (m := re.search(r'requests a delay of (\d+)ms', l))]
print(f'total {len(d)}   in-night {sum(1 for t,v in d if CAD1<=t<HIB)}')
vals = [v for t, v in d]
print(f'min={min(vals)} max={max(vals)} mean={st.mean(vals):.1f} median={st.median(vals)}')
print('buckets of 2000ms:')
for b, n in sorted(Counter(v // 2000 * 2000 for v in vals).items()):
    print(f'   {b:6d}-{b+1999:6d}ms  x{n:3d}  {"#"*n}')
nv = [v for t, v in d if CAD1 <= t < HIB]
if nv:
    print(f'in-night: n={len(nv)} min={min(nv)} max={max(nv)} mean={st.mean(nv):.1f} '
          f'values={sorted(Counter(nv).items())}')

# ------------------------------------------------------- TASK 8: duty cycle
print('\n=== TASK 8: duty cycle ===')
def duty(lo, hi, label):
    tot = (hi - lo).total_seconds()
    slp = 0.0
    for a in attempts:
        if a['kind'] in ('SLEEP', 'AUTOSLEEP') and a['t_out'] and a['t_in'] >= lo and a['t_out'] <= hi:
            slp += (a['t_out'] - a['t_in']).total_seconds()
    for (t1, _), (t2, _) in zip(hib_in, hib_out):
        if t1 >= lo and t2 <= hi:
            slp += (t2 - t1).total_seconds()
    print(f'{label}: span={tot:.0f}s sleep={slp:.0f}s awake={tot-slp:.0f}s '
          f'asleep={100*slp/tot:.1f}% awake={100*(tot-slp)/tot:.1f}%')
    return tot, slp

duty(CAD1, HIB, '1-min cadence window     ')
duty(PREV_HIB_OUT, HIB, 'since prev hibernation exit')
duty(datetime(YEAR,8,12,1,0,49), HIB, 'since timer install 01:00:49')
print('xochitl accumulator: already slept 14419282ms = %.0fs' % (14419282/1000))

# --------------------------------------------------- TASK 7: gaps/anomalies
print('\n=== TASK 7: gaps in wake sequence (night window) ===')
outs = [a['t_out'] for a in sleeps if CAD1 <= a['t_out'] < HIB]
for k in range(len(outs) - 1):
    g = (outs[k + 1] - outs[k]).total_seconds()
    if g > 180:
        print(f'   GAP {g:.0f}s  {outs[k]} -> {outs[k+1]}')
print('xochitl main pid values:',
      dict(Counter(m.group(1) for t, i, l in ev
                   if (m := re.search(r'xochitl\[(\d+)\]', l)) and
                   re.search(r'rm\.batterymanager', l))))
print('\n=== morning wake reasons after hibernation ===')
for t, i, l in ev:
    if t >= datetime(YEAR,8,12,8,19,40) and re.search(
            r'wakeup-reason|Woke up with reason|hibernation (entry|exit)|already slept|'
            r'Power key pressed|Enter (hibernate|autosleep)|Exit (HIBERNATE|AUTOSLEEP)', l):
        print('  ', t.strftime('%H:%M:%S'), re.sub(r'^.*imx93-chiappa ', '', l)[:110])

# =====================================================================
# CORRECTED MODEL (the stated model has no abort term and fails):
#     awake = 34s  +  35s * n_aborts  +  sum(granted grace delays)
# 35s = 34s re-arm window + ~1s failed suspend/resume round trip.
# =====================================================================
print('\n=== CORRECTED MODEL FIT ===')
fit = []
for k in range(len(sel) - 1):
    a, b = sel[k], sel[k + 1]
    nab = sum(1 for x in attempts
              if x['kind'] == 'ABORT' and a['i_out'] < x['i_in'] < b['i_in'])
    dl = [int(m.group(1)) for l in lines[a['i_out']:b['i_in']]
          if (m := re.search(r'requests a delay of (\d+)ms', l))]
    meas = (b['t_in'] - a['t_out']).total_seconds()
    pred = 34 + 35 * nab + sum(dl) / 1000.0
    fit.append(meas - pred)
print('  residual (measured-predicted) histogram:',
      dict(Counter(round(x) for x in fit)))
print(f'  within 1s: {sum(1 for x in fit if abs(x) <= 1)}/{len(fit)}')

print('\n=== UNPLUG / CHARGER BOUNDARIES ===')
for _, _, l in ev:
    if re.search(r'charger_connected|reason=Charger|SOC change (99|100)|'
                 r'wakeup-reason \(0x10\)|Power key pressed', l):
        print('  ', re.sub(r'^(\w+ \d+ \d\d:\d\d:\d\d) imx93-chiappa ', r'\1 ', l)[:110])
