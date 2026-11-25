#!/usr/bin/env bash
# wb1run.sh <name> [VAR=VAL ...]: one clipexp logon from Linux (direct 3389), then logoff and fetch the probe log.
source ~/.cache/int15-win-184c94d7/env.sh
name=$1; shift; envs=(); for kv in "$@"; do envs+=(-e "$kv"); done
mkdir -p $W/wb1/exp
printf 'Set-Content -NoNewline -Path C:\\i8\\runid.txt -Value "%s"\n' "$name" | $R ps >/dev/null
docker exec "${envs[@]}" -e PWFILE=/w/pw wb1-build-184c94d7 timeout 1200 /w/target/release/examples/clipexp > $W/wb1/exp/$name.log 2> $W/wb1/exp/$name.err || echo "clipexp exit $?" >> $W/wb1/exp/$name.err
$R logoff >/dev/null 2>&1 || true
printf '$p = "C:\\i8\\out\\%s.log"; if (Test-Path $p) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($p)) }\n' "$name" | $R ps | tr -d '\r\n' | base64 -d > $W/wb1/exp/$name.probe.log 2>/dev/null || true
grep -c '^SUM' $W/wb1/exp/$name.log; grep '^SUM' $W/wb1/exp/$name.log | grep -o 'verdict=[A-Z]*' | sort | uniq -c; tail -2 $W/wb1/exp/$name.err
