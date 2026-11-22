#!/usr/bin/env python3
"""cmdtime.py <stderr.log>...: per copy, ms from the first WATCH showing the Mac command "I8CMD files" to the first WATCH with files=40."""
import re, sys
from datetime import datetime
for p in sys.argv[1:]:
    out = []; t0 = None
    for line in open(p, errors='replace'):
        m = re.match(r'(\d\d:\d\d:\d\d\.\d{3}) \[WATCH\] (.*)', line)
        if not m: continue
        ts = datetime.strptime(m.group(1), '%H:%M:%S.%f')
        if 'text="I8CMD files' in m.group(2) and t0 is None: t0 = ts
        elif t0 is not None and 'files=40' in m.group(2): out.append(round((ts - t0).total_seconds() * 1000)); t0 = None
    s = sorted(out); print(p.split('/')[-1], 'n=%d median=%s' % (len(s), s[len(s)//2] if s else None), s)
