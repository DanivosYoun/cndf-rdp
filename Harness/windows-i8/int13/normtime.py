#!/usr/bin/env python3
"""normtime.py <stderr.log>...: per copy, ms from the first files FL to the first WATCH with files=40 (board set)."""
import re, sys
from datetime import datetime
def t(s): return datetime.strptime(s, '%H:%M:%S.%f')
for p in sys.argv[1:]:
    fl = None; out = []; armed = False
    for line in open(p, errors='replace'):
        m = re.match(r'(\d\d:\d\d:\d\d\.\d{3}) (.*)', line)
        if not m: continue
        ts, rest = t(m.group(1)), m.group(2)
        if 'WATCH' in rest and 'text="I8CMD files' in rest and not armed: armed = True; fl = None
        if armed and fl is None and ('wire FL' in rest and 'files=true' in rest or 'remote format list received: count=3' in rest): fl = ts
        if armed and fl is not None and 'WATCH' in rest and 'files=40' in rest:
            out.append((ts - fl).total_seconds() * 1000); armed = False; fl = None
    out.sort()
    med = out[len(out)//2] if out else None
    print(p.split('/')[-1], 'n=%d' % len(out), 'median=%s ms' % (round(med) if med else None), [round(x) for x in out])
