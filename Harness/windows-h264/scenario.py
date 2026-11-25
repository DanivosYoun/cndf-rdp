#!/usr/bin/env python3
"""Generate a Win2022 H.264 scenario for rdp-engine-harness."""

import argparse
import json


def command(text):
    return {"op": "clipboardSetLocal", "text": "I8CMD " + text}


def idle(seconds):
    return {"op": "idle", "seconds": seconds}


def cpu(seconds):
    return {"op": "cpuWindow", "seconds": seconds, "scanCode": 42}


def scenario(name, mode, width, height):
    steps = [
        {"op": "connect"},
        {"op": "waitConnected", "timeout": 40},
        {"op": "waitFirstFrame", "timeout": 40},
        {"op": "clipboardWaitLocalPrefix", "prefix": "I8READY", "timeout": 60},
        idle(10),
    ]
    if mode == "cpu":
        steps += [cpu(5), command("anim 45"), idle(3), cpu(9), cpu(9), cpu(9), idle(2)]
    elif mode in ("codec", "refine", "video-frame"):
        settle = 40 if mode == "refine" else 10
        animation = [command("anim 12"), idle(14), command(f"pattern 1500 {settle * 1000}")]
        if mode == "video-frame":
            # Replace the moving picture before the server leaves video encoding.
            animation = [command("anim 16"), idle(9), command("pattern 0 10000")]
        steps += [
            *animation,
            {"op": "dumpFrame", "seconds": 4, "timeout": 30, "scanCode": 42},
            {"op": "clipboardWaitLocalPrefix", "prefix": "I8DONE pattern", "timeout": 60},
        ]
    elif mode == "resize":
        steps += [command("anim 32"), idle(3)]
        burst = [(1104, 704), (900, 650), (1200, 760), (1000, 720), (1180, 740)]
        for delay, final in [(0.12, (1060, 690)), (0.4, (1160, 720))]:
            for w, h in burst:
                steps.append({"op": "resize", "width": w, "height": h, "seconds": delay})
            w, h = final
            steps.append({"op": "resize", "width": w, "height": h, "seconds": 5})
    elif mode == "4k":
        steps += [command("anim 16"), idle(17)]
    else:  # 4K CPU observation on the uninstrumented build
        steps += [command("anim 16"), idle(3), cpu(9), idle(2)]
    steps.append({"op": "shutdown"})
    return {"name": name, "runs": [{
        "id": name, "host": "127.0.0.1", "port": 33390,
        "username": "Administrator", "passwordEnv": "I8_PASS",
        "enableClipboard": True, "window": {"width": width, "height": height},
        "steps": steps, "expect": {"connected": True, "firstFrame": True},
    }]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("name")
    parser.add_argument(
        "mode", choices=["codec", "refine", "video-frame", "cpu", "resize", "4k", "4k-cpu"]
    )
    parser.add_argument("width", type=int)
    parser.add_argument("height", type=int)
    options = parser.parse_args()
    print(json.dumps(scenario(options.name, options.mode, options.width, options.height), indent=2))
