#!/usr/bin/env python3
"""Writes the int-8 Windows normal-path scenarios (rows a-e) for run-i8.sh.

    scenarios.py <out dir> <Mac source dir>

<Mac source dir> holds the Mac->Windows fixtures: folder 폴더M (nested folder, Korean names, an
empty folder) and big-m.bin (1 GiB). Commands to the Windows probe (i8probe.ps1) travel as
copied text "I8CMD ..." through the session clipboard.
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

def write(name, steps, clipboard=True, expect=None, **extra):
    run = {"id": name, "host": "127.0.0.1", "port": 33389, "username": "Administrator",
           "passwordEnv": "I8_PASS", "enableClipboard": clipboard,
           "steps": HEAD + steps + [{"op": "shutdown"}],
           "expect": expect or {"connected": True, "firstFrame": True}}
    run.update(extra)
    json.dump({"name": name, "runs": [run]}, open(os.path.join(out, name + ".json"), "w"), ensure_ascii=False)

# (a) connect + five Display Control resizes, 1080p / 4K, egfx on (auto) / off (compat)
sizes = {"1080p": ((1920, 1080), [(1600, 900), (1920, 1080), (1280, 720), (1920, 1200), (1920, 1080)]),
         "4k": ((3840, 2160), [(3200, 1800), (3840, 2160), (2560, 1440), (3840, 2400), (3840, 2160)])}
for res, (base, steps) in sizes.items():
    for gfx in ("auto", "compat"):
        write(f"a-{res}-{gfx}",
              [{"op": "idle", "seconds": 5}] + [{"op": "resize", "width": w, "height": h, "seconds": 5} for w, h in steps]
              + [{"op": "idle", "seconds": 2}],
              clipboard=False, window={"width": base[0], "height": base[1]}, graphicsMode=gfx,
              expect={"connected": True, "firstFrame": True, "resizeKeepsSession": True})

# (b) text both ways with Korean and an emoji, then five back-to-back copies each way
w2m = "W2M 한글 🎵 텍스트"
write("b-text", [READY,
    {"op": "clipboardSetLocal", "text": "M2W 한글 🎵 텍스트"}, {"op": "idle", "seconds": 2},
    cmd("settext " + b64(w2m)), {"op": "clipboardExpectLocal", "text": w2m, "timeout": 15},
    # A Mac copy within ~300 ms of a received remote copy is lost on Windows (both engines,
    # int-8 dbg-window); the burst starts 1 s later so it measures the burst alone.
    {"op": "idle", "seconds": 1},
    ] + [{"op": "clipboardSetLocal", "text": f"M2W-연속-{k}"} for k in range(1, 6)] + [{"op": "idle", "seconds": 3},
    cmd("burst 5 " + b64("W2M-연속")), {"op": "clipboardExpectLocal", "text": "W2M-연속-5", "timeout": 15},
    {"op": "idle", "seconds": 2}])

# (c) files
write("c-w2m-1g", [READY, cmd("files " + b64(r"C:\i8\src\big.bin")),
    {"op": "clipboardExpectLocalFiles", "count": 1, "timeout": 900}])
write("c-w2m-multi", [READY, cmd("files " + b64(r"C:\i8\src\multi\small.txt|C:\i8\src\multi\한글이름.txt|C:\i8\src\multi\mid.bin")),
    {"op": "clipboardExpectLocalFiles", "count": 3, "timeout": 60}])
write("c-w2m-folder", [READY, cmd("files " + b64(r"C:\i8\src\폴더W")),
    {"op": "clipboardExpectLocalFiles", "count": 1, "timeout": 60}, {"op": "idle", "seconds": 3}])
write("c-m2w-folder", [READY, cmd("paste c-m2w-folder"), {"op": "idle", "seconds": 5},
    {"op": "clipboardSetLocalFiles", "paths": [f"{src}/폴더M"]},
    {"op": "clipboardWaitLocalPrefix", "prefix": "I8DONE", "timeout": 180}])
write("c-m2w-multi", [READY, cmd("paste c-m2w-multi"), {"op": "idle", "seconds": 5},
    {"op": "clipboardSetLocalFiles", "paths": [f"{src}/multi/small.txt", f"{src}/multi/한글이름.txt", f"{src}/multi/mid.bin"]},
    {"op": "clipboardWaitLocalPrefix", "prefix": "I8DONE", "timeout": 180}])
# interruptions: window close (shutdown) or network cut (run-i8.sh CUT_AFTER) while a 1 GiB copy runs
write("c-w2m-close", [READY, cmd("files " + b64(r"C:\i8\src\big.bin")), {"op": "idle", "seconds": 30}],
      expect={"connected": True, "firstFrame": True})
write("c-w2m-cut", [READY, cmd("files " + b64(r"C:\i8\src\big.bin")),
    {"op": "clipboardExpectLocalFiles", "count": 1, "timeout": 120}], expect={"connected": True, "firstFrame": True})
write("c-m2w-close", [READY, cmd("paste c-m2w-close"), {"op": "idle", "seconds": 5},
    {"op": "clipboardSetLocalFiles", "paths": [f"{src}/big-m.bin"]}, {"op": "idle", "seconds": 40}])
write("c-m2w-cut", [READY, cmd("paste c-m2w-cut"), {"op": "idle", "seconds": 5},
    {"op": "clipboardSetLocalFiles", "paths": [f"{src}/big-m.bin"]}, {"op": "idle", "seconds": 120}])

# (d) sound played locally
write("d-sound", [READY, cmd("sound 20"), {"op": "audioExpectWaves", "minWaves": 20, "timeout": 30},
    {"op": "idle", "seconds": 5}], audioMode=1)

# (e) vertical then horizontal wheel over the probe form (it logs WM_MOUSEWHEEL / WM_MOUSEHWHEEL)
write("e-scroll", [READY, {"op": "keys", "text": "click:300,150 wait:500"},
    {"op": "scroll", "scrollUnit": "line", "scrollDeltas": [1, 1, 1, -1, -1, -1], "pointerX": 300, "pointerY": 150, "intervalMs": 200},
    {"op": "scroll", "scrollUnit": "line", "scrollDeltas": [0, 0, 0, 0], "scrollDeltasX": [1, 1, -1, -1], "pointerX": 300, "pointerY": 150, "intervalMs": 200},
    {"op": "idle", "seconds": 2}])
