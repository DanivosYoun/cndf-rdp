#!/usr/bin/env python3
"""lw1.py <results dir> <run>...: G-W1 per-trial board class (gw1.py rules) x contention markers from stderr.

markers per trial (between the WATCH of "I8CMD mix k" and the next one):
  out   = an FL saw RANGEs outstanding (IronRDP wirelog: "wire FL ... outstanding=N>0")
  stale = an answer of an earlier RANGE came after an FL (FreeRDP product: "stream not waiting";
          IronRDP wirelog: "wire stale answer after FL")
  ref   = "refused file range" (FreeRDP gate), p4 = stale-server-list refusals, nolock = has no lock
"""
import json, sys, os, re, collections
R = sys.argv[1]
sh = {}
for l in open(f'{R}/int11-sources.txt'):
    if l.startswith('sha '):
        _, p, h = l.split(); s, f = p.split('\\'); sh[h] = (s, f)
for name in sys.argv[2:]:
    try:
        it = json.load(open(f'{R}/{name}.json'))['runs'][0]['iterations'][0]
    except Exception as e:
        print('==', name, 'no result', e); continue
    trials = {}
    for f in it['localFiles']:
        trials.setdefault(f.get('snap'), []).append(f)
    nmax = max([int(s[3:]) for s in trials if s and s.startswith('mix')] + [19])
    cls = {}
    for k in range(nmax + 1):
        fs = trials.get(f'mix{k}', [])
        if not fs: cls[k] = 'NOFILES'; continue
        kinds = []
        for f in fs:
            src = sh.get(f.get('sha256')); nm = re.sub(r' \d+(?=\.bin$)', '', f['name'])
            kinds.append('A' if src and src[0] == 'gw1A' and src[1] == nm else 'B' if src and src[0] in ('gw1B', 'gw1C') and src[1] == nm else 'X')
        a, b, x = kinds.count('A'), kinds.count('B'), kinds.count('X')
        cls[k] = 'B' if b == len(fs) == 40 else 'A' if a == len(fs) else 'MISMATCH' if x == len(fs) else f'MIXED(A{a}B{b}X{x}n{len(fs)})'
    mk = collections.defaultdict(lambda: collections.Counter()); k = None
    for l in open(f'{R}/{name}.stderr.log', errors='replace'):
        m = re.search(r'text="I8CMD mix (\d+) ', l)
        if m and k != int(m.group(1)): k = int(m.group(1))
        if k is None: continue
        mo = re.search(r'wire FL files=\w+ outstanding=(\d+)', l)
        if mo and int(mo.group(1)) > 0: mk[k]['out'] += 1
        if 'stream not waiting' in l or 'wire stale answer after FL' in l: mk[k]['stale'] += 1
        if 'refused file range' in l: mk[k]['ref'] += 1
        if 'stale-server-list' in l:
            mc = re.search(r'count=(\d+)', l); mk[k]['p4'] += int(mc.group(1)) if mc else 1
        if 'has no lock' in l: mk[k]['nolock'] += 1
    tab = collections.Counter(); rows = []
    for k in range(nmax + 1):
        c = mk[k]; key = ('stale' if c['stale'] else 'out' if c['out'] else 'none', cls[k]); tab[key] += 1
        rows.append(f"mix{k}:{cls[k]}" + ''.join(f",{n}{v}" for n, v in sorted(c.items())))
    total = collections.Counter(cls.values())
    print('==', name, dict(total), 'contam=', sum(v for c, v in total.items() if c != 'B' and c != 'NOFILES'), 'nofiles=', total.get('NOFILES', 0))
    print('   by marker:', sorted(tab.items()))
    print('   ', ' '.join(rows))
