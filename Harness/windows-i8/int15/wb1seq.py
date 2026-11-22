#!/usr/bin/env python3
"""wb1seq.py <clipexp log>...: per-trial order of file FLs (F), descriptor requests (q) and responses
(a = A names, b = B names, x = FAIL), and how many descriptor requests were outstanding when FL(B) (the
third file FL) arrived; for those, the names of the responses that came after FL(B)."""
import re, sys, collections
def t(s):
    h, m, x = s.split(':'); return (int(h) * 3600 + int(m) * 60 + float(x)) * 1000
T = []
for path in sys.argv[1:]:
    tr = None
    for l in open(path, errors='replace'):
        m = re.match(r'(\d\d:\d\d:\d\d\.\d{3}) \+\d+ (.*)', l)
        if not m: continue
        ts, msg = t(m.group(1)), m.group(2)
        if msg.startswith('TRIAL-START'): tr = []; T.append(tr)
        elif tr is None: continue
        elif msg.startswith('<FL ') and 'fgdw=Some' in msg: tr.append('F')
        elif msg.startswith('>FDREQ fgdw'): tr.append('q')
        elif msg.startswith('<FDRESP fgdw'):
            f = re.search(r'first=Some\("(.)', msg); tr.append('x' if ' FAIL ' in msg else 'a' if f and f.group(1) == 'a' else 'b')
seqs = collections.Counter(''.join(x) for x in T); out = collections.Counter(); after = collections.Counter()
for tr in T:
    q = r = nf = 0
    for i, e in enumerate(tr):
        if e == 'F':
            nf += 1
            if nf == 3:
                out[q - r] += 1
                if q - r > 0: after[''.join(x for x in tr[i:] if x in 'abx')[:q - r]] += 1
                break
        elif e == 'q': q += 1
        else: r += 1
print('trials', len(T)); [print(' ', v, k) for k, v in seqs.most_common()]
print('outstanding descriptor requests at FL(B):', dict(out))
print('names of the first responses after FL(B) when requests were outstanding:', dict(after))
