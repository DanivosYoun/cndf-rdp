#!/usr/bin/env python3
"""Row verdicts for iron-share-verify.

  judge.py <run>.windows.txt <run>.mac.jsonl  ->  one JSON line per row

The Windows log is split at every F7 press (vk 0x76) the host injected; the n-th segment is the
n-th "row" event of the Mac log. Keys are Windows VKs; a "tap" is a press of VK_HANGUL (0x15),
VK_HANJA (0x19) or right Alt (0xa5, the Han/Yeong scancode of the Korean profile on an en-US-only
server)."""
import json, re, sys
from datetime import datetime, timezone

LINE = re.compile(r"^\s*(\d+) (\d\d:\d\d:\d\d\.\d+) (.*)$")
TAPS = {0x15, 0x19, 0xa5}
MARK = 0x76


def parse(path):
    events = []
    for raw in open(path, encoding="utf-8", errors="replace"):
        m = LINE.match(raw)
        if not m:
            continue
        ms, utc, rest = int(m.group(1)), m.group(2), m.group(3)
        e = {"ms": ms, "utc": utc}
        if rest.startswith("key "):
            k = re.match(r"key (down|up) vk=0x([0-9a-f]+) scan=0x([0-9a-f]+) ext=(\d) injected=(\d)", rest)
            e.update(kind="key", dir=k.group(1), vk=int(k.group(2), 16), injected=k.group(5) == "1")
        elif rest.startswith("mouse "):
            k = re.match(r"mouse (\w+) x=(-?\d+) y=(-?\d+) delta=(-?\d+)", rest)
            e.update(kind="mouse", what=k.group(1), x=int(k.group(2)), y=int(k.group(3)), delta=int(k.group(4)))
        elif rest.startswith("held "):
            v = rest[5:].strip()
            e.update(kind="held", held=set() if v == "-" else {int(x, 16) for x in v.split(",")})
        elif rest.startswith("screen "):
            e.update(kind="screen", size=rest[7:].strip())
        else:
            e.update(kind="other", text=rest)
        events.append(e)
    return events


def segments(events):
    segs, cur = [], None
    for e in events:
        if e["kind"] == "key" and e["vk"] == MARK and e["dir"] == "down":
            cur = []
            segs.append(cur)
            continue
        if cur is not None:
            cur.append(e)
    return segs


def keys(seg):
    return [e for e in seg if e["kind"] == "key" and e["vk"] != MARK]


def seq(seg):
    return " ".join("%x%s" % (e["vk"], "d" if e["dir"] == "down" else "u") for e in keys(seg))


def idx(seg, vk, d, after=-1):
    for i, e in enumerate(seg):
        if i > after and e["kind"] == "key" and e["vk"] == vk and e["dir"] == d:
            return i
    return None


def has(seg, vk, d="down"):
    return idx(seg, vk, d) is not None


def mouse_idx(seg, what, after=-1):
    for i, e in enumerate(seg):
        if i > after and e["kind"] == "mouse" and e["what"] == what:
            return i
    return None


def final_held(seg):
    held = None
    for e in seg:
        if e["kind"] == "held":
            held = e["held"] - {MARK}
    return held


def held_between(seg, vk, start, end):
    """True if vk stays held (no up event) in seg[start:end]."""
    return all(not (e["kind"] == "key" and e["vk"] == vk and e["dir"] == "up") for e in seg[start:end])


def utc_ms(day, utc):
    h, m, s = utc.split(":")
    return int((int(h) * 3600 + int(m) * 60 + float(s)) * 1000)


def judge_row(name, seg, mac_events):
    checks = {}
    if name == "S1":
        a_up, l_up = idx(seg, 0x41, "up"), mouse_idx(seg, "lup")
        c_dn = idx(seg, 0x43, "down")
        checks["A_released"] = a_up is not None
        checks["mouse_released"] = l_up is not None
        checks["B_held_until_own_up"] = c_dn is not None and held_between(seg, 0x42, 0, (idx(seg, 0x43, "up") or 0) + 1)
        checks["B_input_after_revoke"] = c_dn is not None and a_up is not None and c_dn > a_up
        checks["revoked_D_absent"] = not has(seg, 0x44)
        ctrl_up = idx(seg, 0xa2, "up")
        checks["A_ctrl_released_with_A"] = (ctrl_up is not None and a_up is not None
                                            and abs(seg[ctrl_up]["ms"] - seg[a_up]["ms"]) <= 50)
        checks["restored_E_arrives"] = has(seg, 0x45)
    elif name == "S2":
        a_up, c_dn = idx(seg, 0x41, "up"), idx(seg, 0x43, "down")
        checks["A_released_on_leave"] = a_up is not None and (c_dn is None or a_up < c_dn)
        checks["B_held_until_own_up"] = c_dn is not None and held_between(seg, 0x42, 0, (idx(seg, 0x43, "up") or 0) + 1)
        checks["B_input_arrives"] = c_dn is not None
        checks["rejoined_E_arrives"] = has(seg, 0x45)
    elif name == "S3":
        a_up, e_dn = idx(seg, 0x41, "up"), idx(seg, 0x45, "down")
        checks["old_conn_A_released"] = a_up is not None
        checks["new_conn_E_arrives"] = e_dn is not None
        checks["old_conn_D_absent"] = not has(seg, 0x44)
        checks["B_held_until_own_up"] = has(seg, 0x43) and held_between(seg, 0x42, 0, (idx(seg, 0x43, "up") or 0) + 1)
        checks["A_release_order"] = ("before_E" if a_up is not None and e_dn is not None and a_up < e_dn else
                                    "after_E" if a_up is not None else "none")
    elif name in ("S4K", "S4T"):
        a_up, b_up, x_dn = idx(seg, 0x41, "up"), idx(seg, 0x42, "up"), idx(seg, 0x58, "down")
        checks["A_released"] = a_up is not None and (x_dn is None or a_up < x_dn)
        checks["B_released"] = b_up is not None and (x_dn is None or b_up < x_dn)
        checks["A_input_after_restart"] = x_dn is not None
        checks["B_input_after_restart"] = has(seg, 0x5a)
    elif name == "S5":
        c_dn, a_up = idx(seg, 0x43, "down"), idx(seg, 0x41, "up")
        checks["A_held_through_resize"] = c_dn is not None and held_between(seg, 0x41, 0, c_dn)
        checks["B_input_after_resize"] = c_dn is not None
        checks["A_released_by_owner"] = a_up is not None and c_dn is not None and a_up > c_dn
        checks["screens"] = [e["size"] for e in seg if e["kind"] == "screen"]
        checks["server_resized_1024x768"] = "1024x768" in checks["screens"]
    elif name == "S6":
        checks["A_released"] = has(seg, 0x41, "up")
        checks["B_released"] = has(seg, 0x42, "up")
        checks["mouse_released"] = mouse_idx(seg, "lup") is not None
    elif name.startswith("K"):
        taps = [e for e in keys(seg) if e["vk"] in TAPS and e["dir"] == "down"]
        want = 2 if name.startswith(("K5-", "K13-")) else 1
        checks["taps"] = len(taps)
        checks["taps_expected"] = want
        checks["taps_ok"] = len(taps) == want
        q = idx(seg, 0x51, "down")
        held_at_q = None
        if q is not None:
            for e in seg[q:]:
                if e["kind"] == "held":
                    held_at_q = sorted(e["held"])
                    break
        checks["Q_arrives"] = q is not None
        checks["Q_without_modifiers"] = held_at_q == [0x51]
        # A tap with Control or Alt down is a chord, not a tap (design G6/G7).
        bad = []
        down = set()
        for e in keys(seg):
            if e["dir"] == "down":
                if e["vk"] in TAPS and down & {0xa2, 0xa3, 0xa4}:
                    bad.append("%x with %s" % (e["vk"], ",".join("%x" % v for v in sorted(down))))
                down.add(e["vk"])
            else:
                down.discard(e["vk"])
        checks["tap_under_ctrl_or_alt"] = bad
    held = final_held(seg)
    checks["end_held"] = "-" if not held else ",".join("%x" % v for v in sorted(held))
    checks["end_clean"] = not held
    bools = [v for k, v in checks.items() if isinstance(v, bool)]
    return {"row": name, "pass": all(bools), "seq": seq(seg), "checks": checks}


def main():
    win, mac = sys.argv[1], sys.argv[2]
    mac_events = [json.loads(l) for l in open(mac) if l.strip()]
    rows = [e["row"] for e in mac_events if e["ev"] == "row"]
    events = parse(win)
    starts = [i for i, e in enumerate(events) if e["kind"] == "other" and e["text"].startswith("start run=")]
    if starts:  # an earlier run under the same name appended to the same file
        events = events[starts[-1]:]
    segs = segments(events)
    for i, name in enumerate(rows):
        if name.endswith("END"):
            continue
        seg = segs[i] if i < len(segs) else []
        short = name.split("-")[0] if name.startswith("S") else name
        out = judge_row(short if name.startswith("S") else name, seg, mac_events)
        out["row"] = name
        print(json.dumps(out, ensure_ascii=False))
    if len(segs) != len(rows):
        print(json.dumps({"warning": "segments %d != rows %d" % (len(segs), len(rows))}))


if __name__ == "__main__":
    main()
