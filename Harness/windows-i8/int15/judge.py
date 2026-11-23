#!/usr/bin/env python3
"""judge.py <results dir> <expected.json> <run>... : Windows tree vs expected (names, sizes, SHA-256),
secret content on Windows, [OMIT]/[DROP] lines, paste/dialog lines, key session-log counts."""
import base64, json, os, re, sys, unicodedata
R, E = sys.argv[1], json.load(open(sys.argv[2]))
SECRET = 'b42b8d52f87e094ec119dbb7977f5e87778430703fff9bc18003b22c675e39f8'
KEYS = [('refused', 'refused file range'), ('cfail', 'contents failed'), ('nolock', 'has no lock'),
        ('replaced', 'replaced-offer'), ('srvLock', 'server locked local clipboard data'),
        ('rangeFail', 'RANGE failed'), ('localRefused', 'local file request refused')]
for run in sys.argv[3:]:
    scen = re.sub(r'-(freerdp|ironrdp)(-\d+)?$', '', run)
    exp = E.get(scen, [])
    pl = open(f'{R}/{run}.probe.log', errors='replace').read() if os.path.exists(f'{R}/{run}.probe.log') else ''
    err = open(f'{R}/{run}.stderr.log', errors='replace').read() if os.path.exists(f'{R}/{run}.stderr.log') else ''
    sl = ''.join(open(f'{R}/{f}', errors='replace').read() for f in sorted(os.listdir(R)) if re.fullmatch(re.escape(run) + r'-\d+\.session\.log', f))
    trees = [l for l in pl.splitlines() if ' tree ' in l]
    dialogs = [l.split(' dialogs ', 1)[1] for l in pl.splitlines() if ' dialogs ' in l]
    out = []
    for i, ex in enumerate(exp):
        if i >= len(trees): out.append(f'[{i}] tree=MISSING'); continue
        got = {}
        for t in trees[i].split():
            if t.startswith('f:'):
                _, b, ln, *h = t.split(':'); got[unicodedata.normalize('NFC', base64.b64decode(b).decode())] = f'{ln}:{h[0] if h else "-"}'
            elif t.startswith('d:'):
                got[unicodedata.normalize('NFC', base64.b64decode(t[2:]).decode())] = 'dir'
        want = ex['entries']
        miss = sorted(set(want) - set(got)); extra = sorted(set(got) - set(want))
        bad = sorted(k for k in set(want) & set(got) if want[k] != got[k])
        secret = sum(1 for v in got.values() if SECRET in v)
        verdict = 'MATCH' if not (miss or extra or bad or secret) else 'DIFF'
        s = f'[{i}] {verdict} n={len(got)}/{len(want)} omittedExp={ex["omitted"]} secret={secret}'
        if miss: s += f' miss={miss[:4]}'
        if extra: s += f' extra={extra[:4]}'
        if bad: s += ' bad=' + ','.join(f'{k}:{got[k][:20]}' for k in bad[:3])
        out.append(s)
    omit = re.findall(r'\[OMIT\] count=(\d+)', err); drop = re.findall(r'\[DROP\] provided=(\w+)', err)
    keys = {k: sl.count(v) for k, v in KEYS if sl.count(v)}
    ev = [w for w in ('paste sent', 'paste retry', 'explorer focused for drop', 'drop-no-files', 'cancel sent', 'cancel no progress', 'paste no files') if w in pl]
    ctrlv = err.count('local file drag forwarded as Ctrl+V') + sl.count('local file drag forwarded as Ctrl+V')
    res = ''
    try:
        j = json.load(open(f'{R}/{run}.json'))['runs'][0]; res = 'PASS' if j.get('passed', j.get('pass')) else 'FAIL'
    except Exception: res = 'nojson'
    print(run, res, ' '.join(out) or '-', f'omit={omit} drop={drop} ctrlV={ctrlv}', 'ev=' + ','.join(ev), 'dialogs=' + (dialogs[-1] if dialogs else '?'), keys)
