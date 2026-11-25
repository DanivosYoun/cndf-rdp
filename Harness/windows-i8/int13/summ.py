#!/usr/bin/env python3
"""summ.py <results dir> <run>...: one line per run from the harness JSON (pass, key steps, staging, disconnect)."""
import json, sys, re, os
R = sys.argv[1]
KEEP = ('clipboardWaitLocalPrefix', 'clipboardExpectLocalFiles', 'clipboardExpectLocal:', 'stagingWait', 'waitDisconnected', 'reconnect', 'stagingEnd', 'clipboardSnapshotLocal')
for name in sys.argv[2:]:
    p = f'{R}/{name}.json'
    if not os.path.exists(p): print(name, 'NO-JSON'); continue
    r = json.load(open(p))['runs'][0]
    for it in r['iterations']:
        st = [s for s in it['steps'] if s.startswith(KEEP)]
        print(f"{name}#{it['iteration']} pass={r['passed']} dur={round(it['durationMs']/1000)}s shutMs={round(it.get('shutdownMs') or 0)} disc={it.get('disconnectBeforeShutdown')} | " + ' ; '.join(st))
