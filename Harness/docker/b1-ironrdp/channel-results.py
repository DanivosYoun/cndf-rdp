"""Extract advertised static channels and answers to the server's two audio DVC opens."""
import json
from pathlib import Path
import re
import sys


def parse(log):
    record = None
    for line in log.splitlines():
        static = re.search(r"K3 static channels channel_names=(\[.*\])", line)
        flags = re.search(r"K3 Client Info flags=(\d+)", line)
        dynamic = re.search(r'K3 audio DVC name="(\w+)" accepted=(true|false)', line)
        if (flags or dynamic) and not record:
            raise ValueError("received Client Info or DVC response before static channel advertisement")
        if static:
            record = {"staticChannels": sorted(json.loads(static[1])), "audioDvc": {}}
            yield record
        elif flags:
            record["audioInfoFlags"] = int(flags[1]) & 0x282000
        elif dynamic:
            record["audioDvc"][dynamic[1]] = dynamic[2] == "true"


scenario = json.loads(Path(sys.argv[1]).read_text())
records = list(parse(Path(sys.argv[2]).read_text()))
if len(records) != len(scenario["runs"]):
    sys.exit(f"expected {len(scenario['runs'])} RDP connections, found {len(records)}")
for run, record in zip(scenario["runs"], records):
    record["id"] = run["id"]
print(json.dumps(records, indent=2, sort_keys=True))
if any("audioInfoFlags" not in record or len(record["audioDvc"]) != 2 for record in records):
    sys.exit("incomplete Client Info or audio DVC observations")
