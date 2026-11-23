#!/usr/bin/env python3
"""x6.py <results dir> <run>...: X-6 counts - materialization failed/discarded lines in the session
log (file sink) and on stderr (delegate), and the staging step results."""
import json, os, re, sys
R = sys.argv[1]
pat = re.compile(r'materialization (failed|discarded)')
for name in sys.argv[2:]:
    sl = ''.join(open(f'{R}/{f}', errors='replace').read() for f in sorted(os.listdir(R)) if re.fullmatch(re.escape(name) + r'-\d+\.session\.log', f))
    er = open(f'{R}/{name}.stderr.log', errors='replace').read() if os.path.exists(f'{R}/{name}.stderr.log') else ''
    st = []
    try:
        for it in json.load(open(f'{R}/{name}.json'))['runs'][0]['iterations']:
            st += [s for s in it['steps'] if s.startswith(('stagingWait', 'stagingEnd'))]
    except Exception as e: st = [f'nojson {e}']
    print(name, 'file=%d' % len(pat.findall(sl)), 'stderr=%d' % len(pat.findall(er)), '|', ' '.join(st)[:200],
          '|', '; '.join(sorted(set(m.group(0) for m in re.finditer(r'Remote file materialization [^\n]{0,60}', sl))))[:200])
