#!/usr/bin/env python3
"""Collect and summarize Windows rdpclip private memory & handle samples via run-i8.sh ps.

Usage:
  rdpclip-mem.py --dry-run
  rdpclip-mem.py --once [--out <log>] [--run-i8 <path>]
  rdpclip-mem.py --interval 5 --count 12 [--out <log>] [--run-i8 <path>]
  rdpclip-mem.py --summarize <log> [--max-delta-kb 100] [--json]

Timestamps are always KST (UTC+9). Does not connect to Windows in --dry-run or --summarize mode.
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import time

KST = datetime.timezone(datetime.timedelta(hours=9), name="KST")

PS_QUERY = (
    'Get-Process rdpclip -ErrorAction SilentlyContinue | ForEach-Object { '
    '"rdpclip pid=" + $_.Id + '
    '" sess=" + $_.SessionId + '
    '" privKB=" + [math]::Round($_.PrivateMemorySize64/1KB) + '
    '" wsKB=" + [math]::Round($_.WorkingSet64/1KB) + '
    '" handles=" + $_.HandleCount }; '
    # No rdpclip (no session yet, or between logons) leaves $? false, which run-i8.sh ps reports
    # as a failure; the sample is then just empty.
    'exit 0'
)

SAMPLE_RE = re.compile(
    r"^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} KST)\s+"
    r"rdpclip\s+pid=(?P<pid>\d+)\s+sess=(?P<sess>\d+)\s+"
    r"privKB=(?P<priv_kb>\d+)\s+wsKB=(?P<ws_kb>\d+)\s+handles=(?P<handles>\d+)\s*$"
)


def default_run_i8_path() -> str:
    return os.environ.get(
        "RUN_I8",
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "run-i8.sh"),
    )


def now_kst() -> str:
    return datetime.datetime.now(KST).strftime("%Y-%m-%d %H:%M:%S KST")


def collect_once(run_i8: str, timestamp: str | None = None) -> list[str]:
    proc = subprocess.run(
        [run_i8, "ps"],
        input=PS_QUERY + "\n",
        text=True,
        capture_output=True,
        check=True,
    )
    stamp = timestamp or now_kst()
    lines = []
    for raw in proc.stdout.replace("\r", "").splitlines():
        line = raw.strip()
        if not line:
            continue
        lines.append(f"{stamp} {line}")
    if not lines:
        lines.append(f"{stamp} rdpclip none")
    return lines


def parse_samples(lines: list[str]) -> list[dict]:
    samples = []
    for line in lines:
        m = SAMPLE_RE.match(line.strip())
        if not m:
            continue
        samples.append(
            {
                "timestamp": m.group("ts"),
                "pid": int(m.group("pid")),
                "sessionId": int(m.group("sess")),
                "privKB": int(m.group("priv_kb")),
                "wsKB": int(m.group("ws_kb")),
                "handles": int(m.group("handles")),
            }
        )
    return samples


def summarize_samples(samples: list[dict]) -> dict:
    by_pid: dict[int, list[dict]] = {}
    pid_order: list[int] = []
    for s in samples:
        pid = s["pid"]
        if pid not in by_pid:
            by_pid[pid] = []
            pid_order.append(pid)
        by_pid[pid].append(s)

    per_pid = []
    max_delta_kb = 0
    for pid in pid_order:
        rows = by_pid[pid]
        privs = [r["privKB"] for r in rows]
        handles = [r["handles"] for r in rows]
        delta_max = max(privs) - privs[0]
        delta_end = privs[-1] - privs[0]
        max_delta_kb = max(max_delta_kb, delta_max)
        per_pid.append(
            {
                "pid": pid,
                "sessionId": rows[0]["sessionId"],
                "samples": len(rows),
                "firstTimestamp": rows[0]["timestamp"],
                "lastTimestamp": rows[-1]["timestamp"],
                "firstPrivKB": privs[0],
                "minPrivKB": min(privs),
                "maxPrivKB": max(privs),
                "lastPrivKB": privs[-1],
                "deltaMaxKB": delta_max,
                "deltaEndKB": delta_end,
                "minHandles": min(handles),
                "maxHandles": max(handles),
            }
        )
    return {
        "totalSamples": len(samples),
        "uniquePids": len(pid_order),
        "maxDeltaKB": max_delta_kb,
        "pids": per_pid,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Sample and summarize Windows rdpclip memory.")
    parser.add_argument("--run-i8", default=default_run_i8_path(), help="Path to run-i8.sh")
    parser.add_argument("--once", action="store_true", help="Collect one sample and exit")
    parser.add_argument("--interval", type=float, default=5.0, help="Seconds between samples (default: 5)")
    parser.add_argument("--count", type=int, default=0, help="Number of samples to collect (0 = unlimited)")
    parser.add_argument("--duration", type=float, default=0.0, help="Stop after this many seconds (0 = unlimited)")
    parser.add_argument("--out", default=None, help="Append collected sample lines to this file")
    parser.add_argument("--quiet", action="store_true", help="Do not echo sample lines to stdout")
    parser.add_argument("--dry-run", action="store_true", help="Print command & PS query without running")
    parser.add_argument("--summarize", default=None, help="Summarize an existing sample log file")
    parser.add_argument("--max-delta-kb", type=int, default=None, help="Fail --summarize if maxDeltaKB exceeds this")
    parser.add_argument("--json", action="store_true", help="Emit --summarize output as JSON")
    args = parser.parse_args(argv)

    if args.summarize is not None:
        with open(args.summarize, encoding="utf-8") as fh:
            samples = parse_samples(fh.read().splitlines())
        summary = summarize_samples(samples)
        if args.json:
            print(json.dumps(summary, ensure_ascii=False, indent=2))
        else:
            print(
                f"rdpclip-mem: samples={summary['totalSamples']} "
                f"pids={summary['uniquePids']} maxDeltaKB={summary['maxDeltaKB']}"
            )
            for row in summary["pids"]:
                print(
                    f"  pid={row['pid']} sess={row['sessionId']} n={row['samples']} "
                    f"privKB={row['firstPrivKB']}..{row['maxPrivKB']} (last={row['lastPrivKB']}, "
                    f"deltaMax={row['deltaMaxKB']:+d}KB, deltaEnd={row['deltaEndKB']:+d}KB) "
                    f"handles={row['minHandles']}..{row['maxHandles']}"
                )
        if args.max_delta_kb is not None and summary["maxDeltaKB"] > args.max_delta_kb:
            print(
                f"rdpclip-mem: FAIL maxDeltaKB={summary['maxDeltaKB']} > {args.max_delta_kb}",
                file=sys.stderr,
            )
            return 1
        return 0

    if args.dry_run:
        mode = "once" if args.once else f"interval={args.interval}s count={args.count} duration={args.duration}s"
        print(f"DRY-RUN [{now_kst()}] mode=({mode})")
        print(f"CMD: {args.run_i8} ps")
        print(f"PS: {PS_QUERY}")
        if args.out:
            print(f"OUT: {args.out}")
        return 0

    count = 1 if args.once else args.count
    if count < 0 or args.interval < 0 or args.duration < 0:
        print("rdpclip-mem: count, interval, and duration must be >= 0", file=sys.stderr)
        return 2

    out_fh = open(args.out, "a", encoding="utf-8") if args.out else None
    try:
        started = time.monotonic()
        taken = 0
        while True:
            lines = collect_once(args.run_i8)
            for line in lines:
                if not args.quiet:
                    print(line, flush=True)
                if out_fh is not None:
                    out_fh.write(line + "\n")
            if out_fh is not None:
                out_fh.flush()
            taken += 1
            if count > 0 and taken >= count:
                break
            if args.duration > 0 and (time.monotonic() - started) >= args.duration:
                break
            if args.interval > 0:
                time.sleep(args.interval)
    finally:
        if out_fh is not None:
            out_fh.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
