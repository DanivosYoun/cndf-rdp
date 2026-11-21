#!/usr/bin/env python3
"""Judges one B5 run on the Linux side (server-memory design, K8).

    judge.py <scenario.json> <result.json> <server.log> [<attack session log>]

Footprint growth = attack run physFootprintMaxBytes - warm-up run physFootprintMaxBytes (the
warm-up run connects to the same server, gets one frame and idles: the harness exposes only the
per-run maximum, so the warm-up maximum stands in for the design's "first 5 s baseline").
PASS needs all of:
  budget   growth <= pathBudgetBytes + marginBytes (design D1 path budget + 64 MiB)
  warmup   the warm-up run connected and showed its first frame
  outcome  "connected": the attack run stayed connected until the harness shut it down;
           "ended": the session ended with a classified failure or disconnect reason
  log      logPattern (if set) appears in the attack run's session log
Prints one JSON verdict and exits 0 on PASS, 1 on FAIL.
"""
import json
import re
import sys

MIB = 1024 * 1024


def main():
    scenario_path, result_path, server_log_path = sys.argv[1:4]
    session_log_path = sys.argv[4] if len(sys.argv) > 4 else None
    scenario = json.load(open(scenario_path))
    b5 = scenario["b5"]
    result = json.load(open(result_path))
    runs = {run["id"]: run for run in result["runs"]}
    warmup = runs["warmup"]["iterations"][0]
    attack = runs["attack"]["iterations"][0]

    growth = attack["physFootprintMaxBytes"] - warmup["physFootprintMaxBytes"]
    limit = b5["pathBudgetBytes"] + b5["marginBytes"]
    checks = {"budget": growth <= limit}
    checks["warmup"] = bool(warmup.get("connected")) and warmup.get("firstFrameMs") is not None

    ended = attack.get("failure") or attack.get("disconnectBeforeShutdown")
    if b5["outcome"] == "connected":
        checks["outcome"] = bool(attack.get("connected")) and not ended
    else:
        checks["outcome"] = bool(ended)

    log_lines = []
    if b5.get("logPattern"):
        if session_log_path:
            try:
                log_lines = [line.strip() for line in open(session_log_path, errors="replace")
                             if b5["logPattern"] in line]
            except FileNotFoundError:
                pass
        checks["log"] = bool(log_lines)

    server = open(server_log_path, errors="replace").read()
    attack_line = next((line for line in server.splitlines() if " attack=" in line and "connection=" in line), None)
    wire = None
    if attack_line:
        match = re.search(r" wire=(\d+)", attack_line)
        wire = int(match.group(1)) if match else None

    verdict = {
        "scenario": scenario["name"],
        "attack": b5["attack"],
        "args": b5["args"],
        "warmupFootprintMaxBytes": warmup["physFootprintMaxBytes"],
        "attackFootprintMaxBytes": attack["physFootprintMaxBytes"],
        "growthBytes": growth,
        "growthMiB": round(growth / MIB, 1),
        "limitBytes": limit,
        "limitMiB": round(limit / MIB, 1),
        "wireBytes": wire,
        "serverAttackLine": attack_line,
        "attackConnected": attack.get("connected"),
        "attackFailure": attack.get("failure"),
        "attackFailureDetail": attack.get("failureDetail"),
        "attackDisconnectBeforeShutdown": attack.get("disconnectBeforeShutdown"),
        "attackFramesReceived": attack.get("framesReceived"),
        "attackSteps": attack.get("steps"),
        "expectedOutcome": b5["outcome"],
        "logPattern": b5.get("logPattern"),
        "logLines": log_lines[:3],
        "checks": checks,
        "passed": all(checks.values()),
    }
    print(json.dumps(verdict, indent=2))
    return 0 if verdict["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
