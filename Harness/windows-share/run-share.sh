#!/usr/bin/env bash
# iron-share-verify driver, run on the Linux Docker host (after Harness/windows-ime/run-k5.sh).
#
#   ISV_BATCH=<batch> ISV_PASSWORD_FILE=<file> ISV_MAC_DIR=<mac dir> Harness/windows-share/run-share.sh \
#     setup | run <name> <mode share|display> <engine ironRDP|freeRDP> [VAR=value ...] | fetch <name> | logoff | teardown
#
# The isolated relay (postgres + control-plane + session-relay containers, plain HTTP on
# 127.0.0.1:${ISV_RELAY_PORT}) and the relay control endpoint (relay-control.py, ${ISV_CONTROL_PORT})
# run on this host. One ssh process carries three reverse forwards to the Mac: Windows 3389,
# the relay and the control endpoint; its PID is recorded and only that PID is killed.
# WinRM is python:3.12-alpine + pywinrm (NTLM, message encryption) in a labelled container.
# The Mac side runs IronShareVerifyTests (in an app working copy at ${ISV_MAC_DIR}/app) through
# `swift test --skip-build`, holding ~/xcode-work/.swift.lock.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${ISV_BATCH:?set ISV_BATCH}"
: "${ISV_PASSWORD_FILE:?set ISV_PASSWORD_FILE}"
: "${ISV_MAC_DIR:?set ISV_MAC_DIR (relative to the Mac home)}"
SERVER="${ISV_SERVER:-158.247.237.175}"
WORK="${ISV_WORK:-${HOME}/.cache/iron-share-${ISV_BATCH}/run}"
MAC="${ISV_MAC:-danivosy@192.168.3.105}"
RELAY_PORT="${ISV_RELAY_PORT:-28080}"
CONTROL_PORT="${ISV_CONTROL_PORT:-28081}"
RELAY_CONTAINER="${ISV_RELAY_CONTAINER:-is-relay}"
CONTAINER="isv-winrm-${ISV_BATCH}"
mkdir -p "${WORK}/results" "${WORK}/ps"
chmod 700 "${WORK}"

log() { printf '[isv %s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
mac() { ssh -o BatchMode=yes "${MAC}" "$@"; }

winrm_up() {
  docker inspect "${CONTAINER}" >/dev/null 2>&1 && return
  cp "${ISV_PASSWORD_FILE}" "${WORK}/pw"; chmod 600 "${WORK}/pw"
  cat > "${WORK}/wr.py" <<'PY'
import sys, winrm
s = winrm.Session('http://%s:5985/wsman' % sys.argv[1], auth=('Administrator', open('/w/pw').read().strip()),
                  transport='ntlm', message_encryption='auto')
r = s.run_ps(open(sys.argv[2], encoding='utf-8').read())
sys.stdout.write(r.std_out.decode('utf-8', 'replace'))
if r.status_code != 0:
    sys.stderr.write(r.std_err.decode('utf-8', 'replace')[:4000])
sys.exit(r.status_code)
PY
  docker run -d --label "roster.batch=${ISV_BATCH}" -m 512m --name "${CONTAINER}" -v "${WORK}:/w" python:3.12-alpine sleep 21600 >/dev/null
  docker exec "${CONTAINER}" pip install -q pywinrm >/dev/null 2>&1
}

ps() {
  local file
  file="$(mktemp "${WORK}/ps/XXXXXX.ps1")"
  cat > "${file}"
  docker exec "${CONTAINER}" python /w/wr.py "${SERVER}" "/w/ps/$(basename "${file}")"
  rm -f "${file}"
}

# pywinrm run_ps is limited by the cmd line length, so the file travels in 2000-character chunks.
upload() {
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
    -R "127.0.0.1:33389:${SERVER}:3389" -R "127.0.0.1:${RELAY_PORT}:127.0.0.1:${RELAY_PORT}" \
    -R "127.0.0.1:${CONTROL_PORT}:127.0.0.1:${CONTROL_PORT}" "${MAC}" > "${WORK}/tunnel.log" 2>&1 &
  echo $! > "${WORK}/tunnel.pid"
  sleep 3
  kill -0 "$(cat "${WORK}/tunnel.pid")" || { cat "${WORK}/tunnel.log" >&2; return 1; }
  log "tunnel pid $(cat "${WORK}/tunnel.pid")"
}

control_up() {
  [[ -f "${WORK}/control.pid" ]] && kill -0 "$(cat "${WORK}/control.pid")" 2>/dev/null && return
  python3 "${HERE}/relay-control.py" "${CONTROL_PORT}" "${RELAY_CONTAINER}" "http://127.0.0.1:${RELAY_PORT}/healthz" \
    > "${WORK}/control.log" 2>&1 &
  echo $! > "${WORK}/control.pid"
  log "control pid $(cat "${WORK}/control.pid")"
}

logoff() {
  ps <<'PS'
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
New-Item -ItemType Directory -Force C:\k5share\out | Out-Null
'lang-before=' + ((Get-WinUserLanguageList | ForEach-Object { $_.LanguageTag + ' | ' + ($_.InputMethodTips -join ',') }) -join ' ; ')
'disk-free-GB=' + [math]::Round((Get-PSDrive C).Free / 1GB, 1)
'sessions=' + @(Get-CimInstance Win32_LogonSession -Filter 'LogonType=10' -ErrorAction SilentlyContinue).Count
PS
  upload "${HERE}/shareprobe.ps1" 'C:\k5share\shareprobe.ps1'
  ps <<'PS'
$ErrorActionPreference = 'Stop'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\k5share\shareprobe.ps1'
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:COMPUTERNAME\Administrator"
$principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\Administrator" -LogonType Interactive
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 40)
Register-ScheduledTask -TaskName ISVShareProbe -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
'task=' + (Get-ScheduledTask ISVShareProbe).State
PS
  tunnel_up
  control_up
}

# run <name> <mode> <engine> [VAR=value ...]: one RDP logon, the rows, then fetch and log off.
run() {
  local name="$1" mode="$2" engine="$3"
  shift 3
  local extra="" kv
  for kv in "$@"; do extra+=" ${kv}"; done
  printf 'Remove-Item -Force -ErrorAction SilentlyContinue C:\\k5share\\out\\%s.log; Set-Content -NoNewline -Path C:\\k5share\\runid.txt -Value "%s"\n' "${name}" "${name}" | ps
  log "run ${name} mode=${mode} engine=${engine}${extra}"
  set +e
  mac "M=\$HOME/${ISV_MAC_DIR}; mkdir -p \$M/results \$M/diag; cd \$M/app
    export TMPDIR=\$M/tmp PATH=\$HOME/.cargo/bin:/opt/homebrew/bin:\$PATH DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    export CNDF_DIAGNOSTICS_DIR=\$M/diag CNDF_QA_SHARE_VERIFY=1 CNDF_CONTROL_PLANE_TOKEN=isv-dev
    export CNDF_SESSION_RELAY_URL=http://localhost:${RELAY_PORT} ISV_CONTROL_URL=http://localhost:${CONTROL_PORT}
    export ISV_PASSWORD_FILE=\$M/pw ISV_OUT=\$M/results ISV_RUN=${name} ISV_MODE=${mode} ISV_ENGINE=${engine}${extra}
    lock=\$HOME/xcode-work/.swift.lock; until shlock -p \$\$ -f \$lock; do sleep 5; done; trap 'rm -f \$lock' EXIT
    swift test --skip-build --filter IronShareVerifyTests/testIronShareVerify" \
    > "${WORK}/results/${name}.stdout.log" 2> "${WORK}/results/${name}.stderr.log"
  local rc=$?
  set -e
  rsync -a --rsync-path=/opt/homebrew/bin/rsync "${MAC}:${ISV_MAC_DIR}/results/${name}.mac.jsonl" "${WORK}/results/" 2>/dev/null || true
  logoff >/dev/null
  fetch "${name}"
  log "run ${name} rc=${rc}: $(grep -E 'Executed|error' "${WORK}/results/${name}.stdout.log" | tail -2 | tr '\n' ' ')"
}

fetch() {
  printf '$o = "C:\\k5share\\out\\%s.log"; if (Test-Path $o) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($o)) }\n' "$1" | ps \
    | python3 -c 'import base64, sys; sys.stdout.write(base64.b64decode("".join(sys.stdin.read().split())).decode("utf-8", "replace"))' \
    > "${WORK}/results/$1.windows.txt" || true
}

teardown() {
  winrm_up
  logoff || true
  ps <<'PS' || true
Unregister-ScheduledTask -TaskName ISVShareProbe -Confirm:$false -ErrorAction SilentlyContinue
Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID -and $_.SessionId -ne 0 } | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force C:\k5share -ErrorAction SilentlyContinue
'task=' + [bool](Get-ScheduledTask ISVShareProbe -ErrorAction SilentlyContinue)
'dir=' + (Test-Path C:\k5share)
'lang-after=' + ((Get-WinUserLanguageList | ForEach-Object { $_.LanguageTag + ' | ' + ($_.InputMethodTips -join ',') }) -join ' ; ')
'quser=' + [bool](quser 2>$null)
PS
  for f in tunnel control; do
    if [[ -f "${WORK}/${f}.pid" ]]; then kill "$(cat "${WORK}/${f}.pid")" 2>/dev/null || true; rm -f "${WORK}/${f}.pid"; fi
  done
  mac "rm -f \$HOME/${ISV_MAC_DIR}/pw" || true
  docker rm -fv "${CONTAINER}" >/dev/null 2>&1 || true
  rm -f "${WORK}/pw" "${WORK}/wr.py"
}

case "${1:-}" in
  setup) setup ;;
  run) winrm_up; tunnel_up; control_up; shift; run "$@" ;;
  fetch) winrm_up; fetch "$2" ;;
  logoff) winrm_up; logoff ;;
  teardown) teardown ;;
  *) echo "usage: $0 setup|run <name> <mode> <engine> [VAR=value ...]|fetch <name>|logoff|teardown" >&2; exit 2 ;;
esac
