#!/usr/bin/env python3
"""expect.py <scenario dir> : on the Mac, the Windows tree each Mac->Windows scenario should make,
by the staging-package rule (links skipped and counted, dirs + regular files offered, a name past
259 UTF-16 units skipped with its subtree). Prints one JSON object {scenario: {entries, omitted}}."""
import hashlib, json, os, stat, sys, unicodedata
def sha(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''): h.update(b)
    return h.hexdigest()
def walk(path, name, ents, om):
    st = os.lstat(path)
    if stat.S_ISLNK(st.st_mode) or len(name.encode('utf-16-le')) // 2 > 259 or not (stat.S_ISDIR(st.st_mode) or stat.S_ISREG(st.st_mode)):
        om[0] += 1; return
    nm = unicodedata.normalize('NFC', name)
    if stat.S_ISDIR(st.st_mode):
        ents[nm] = 'dir'
        for c in sorted(os.listdir(path)): walk(os.path.join(path, c), name + '\\' + c.replace('\\', '_'), ents, om)
    else:
        ents[nm] = f'{st.st_size}:{sha(path)}'
res = {}
for f in sorted(os.listdir(sys.argv[1])):
    sc = json.load(open(os.path.join(sys.argv[1], f)))
    for st_ in sc['runs'][0]['steps']:
        if st_['op'] in ('clipboardSetLocalFiles', 'dropLocalFiles'):
            ents, om = {}, [0]
            for p in st_['paths']: walk(p, os.path.basename(p).replace('\\', '_'), ents, om)
            res.setdefault(f[:-5], []).append({'op': st_['op'], 'entries': ents, 'omitted': om[0]})
json.dump(res, sys.stdout, ensure_ascii=False, indent=0)
