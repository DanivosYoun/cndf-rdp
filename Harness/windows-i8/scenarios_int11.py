#!/usr/bin/env python3
"""Writes the int-11 Windows scenarios (download-lifecycle G-W*, file-copy W*, existing M*) for run-i8.sh.

    scenarios_int11.py <out dir> <Mac source dir>

Windows sources come from setup plus int11-sources.ps1; Mac sources: 폴더M, multi/, big-m.bin,
gw7/ (folder `x\\` with f.txt, file `a\\b.txt`), m2empty/빈폴더단독, big-3g.bin. The harness ops
watch / stagingWait / waitDisconnected / reconnect / clipboardSnapshotLocal are on this branch.
"""
import base64, json, os, sys

out, src = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)

def b64(text):
    return base64.b64encode(text.encode()).decode()

def cmd(text):
    return {"op": "clipboardSetLocal", "text": "I8CMD " + text}

READY = {"op": "clipboardWaitLocalPrefix", "prefix": "I8READY", "timeout": 60}
HEAD = [{"op": "connect"}, {"op": "waitConnected", "timeout": 40}, {"op": "waitFirstFrame", "timeout": 40}]
BIG = r"C:\i8\src\big.bin"

def write(name, steps, tail=None, expect=None, **extra):
    run = {"id": name, "host": "127.0.0.1", "port": 33389, "username": "Administrator",
           "passwordEnv": "I8_PASS", "enableClipboard": True,
           "steps": HEAD + steps + (tail if tail is not None else [{"op": "shutdown"}]),
           "expect": expect or {"connected": True, "firstFrame": True}}
    run.update(extra)
    json.dump({"name": name, "runs": [run]}, open(os.path.join(out, name + ".json"), "w"), ensure_ascii=False)

def paste(leaf, paths, timeout=180):
    return [READY, cmd("paste " + leaf), {"op": "idle", "seconds": 5},
            {"op": "clipboardSetLocalFiles", "paths": paths},
            {"op": "clipboardWaitLocalPrefix", "prefix": "I8DONE", "timeout": timeout}]

# G-W3 / W1 / W2 / W2b: normal copies started by the double Format List of SetFileDropList
write("gw3-1g", [READY, cmd("files " + b64(BIG)), {"op": "clipboardExpectLocalFiles", "count": 1, "timeout": 900}])
write("gw3-multi", [READY, cmd("files " + b64(r"C:\i8\src\multi\small.txt|C:\i8\src\multi\한글이름.txt|C:\i8\src\multi\mid.bin")),
    {"op": "clipboardExpectLocalFiles", "count": 3, "timeout": 60}, {"op": "idle", "seconds": 3}])
write("gw3-folder", [READY, cmd("files " + b64(r"C:\i8\src\폴더W")),
    {"op": "clipboardExpectLocalFiles", "count": 1, "timeout": 60}, {"op": "idle", "seconds": 3},
    {"op": "clipboardSnapshotLocal", "prefix": "after3s"}],
    tail=[{"op": "shutdown"}, {"op": "clipboardSnapshotLocal", "prefix": "aftershutdown"}])

# G-W1: set A then set B (same names and sizes, other bytes) after a delay, ten delays
mix = [READY]
for k, ms in enumerate([50, 100, 150, 200, 250, 300, 400, 500, 700, 1000]):
    mix += [cmd(f"mix {k} {ms}"), {"op": "watch", "seconds": 6}, {"op": "clipboardSnapshotLocal", "prefix": f"mix{k}"}]
write("gw1-mix", mix)
# G-W1 variant: set B has other names (g00..g39), so a stale answer shows as a name/content mismatch
mixc = [READY]
for k, ms in enumerate([50, 100, 150, 200, 250, 300, 400, 500, 700, 1000]):
    mixc += [cmd(f"mix {k} {ms} gw1C g"), {"op": "watch", "seconds": 6}, {"op": "clipboardSnapshotLocal", "prefix": f"mix{k}"}]
write("gw1-mixc", mixc)

# G-W2 / W6a / M5: SetImage 15 s into a 1 GiB copy
write("gw2-img", [READY, cmd(f"fileimg {b64(BIG)} 15000"), {"op": "watch", "seconds": 30},
    {"op": "clipboardSnapshotLocal", "prefix": "after"}, {"op": "stagingWait", "timeout": 2}])

# G-W4: network cut during a 1 GiB copy (CUT_AFTER), tunnel back (CUT_RESTORE), reconnect
write("gw4-cut", [READY, cmd("files " + b64(BIG)), {"op": "waitDisconnected", "timeout": 120},
    {"op": "stagingWait", "timeout": 2}, {"op": "watch", "seconds": 8}, {"op": "reconnect", "timeout": 60},
    {"op": "watch", "seconds": 20}, {"op": "clipboardSnapshotLocal", "prefix": "after-reconnect"}],
    expect={"connected": True, "firstFrame": True, "disconnect": "error"})

# G-W5 / W3: window close during a 1 GiB copy; window close right after a 0-byte copy
write("gw5-close", [READY, cmd("files " + b64(BIG)), {"op": "idle", "seconds": 30}],
    tail=[{"op": "shutdown"}, {"op": "stagingWait", "timeout": 2}])
# The board is recorded right before the close: a 0-byte file already on the board is the
# board's (it stays), one that is not must be gone 2 s after the close.
write("gw5-zero", [READY, cmd("files " + b64(r"C:\i8\src\zero.bin")), {"op": "idle", "seconds": 0.15},
    {"op": "clipboardSnapshotLocal", "prefix": "beforeclose"}],
    tail=[{"op": "shutdown"}, {"op": "stagingWait", "timeout": 2}])
# W3: network cut without reconnect
write("w3-cut", [READY, cmd("files " + b64(BIG)), {"op": "waitDisconnected", "timeout": 120},
    {"op": "stagingWait", "timeout": 2}], expect={"connected": True, "firstFrame": True, "disconnect": "error"})

# G-W6: 300 empty top folders + 300 folders holding one 1 KiB file
gw6 = "|".join([rf"C:\i8\src\gw6\e{k:03d}" for k in range(300)] + [rf"C:\i8\src\gw6\d{k:03d}" for k in range(300)])
write("gw6-600", [READY, cmd("files " + b64(gw6)), {"op": "clipboardExpectLocalFiles", "count": 600, "timeout": 300}])

# G-W7: Mac names with a backslash
write("gw7-bslash", paste("gw7-bslash", [f"{src}/gw7/x\\", f"{src}/gw7/a\\b.txt"]))

# W6b: Mac local text copy during a 1 GiB copy
write("w6b-local", [READY, cmd("files " + b64(BIG)), {"op": "idle", "seconds": 15},
    {"op": "clipboardSetLocal", "text": "W6B-로컬-텍스트"}, {"op": "watch", "seconds": 10},
    {"op": "clipboardSnapshotLocal", "prefix": "after"}, {"op": "stagingWait", "timeout": 2}, {"op": "idle", "seconds": 3}])

# W4 diagnosis: Mac copy d ms after a received remote text; then the same with a re-advertise at +700 ms
w4 = [READY]
for d in [0, 100, 300, 450, 600, 800]:
    for i in range(1, 4):
        r, m = f"W4-r-{d}-{i}", f"W4-m-{d}-{i}"
        w4 += [cmd("settext " + b64(r)), {"op": "clipboardExpectLocal", "text": r, "timeout": 15},
               {"op": "idle", "seconds": d / 1000}, {"op": "clipboardSetLocal", "text": m}, {"op": "idle", "seconds": 3}]
for i in range(1, 4):
    r, m = f"W4-r-re-{i}", f"W4-m-re-{i}"
    w4 += [cmd("settext " + b64(r)), {"op": "clipboardExpectLocal", "text": r, "timeout": 15},
           {"op": "idle", "seconds": 0.3}, {"op": "clipboardSetLocal", "text": m}, {"op": "idle", "seconds": 0.7},
           {"op": "clipboardSetLocal", "text": m}, {"op": "idle", "seconds": 3}]
write("w4-diag", w4)

# M1 / M2 / M3 (Mac -> Windows)
write("m1-folder", paste("m1-folder", [f"{src}/폴더M"]))
write("m2-empty", paste("m2-empty", [f"{src}/m2empty/빈폴더단독"]))
write("m3-multi", paste("m3-multi", [f"{src}/multi/small.txt", f"{src}/multi/한글이름.txt", f"{src}/multi/mid.bin"]))
write("m3-1g", paste("m3-1g", [f"{src}/big-m.bin"], timeout=1100))
write("m3-close", [READY, cmd("paste m3-close"), {"op": "idle", "seconds": 5},
    {"op": "clipboardSetLocalFiles", "paths": [f"{src}/big-m.bin"]}, {"op": "idle", "seconds": 40}])
write("m3-cut", [READY, cmd("paste m3-cut"), {"op": "idle", "seconds": 5},
    {"op": "clipboardSetLocalFiles", "paths": [f"{src}/big-m.bin"]}, {"op": "idle", "seconds": 120}],
    expect={"connected": True, "firstFrame": True, "disconnect": "error"})
# (5) Mac -> Windows file over 2 GiB
write("big3g", paste("big3g", [f"{src}/big-3g.bin"], timeout=1100))

# M4: files then text (and the reverse) 20 ms apart, five times each
m4 = [READY]
for k in range(1, 6):
    m4 += [cmd(f"flip ft {k} 20"), {"op": "idle", "seconds": 4}, {"op": "clipboardSnapshotLocal", "prefix": f"ft{k}"},
           cmd(f"flip tf {k} 20"), {"op": "idle", "seconds": 4}, {"op": "clipboardSnapshotLocal", "prefix": f"tf{k}"}]
write("m4-flip", m4)

# M6: the copied source is opened exclusively / deleted 10 s into the copy
write("m6-hold", [READY, cmd(f"hold {b64(BIG)} 10000 40000"), {"op": "watch", "seconds": 45},
    {"op": "clipboardSnapshotLocal", "prefix": "after"}, {"op": "stagingWait", "timeout": 2}])
write("m6-del", [READY, cmd(f"del {b64(r'C:\i8\src\big2.bin')} 10000"), {"op": "watch", "seconds": 40},
    {"op": "clipboardSnapshotLocal", "prefix": "after"}, {"op": "stagingWait", "timeout": 2}])
# M7: an 8 MiB source cut to 3 MiB 200 ms after the copy
write("m7-trunc", [READY, cmd(f"trunc {b64(r'C:\i8\src\m7.bin')} 200 3145728"), {"op": "watch", "seconds": 20},
    {"op": "clipboardSnapshotLocal", "prefix": "after"}, {"op": "stagingWait", "timeout": 2}])

# M8: rapid Mac copies (int-8 dbg-rapid): one, five back to back, then a last one
write("m8-rapid", [READY, {"op": "clipboardSetLocal", "text": "M2W-단일"}, {"op": "idle", "seconds": 3}]
    + [{"op": "clipboardSetLocal", "text": f"M2W-빠른-{k}"} for k in range(1, 6)]
    + [{"op": "idle", "seconds": 10}, {"op": "clipboardSetLocal", "text": "M2W-끝"}, {"op": "idle", "seconds": 3}])
