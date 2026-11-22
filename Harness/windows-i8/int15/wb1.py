#!/usr/bin/env python3
"""wb1.py <clipexp log>... : W-B1 per trial. File FLs are counted per trial: the
first two are A (2000 names a*), the rest B (40 names g*). Reports (i) descriptor responses
with A names after B's first FL, (ii) B-name responses before B's first FL (R-2) and their lead
over that FL, (iii) FL(B)-FL(A) minus the B delay, split by whether a descriptor response came
<= 5 ms before FL(B) (the deferral signature)."""
import re, sys, statistics
def t(s):
    h, m, x = s.split(':'); return (int(h) * 3600 + int(m) * 60 + float(x)) * 1000
rows, fcr = [], []
for path in sys.argv[1:]:
    trial = None
    for l in open(path, errors='replace'):
        m = re.match(r'(\d\d:\d\d:\d\d\.\d{3}) \+\d+ (.*)', l)
        if not m: continue
        ts, msg = t(m.group(1)), m.group(2)
        if msg.startswith('TRIAL-START'):
            k, d = re.search(r'k=(\d+) delay=(\d+)', msg).groups()
            trial = {'file': path, 'k': int(k), 'd': int(d), 'fl': [], 'resp': [], 'req': []}; rows.append(trial)
        elif trial is None: continue
        elif msg.startswith('<FL ') and 'fgdw=Some' in msg: trial['fl'].append(ts)
        elif msg.startswith('>FDREQ fgdw'): trial['req'].append(ts)
        elif msg.startswith('<FDRESP fgdw'):
            f = re.search(r'first=Some\("([^"]*)"\)', msg); n = re.search(r' n=(\d+)', msg)
            name = f.group(1) if f else ''
            trial['resp'].append((ts, 'A' if name.startswith('a') else 'B' if name.startswith('g') else '?', int(n.group(1)) if n else -1, 'STALE' in msg))
        elif msg.startswith('<FCRESP'):
            r = re.search(r'rtt=(\d+)ms', msg)
            if r: fcr.append(int(r.group(1)))
        elif msg.startswith('TRIAL-END'): trial['end'] = msg
viol, r2, defer, nodefer, nob, odd = [], [], [], [], 0, 0
for tr in rows:
    # each .NET SetFileDropList gives the server's FL twice: FLs 1-2 are A, 3-4 are B
    fl = tr['fl']
    groups = [fl[:2], fl[2:]] if len(fl) >= 3 else [fl]
    if len(fl) != 4: odd += 1
    if len(groups) < 2: nob += 1; tr['why'] = 'no-B-FL'; continue
    a0, b0 = groups[0][0], groups[1][0]
    for ts, cls, n, stale in tr['resp']:
        if cls == 'A' and ts > b0: viol.append((tr['file'].split('/')[-1], tr['k'], tr['d'], round(ts - b0)))
        if cls == 'B' and ts < b0: r2.append((tr['file'].split('/')[-1], tr['k'], tr['d'], round(b0 - ts)))
    pre = [ts for ts, cls, n, s in tr['resp'] if 0 <= b0 - ts <= 5]
    (defer if pre else nodefer).append((tr['d'], round(b0 - a0 - tr['d'])))
print(f'trials={len(rows)} noB={nob} FLs!=4={odd} FCRESP rtt min/median={min(fcr) if fcr else "-"}/{statistics.median(fcr) if fcr else "-"} ms')
print(f'(i) A-name descriptor after FL(B): {len(viol)}', viol[:10])
print(f'(ii) R-2 (B names before FL(B)): {len(r2)} lead ms max={max([x[3] for x in r2]) if r2 else "-"}', r2[:10])
def summ(lst):
    by = {}
    for d, x in lst: by.setdefault(d, []).append(x)
    return ' '.join(f'{d}:{statistics.median(v)}({len(v)})' for d, v in sorted(by.items()))
print('(iii) FL(B)-FL(A)-delay ms, response <=5 ms before FL(B):', summ(defer))
print('(iii) same, no response just before FL(B):', summ(nodefer))
