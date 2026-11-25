#!/usr/bin/env bash
# M4 H.264 acceptance harness (CNDF-Docs 2026-11-21/ironrdp/m4-h264-design.md A1/A2, K3).
# Runs on the Linux Docker host, like Scripts/run-engine-harness.sh.
#
#   HARNESS_BATCH=<batch8> Scripts/run-m4-acceptance.sh all       # images, Mac build, every case, judge, clean up
#   HARNESS_BATCH=<batch8> Scripts/run-m4-acceptance.sh case <c>  # one case: b3-1280x720
#   Scripts/run-m4-acceptance.sh selftest                          # judge on synthetic inputs only (no servers)
#   HARNESS_BATCH=<batch8> Scripts/run-m4-acceptance.sh login     # B3 IronRDP autologon, right and wrong password
#   HARNESS_BATCH=<batch8> Scripts/run-m4-acceptance.sh down      # remove containers, tunnel, Mac dir, secrets
#
# B3-GFX xrdp 0.10.5 + x264 runs IronRDP at 1280x720 and records AVC420 evidence.
# The judge compares against the verified IronRDP baseline and prints historical FreeRDP diagnostics.
# B3 logs on with the scenario password (Client Info autologon, no typing): the script watches
# the server's login results and hands each to its iteration (<run id>-<n>.login on the Mac),
# and the scenario's waitLogin step sends no key before "ok".
# `login` connects IronRDP to B3 once with the right and once with a wrong one-time password
# (session log at TRACE), checks the server's login result and the X session, and searches
# both passwords in every log and result it copied (plus a planted control).
#
# Environment:
#   HARNESS_BATCH    label value for roster.batch (required except for selftest)
#   M4_FREERDP_BASELINE / M4_FREERDP_MANIFEST  Historical B3 result and checksum manifest
#   HARNESS_WORK     Linux state dir   (default ~/.cache/m4-acceptance-$HARNESS_BATCH)
#   HARNESS_MAC      ssh target        (default danivosy@192.168.3.105)
#   HARNESS_MAC_DIR  dir under Mac ~   (default xcode-work/m4-acceptance-$HARNESS_BATCH)
#   HARNESS_BIND_IP  LAN IP to publish on (default: source IP of the default route)
# Results stay in $HARNESS_WORK/results/<case>/{<engine>/,screen-*.xwd,verdict.json}.
# Exit status of `all` / `case`: 0 every verdict pass, 3 some check not run (e.g. IronRDP
# without K1), 1 a check failed or a step broke.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
M4_DIR="${ROOT_DIR}/Harness/docker/m4"
JUDGE="${M4_DIR}/judge.py"

if [[ "${1:-}" == selftest ]]; then
  exec python3 -IB "${JUDGE}" selftest
fi

: "${HARNESS_BATCH:?set HARNESS_BATCH (roster batch id, used as the container label)}"
IRON_BASELINE="${M4_DIR}/baselines/2026-11-23-ironrdp"
FROZEN_FREERDP="${HOME}/Documents/CNDF-Docs/2026-11-26/ironrdp/freerdp-baseline"
FREE_BASELINE="${M4_FREERDP_BASELINE:-${FROZEN_FREERDP}/m4-k3/b3-1280x720/freerdp/result.json}"
FREE_MANIFEST="${M4_FREERDP_MANIFEST:-${FROZEN_FREERDP}/SHA256SUMS}"
WORK="${HARNESS_WORK:-${HOME}/.cache/m4-acceptance-${HARNESS_BATCH}}"
MAC="${HARNESS_MAC:-danivosy@192.168.3.105}"
MAC_DIR="${HARNESS_MAC_DIR:-xcode-work/m4-acceptance-${HARNESS_BATCH}}"
BIND_IP="${HARNESS_BIND_IP:-$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p')}"
LABEL="roster.batch=${HARNESS_BATCH}"
B3_IMAGE="cndf-harness-m4-b3-xrdp-gfx:${HARNESS_BATCH}"
# Own ports, so an engine-harness run of another batch (33891-33898) does not collide.
PORT_B3=33902
MAC_PATH='PATH=$HOME/.cargo/bin:/opt/homebrew/bin:$PATH'

mac() { ssh -o BatchMode=yes "${MAC}" "$@"; }
log() { printf '[m4 %s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
name() { echo "m4-harness-$1-${HARNESS_BATCH}"; }
pause() { timeout "$1" tail -f /dev/null || true; }

check_memory() {
  local avail
  avail="$(free -g | awk '/^Mem:/ {print $7}')"
  log "host available memory ${avail}G"
  (( avail >= 20 )) || { log "less than 20G available; not starting servers"; exit 1; }
}

# Builds the server images the given cases use.
images() {
  docker build --label "${LABEL}" -t "${B3_IMAGE}" -f "${M4_DIR}/b3-xrdp-gfx.Dockerfile" "${M4_DIR}"
}

secrets() {
  mkdir -p "${WORK}/results"
  chmod 700 "${WORK}"
  if [[ ! -f "${WORK}/secrets.env" ]]; then
    {
      echo "HARNESS_B3GFX_PASS=$(openssl rand -hex 12)"
      echo "HARNESS_B3GFX_WRONG=$(openssl rand -hex 12)"
    } > "${WORK}/secrets.env"
    chmod 600 "${WORK}/secrets.env"
  fi
}

wait_port() {
  local port="$1"
  for _ in $(seq 1 60); do
    if (exec 3<>"/dev/tcp/${BIND_IP}/${port}") 2>/dev/null; then return 0; fi
    pause 1
  done
  log "port ${port} did not open"
  return 1
}

tunnel_up() {
  [[ -f "${WORK}/tunnel.pid" ]] && kill -0 "$(cat "${WORK}/tunnel.pid")" 2>/dev/null && return
  ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 \
    -R "127.0.0.1:${PORT_B3}:${BIND_IP}:${PORT_B3}" "${MAC}" \
    > "${WORK}/tunnel.log" 2>&1 &
  echo $! > "${WORK}/tunnel.pid"
  pause 3
  kill -0 "$(cat "${WORK}/tunnel.pid")" || { cat "${WORK}/tunnel.log" >&2; return 1; }
  log "tunnel pid $(cat "${WORK}/tunnel.pid")"
}

# Same build as run-engine-harness.sh mac_build (IronRDP, then the harness),
# plus -enable-testing: KeyScript.swift has `@testable import RDPMacView`, which the Xcode 27.2
# toolchain rejects in a release build without it ("unable to resolve ... 'RDPMacView'").
mac_build() {
  rsync -a --delete --mkpath --exclude .git --exclude .build --exclude Vendor \
    --rsync-path=/opt/homebrew/bin/rsync "${ROOT_DIR}/" "${MAC}:${MAC_DIR}/cndf-rdp/"
  mac "set -euo pipefail; export ${MAC_PATH}; M=\$HOME/${MAC_DIR}
    lock=\$HOME/xcode-work/.swift.lock
    # The lock is shared with other batches' builds; wait up to 10 minutes for it.
    n=0
    until shlock -f \"\$lock\" -p \$\$; do
      n=\$((n + 1)); [[ \$n -le 120 ]] || { echo 'Mac Swift build lock is occupied' >&2; exit 1; }
      sleep 5
    done
    trap 'rm -f \"\$lock\"' EXIT
    mkdir -p \"\$M/tmp\"
    export TMPDIR=\$M/tmp
    cd \$M/cndf-rdp
    [[ -f Vendor/IronRDP/install/lib/libcndf_ironrdp.a ]] || bash Scripts/build-ironrdp.sh --features legacy-tls > \$M/ironrdp-build.log 2>&1
    swift build --build-system native -c release --product rdp-engine-harness -Xswiftc -enable-testing 2>&1 | tail -3"
  rsync -a --mkpath --rsync-path=/opt/homebrew/bin/rsync "${WORK}/secrets.env" "${MAC}:${MAC_DIR}/secrets.env"
  mac "chmod 600 \$HOME/${MAC_DIR}/secrets.env"
}

# Starts a fresh B3 server.
start_server() {
  local case="$1"
  # shellcheck disable=SC1091
  source "${WORK}/secrets.env"
  case "${case}" in
    b3-*)
      # One B3 server per case; b3-login uses the same image.
      docker rm -fv "$(name b3)" >/dev/null 2>&1 || true
      docker run -d --label "${LABEL}" --name "$(name b3)" -m 4g -p "${BIND_IP}:${PORT_B3}:3389" \
        -e HARNESS_USER=harness -e HARNESS_PASS="${HARNESS_B3GFX_PASS}" "${B3_IMAGE}" >/dev/null
      wait_port "${PORT_B3}"
      ;;
  esac
}

# xwd of the server screen the session shows (the xrdp session's Xorg).
capture_screen() {
  local case="$1" out="$2"
  case "${case}" in
    b3-*)
      docker exec -u harness "$(name b3)" sh -c '
        d=$(ls /tmp/.X11-unix | sed -n "s/^X\([0-9]*\)$/\1/p" | head -1)
        [ -n "$d" ] || { echo "no X display in the B3 container" >&2; exit 1; }
        DISPLAY=:$d XAUTHORITY=$HOME/.Xauthority xwd -root -silent' > "${out}"
      ;;
  esac
}

# B3 login results the server logged so far: ok (sesman logged the user in) or refused.
login_count() {
  local pattern
  case "$1" in
    ok) pattern='Received sys login status for harness : logged in' ;;
    refused) pattern='User does not exist, or could not be authenticated' ;;
  esac
  local count
  count="$(docker exec "$(name b3)" sh -c "cat /var/log/xrdp.log /var/log/xrdp-sesman.log 2>/dev/null | grep -cF '${pattern}' || true" 2>/dev/null)"
  echo "${count:-0}"
}

# Hands each new B3 login result to the next iteration of run $1 ($2 iterations): writes
# <run id>-<n>.login ("ok" or "refused") into the Mac work directory. Stops at the first
# connection without a result within 40 s; its iteration's waitLogin then fails.
login_markers() {
  local run_id="$1" iterations="$2" i ok refused result
  local ok_base refused_base
  ok_base="$(login_count ok)" refused_base="$(login_count refused)"
  for ((i = 1; i <= iterations; i++)); do
    result=""
    for _ in $(seq 1 80); do
      ok="$(login_count ok)" refused="$(login_count refused)"
      if (( ok > ok_base )); then result=ok; ok_base="${ok}"; break; fi
      if (( refused > refused_base )); then result=refused; refused_base="${refused}"; break; fi
      pause 0.5
    done
    [[ -n "${result}" ]] || { log "login ${run_id}-${i}: no server result"; return 0; }
    log "login ${run_id}-${i}: ${result}"
    mac "mkdir -p \$HOME/${MAC_DIR}/work && echo ${result} > \$HOME/${MAC_DIR}/work/${run_id}-${i}.login"
  done
}

# One engine through one case on the Mac; copies the result, final frames and session logs.
# $3 overrides the scenario (default m4-<case>).
run_engine() {
  local case="$1" engine="$2" scenario="${3:-m4-$1}" out="${WORK}/results/$1/$2" watcher="" errors
  errors="${out}/collect-errors.txt"
  mkdir -p "${out}"
  rm -f "${errors}"
  rsync -a --mkpath --rsync-path=/opt/homebrew/bin/rsync "${ROOT_DIR}/Harness/docker/scenarios/${scenario}.json" \
    "${MAC}:${MAC_DIR}/scenarios/"
  log "case ${case} engine ${engine}"
  if [[ "${case}" == b3-* ]]; then
    local run_id iterations
    read -r run_id iterations < <(python3 -I -c 'import json, sys; r = json.load(open(sys.argv[1]))["runs"][0]; print(r["id"], r.get("repeat", 1))' \
      "${ROOT_DIR}/Harness/docker/scenarios/${scenario}.json")
    login_markers "${run_id}" "${iterations}" &
    watcher=$!
  fi
  set +e
  mac "set -a; source \$HOME/${MAC_DIR}/secrets.env; set +a; M=\$HOME/${MAC_DIR}
    rm -rf \$M/home \$M/work; mkdir -p \$M/home \$M/results \$M/work
    rm -f \$M/results/${scenario}.json
    HOME=\$M/home \$M/cndf-rdp/.build/release/rdp-engine-harness \
      --scenario \$M/scenarios/${scenario}.json --out \$M/results/${scenario}.json --engine ${engine} \
      --trust-suite cndf.rdp-engine-harness.${HARNESS_BATCH} --work-dir \$M/work --reset-trust 1 --drop-trust 1" \
    > "${out}/stdout.log" 2> "${out}/stderr.log"
  local status=$?
  if [[ -n "${watcher}" ]]; then
    kill "${watcher}" 2>/dev/null
    wait "${watcher}" 2>/dev/null
  fi
  (( status == 0 )) || echo "rdp-engine-harness exit ${status}" >> "${errors}"
  rsync -a --rsync-path=/opt/homebrew/bin/rsync "${MAC}:${MAC_DIR}/results/${scenario}.json" "${out}/result.json" \
    || echo "result.json not collected" >> "${errors}"
  rsync -a --rsync-path=/opt/homebrew/bin/rsync --include '*.final.ppm' --include '*.session.log' --exclude '*' \
    "${MAC}:${MAC_DIR}/work/" "${out}/" || echo "frames and session logs not collected" >> "${errors}"
  set -e
  log "case ${case} engine ${engine} exit ${status}: $(tail -1 "${out}/stdout.log" 2>/dev/null)"
}

run_case() {
  local case="$1" dir="${WORK}/results/$1" args=() status=0
  [[ -f "${ROOT_DIR}/Harness/docker/scenarios/m4-${case}.json" ]] || { log "unknown case ${case}"; return 1; }
  rm -rf "${dir}"
  mkdir -p "${dir}"
  start_server "${case}"
  run_engine "${case}" ironrdp
  local truth="${dir}/screen-after-ironrdp.xwd"
  capture_screen "${case}" "${truth}" || log "xwd capture failed"
  docker exec "$(name b3)" sh -c 'tail -200 /var/log/xrdp.log; tail -100 /var/log/xrdp-sesman.log' \
    > "${dir}/server.log" 2>&1 || true
  docker rm -fv "$(name b3)" >/dev/null 2>&1 || true
  args=(evaluate --case "${case}" --codec AVC420 --size 1280 720 --min-frames 97
        --baseline "${IRON_BASELINE}/result.json" --baseline-manifest "${IRON_BASELINE}/SHA256SUMS"
        --ironrdp "${dir}/ironrdp/result.json" --out "${dir}/verdict.json")
  if [[ -n "${M4_FREERDP_BASELINE:-}${M4_FREERDP_MANIFEST:-}" || -e "${FREE_BASELINE}" || -e "${FREE_MANIFEST}" ]]; then
    args+=(--freerdp "${FREE_BASELINE}" --freerdp-manifest "${FREE_MANIFEST}")
  fi
  [[ -n "${truth}" && -s "${truth}" ]] && args+=(--truth "${truth}")
  python3 -IB "${JUDGE}" "${args[@]}" || status=$?
  return "${status}"
}

# B3 autologon (design iron-autologon-log): IronRDP with the right password must start the
# user's X session without a key press; with a wrong one the server must refuse the login.
# Neither password may appear in anything the run copied back.
login_case() {
  local dir="${WORK}/results/b3-login" status=0 problems=() ok_before x_before
  rm -rf "${dir}"
  mkdir -p "${dir}"
  start_server b3-login
  ok_before="$(login_count ok)"
  run_engine b3-login ironrdp m4-b3-login-ok
  mv "${dir}/ironrdp" "${dir}/right"
  docker exec "$(name b3)" sh -c 'grep -c "X server :[0-9]* is working" /var/log/xrdp-sesman.log' > "${dir}/x-sessions.txt" 2>&1 || true
  docker exec "$(name b3)" sh -c 'pgrep -u harness -f m4/animator.py >/dev/null && echo desktop-running || echo no-desktop' \
    > "${dir}/desktop.txt" 2>&1 || true
  (( $(login_count ok) == ok_before + 1 )) || problems+=("right password: server logged in $(( $(login_count ok) - ok_before )) times, expected 1")
  grep -q desktop-running "${dir}/desktop.txt" || problems+=("right password: no desktop (animator) for the user")
  x_before="$(login_count refused)"
  ok_before="$(login_count ok)"
  run_engine b3-login ironrdp m4-b3-login-refused
  mv "${dir}/ironrdp" "${dir}/wrong"
  (( $(login_count refused) == x_before + 1 )) || problems+=("wrong password: server refused $(( $(login_count refused) - x_before )) times, expected 1")
  (( $(login_count ok) == ok_before )) || problems+=("wrong password: the server logged the user in")
  docker exec "$(name b3)" sh -c 'tail -200 /var/log/xrdp.log; tail -200 /var/log/xrdp-sesman.log' > "${dir}/server.log" 2>&1 || true
  docker rm -fv "$(name b3)" >/dev/null 2>&1 || true
  for side in right wrong; do
    [[ -s "${dir}/${side}/collect-errors.txt" ]] && problems+=("${side}: $(tr '\n' ' ' < "${dir}/${side}/collect-errors.txt")")
  done
  # The search must find a planted copy, or a clean result proves nothing.
  # shellcheck disable=SC1091
  source "${WORK}/secrets.env"
  printf 'planted %s\n' "${HARNESS_B3GFX_WRONG}" > "${dir}/planted-control.log"
  grep -rqF -- "${HARNESS_B3GFX_WRONG}" "${dir}/planted-control.log" || problems+=("leak search missed the planted control")
  rm -f "${dir}/planted-control.log"
  local secret
  for secret in "${HARNESS_B3GFX_PASS}" "${HARNESS_B3GFX_WRONG}"; do
    if grep -rlF -- "${secret}" "${dir}" > "${dir}/leaks.txt"; then problems+=("a password is in $(tr '\n' ' ' < "${dir}/leaks.txt")"); fi
  done
  rm -f "${dir}/leaks.txt"
  python3 -I - "${dir}" "${problems[@]+"${problems[@]}"}" <<'PY'
import json, sys
directory, problems = sys.argv[1], sys.argv[2:]
verdict = {"case": "b3-login", "verdict": "fail" if problems else "pass", "problems": problems}
with open(f"{directory}/login-verdict.json", "w") as f:
    json.dump(verdict, f, indent=2)
print(f"b3-login: verdict={verdict['verdict']} " + "; ".join(problems))
PY
  (( ${#problems[@]} == 0 )) || status=1
  return "${status}"
}

down() {
  local n
  for n in b3; do
    docker rm -fv "$(name "${n}")" >/dev/null 2>&1 || true
  done
  if [[ -f "${WORK}/tunnel.pid" ]]; then
    kill "$(cat "${WORK}/tunnel.pid")" 2>/dev/null || true
    rm -f "${WORK}/tunnel.pid"
  fi
  mac "defaults delete cndf.rdp-engine-harness.${HARNESS_BATCH} >/dev/null 2>&1; rm -f \"\$HOME/Library/Preferences/cndf.rdp-engine-harness.${HARNESS_BATCH}.plist\"; rm -rf \$HOME/${MAC_DIR}" || true
  rm -f "${WORK}/secrets.env"
  log "down: containers, tunnel, Mac work dir and secrets removed (results kept in ${WORK}/results)"
}

# Runs the given cases; the worst verdict decides the exit status (1 fail > 3 incomplete > 0).
run_cases() {
  local case status worst=0
  check_memory
  images "$@"
  secrets
  mac_build
  tunnel_up
  for case in "$@"; do
    status=0
    run_case "${case}" || status=$?
    if (( status == 1 || (status != 0 && status != 3) )); then worst=1
    elif (( status == 3 && worst == 0 )); then worst=3
    fi
  done
  log "results in ${WORK}/results"
  return "${worst}"
}

case "${1:-}" in
  all)
    trap down EXIT
    # shellcheck disable=SC2086
    run_cases b3-1280x720
    ;;
  case)
    [[ -n "${2:-}" ]] || { echo "usage: $0 case b3-1280x720" >&2; exit 2; }
    trap down EXIT
    run_cases "$2"
    ;;
  login)
    trap down EXIT
    check_memory
    images b3-login
    secrets
    mac_build
    tunnel_up
    login_case
    ;;
  down) down ;;
  *)
    echo "usage: $0 all|case <case>|login|selftest|down" >&2
    exit 2
    ;;
esac
