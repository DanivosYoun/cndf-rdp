#!/usr/bin/env python3
"""missing.py <results dir> <run>...: board snapshot entries whose file was gone ("missing") per
snapshot, in snapshot order, plus the stderr staging timeline lines around them."""
import json, sys, collections
R = sys.argv[1]
for name in sys.argv[2:]:
    try: its = json.load(open(f'{R}/{name}.json'))['runs'][0]['iterations']
    except Exception as e: print(name, 'no json', e); continue
    tot = miss = 0; per = []
    for it in its:
        snaps = collections.OrderedDict()
        for f in it.get('localFiles', []):
            s = snaps.setdefault(f.get('snap', '?'), [0, []]); s[0] += 1
            if f.get('missing') == 'true': s[1].append(f['name'])
        for k, (n, m) in snaps.items():
            tot += n; miss += len(m)
            if m: per.append(f"it{it['iteration']}:{k}:{len(m)}/{n}:{m[0]}..{m[-1]}")
    print(name, f'entries={tot} missing={miss}', ' '.join(per))
