#!/usr/bin/env python3
"""Writes the clip-lock (int-13, L-W1..L-W9) Windows scenarios for run-i8.sh.

    scenarios_lock.py <out dir> <Mac source dir> [--burst-watch-seconds 6] [--recopy-delay 45]

Requires setup plus int11-sources.ps1 on Windows, and big-m.bin + multi/mid.bin under
<Mac source dir> on the Mac. All ops match Sources/RDPEngineHarness/Scenario.swift.
"""
import argparse
import base64
import json
import os
import sys

MIN_BURST_WATCH_SECONDS = 6.0
GW1_DELAYS_MS = [50, 100, 150, 200, 250, 300, 400, 500, 700, 1000]
READY = {"op": "clipboardWaitLocalPrefix", "prefix": "I8READY", "timeout": 60}
HEAD = [
    {"op": "connect"},
    {"op": "waitConnected", "timeout": 40},
    {"op": "waitFirstFrame", "timeout": 40},
]


def b64(text: str) -> str:
    return base64.b64encode(text.encode("utf-8")).decode("ascii")


def cmd(text: str) -> dict:
    return {"op": "clipboardSetLocal", "text": "I8CMD " + text}


def gw1_a_paths() -> str:
    return "|".join(rf"C:\i8\src\gw1A\f{i:02d}.bin" for i in range(40))


def build_scenario(name: str, steps: list, tail=None, expect=None, **extra) -> dict:
    run = {
        "id": name,
        "host": "127.0.0.1",
        "port": 33389,
        "username": "Administrator",
        "passwordEnv": "I8_PASS",
        "enableClipboard": True,
        "steps": HEAD + steps + (tail if tail is not None else [{"op": "shutdown"}]),
        "expect": expect or {"connected": True, "firstFrame": True},
    }
    run.update(extra)
    return {"name": name, "runs": [run]}


def generate_scenarios(
    src: str,
    burst_watch_seconds: float = 6.0,
    recopy_delay_seconds: float = 45.0,
    recopy_replacement: str | None = None,
) -> dict[str, dict]:
    if burst_watch_seconds < MIN_BURST_WATCH_SECONDS:
        raise ValueError(
            f"burst watch seconds must be >= {MIN_BURST_WATCH_SECONDS} "
            f"(got {burst_watch_seconds}; trace §3.5 showed 2.4s is too short for B download)"
        )
    if recopy_delay_seconds <= 0:
        raise ValueError(f"recopy delay seconds must be > 0 (got {recopy_delay_seconds})")

    replacement = recopy_replacement or f"{src}/multi/mid.bin"
    scenarios: dict[str, dict] = {}

    # L-W1 / L-W4: G-W1 same-name B (20 trials = 10 delays x 2 rounds), watch 6 s
    mix20 = [READY]
    for k, ms in enumerate(GW1_DELAYS_MS * 2):
        mix20 += [
            cmd(f"mix {k} {ms}"),
            {"op": "watch", "seconds": 6},
            {"op": "clipboardSnapshotLocal", "prefix": f"mix{k}"},
        ]
    scenarios["gw1-mix20"] = build_scenario("gw1-mix20", mix20)

    # L-W1 / L-W4: G-W1 other-name B (20 trials = 10 delays x 2 rounds), watch 6 s
    mixc20 = [READY]
    for k, ms in enumerate(GW1_DELAYS_MS * 2):
        mixc20 += [
            cmd(f"mix {k} {ms} gw1C g"),
            {"op": "watch", "seconds": 6},
            {"op": "clipboardSnapshotLocal", "prefix": f"mix{k}"},
        ]
    scenarios["gw1-mixc20"] = build_scenario("gw1-mixc20", mixc20)

    # L-W3: 60 burst trials (240 file FLs), watch >= 6 s so B finishes before snapshot
    burst60 = [READY]
    for k in range(60):
        burst60 += [
            cmd(f"mix {k} 300 gw1C g"),
            {"op": "watch", "seconds": burst_watch_seconds},
            {"op": "clipboardSnapshotLocal", "prefix": f"mix{k}"},
        ]
    scenarios["gw1-burst60"] = build_scenario("gw1-burst60", burst60)

    # L-W6: Mac->Windows 1 GiB paste interrupted ~30% in by a Mac re-copy of another file.
    # Run 3 times via run-i8.sh (logoff between runs clears any Explorer error dialog).
    scenarios["lw6-m2w-recopy"] = build_scenario(
        "lw6-m2w-recopy",
        [
            READY,
            cmd("paste lw6-m2w-recopy"),
            {"op": "idle", "seconds": 5},
            {"op": "clipboardSetLocalFiles", "paths": [f"{src}/big-m.bin"]},
            {"op": "idle", "seconds": recopy_delay_seconds},
            {"op": "clipboardSetLocalFiles", "paths": [replacement]},
            {"op": "watch", "seconds": 15},
            {"op": "clipboardSnapshotLocal", "prefix": "after-recopy"},
            {"op": "clipboardWaitLocalPrefix", "prefix": "I8DONE", "timeout": 600},
        ],
    )

    # L-W7: 10 reconnects while holding an active file lock (each iteration acquires a lock
    # and shuts down without unlocking).
    scenarios["lw7-lock-reconnect"] = build_scenario(
        "lw7-lock-reconnect",
        [
            READY,
            cmd("files " + b64(gw1_a_paths())),
            {"op": "clipboardExpectLocalFiles", "count": 40, "timeout": 60},
        ],
        repeat=10,
    )

    # L-W9: 10 normal single copies of 40 x 64 KiB files (no contention)
    norm40 = [READY]
    files_cmd = cmd("files " + b64(gw1_a_paths()))
    for k in range(10):
        norm40 += [
            files_cmd,
            {"op": "watch", "seconds": 6},
            {"op": "clipboardSnapshotLocal", "prefix": f"copy{k}"},
        ]
    scenarios["norm40"] = build_scenario("norm40", norm40)

    return scenarios


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Generate clip-lock (L-W1..L-W9) harness scenarios.")
    parser.add_argument("out_dir", help="Output directory for scenario JSON files")
    parser.add_argument("mac_src_dir", help="Mac source directory holding big-m.bin and multi/mid.bin")
    parser.add_argument(
        "--burst-watch-seconds",
        type=float,
        default=6.0,
        help="Watch duration per trial in gw1-burst60 (must be >= 6.0; default: 6.0)",
    )
    parser.add_argument(
        "--recopy-delay",
        type=float,
        default=45.0,
        help="Seconds after starting 1 GiB paste before Mac re-copies another file (default: 45.0)",
    )
    parser.add_argument(
        "--recopy-replacement",
        default=None,
        help="Mac file path copied mid-paste in lw6-m2w-recopy (default: <mac_src_dir>/multi/mid.bin)",
    )
    args = parser.parse_args(argv)

    try:
        scenarios = generate_scenarios(
            args.mac_src_dir,
            burst_watch_seconds=args.burst_watch_seconds,
            recopy_delay_seconds=args.recopy_delay,
            recopy_replacement=args.recopy_replacement,
        )
    except ValueError as exc:
        print(f"scenarios_lock.py: {exc}", file=sys.stderr)
        return 2

    os.makedirs(args.out_dir, exist_ok=True)
    for name, payload in scenarios.items():
        path = os.path.join(args.out_dir, f"{name}.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False)
            fh.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
