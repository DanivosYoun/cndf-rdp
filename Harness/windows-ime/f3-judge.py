#!/usr/bin/env python3
"""F3 (Hangul follow design V-W): splits one probe log into rows and counts what the server saw.

  f3-judge.py <run>.windows.txt <label> [<label>...]

The row scripts in run-f3.sh start every row with an F7 tap (vk 0x76), so the log between the
n-th and the (n+1)-th F7 down belongs to the n-th label. Per row it prints the Han/Yeong (vk 0x15),
Space (0x20), RMENU (0xa5) and LMENU (0xa4) key downs, MenuStrip activations, foreground menu-mode
entries, the IME native-mode values the focused box went through, and the last foreground-window IME
line. Output is one JSON object per row.
"""
import json
import re
import sys


def main():
    path, labels = sys.argv[1], sys.argv[2:]
    text = open(path, encoding="utf-8", errors="replace").read()
    keys = text.split("=== keys.log", 1)[-1].split("=== state.txt", 1)[0]
    state = text.split("=== state.txt", 1)[1] if "=== state.txt" in text else ""
    rows, current = [], None
    for line in keys.splitlines():
        if re.search(r"key down vk=0x76 ", line):
            current = {"lines": []}
            rows.append(current)
            continue
        if current is not None:
            current["lines"].append(line)
    for index, label in enumerate(labels):
        lines = rows[index]["lines"] if index < len(rows) else None
        if lines is None:
            print(json.dumps({"row": label, "missing": True}))
            continue
        down = lambda vk: sum(1 for l in lines if re.search(r"key down vk=0x%s " % vk, l) and "vk=0x76" not in l)
        natives = [m.group(1) for l in lines for m in [re.search(r"\bime \S+ open=\d conv=0x[0-9a-f]+ native=(\d)", l)] if m]
        fgime = [l.split("fgime ", 1)[1] for l in lines if " fgime " in l]
        inmenu = sum(1 for l in lines if " menumode " in l and l.endswith("inmenu=1"))
        print(json.dumps({
            "row": label, "vk15": down("15"), "space": down("20"), "rmenu": down("a5"), "lmenu": down("a4"),
            "menuActivate": sum(1 for l in lines if " menu activate " in l), "inMenuMode": inmenu,
            "native": natives, "fgime": fgime[-1] if fgime else None,
            "windows": [l.split(None, 1)[1] for l in lines if " window new " in l or " console " in l],
        }, ensure_ascii=False))
    print(json.dumps({"state": dict(l.split("=", 1) for l in state.strip().splitlines() if "=" in l)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
