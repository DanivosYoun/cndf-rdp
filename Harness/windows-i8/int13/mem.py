#!/usr/bin/env python3
"""mem.py <log>...: per rdpclip PID: time span (KST), samples, priv KB first-steady/max/last, handles; skips the first 15 s (rdpclip start)."""
import re, sys, collections
from datetime import datetime
S = collections.OrderedDict()
for p in sys.argv[1:]:
    for l in open(p):
        m = re.match(r'(\S+ \S+) KST rdpclip pid=(\d+) sess=\d+ privKB=(\d+) wsKB=\d+ handles=(\d+)', l)
        if m: S.setdefault(m.group(2), []).append((datetime.strptime(m.group(1), '%Y-%m-%d %H:%M:%S'), int(m.group(3)), int(m.group(4))))
for pid, xs in S.items():
    t0 = xs[0][0]; st = [x for x in xs if (x[0] - t0).total_seconds() >= 15] or xs
    pv = [x[1] for x in st]; hv = [x[2] for x in st]
    print(f'pid={pid} {xs[0][0]:%H:%M:%S}-{xs[-1][0]:%H:%M:%S} n={len(xs)} privKB steady-first={pv[0]} max={max(pv)} last={pv[-1]} (max-first=+{max(pv)-pv[0]} last-first={pv[-1]-pv[0]:+d}) handles={min(hv)}..{max(hv)}')
