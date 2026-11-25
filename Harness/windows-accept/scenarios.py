#!/usr/bin/env python3
"""Generate rdp-engine-harness inputs for the Windows acceptance rows."""

import argparse
import base64
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("output", type=Path)
parser.add_argument("mac_fixture_dir")
parser.add_argument("--port", type=int, required=True)
parser.add_argument("--domain", required=True, help="Windows computer name for local NLA")
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)


def step(op, **fields):
    return dict(op=op, **fields)


def encoded(text):
    return base64.b64encode(text.encode()).decode()


def command(text):
    return step("clipboardSetLocal", text="I8CMD " + text)


def files(path):
    return command("files " + encoded(path))


CONNECT = [
    step("connect"),
    step("waitConnected", timeout=20),
    step("waitFirstFrame", timeout=25),
]
READY = step("clipboardWaitLocalPrefix", prefix="I8READY", timeout=25)
WIN_FILE = r"C:\i8\src\한글-win.txt"
SIZES = [
    [(1100, 700), (900, 650), (1200, 760), (1000, 720), (1180, 740), (1060, 690)],
    [(1024, 768), (1280, 720), (960, 640), (1240, 780), (1120, 700), (1300, 820)],
    [(1180, 760), (1000, 600), (1260, 800), (1080, 700), (940, 660), (1160, 720)],
]


def run(name, steps, *, password_env="I8_PASS", log_level="debug", **fields):
    return dict(
        id=name,
        host="127.0.0.1",
        port=args.port,
        username="Administrator",
        domain=args.domain,
        passwordEnv=password_env,
        enableClipboard=True,
        logLevel=log_level,
        steps=steps + [step("shutdown")],
        **fields,
    )


def write(name, *runs):
    scenario = json.dumps(dict(name=name, runs=runs), ensure_ascii=False, indent=2)
    (args.output / (name + ".json")).write_text(scenario + "\n", encoding="utf-8")


def trust(name, callback=None):
    expect = dict(connected=True, firstFrame=True)
    if callback:
        expect["trustCallbacks"] = [callback]
    return run(name, CONNECT + [step("idle", seconds=2)], expect=expect)


def wrong_password(name):
    return run(
        name,
        [step("connect"), step("idle", seconds=4)],
        password_env="I8_BAD",
        expect=dict(connected=False, failure="authenticationFailed"),
    )


def reject_certificate(name):
    return run(
        name,
        [step("connect"), step("idle", seconds=4)],
        promptAnswer="deny",
        expect=dict(
            connected=False,
            trustCallbacks=["changed"],
            prompts=1,
            failure="certificateRejected",
        ),
    )


write("trust", trust("trust-1", "new"), trust("trust-2", "same"), trust("trust-3", "same"))
write("trust-free", trust("trust-free"))
write("bad", *(wrong_password(f"bad-{i}") for i in range(1, 4)))
write("bad-free", wrong_password("bad-free"))
write("changed", *(reject_certificate(f"changed-{i}") for i in range(1, 4)))
write("changed-free", reject_certificate("changed-free"))


def feature(name, label, steps, **fields):
    case = f"{name}-{label}"
    write(case, run(case, CONNECT + steps, **fields))


for label in ("iron-1", "iron-2", "iron-3", "free-1"):
    mac = args.mac_fixture_dir
    feature("gfx", label, [step("idle", seconds=3)], log_level="trace")
    feature("text", label, [
        READY,
        step("clipboardSetLocal", text="M2W 한글 🎵 텍스트"),
        step("idle", seconds=2),
        command("settext " + encoded("W2M 한글 🎵 텍스트")),
        step("clipboardExpectLocal", text="W2M 한글 🎵 텍스트", timeout=12),
    ])
    feature("w2m", label, [
        READY, files(WIN_FILE), step("clipboardExpectLocalFiles", count=1, timeout=20),
    ])
    feature("m2w", label, [
        READY,
        command("paste " + label),
        step("idle", seconds=4),
        step("clipboardSetLocalFiles", paths=[f"{mac}/한글-mac.txt"]),
        step("clipboardWaitLocalPrefix", prefix="I8DONE", timeout=50),
    ])
    feature("cancel", label, [
        READY,
        command(f"pastecancel cancel-{label} 1200"),
        step("idle", seconds=4),
        step("clipboardSetLocalFiles", paths=[f"{mac}/cancel.bin"]),
        step("clipboardWaitLocalPrefix", prefix="I8DONE", timeout=45),
    ])
    feature("sound", label, [
        READY, command("sound 8"), step("audioExpectWaves", minWaves=1, timeout=15),
    ], audioMode=1)
    feature("wheel", label, [
        step("idle", seconds=5),
        step("keys", text="click:300,150 wait:500"),
        step("scroll", scrollUnit="line", scrollDeltas=[1, 1, 1, -1, -1, -1],
             pointerX=300, pointerY=150, intervalMs=200),
        step("scroll", scrollUnit="line", scrollDeltas=[0, 0, 0, 0], scrollDeltasX=[1, 1, -1, -1],
             pointerX=300, pointerY=150, intervalMs=200),
        step("idle", seconds=2),
    ])
    feature("ime", label, [
        step("idle", seconds=8),
        step("keys", text="click:100,40 f7 ropt wait:800 f7 ropt wait:800 f7", seconds=1),
    ], keyboardProfile="korean")
    feature("drive", label, [step("idle", seconds=9)], shareHome=True)
    feature("reconnect", label, [
        step("idle", seconds=5),
        step("waitDisconnected", timeout=10),
        step("idle", seconds=8),
        step("reconnect", timeout=25),
        step("waitFirstFrame", timeout=15),
        step("idle", seconds=2),
    ])
    feature("cut", label, [
        READY,
        files(r"C:\i8\src\cut.bin"),
        step("watch", seconds=9),
        step("waitDisconnected", timeout=10),
        step("idle", seconds=5),
        step("reconnect", timeout=25),
        step("idle", seconds=4),
        files(WIN_FILE),
        step("clipboardExpectLocalFiles", count=1, timeout=20),
    ])

    resize = [step("idle", seconds=5)]
    for sequence in SIZES:
        for gap in (0.12, 0.4):
            for i, (width, height) in enumerate(sequence):
                seconds = 5 if i == len(sequence) - 1 else gap
                resize.append(step("resize", width=width, height=height, seconds=seconds))
            resize.append(step("resize", width=1280, height=800, seconds=1))
    feature("resize", label, resize)
