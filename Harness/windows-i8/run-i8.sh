#!/usr/bin/env bash
# int-8 Windows normal-path measurement (rows a-e), driven from the Linux Docker host.
#
#   I8_BATCH=<batch> I8_PASSWORD_FILE=<file> I8_MAC_DIR=<dir under Mac ~> Harness/windows-i8/run-i8.sh \
#       setup | run <name> <engine> <scenario.json> | teardown
#
# Same transport as Harness/windows-ime/run-k5.sh: WinRM from a python:3.12-alpine + pywinrm
# container (NTLM, message encryption), one reverse tunnel -R 127.0.0.1:33389:<server>:3389 to the
# Mac whose PID is recorded, rdp-engine-harness built from this tree in $I8_MAC_DIR/cndf-rdp.
# setup: record the language list, upload i8probe.ps1, register the AtLogOn interactive task
# I8Probe, create the Windows source files under C:\i8\src. run: one logon; afterwards the
# result JSON, session log, Mac staging listing and probe log land in $WORK/results, the Mac
# staging directory of that run is deleted, the session is logged off and C:\i8\dst is emptied.
# CUT_AFTER=<s> kills the tunnel that many seconds after the harness starts (network cut) and
# brings it back when the harness ends. teardown: remove the task and C:\i8, log off, stop the
# tunnel and the container.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${I8_BATCH:?set I8_BATCH}" "${I8_PASSWORD_FILE:?set I8_PASSWORD_FILE}" "${I8_MAC_DIR:?set I8_MAC_DIR}"
SERVER="${I8_SERVER:-158.247.237.175}"
WORK="${I8_WORK:-${HOME}/.cache/i8-${I8_BATCH}}"
MAC="${I8_MAC:-danivosy@192.168.3.105}"
CONTAINER="i8-winrm-${I8_BATCH}"
mkdir -p "${WORK}/results" "${WORK}/ps"
chmod 700 "${WORK}"

log() { printf '[i8 %s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
mac() { ssh -o BatchMode=yes "${MAC}" "$@"; }

winrm_up() {
  docker inspect "${CONTAINER}" >/dev/null 2>&1 && return
  cp "${I8_PASSWORD_FILE}" "${WORK}/pw"; chmod 600 "${WORK}/pw"
  cat > "${WORK}/wr.py" <<'PY'
import sys, winrm
s = winrm.Session('http://%s:5985/wsman' % sys.argv[1], auth=('Administrator', open('/i8/pw').read().strip()),
                  transport='ntlm', message_encryption='auto')
r = s.run_ps(open(sys.argv[2], encoding='utf-8').read())
sys.stdout.write(r.std_out.decode('utf-8', 'replace'))
if r.status_code != 0:
    sys.stderr.write(r.std_err.decode('utf-8', 'replace')[:4000])
sys.exit(r.status_code)
PY
  docker run -d --label "roster.batch=${I8_BATCH}" -m 512m --name "${CONTAINER}" -v "${WORK}:/i8" python:3.12-alpine sleep 21600 >/dev/null
  docker exec "${CONTAINER}" pip install -q pywinrm >/dev/null 2>&1
}

ps() {
  local file
  file="$(mktemp "${WORK}/ps/XXXXXX.ps1")"
  cat > "${file}"
  docker exec "${CONTAINER}" python /i8/wr.py "${SERVER}" "/i8/ps/$(basename "${file}")"
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

tunnel_down() {
  if [[ -f "${WORK}/tunnel.pid" ]]; then kill "$(cat "${WORK}/tunnel.pid")" 2>/dev/null || true; rm -f "${WORK}/tunnel.pid"; fi
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
New-Item -ItemType Directory -Force C:\i8\out, C:\i8\dst, C:\i8\src | Out-Null
if (-not (Test-Path C:\i8\lang-before.txt)) {
  Get-WinUserLanguageList | ForEach-Object { "$($_.LanguageTag) | $($_.InputMethodTips -join ',')" } | Set-Content -Encoding UTF8 C:\i8\lang-before.txt
}
'lang-before=' + ((Get-Content C:\i8\lang-before.txt) -join ' ; ')
'freeGB=' + [math]::Round((Get-PSDrive C).Free / 1GB, 1)
PS
  upload "${ROOT_DIR}/Harness/windows-i8/i8probe.ps1" 'C:\i8\i8probe.ps1'
  ps <<'PS'
$ErrorActionPreference = 'Stop'
# PowerShell 5.1 reads a BOM-less script as ANSI; the probe is ASCII, so it is fine as is.
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -Sta -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\i8\i8probe.ps1'
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:COMPUTERNAME\Administrator"
$principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\Administrator" -LogonType Interactive
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 25)
Register-ScheduledTask -TaskName I8Probe -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
'task=' + (Get-ScheduledTask I8Probe).State
PS
  # Source files: 1 GiB random, three files (20 B, Korean name, 6 MiB), a folder tree with a
  # nested folder, a Korean name and an empty folder.
  ps <<'PS'
$ErrorActionPreference = 'Stop'
function Rand([string]$path, [long]$bytes) {
  if ((Test-Path $path) -and (Get-Item $path).Length -eq $bytes) { return }
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $buf = New-Object byte[] (4MB)
  $f = [IO.File]::Create($path)
  try { for ($done = 0L; $done -lt $bytes; $done += $n) { $n = [math]::Min($buf.Length, $bytes - $done); $rng.GetBytes($buf); $f.Write($buf, 0, $n) } } finally { $f.Close() }
}
Rand C:\i8\src\big.bin 1GB
New-Item -ItemType Directory -Force C:\i8\src\multi, "C:\i8\src\폴더W\하위\깊은", "C:\i8\src\폴더W\빈폴더" | Out-Null
[IO.File]::WriteAllText('C:\i8\src\multi\small.txt', 'int8 small file 20B.')
[IO.File]::WriteAllText('C:\i8\src\multi\한글이름.txt', 'win-file-payload-한글', [Text.UTF8Encoding]::new($false))
Rand C:\i8\src\multi\mid.bin 6MB
[IO.File]::WriteAllText('C:\i8\src\폴더W\루트.txt', 'root-한글', [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText('C:\i8\src\폴더W\하위\깊은\안쪽.txt', 'nested-한글', [Text.UTF8Encoding]::new($false))
Get-ChildItem -Recurse C:\i8\src -File | ForEach-Object { 'src ' + $_.FullName.Substring(8) + ' ' + $_.Length + ' ' + (Get-FileHash -Algorithm SHA256 $_.FullName).Hash.ToLower() }
PS
  tunnel_up
}

run() {
  local name="$1" engine="$2" scenario="$3" cut_pid=""
  printf 'Set-Content -NoNewline -Path C:\\i8\\runid.txt -Value "%s"\n' "${name}" | ps
  # The run id names the session log; use the run name so repeated runs keep their own logs.
  python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); d["runs"][0]["id"] = sys.argv[3]; json.dump(d, open(sys.argv[2], "w"), ensure_ascii=False)' \
    "${scenario}" "${WORK}/results/${name}.scenario.json" "${name}"
  rsync -a --mkpath --rsync-path=/opt/homebrew/bin/rsync "${WORK}/results/${name}.scenario.json" "${MAC}:${I8_MAC_DIR}/scenarios/${name}.json"
  log "run ${name} engine=${engine}"
  if [[ -n "${CUT_AFTER:-}" ]]; then
    # CUT_RESTORE=<s>: bring the tunnel back that many seconds after the cut (reconnect rows).
    ( sleep "${CUT_AFTER}"; kill "$(cat "${WORK}/tunnel.pid")" 2>/dev/null; echo "cut $(date '+%H:%M:%S.%3N')" >> "${WORK}/results/${name}.cut.txt"
      if [[ -n "${CUT_RESTORE:-}" ]]; then sleep "${CUT_RESTORE}"; tunnel_up; echo "restored $(date '+%H:%M:%S.%3N')" >> "${WORK}/results/${name}.cut.txt"; fi ) &
    cut_pid=$!
  fi
  set +e
  mac "set -a; source \$HOME/${I8_MAC_DIR}/i8.env; set +a; M=\$HOME/${I8_MAC_DIR}; mkdir -p \$M/home \$M/work \$M/results \$M/tmp/${name}
    HOME=\$M/home TMPDIR=\$M/tmp/${name}/ \$M/cndf-rdp/.build/release/rdp-engine-harness --scenario \$M/scenarios/${name}.json \
      --out \$M/results/${name}.json --engine ${engine} --trust-suite cndf.rdp-engine-harness.i8-${I8_BATCH} --work-dir \$M/work" \
    > "${WORK}/results/${name}.stdout.log" 2> "${WORK}/results/${name}.stderr.log"
  set -e
  # tunnel_up starts a new tunnel only when the recorded PID is gone, so a restored one is kept.
  if [[ -n "${cut_pid}" ]]; then kill "${cut_pid}" 2>/dev/null || true; wait "${cut_pid}" 2>/dev/null || true; tunnel_up; fi
  rsync -a --rsync-path=/opt/homebrew/bin/rsync "${MAC}:${I8_MAC_DIR}/results/${name}.json" "${WORK}/results/" 2>/dev/null || true
  rsync -a --rsync-path=/opt/homebrew/bin/rsync "${MAC}:${I8_MAC_DIR}/work/${name}-1.session.log" "${WORK}/results/" 2>/dev/null || true
  mac "cd \$HOME/${I8_MAC_DIR}/tmp/${name} && find . -print0 | xargs -0 stat -f '%z %N' ; cd .. && rm -rf ${name}" > "${WORK}/results/${name}.staging.txt" 2>&1 || true
  printf '%s\n' 'Get-ChildItem -Recurse -Force C:\i8\dst -ErrorAction SilentlyContinue | ForEach-Object { "dst " + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_.FullName.Substring(10))) + " " + $(if ($_.PSIsContainer) { "dir" } else { $_.Length }) }' | ps > "${WORK}/results/${name}.dst.txt" 2>&1 || true
  logoff >/dev/null
  printf '$p = "C:\\i8\\out\\%s.log"; if (Test-Path $p) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($p)) }\nRemove-Item -Recurse -Force C:\\i8\\dst\\* -ErrorAction SilentlyContinue\n' "${name}" | ps \
    | tr -d '\r\n' | base64 -d > "${WORK}/results/${name}.probe.log" 2>/dev/null || true
  log "run ${name}: $(tail -1 "${WORK}/results/${name}.stdout.log" 2>/dev/null)"
}

teardown() {
  winrm_up
  logoff || true
  ps <<'PS' || true
Unregister-ScheduledTask -TaskName I8Probe -Confirm:$false -ErrorAction SilentlyContinue
Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID -and $_.SessionId -ne 0 } | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force C:\i8 -ErrorAction SilentlyContinue
'task=' + [bool](Get-ScheduledTask I8Probe -ErrorAction SilentlyContinue)
'i8dir=' + (Test-Path C:\i8)
Get-WinUserLanguageList | ForEach-Object { 'lang=' + $_.LanguageTag + ' | ' + ($_.InputMethodTips -join ',') }
'quser=' + [bool](quser 2>$null)
PS
  tunnel_down
  mac "defaults delete cndf.rdp-engine-harness.i8-${I8_BATCH} >/dev/null 2>&1; rm -f \$HOME/${I8_MAC_DIR}/i8.env" || true
  docker rm -fv "${CONTAINER}" >/dev/null 2>&1 || true
  rm -f "${WORK}/pw" "${WORK}/wr.py"
}

case "${1:-}" in
  setup) setup ;;
  run) winrm_up; tunnel_up; shift; run "$@" ;;
  logoff) winrm_up; logoff ;;
  ps) winrm_up; ps ;;
  teardown) teardown ;;
  *) echo "usage: $0 setup|run <name> <engine> <scenario.json>|logoff|ps|teardown" >&2; exit 2 ;;
esac
