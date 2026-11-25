#!/usr/bin/env bash
# Exercise the actual driver functions with synthetic server and client output.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "$root/.harness-baseline-test.XXXXXXXX")"
trap 'rm -rf "$scratch"' EXIT
export HARNESS_BATCH=regression HARNESS_BIND_IP=127.0.0.1
source <(sed -e '/^case "${1:-}" in/,$d' -e "s|^ROOT_DIR=.*|ROOT_DIR='$root'|" "$root/Scripts/run-engine-harness.sh")
baseline="$root/Harness/docker/baselines"
channels="$baseline/2026-11-21-ironrdp-m3-macos/b1-channels.json"
fixture="$scratch/fixture"
mkdir -p "$fixture"
python3 - "$channels" "$fixture/channels.log" <<'PY'
import json, sys
with open(sys.argv[2], 'w') as log:
    for row in json.load(open(sys.argv[1])):
        print('K3 static channels channel_names=' + json.dumps(row['staticChannels']), file=log)
        print(f"K3 Client Info flags={row['audioInfoFlags']}", file=log)
        for name, accepted in row['audioDvc'].items():
            print(f'K3 audio DVC name="{name}" accepted={str(accepted).lower()}', file=log)
PY
cat > "$fixture/b1-keyboard.txt" <<'DATA'
keyboard_layout: 0 keyboard_type: KeyboardType(4) keyboard_subtype: 0 keyboard_functional_keys_count: 12 ime_file_name: ""
keyboard_layout: 1042 keyboard_type: KeyboardType(8) keyboard_subtype: 3 keyboard_functional_keys_count: 12 ime_file_name: ""
DATA
cat > "$fixture/b3-keyboard.txt" <<'DATA'
Loading keymap file /etc/xrdp/km-00000409.ini
Cannot find keymap file /etc/xrdp/km-00000000.ini
Loading keymap file /etc/xrdp/km-00000409.ini
Loading keymap file /etc/xrdp/km-00000412.ini
DATA
cat > "$fixture/client-keyboard.txt" <<'DATA'
RDP keyboard profile=korean layout=0x412 type=8 subtype=3 fn=12
RDP keyboard profile=standard layout=0x0 type=4 subtype=0 fn=12
DATA
free() { printf 'Mem: 100 0 0 0 0 100\n'; }
start_b1() { :; }
mac_build() { :; }
mac() { :; }
tunnel_up() { :; }
wait_port() { :; }
secrets() { printf 'HARNESS_B1_PASS=test\nHARNESS_B3_PASS=test\n' > "$WORK/secrets.env"; }
run_scenario() { printf '{"passed":true}\n' > "$WORK/results/$(basename "$1")"; }
rsync() {
  if [[ "${*: -1}" == */sessions/ ]]; then
    mkdir -p "${*: -1}"
    cp "$fixture/client-keyboard.txt" "${*: -1}run.session.log"
  fi
}
docker() {
  case "$1" in
    logs) cat "$fixture/$b1_log";;
    exec) cat "$fixture/b3-keyboard.txt";;
  esac
}
status=0
run() {
  local expected="$1" name="$2" actual
  WORK="$(mktemp -d "$scratch/run.XXXXXXXX")"
  if "$3" > "$WORK/output" 2>&1; then actual=pass; else actual=fail; fi
  if [[ "$expected" != "$actual" ]]; then
    printf '%s: expected %s, got %s\n' "$name" "$expected" "$actual" >&2
    cat "$WORK/output" >&2
    status=1
  fi
}
b1_log=channels.log
run pass 'M3 baseline match' m3_channels
sed -i.bak 's/,"rdpdr"//g; s/"rdpdr", //g; s/accepted=true/accepted=false/g' "$fixture/channels.log"
run fail 'M3 incorrect audio/channel data' m3_channels
b1_log=b1-keyboard.txt
run pass 'K1 baseline match' keyboard_fields
sed -i.bak 's/1042/1033/' "$fixture/$b1_log"
run fail 'K1 GCC layout mismatch' keyboard_fields
mv "$fixture/$b1_log.bak" "$fixture/$b1_log"
sed -i.bak 's/Loading keymap file \/etc\/xrdp\/km-00000412/Cannot find keymap file \/etc\/xrdp\/km-00000412/' "$fixture/b3-keyboard.txt"
run fail 'K1 keymap mismatch' keyboard_fields
mv "$fixture/b3-keyboard.txt.bak" "$fixture/b3-keyboard.txt"
: > "$fixture/client-keyboard.txt"
run fail 'K1 missing client fields' keyboard_fields
git -C "$root" check-ignore -q Vendor/FreeRDP/probe || status=1
exit "$status"
