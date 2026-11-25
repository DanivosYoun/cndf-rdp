#!/usr/bin/env python3
"""Summarize Win2022 H.264 CPU windows with a session-level bootstrap."""

import argparse
import json
import random
import re
from pathlib import Path
from statistics import median


def load_windows(folder, prefix):
    run = json.loads((folder / "result.json").read_text())["runs"][0]
    iteration = run["iterations"][0]
    windows = iteration["cpuWindows"]
    if not run["passed"] or iteration.get("disconnectBeforeShutdown"):
        raise ValueError("session failed")
    if "build/test processes: 0" not in (folder / "mac-load.txt").read_text():
        raise ValueError("Mac was busy")
    if (folder / "windows.log").read_text().count("anim start s=45") != 1:
        raise ValueError("expected exactly one server animation")
    engine = run["engine"]
    session_log = (folder / f"{run['id']}-1.session.log").read_text()
    if engine == "ironrdp":
        codec = r"H\.264 summary pictures=[1-9]\d*"
    elif prefix == "default":
        codec = r"Graphics: summary .*\bAVC420=[1-9]\d*"
    else:
        codec = r"Graphics: summary .*\bAVC444(?:v2)?=[1-9]\d*"
    if not re.search(codec, session_log):
        raise ValueError("session did not receive the expected H.264 stream")
    if [window["seconds"] for window in windows] != [5, 9, 9, 9]:
        raise ValueError("expected one idle window and three animation windows")
    frames = [window["framesReceived"] for window in windows[1:]]
    if min(frames) <= 0:
        raise ValueError("empty animation window")
    cpu = [window["userMs"] + window["systemMs"] for window in windows[1:]]
    return engine, list(zip(cpu, frames))


def measures(sessions):
    windows = [window for session in sessions for window in session]
    return (
        median(cpu for cpu, _ in windows),
        median(cpu / frames for cpu, frames in windows),
        sum(cpu for cpu, _ in windows) / sum(frames for _, frames in windows),
    )


def ratios(iron, free):
    return [a / b for a, b in zip(measures(iron), measures(free))]


def summarize(root, prefix):
    sessions = {"ironrdp": {}, "freerdp": {}}
    skipped = {}
    for folder in sorted(root.glob(f"{prefix}-cpu-*")):
        try:
            engine, windows = load_windows(folder, prefix)
        except (FileNotFoundError, ValueError) as error:
            skipped[folder.name] = str(error)
            continue
        sessions[engine][folder.name] = windows

    labels = ("cpu_ms_median", "ms_per_frame_median", "ms_per_frame_weighted")
    report = {"engines": {}, "skipped": skipped}
    for engine, runs in sessions.items():
        if runs:
            report["engines"][engine] = {
                "sessions": runs,
                "measures": dict(zip(labels, measures(runs.values()))),
            }
    iron, free = (list(sessions[engine].values()) for engine in sessions)
    if min(len(iron), len(free)) >= 8:
        rng = random.Random(17)
        draws = [ratios(rng.choices(iron, k=len(iron)), rng.choices(free, k=len(free)))
                 for _ in range(10000)]
        report["ratios"] = {}
        for name, point, samples in zip(labels, ratios(iron, free), zip(*draws)):
            ordered = sorted(samples)
            report["ratios"][name] = {"point": point, "95_percent": [ordered[249], ordered[9749]]}
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("prefix")
    args = parser.parse_args()
    print(json.dumps(summarize(args.root, args.prefix), indent=2))
