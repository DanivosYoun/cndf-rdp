#!/usr/bin/env bash
# M4 H.264 acceptance harness (CNDF-Docs 2026-11-21/ironrdp/m4-h264-design.md A1/A2, K3).
# Runs on the Linux Docker host, like Scripts/run-engine-harness.sh.
#
#   HARNESS_BATCH=<batch8> Scripts/run-m4-acceptance.sh all       # images, Mac build, every case, judge, clean up
#   HARNESS_BATCH=<batch8> Scripts/run-m4-acceptance.sh case <c>  # one case: b2-1280x800 | b2-1104x704 | b3-1280x720
#   Scripts/run-m4-acceptance.sh selftest                          # judge on synthetic inputs only (no servers)
#   HARNESS_BATCH=<batch8> Scripts/run-m4-acceptance.sh down      # remove containers, tunnel, Mac dir, secrets
#
# Cases (server -> codec the FreeRDP session log must count):
#   b2-1280x800  B2 FreeRDP 3.33.1 shadow, Xvfb 1280x800 -> AVC444v2 (A2)
#   b2-1104x704  B2 shadow at 1104x704 (16 x odd) -> AVC444v2 (A2, the design's first falsification point)
#   b3-1280x720  B3-GFX xrdp 0.10.5 + x264 (Harness/docker/m4), session 1280x720 -> AVC420 (A1)
# Per case: one fresh server container; for each engine in M4_ENGINES the scenario
# Harness/docker/scenarios/m4-<case>.json runs 5 times (connect, first frame, `a` = ~8 s colour
# change measured by cpuWindow, `b` = final picture kept by dumpFrame); then xwd captures the
# server screen. Harness/docker/m4/judge.py compares PSNR(IronRDP, FreeRDP) >= 40 dB and
# median CPU IronRDP <= 1.2 x FreeRDP, plus codec and (IronRDP K1 log) hardware/failures.
#
# Environment:
#   HARNESS_BATCH    label value for roster.batch (required except for selftest)
#   M4_ENGINES       engines to run, default "freerdp ironrdp"
#   M4_CASES         cases for `all`, default "b2-1280x800 b2-1104x704 b3-1280x720"
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
  exec python3 -I "${JUDGE}" selftest
fi

: "${HARNESS_BATCH:?set HARNESS_BATCH (roster batch id, used as the container label)}"
ENGINES="${M4_ENGINES:-freerdp ironrdp}"
CASES="${M4_CASES:-b2-1280x800 b2-1104x704 b3-1280x720}"
WORK="${HARNESS_WORK:-${HOME}/.cache/m4-acceptance-${HARNESS_BATCH}}"
MAC="${HARNESS_MAC:-danivosy@192.168.3.105}"
MAC_DIR="${HARNESS_MAC_DIR:-xcode-work/m4-acceptance-${HARNESS_BATCH}}"
BIND_IP="${HARNESS_BIND_IP:-$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p')}"
LABEL="roster.batch=${HARNESS_BATCH}"
B2_IMAGE="cndf-harness-b2-freerdp-shadow:${HARNESS_BATCH}"
B3_IMAGE="cndf-harness-m4-b3-xrdp-gfx:${HARNESS_BATCH}"
# Own ports, so an engine-harness run of another batch (33891-33898) does not collide.
PORT_B2=33901 PORT_B3=33902
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

images() {
  docker build --label "${LABEL}" -t "${B2_IMAGE}" "${ROOT_DIR}/Harness/docker/b2-freerdp-shadow"
  docker build --label "${LABEL}" -t "${B3_IMAGE}" -f "${M4_DIR}/b3-xrdp-gfx.Dockerfile" "${M4_DIR}"
}

secrets() {
  mkdir -p "${WORK}/results"
  chmod 700 "${WORK}"
  if [[ ! -f "${WORK}/secrets.env" ]]; then
    {
      echo "HARNESS_B2_PASS=$(openssl rand -hex 12)"
      echo "HARNESS_B3GFX_PASS=$(openssl rand -hex 12)"
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
    -R "127.0.0.1:${PORT_B2}:${BIND_IP}:${PORT_B2}" -R "127.0.0.1:${PORT_B3}:${BIND_IP}:${PORT_B3}" "${MAC}" \
    > "${WORK}/tunnel.log" 2>&1 &
  echo $! > "${WORK}/tunnel.pid"
  pause 3
  kill -0 "$(cat "${WORK}/tunnel.pid")" || { cat "${WORK}/tunnel.log" >&2; return 1; }
  log "tunnel pid $(cat "${WORK}/tunnel.pid")"
}

# Same build as run-engine-harness.sh mac_build (FreeRDP + IronRDP once, then the harness),
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
    [[ -f Vendor/FreeRDP/install/lib/libfreerdp3.dylib ]] || bash Scripts/build-freerdp.sh > \$M/freerdp-build.log 2>&1
    [[ -f Vendor/IronRDP/install/lib/libcndf_ironrdp.a ]] || bash Scripts/build-ironrdp.sh --features legacy-tls > \$M/ironrdp-build.log 2>&1
    swift build -c release --product rdp-engine-harness -Xswiftc -enable-testing 2>&1 | tail -3"
  rsync -a --mkpath --rsync-path=/opt/homebrew/bin/rsync "${WORK}/secrets.env" "${MAC}:${MAC_DIR}/secrets.env"
  mac "chmod 600 \$HOME/${MAC_DIR}/secrets.env"
}

# Starts the server of case $1 and, for B2, the animator on its Xvfb.
start_server() {
  local case="$1" width height
  # shellcheck disable=SC1091
  source "${WORK}/secrets.env"
  case "${case}" in
    b2-*)
      width="${case#b2-}" height="${width#*x}" width="${width%x*}"
      docker rm -fv "$(name b2)" >/dev/null 2>&1 || true
      docker run -d --label "${LABEL}" --name "$(name b2)" -m 2g -p "${BIND_IP}:${PORT_B2}:3389" \
        -e HARNESS_USER=harness -e HARNESS_PASS="${HARNESS_B2_PASS}" \
        -e SCREEN_WIDTH="${width}" -e SCREEN_HEIGHT="${height}" "${B2_IMAGE}" >/dev/null
      wait_port "${PORT_B2}"
      docker cp "${M4_DIR}/animator.py" "$(name b2):/harness/m4-animator.py"
      # Mapped after the probe window and the same size, so it covers it (no window manager).
      docker exec -d -e DISPLAY=:0 -e SCREEN_WIDTH="${width}" -e SCREEN_HEIGHT="${height}" "$(name b2)" \
        python3 /harness/m4-animator.py
      pause 5
      ;;
    b3-*)
      docker rm -fv "$(name b3)" >/dev/null 2>&1 || true
      docker run -d --label "${LABEL}" --name "$(name b3)" -m 4g -p "${BIND_IP}:${PORT_B3}:3389" \
        -e HARNESS_USER=harness -e HARNESS_PASS="${HARNESS_B3GFX_PASS}" "${B3_IMAGE}" >/dev/null
      wait_port "${PORT_B3}"
      ;;
  esac
}

# xwd of the server screen the session shows (B2 Xvfb :0, B3 the xrdp session's Xorg).
capture_screen() {
  local case="$1" out="$2"
  case "${case}" in
    b2-*) docker exec -e DISPLAY=:0 "$(name b2)" xwd -root -silent > "${out}" ;;
    b3-*)
      docker exec -u harness "$(name b3)" sh -c '
        d=$(ls /tmp/.X11-unix | sed -n "s/^X\([0-9]*\)$/\1/p" | head -1)
        [ -n "$d" ] || { echo "no X display in the B3 container" >&2; exit 1; }
        DISPLAY=:$d XAUTHORITY=$HOME/.Xauthority xwd -root -silent' > "${out}"
      ;;
  esac
}

# One engine through one case on the Mac; copies the result, final frames and session logs.
run_engine() {
  local case="$1" engine="$2" scenario="m4-$1" out="${WORK}/results/$1/$2"
  mkdir -p "${out}"
  rsync -a --mkpath --rsync-path=/opt/homebrew/bin/rsync "${ROOT_DIR}/Harness/docker/scenarios/${scenario}.json" \
    "${MAC}:${MAC_DIR}/scenarios/"
  log "case ${case} engine ${engine}"
  set +e
  mac "set -a; source \$HOME/${MAC_DIR}/secrets.env; set +a; M=\$HOME/${MAC_DIR}
    rm -rf \$M/home \$M/work; mkdir -p \$M/home \$M/results \$M/work
    rm -f \$M/results/${scenario}.json
    HOME=\$M/home \$M/cndf-rdp/.build/release/rdp-engine-harness \
      --scenario \$M/scenarios/${scenario}.json --out \$M/results/${scenario}.json --engine ${engine} \
      --trust-suite cndf.rdp-engine-harness.${HARNESS_BATCH} --work-dir \$M/work --reset-trust 1 --drop-trust 1" \
    > "${out}/stdout.log" 2> "${out}/stderr.log"
  local status=$?
  set -e
  rsync -a --rsync-path=/opt/homebrew/bin/rsync "${MAC}:${MAC_DIR}/results/${scenario}.json" "${out}/result.json" || true
  rsync -a --rsync-path=/opt/homebrew/bin/rsync --include '*.final.ppm' --include '*.session.log' --exclude '*' \
    "${MAC}:${MAC_DIR}/work/" "${out}/" || true
  log "case ${case} engine ${engine} exit ${status}: $(tail -1 "${out}/stdout.log" 2>/dev/null)"
}

codec_of() {
  case "$1" in
    b2-*) echo AVC444v2 ;;
    b3-*) echo AVC420 ;;
  esac
}

run_case() {
  local case="$1" engine dir="${WORK}/results/$1" args=() status=0
  [[ -f "${ROOT_DIR}/Harness/docker/scenarios/m4-${case}.json" ]] || { log "unknown case ${case}"; return 1; }
  rm -rf "${dir}"
  mkdir -p "${dir}"
  start_server "${case}"
  for engine in ${ENGINES}; do
    run_engine "${case}" "${engine}"
    capture_screen "${case}" "${dir}/screen-after-${engine}.xwd" || log "xwd capture failed after ${engine}"
  done
  case "${case}" in
    b2-*) docker logs "$(name b2)" > "${dir}/server.log" 2>&1 || true ;;
    b3-*) docker exec "$(name b3)" sh -c 'tail -200 /var/log/xrdp.log; tail -100 /var/log/xrdp-sesman.log' \
            > "${dir}/server.log" 2>&1 || true ;;
  esac
  docker rm -fv "$(name "${case%%-*}")" >/dev/null 2>&1 || true
  # The screen is the same final picture after every engine; the judge uses the last capture.
  local truth
  truth="$(ls "${dir}"/screen-after-*.xwd 2>/dev/null | tail -1 || true)"
  [[ -f "${dir}/freerdp/result.json" ]] || { log "case ${case}: no FreeRDP result"; return 1; }
  args=(evaluate --case "${case}" --codec "$(codec_of "${case}")" --freerdp "${dir}/freerdp/result.json"
        --ironrdp "${dir}/ironrdp/result.json" --out "${dir}/verdict.json")
  [[ -n "${truth}" && -s "${truth}" ]] && args+=(--truth "${truth}")
  python3 -I "${JUDGE}" "${args[@]}" || status=$?
  return "${status}"
}

down() {
  local n
  for n in b2 b3; do
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
  images
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
    run_cases ${CASES}
    ;;
  case)
    [[ -n "${2:-}" ]] || { echo "usage: $0 case b2-1280x800|b2-1104x704|b3-1280x720" >&2; exit 2; }
    trap down EXIT
    run_cases "$2"
    ;;
  down) down ;;
  *)
    echo "usage: $0 all|case <case>|selftest|down" >&2
    exit 2
    ;;
esac
