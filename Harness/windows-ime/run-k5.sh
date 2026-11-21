#!/usr/bin/env bash
# K5 Windows IME end-to-end test (Korean input design V4), driven from the Linux Docker host.
#
#   K5_BATCH=<roster batch> K5_PASSWORD_FILE=<file> Harness/windows-ime/run-k5.sh setup|run <name> <engine> <profile> <op> <script> [<op> <script>...]|fetch <name>|logoff|teardown
#
# The Windows server only accepts the Linux egress, so WinRM (python:3.12-alpine + pywinrm, NTLM
# with message encryption) runs here and the Mac reaches 3389 through one reverse tunnel
# (-R 127.0.0.1:33389:<server>:3389); its PID is recorded and only that PID is killed.
# setup: upload probe.ps1, register the AtLogOn interactive task K5ImeProbe, record the
# Administrator language list; teardown: remove the task and C:\k5, restore the language list,
# log off, stop the tunnel and the WinRM container. The Mac side is rdp-engine-harness built
# from this tree in $K5_MAC_DIR. The F3 follow tokens (KeyScript follow/src) use RDPClientView's
# internal test hook, so build it with `swift build -c release --product rdp-engine-harness
# -Xswiftc -enable-testing`.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${K5_BATCH:?set K5_BATCH}"
: "${K5_PASSWORD_FILE:?set K5_PASSWORD_FILE (Administrator password, never on the command line)}"
SERVER="${K5_SERVER:-158.247.237.175}"
WORK="${K5_WORK:-${HOME}/.cache/k5-${K5_BATCH}}"
MAC="${K5_MAC:-danivosy@192.168.3.105}"
MAC_DIR="${K5_MAC_DIR:-xcode-work/k5-${K5_BATCH}}"
CONTAINER="k5-winrm-${K5_BATCH}"
mkdir -p "${WORK}/results" "${WORK}/ps"
chmod 700 "${WORK}"

log() { printf '[k5 %s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
mac() { ssh -o BatchMode=yes "${MAC}" "$@"; }

winrm_up() {
  docker inspect "${CONTAINER}" >/dev/null 2>&1 && return
  cp "${K5_PASSWORD_FILE}" "${WORK}/pw"; chmod 600 "${WORK}/pw"
  cat > "${WORK}/wr.py" <<'PY'
import sys, winrm
s = winrm.Session('http://%s:5985/wsman' % sys.argv[1], auth=('Administrator', open('/k5/pw').read().strip()),
                  transport='ntlm', message_encryption='auto')
r = s.run_ps(open(sys.argv[2], encoding='utf-8').read())
sys.stdout.write(r.std_out.decode('utf-8', 'replace'))
if r.status_code != 0:
    sys.stderr.write(r.std_err.decode('utf-8', 'replace')[:4000])
sys.exit(r.status_code)
PY
  docker run -d --label "roster.batch=${K5_BATCH}" -m 512m --name "${CONTAINER}" -v "${WORK}:/k5" python:3.12-alpine sleep 14400 >/dev/null
  docker exec "${CONTAINER}" pip install -q pywinrm >/dev/null 2>&1
}

# Runs PowerShell from stdin on the server.
ps() {
  local file
  file="$(mktemp "${WORK}/ps/XXXXXX.ps1")"
  cat > "${file}"
  docker exec "${CONTAINER}" python /k5/wr.py "${SERVER}" "/k5/ps/$(basename "${file}")"
  rm -f "${file}"
}

upload() { # <local file> <remote path>
  local b64 chunk i=0
  b64="$(base64 -w0 "$1")"
  printf 'if (Test-Path "%s.b64") { Remove-Item -Force "%s.b64" }\n' "$2" "$2" | ps
  while [[ -n "${b64:i:1}" ]]; do
    chunk="${b64:i:2000}"
    printf 'Add-Content -NoNewline -Path "%s.b64" -Value "%s"\n' "$2" "${chunk}" | ps
    i=$((i + 2000))
  done
  printf '[IO.File]::WriteAllBytes("%s", [Convert]::FromBase64String((Get-Content -Raw "%s.b64"))); Remove-Item "%s.b64"\n' "$2" "$2" "$2" | ps
}

tunnel_up() {
  [[ -f "${WORK}/tunnel.pid" ]] && kill -0 "$(cat "${WORK}/tunnel.pid")" 2>/dev/null && return
  ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 \
    -R "127.0.0.1:33389:${SERVER}:3389" "${MAC}" > "${WORK}/tunnel.log" 2>&1 &
  echo $! > "${WORK}/tunnel.pid"
  sleep 3
  kill -0 "$(cat "${WORK}/tunnel.pid")" || { cat "${WORK}/tunnel.log" >&2; return 1; }
  log "tunnel pid $(cat "${WORK}/tunnel.pid")"
}

logoff() {
  ps <<'PS'
$ids = (quser 2>$null | Select-Object -Skip 1 | ForEach-Object { ($_ -replace '^>', ' ').Trim() -split '\s+' } | Where-Object { $_ -match '^\d+$' })
foreach ($line in (quser 2>$null | Select-Object -Skip 1)) {
  $f = ($line -replace '^>', ' ').Trim() -split '\s+'
  $id = $f | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1
  if ($id) { logoff $id }
}
for ($i = 0; $i -lt 30; $i++) { if (-not (quser 2>$null)) { 'sessions=0'; break }; Start-Sleep 1 }
PS
}

setup() {
  winrm_up
  ps <<'PS'
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force C:\k5\out | Out-Null
if (-not (Test-Path C:\k5\lang-before.json)) {
  Get-WinUserLanguageList | ForEach-Object { [pscustomobject]@{ Tag = $_.LanguageTag; Tips = @($_.InputMethodTips) } } |
    ConvertTo-Json -Depth 3 | Set-Content -Encoding UTF8 C:\k5\lang-before.json
}
'lang-before=' + (Get-Content -Raw C:\k5\lang-before.json)
PS
  upload "${ROOT_DIR}/Harness/windows-ime/probe.ps1" 'C:\k5\probe.ps1'
  ps <<'PS'
$ErrorActionPreference = 'Stop'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\k5\probe.ps1'
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:COMPUTERNAME\Administrator"
$principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\Administrator" -LogonType Interactive
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
Register-ScheduledTask -TaskName K5ImeProbe -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
'task=' + (Get-ScheduledTask K5ImeProbe).State
PS
  tunnel_up
}

korean_on() {
  ps <<'PS'
$l = Get-WinUserLanguageList
if (-not ($l | Where-Object LanguageTag -eq 'ko')) { $l.Add('ko-KR'); Set-WinUserLanguageList $l -Force }
Get-WinUserLanguageList | ForEach-Object { "$($_.LanguageTag) | $($_.InputMethodTips -join ',')" }
PS
}

# run <name> <engine> <profile> <op> <script> [<op> <script>...]: one RDP logon on the Mac, the
# key steps in order, then fetch and log off.
run() {
  local name="$1" engine="$2" profile="$3" op="$4"
  shift 3
  printf 'Set-Content -NoNewline -Path C:\\k5\\runid.txt -Value "%s"\n' "${name}" | ps
  python3 - "${WORK}/results/${name}.scenario.json" "${name}" "${profile}" "$@" <<'PY'
import json, sys
path, name, profile = sys.argv[1:4]
pairs = sys.argv[4:]
keys = [{"op": pairs[i], "text": pairs[i + 1], "seconds": 3} for i in range(0, len(pairs), 2)]
json.dump({"name": name, "runs": [{
    "id": name, "host": "127.0.0.1", "port": 33389, "username": "Administrator", "passwordEnv": "K5_PASS",
    "keyboardProfile": profile,
    "steps": [{"op": "connect"}, {"op": "waitConnected", "timeout": 40}, {"op": "waitFirstFrame", "timeout": 40},
              {"op": "idle", "seconds": 40}] + keys + [{"op": "shutdown"}],
    "expect": {"connected": True, "firstFrame": True}}]}, open(path, "w"))
PY
  rsync -a --mkpath --rsync-path=/opt/homebrew/bin/rsync "${WORK}/results/${name}.scenario.json" "${MAC}:${MAC_DIR}/scenarios/"
  log "run ${name} engine=${engine} profile=${profile} op=${op}"
  set +e
  mac "set -a; source \$HOME/${MAC_DIR}/k5.env; set +a; M=\$HOME/${MAC_DIR}; mkdir -p \$M/home \$M/work \$M/results
    HOME=\$M/home \$M/cndf-rdp/.build/release/rdp-engine-harness --scenario \$M/scenarios/${name}.scenario.json \
      --out \$M/results/${name}.json --engine ${engine} --trust-suite cndf.rdp-engine-harness.k5-${K5_BATCH} --work-dir \$M/work" \
    > "${WORK}/results/${name}.stdout.log" 2> "${WORK}/results/${name}.stderr.log"
  set -e
  rsync -a --rsync-path=/opt/homebrew/bin/rsync "${MAC}:${MAC_DIR}/results/${name}.json" "${WORK}/results/" 2>/dev/null || true
  rsync -a --rsync-path=/opt/homebrew/bin/rsync "${MAC}:${MAC_DIR}/work/${name}-1.session.log" "${WORK}/results/" 2>/dev/null || true
  # Log off first: the probe holds its key log open until its session ends.
  logoff >/dev/null
  fetch "${name}"
  log "run ${name}: $(tail -1 "${WORK}/results/${name}.stdout.log" 2>/dev/null)"
}

# WinRM output goes through the OEM code page, so the UTF-8 files travel as base64.
fetch() {
  printf '$o = "C:\\k5\\out\\%s"; foreach ($e in "keys.log", "state.txt") { if (Test-Path "$o.$e") { "=== $e"; [Convert]::ToBase64String([IO.File]::ReadAllBytes("$o.$e")) } }\n' "$1" | ps \
    | python3 -c 'import base64, re, sys
for part in re.split(r"^(=== .*)$", sys.stdin.read(), flags=re.M):
    if part.startswith("==="): print(part)
    elif part.strip(): sys.stdout.write(base64.b64decode("".join(part.split())).decode("utf-8", "replace"))' > "${WORK}/results/$1.windows.txt" || true
}

# The language list recorded by setup, restored (teardown, and between the C4 sets).
LANG_RESTORE='if (Test-Path C:\k5\lang-before.json) {
  $before = Get-Content -Raw C:\k5\lang-before.json | ConvertFrom-Json
  $list = New-WinUserLanguageList @($before)[0].Tag
  foreach ($entry in @($before) | Select-Object -Skip 1) { $list.Add($entry.Tag) }
  Set-WinUserLanguageList $list -Force
}'

korean_off() {
  { printf '%s\n' "${LANG_RESTORE}"; echo "Get-WinUserLanguageList | ForEach-Object { 'lang=' + \$_.LanguageTag + ' | ' + (\$_.InputMethodTips -join ',') }"; } | ps
}

teardown() {
  winrm_up
  logoff || true
  { echo 'Unregister-ScheduledTask -TaskName K5ImeProbe -Confirm:$false -ErrorAction SilentlyContinue'; printf '%s\n' "${LANG_RESTORE}"; cat <<'PS'; } | ps || true
Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID -and $_.SessionId -ne 0 } | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force C:\k5 -ErrorAction SilentlyContinue
'task=' + [bool](Get-ScheduledTask K5ImeProbe -ErrorAction SilentlyContinue)
'k5dir=' + (Test-Path C:\k5)
Get-WinUserLanguageList | ForEach-Object { 'lang=' + $_.LanguageTag + ' | ' + ($_.InputMethodTips -join ',') }
'quser=' + [bool](quser 2>$null)
PS
  if [[ -f "${WORK}/tunnel.pid" ]]; then kill "$(cat "${WORK}/tunnel.pid")" 2>/dev/null || true; rm -f "${WORK}/tunnel.pid"; fi
  mac "defaults delete cndf.rdp-engine-harness.k5-${K5_BATCH} >/dev/null 2>&1; rm -f \$HOME/${MAC_DIR}/k5.env" || true
  docker rm -fv "${CONTAINER}" >/dev/null 2>&1 || true
  rm -f "${WORK}/pw" "${WORK}/wr.py"
}

case "${1:-}" in
  setup) setup ;;
  korean-on) winrm_up; korean_on ;;
  korean-off) winrm_up; korean_off ;;
  run) winrm_up; tunnel_up; shift; run "$@" ;;
  fetch) winrm_up; fetch "$2" ;;
  logoff) winrm_up; logoff ;;
  teardown) teardown ;;
  *) echo "usage: $0 setup|korean-on|korean-off|run <name> <engine> <profile> <op> <script>|fetch <name>|logoff|teardown" >&2; exit 2 ;;
esac
