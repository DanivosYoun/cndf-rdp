#!/usr/bin/env python3
"""Writes the int-13 Windows scenarios that scenarios_int11.py / scenarios_lock.py do not cover.

    scenarios_int13.py <out dir>

  x1-noop      X-1: probe SetText, and as soon as the text is on the Mac board a local copy
               "I8CMD noop <k>" (an unknown verb the probe only logs), x20. A later remote write
               shows as the board going back to the remote text in the WATCH lines.
  x3-order     X-3: probe copies A and B 700 ms apart (verb settext2); the Mac copies M 100 ms after
               A reaches the board, so B comes about 500 ms after M. x3.
  x5-cut       X-5: A, M 100 ms later, then a network cut (run with CUT_AFTER/CUT_RESTORE) and a
               reconnect; the probe log shows what the Windows clipboard holds afterwards.
  x7-diag      X-7: like int-11 W4 (Mac copy d ms after a remote copy reached the board,
               d = 0/100/300/450/600/800, x3) for three sources: .NET SetText (control), Notepad
               Ctrl+C, Explorer Ctrl+C of one file.
  lw7-reconnect  L-W7: 10 connections to one Windows logon, each takes a file copy (a lock) and
               closes without unlocking; run with I8_NO_LOGOFF=1 so the logon and rdpclip stay.
  lw7-gw1x5    L-W7: then G-W1 other-name B, five delays, in a reconnected session.
"""
import base64, json, os, sys

out = sys.argv[1]
os.makedirs(out, exist_ok=True)

def b64(text):
    return base64.b64encode(text.encode()).decode()

def cmd(text):
    return {"op": "clipboardSetLocal", "text": "I8CMD " + text}

READY = {"op": "clipboardWaitLocalPrefix", "prefix": "I8READY", "timeout": 60}
HEAD = [{"op": "connect"}, {"op": "waitConnected", "timeout": 40}, {"op": "waitFirstFrame", "timeout": 40}]
A40 = "|".join(rf"C:\i8\src\gw1A\f{i:02d}.bin" for i in range(40))

def write(name, steps, tail=None, expect=None, **extra):
    run = {"id": name, "host": "127.0.0.1", "port": 33389, "username": "Administrator",
           "passwordEnv": "I8_PASS", "enableClipboard": True,
           "steps": HEAD + steps + (tail if tail is not None else [{"op": "shutdown"}]),
           "expect": expect or {"connected": True, "firstFrame": True}}
    run.update(extra)
    json.dump({"name": name, "runs": [run]}, open(os.path.join(out, name + ".json"), "w"), ensure_ascii=False)

x1 = [READY]
for k in range(20):
    r = f"X1-r-{k}"
    x1 += [cmd("settext " + b64(r)), {"op": "clipboardExpectLocal", "text": r, "timeout": 15},
           cmd(f"noop {k}"), {"op": "watch", "seconds": 2}]
write("x1-noop", x1)

x3 = [READY]
for k in range(3):
    a, b, m = f"X3-A-{k}", f"X3-B-{k}", f"X3-M-{k}"
    x3 += [cmd(f"settext2 {b64(a)} 700 {b64(b)}"), {"op": "clipboardExpectLocal", "text": a, "timeout": 15},
           {"op": "idle", "seconds": 0.1}, {"op": "clipboardSetLocal", "text": m}, {"op": "watch", "seconds": 4},
           {"op": "clipboardSnapshotLocal", "prefix": f"x3-{k}"}]
write("x3-order", x3)

write("x5-cut", [READY, cmd("settext " + b64("X5-A")), {"op": "clipboardExpectLocal", "text": "X5-A", "timeout": 15},
    {"op": "idle", "seconds": 0.1}, {"op": "clipboardSetLocal", "text": "X5-M"},
    {"op": "waitDisconnected", "timeout": 90}, {"op": "reconnect", "timeout": 60}, {"op": "watch", "seconds": 8},
    {"op": "clipboardSnapshotLocal", "prefix": "after-reconnect"}],
    expect={"connected": True, "firstFrame": True, "disconnect": "error"})

x7 = [READY]
for src in ["net", "notepad", "explorer"]:
    for d in [0, 100, 300, 450, 600, 800]:
        for i in range(1, 4):
            r, m = f"X7-{src}-{d}-{i}", f"X7-m-{src}-{d}-{i}"
            if src == "explorer":
                x7 += [cmd("excopy " + b64(r"C:\i8\src\multi\small.txt")),
                       {"op": "clipboardExpectLocalFiles", "count": 1, "timeout": 20}]
            else:
                x7 += [cmd(("settext " if src == "net" else "notepad ") + b64(r)),
                       {"op": "clipboardExpectLocal", "text": r, "timeout": 20}]
            x7 += [{"op": "idle", "seconds": d / 1000}, {"op": "clipboardSetLocal", "text": m}, {"op": "idle", "seconds": 3}]
write("x7-diag", x7)

write("lw7-reconnect", [{"op": "idle", "seconds": 4}, cmd("files " + b64(A40)),
    {"op": "clipboardExpectLocalFiles", "count": 40, "timeout": 60}, {"op": "idle", "seconds": 1}], repeat=10)

gw = [{"op": "idle", "seconds": 4}]
for k, ms in enumerate([50, 150, 300, 500, 1000]):
    gw += [cmd(f"mix {k} {ms} gw1C g"), {"op": "watch", "seconds": 6}, {"op": "clipboardSnapshotLocal", "prefix": f"mix{k}"}]
write("lw7-gw1x5", gw)
