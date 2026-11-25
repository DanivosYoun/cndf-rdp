"""Emit one RDP harness run so that one packet observation maps to one result."""
import argparse
import json

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("engine", choices=("ironrdp", "freerdp"))
parser.add_argument("case", choices=("frame", "wrong-password", "reject-cert"))
parser.add_argument("id")
args = parser.parse_args()
frame = args.case == "frame"
failure = {"wrong-password": "authenticationFailed", "reject-cert": "certificateRejected"}
expect = {"connected": frame, "firstFrame": frame}
if not frame:
    expect["failure"] = failure[args.case]
if args.case == "reject-cert":
    expect["trustCallbacks"] = ["changed"]
    expect["prompts"] = 1

print(json.dumps({
    "name": args.id,
    "engine": args.engine,
    "runs": [{
        "id": args.id,
        "host": "127.0.0.1",
        "port": 33389,
        "username": "Administrator",
        "passwordEnv": "LEGACY_TLS_PASSWORD",
        "logLevel": "debug",
        "promptAnswer": "deny",
        "steps": [
            {"op": "connect"},
            {"op": "waitFirstFrame", "timeout": 25},
            {"op": "shutdown"},
        ],
        "expect": expect,
    }],
}, indent=2))
