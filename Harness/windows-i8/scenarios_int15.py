#!/usr/bin/env python3
"""Writes the int-15 Windows scenarios (L-W5 first, staging-package rows) for run-i8.sh.

    scenarios_int15.py <out dir> <Mac source dir>

Mac sources (made by the int-15 fixture script): 폴더M, multi/, small20/s20.txt (20 B),
big-m.bin, pkg/P (X.app with nested Helper.app and a link, Note.rtfd, Plug.bundle,
Proj.xcodeproj, rubyapp/.bundle, Empty.app, normal.txt), pkg/L (links: file, directory, broken,
node_modules/.bin), pkg/rootlink.txt (a link as the selected root), pkg/D (a path past 259
UTF-16 units), pkg/BigPkg.app (300 MiB inside a package) and /tmp/i8pkg-184c94d7 (A3).
"""
import base64, json, os, sys

out, src = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
TMP = "/tmp/i8pkg-184c94d7"
P, L = f"{src}/pkg/P", f"{src}/pkg/L"

def cmd(text):
    return {"op": "clipboardSetLocal", "text": "I8CMD " + text}

READY = {"op": "clipboardWaitLocalPrefix", "prefix": "I8READY", "timeout": 60}
HEAD = [{"op": "connect"}, {"op": "waitConnected", "timeout": 40}, {"op": "waitFirstFrame", "timeout": 40}]

def write(name, steps, expect=None):
    run = {"id": name, "host": "127.0.0.1", "port": 33389, "username": "Administrator",
           "passwordEnv": "I8_PASS", "enableClipboard": True,
           "steps": HEAD + steps + [{"op": "shutdown"}],
           "expect": expect or {"connected": True, "firstFrame": True}}
    json.dump({"name": name, "runs": [run]}, open(os.path.join(out, name + ".json"), "w"), ensure_ascii=False)

def finder(leaf, paths, timeout=180):
    # Finder copy: the general pasteboard + the product's poll (pollLocalClipboard).
    return [READY, cmd("paste " + leaf), {"op": "idle", "seconds": 5},
            {"op": "clipboardSetLocalFiles", "paths": paths},
            {"op": "clipboardWaitLocalPrefix", "prefix": "I8DONE", "timeout": timeout}]

def drop(leaf, paths, timeout=180):
    # Drop: performDragOperation -> sendLocalFiles -> the product's own Ctrl+V into Explorer.
    return [READY, cmd("droppaste " + leaf), {"op": "idle", "seconds": 6},
            {"op": "dropLocalFiles", "paths": paths},
            {"op": "clipboardWaitLocalPrefix", "prefix": "I8DONE", "timeout": timeout}]

# L-W5 (measured first): 20-byte file alone, folder, several files, 1 GiB
write("lw5-small20", finder("lw5-small20", [f"{src}/small20/s20.txt"]))
write("lw5-folder", finder("lw5-folder", [f"{src}/폴더M"]))
write("lw5-multi", finder("lw5-multi", [f"{src}/multi/small.txt", f"{src}/multi/한글이름.txt", f"{src}/multi/mid.bin"]))
write("lw5-1g", finder("lw5-1g", [f"{src}/big-m.bin"], timeout=1100))

# staging-package: Finder direct / parent / mixed / drop, links, /tmp (A3), long name (A1)
write("pk-direct", finder("pk-direct", [f"{P}/X.app"]))
write("pk-parent", finder("pk-parent", [P]))
write("pk-mixed", finder("pk-mixed", [f"{P}/X.app", f"{P}/Note.rtfd", f"{P}/normal.txt", f"{src}/pkg/rootlink.txt"]))
write("pk-drop", drop("pk-drop", [P]))
write("pk-dropmixed", drop("pk-dropmixed", [f"{P}/Plug.bundle", f"{P}/normal.txt", f"{src}/pkg/rootlink.txt"]))
write("pk-links", finder("pk-links", [L]))
write("pk-droplinks", drop("pk-droplinks", [L]))
write("pk-tmp", finder("pk-tmp", [f"{TMP}/T", f"{TMP}/t1.txt"]))
write("pk-long", finder("pk-long", [f"{src}/pkg/D"]))
# link only: no offer (Finder: the Windows board keeps the command text; drop: no Ctrl+V)
write("pk-linkonly", [READY, cmd("paste pk-linkonly"), {"op": "idle", "seconds": 5},
    {"op": "clipboardSetLocalFiles", "paths": [f"{src}/pkg/rootlink.txt"]}, {"op": "idle", "seconds": 20}])
write("pk-droplinkonly", drop("pk-droplinkonly", [f"{src}/pkg/rootlink.txt"]))
# a big package cancelled on Windows, then a normal copy in the same session
write("pk-cancel", [READY, cmd("pastecancel pk-cancel 20000"), {"op": "idle", "seconds": 5},
    {"op": "clipboardSetLocalFiles", "paths": [f"{src}/pkg/BigPkg.app"]},
    {"op": "clipboardWaitLocalPrefix", "prefix": "I8DONE", "timeout": 300}]
    + finder("pk-after-cancel", [f"{src}/multi/small.txt", f"{src}/multi/mid.bin"])[1:])
