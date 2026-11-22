#!/usr/bin/env python3
"""xrows.py x1|x7|x3 <results dir> <run>...
x1: per trial k, after the local "I8CMD noop k" shows on the board, count board changes and whether
    the remote text "X1-r-k" came back (a later remote write overwrote the newer local copy).
x7: per Mac copy "X7-m-<src>-<d>-<i>", did it reach the Windows clipboard (probe log clip text)?
x3: per trial, the last Windows clipboard text and the Mac snapshot.
"""
import sys, re, base64, collections, os
mode, R = sys.argv[1], sys.argv[2]
def probe_texts(name):
    out = []
    p = f'{R}/{name}.probe.log'
    if not os.path.exists(p): return out
    for l in open(p, errors='replace'):
        m = re.search(r'^(\d+) clip text .* head=(\S*)', l)
        if m:
            try: out.append((int(m.group(1)), base64.b64decode(m.group(2)).decode('utf-8', 'replace')))
            except Exception: pass
    return out
for name in sys.argv[3:]:
    if mode == 'x1':
        lines = open(f'{R}/{name}.stderr.log', errors='replace').read().splitlines()
        k = None; res = {}; base = None
        for l in lines:
            m = re.search(r'\[WATCH\] .*change=(\d+) .*text="(.*)"$', l)
            if not m: continue
            ch, tx = int(m.group(1)), m.group(2)
            mm = re.match(r'I8CMD noop (\d+)$', tx)
            if mm and k != int(mm.group(1)):
                k = int(mm.group(1)); base = ch; res[k] = [0, False]
            elif k is not None and tx.startswith('I8CMD settext'):
                k = None
            elif k is not None:
                if ch > base: res[k][0] = max(res[k][0], ch - base)
                if tx == f'X1-r-{k}': res[k][1] = True
        bad = [k for k, (c, back) in res.items() if back or c]
        sess = open(f'{R}/{name}-1.session.log', errors='replace').read()
        sup = sum(int(x) for x in re.findall(r'superseded count=(\d+)', sess)) + sess.count('dropped stale remote format data response')
        print(name, f'trials={len(res)} overwritten={len(bad)} {bad} superseded/stale-drop={sup}')
    elif mode == 'x7':
        texts = [t for _, t in probe_texts(name)]
        got = collections.defaultdict(lambda: [0, 0])
        for src in ['net', 'notepad', 'explorer']:
            for d in [0, 100, 300, 450, 600, 800]:
                for i in range(1, 4):
                    m = f'X7-m-{src}-{d}-{i}'
                    got[(src, d)][1] += 1
                    if m in texts: got[(src, d)][0] += 1
        pl = open(f'{R}/{name}.probe.log', errors='replace').read() if os.path.exists(f'{R}/{name}.probe.log') else ''
        print(name, 'notepad copied', pl.count('notepad copied'), 'excopy copied', pl.count('excopy copied'), 'missing', pl.count('window missing'))
        for src in ['net', 'notepad', 'explorer']:
            print('  ', src, ' '.join(f'{d}:{got[(src, d)][0]}/{got[(src, d)][1]}' for d in [0, 100, 300, 450, 600, 800]))
    elif mode == 'x3':
        texts = probe_texts(name)
        snaps = [l.strip() for l in open(f'{R}/{name}.stderr.log', errors='replace') if '[SNAP]' in l]
        for k in range(3):
            seq = [t for _, t in texts if t.startswith(f'X3-') and t.endswith(f'-{k}')]
            print(name, k, 'windows seq:', seq, '| mac:', next((s.split('[SNAP]')[1] for s in snaps if f'x3-{k} ' in s), '?'))
