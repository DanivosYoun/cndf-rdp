#!/usr/bin/env python3
"""count.py <results dir> <run>...: per-run keyword counts from the session log, plus probe paste tree check."""
import sys, re, os, base64, json
R = sys.argv[1]
KEYS = [('refused', 'refused file range'), ('cfail', 'contents failed'), ('nolock', 'has no lock'),
        ('stale', 'stale-server-list'), ('replaced', 'replaced-offer'), ('chlimit', 'channel message limit'),
        ('budget', 'exceeds the budget'), ('fp8m', 'Discarding Fast-Path fragmented'), ('e0e', '0x4952000E')]
MAC = {}
shaf = os.path.expanduser('~/.cache/int13-8a11de3b/mac-src-sha.txt')
for l in open(shaf):
    m = re.match(r'\\?([0-9a-f]{64})  \./(.*)$', l.strip())
    if m: MAC[os.path.basename(m.group(2).replace('\\\\', '\\'))] = m.group(1)
def nsum(txt, pat):
    return sum(int(m.group(1)) for m in re.finditer(pat, txt))
for name in sys.argv[2:]:
    # repeat scenarios write <run>-1..-N.session.log; join them all
    txt = ''.join(open(f'{R}/{f}', errors='replace').read() for f in sorted(os.listdir(R)) if re.fullmatch(re.escape(name) + r'-\d+\.session\.log', f))
    c = {k: txt.count(s) for k, s in KEYS}
    # refusal summaries carry count=N (IronRDP): add N-1 for those lines
    for k, s in KEYS:
        for m in re.finditer(re.escape(s) + r'[^\n]*?count=(\d+)', txt): c[k] += int(m.group(1)) - 1
    lk = {'srvLock': txt.count('server locked local clipboard data'), 'srvUnlock': txt.count('server unlocked local clipboard data'),
          'fLock': txt.count('Clipboard locked remote clipboard data'), 'fUnlock': txt.count('Clipboard unlocked remote clipboard data'),
          'iReleased': nsum(txt, r'released outgoing locks count=(\d+)')}
    out = [f'{k}={v}' for k, v in {**c, **lk}.items() if v]
    res = ''
    jp = f'{R}/{name}.json'
    if os.path.exists(jp):
        try: res = 'PASS' if json.load(open(jp))['runs'][0].get('passed', json.load(open(jp))['runs'][0].get('pass')) else ''
        except Exception: pass
    pr = f'{R}/{name}.probe.log'
    tree = ''
    if os.path.exists(pr):
        pl = open(pr, errors='replace').read()
        dl = [l for l in pl.splitlines() if ' dialogs ' in l]
        for l in pl.splitlines():
            if ' tree ' in l:
                ok = bad = 0; ents = []
                for t in l.split():
                    if t.startswith('f:'):
                        _, b, ln, *h = t.split(':'); nm = base64.b64decode(b).decode()
                        exp = MAC.get(nm.split('\\')[-1])
                        if h and (exp == h[0] or (exp is None and h[0] in MAC.values())): ok += 1
                        else: bad += 1; ents.append(f'{nm}:{ln}:{h[0][:8] if h else "-"}')
                    elif t.startswith('d:'): ents.append('d:' + base64.b64decode(t[2:]).decode())
                n = re.search(r' n=(\d+) bytes=(\d+)', l)
                tree = f'tree n={n.group(1)} bytes={n.group(2)} shaOK={ok} shaBAD={bad} ' + ' '.join(ents)
        tree += ' ' + (dl[-1].split(' dialogs ', 1)[1] if dl else 'dialogs=?') if tree else ''
    print(name, ' '.join(out) or '-', '|', tree)
