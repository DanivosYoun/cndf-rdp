#!/usr/bin/env python3
"""Row verdicts for the display mode of iron-share-verify (resize R rows, pixel/click P rows).

  judge-display.py <run>.windows.txt <run>.mac.jsonl  ->  one JSON line per row

Segments are split at the host's F7 markers as in judge.py. Screen and DPI lines are tracked over
the whole log, because a P row's reconnect changes them before its marker."""
import json, sys

from judge import parse, segments


def main():
    win, mac = sys.argv[1], sys.argv[2]
    mac_events = [json.loads(l) for l in open(mac) if l.strip()]
    rows = [e["row"] for e in mac_events if e["ev"] == "row"]
    events = parse(win)
    starts = [i for i, e in enumerate(events) if e["kind"] == "other" and e["text"].startswith("start run=")]
    if starts:
        events = events[starts[-1]:]
    # Screen / DPI in force at each segment start (a P row reconnects before its marker).
    state, at_start, cur = {"screen": None, "dpi": None}, [], None
    for e in events:
        if e["kind"] == "key" and e["vk"] == 0x76 and e["dir"] == "down":
            at_start.append(dict(state))
        elif e["kind"] == "screen":
            state["screen"] = e["size"]
        elif e["kind"] == "other" and e["text"].startswith("dpi "):
            state["dpi"] = int(e["text"][4:])
    segs = segments(events)
    for i, name in enumerate(rows):
        if name.endswith("END"):
            continue
        seg = segs[i] if i < len(segs) else []
        checks = {}
        if name.startswith("R-"):
            done = next(e for e in mac_events if e["ev"] == "resize_done" and e["row"] == name)
            screens = [e["size"] for e in seg if e["kind"] == "screen"]
            # The row ends with the harness resizing back to 1280x800 after resize_done.
            applied = screens[:-1] if screens and screens[-1] == "1280x800" else screens
            checks["requested_last"] = done["last"]
            checks["server_sizes"] = applied
            checks["server_final"] = applied[-1] if applied else None
            checks["frame_final"] = done["frame"]
            checks["server_final_is_last"] = checks["server_final"] == done["last"]
            checks["frame_is_last"] = done["frame"] == done["last"] and done["matchedWithin20s"]
            checks["frames_during"] = done["framesDuring"]
            checks["video_during_resize"] = done["framesDuring"] > 0
            checks["still_connected"] = done["connected"]
        elif name.startswith("P"):
            px = next(e for e in mac_events if e["ev"] == "pixels" and e["row"] == name)
            clicks = [e for e in mac_events if e["ev"] == "click" and e["row"] == name]
            downs = [e for e in seg if e["kind"] == "mouse" and e["what"] == "ldown"]
            # Expected server point: the view letterboxes the frame (aspect fit, centred), so a view
            # point maps through that fit, not through a plain stretch (equal for same-aspect rows).
            (pw, ph), (fw, fh) = (tuple(map(int, px[k].split("x"))) for k in ("points", "frame"))
            fit = min(pw / fw, ph / fh)
            ox, oy = (pw - fw * fit) / 2, (ph - fh * fit) / 2
            want = []
            for c in clicks:
                vx, vy = map(int, c["viewPoint"].split(","))
                want.append((round((vx - ox) / fit), round((vy - oy) / fit)))
            checks["stretch_would_be"] = sorted({c["expect"] for c in clicks})
            st = at_start[i] if i < len(at_start) else {}
            checks["points"], checks["backing"], checks["fixed"] = px["points"], px["backing"], px["fixed"]
            checks["frame"], checks["server_screen"], checks["server_dpi"] = px["frame"], st.get("screen"), st.get("dpi")
            checks["frame_is_server_screen"] = px["frame"] == st.get("screen")
            checks["clicks"] = len(downs)
            checks["clicks_expected"] = len(want)
            pts = [(e["x"], e["y"]) for e in downs]
            off = [(w, g) for w, g in zip(want, pts) if abs(w[0] - g[0]) > 1 or abs(w[1] - g[1]) > 1]
            checks["fit_expected"] = sorted({"%d,%d" % w for w in want})
            checks["click_positions_ok"] = len(pts) == len(want) and not off
            if off:
                checks["click_mismatch"] = off[:6]
        bools = [v for k, v in checks.items() if isinstance(v, bool)]
        print(json.dumps({"row": name, "pass": all(bools), "checks": checks}, ensure_ascii=False))
    if len(segs) != len(rows):
        print(json.dumps({"warning": "segments %d != rows %d" % (len(segs), len(rows))}))


if __name__ == "__main__":
    main()
