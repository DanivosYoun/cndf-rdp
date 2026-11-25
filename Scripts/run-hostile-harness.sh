#!/usr/bin/env bash
# B5 hostile-server harness (server-memory design 0ba44ae2, K8). Runs on the Linux Docker host.
#
#   Scripts/run-hostile-harness.sh run <client-tree> [scenario ...]
#       build the B5 image, build rdp-engine-harness from <client-tree> on the Mac, replay each
#       mem-*.json scenario (default: all) against IronRDP, judge on Linux, clean up
#   Scripts/run-hostile-harness.sh compare <control-tree> <fixed-tree> [scenario ...]
#       the same for both trees in one Mac work dir; PASS when every
#       scenario FAILs its budget on the control tree and PASSes on the fixed tree
#   Scripts/run-hostile-harness.sh down
#
# <client-tree> is a cndf-rdp checkout (e.g. the cndf-v0296-int-5 pin as the control, a tree with
# the 0023/0024 patches as the fix). Its Rust/ and Sources/ are what the Mac builds; this script,
# the B5 server and the scenarios always come from this checkout.
#
# The server (Harness/docker/b5-hostile) listens on the LAN IP, port 33899, label
# roster.batch=$HARNESS_BATCH, a memory limit and no tmpfs. A scenario's "b5" block names the
# attack and its sizes; connection 1 is the warm-up (footprint baseline), connection 2 the attack.
# The port reaches the Mac through one reverse ssh tunnel whose PID is recorded and killed.
# The Mac side never runs more than one session at a time; the attack sizes keep the unpatched
# client under ~1 GiB of growth (design: control at reduced scale, <= 2 GiB per attack).
#
# Environment:
#   HARNESS_BATCH   label value for roster.batch (required)
#   HARNESS_WORK    Linux state dir   (default ~/.cache/rdp-hostile-harness-$HARNESS_BATCH)
#   HARNESS_MAC     ssh target        (default danivosy@192.168.3.105)
#   HARNESS_MAC_DIR dir under Mac ~   (default xcode-work/rdp-hostile-harness-$HARNESS_BATCH)
#   HARNESS_BIND_IP LAN IP to publish on (default: source IP of the default route)
#   HARNESS_SERVER_MEMORY  container memory limit (default 2g)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${HARNESS_BATCH:?set HARNESS_BATCH (roster batch id, used as the container label)}"
WORK="${HARNESS_WORK:-${HOME}/.cache/rdp-hostile-harness-${HARNESS_BATCH}}"
MAC="${HARNESS_MAC:-danivosy@192.168.3.105}"
MAC_DIR="${HARNESS_MAC_DIR:-xcode-work/rdp-hostile-harness-${HARNESS_BATCH}}"
BIND_IP="${HARNESS_BIND_IP:-$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p')}"
SERVER_MEMORY="${HARNESS_SERVER_MEMORY:-2g}"
LABEL="roster.batch=${HARNESS_BATCH}"
B5_IMAGE="cndf-harness-b5-hostile:${HARNESS_BATCH}"
B5_NAME="rdp-harness-b5-${HARNESS_BATCH}"
PORT_B5=33899
SCENARIOS="${ROOT_DIR}/Harness/docker/scenarios"
MAC_PATH='PATH=$HOME/.cargo/bin:/opt/homebrew/bin:$PATH'

mac() { ssh -o BatchMode=yes "${MAC}" "$@"; }
log() { printf '[b5 %s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
rsync_mac() { rsync -a --rsync-path=/opt/homebrew/bin/rsync "$@"; }

check_memory() {
  local avail
  avail="$(free -g | awk '/^Mem:/ {print $7}')"
  log "host available memory ${avail}G"
  (( avail >= 20 )) || { log "less than 20G available; not starting"; exit 1; }
}

prepare() {
  mkdir -p "${WORK}/certs" "${WORK}/results"
  chmod 700 "${WORK}"
  if [[ ! -f "${WORK}/secrets.env" ]]; then
    # The server checks no credentials (TLS without NLA); the client still sends one.
    printf 'HARNESS_B5_PASS=%s\n' "$(openssl rand -hex 12)" > "${WORK}/secrets.env"
    chmod 600 "${WORK}/secrets.env"
  fi
  if [[ ! -f "${WORK}/certs/b5.pem" ]]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 7 -subj "/CN=harness-b5" \
      -keyout "${WORK}/certs/b5-key.pem" -out "${WORK}/certs/b5.pem" 2>/dev/null
    chmod 644 "${WORK}/certs/b5.pem" "${WORK}/certs/b5-key.pem"
  fi
  docker build -q --label "${LABEL}" -t "${B5_IMAGE}" "${ROOT_DIR}/Harness/docker/b5-hostile" >/dev/null
  rsync_mac --mkpath "${WORK}/secrets.env" "${MAC}:${MAC_DIR}/secrets.env"
  mac "chmod 600 \$HOME/${MAC_DIR}/secrets.env"
}

wait_port() {
  for _ in $(seq 1 60); do
    if (exec 3<>"/dev/tcp/${BIND_IP}/${PORT_B5}") 2>/dev/null; then return 0; fi
    sleep 1
  done
  log "port ${PORT_B5} did not open"
  return 1
}

tunnel_up() {
  [[ -f "${WORK}/tunnel.pid" ]] && kill -0 "$(cat "${WORK}/tunnel.pid")" 2>/dev/null && return
  ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 \
    -R "127.0.0.1:${PORT_B5}:${BIND_IP}:${PORT_B5}" "${MAC}" > "${WORK}/tunnel.log" 2>&1 &
  echo $! > "${WORK}/tunnel.pid"
  sleep 3
  kill -0 "$(cat "${WORK}/tunnel.pid")" || { cat "${WORK}/tunnel.log" >&2; return 1; }
  log "tunnel pid $(cat "${WORK}/tunnel.pid")"
}

# Builds rdp-engine-harness from the given tree. IronRDP
# and .build are rebuilt whenever the tree's Rust/ differs from the last build.
mac_build() {
  local tree="$1" digest
  digest="$(cd "${tree}" && find Rust Sources Package.swift -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16)"
  rsync_mac --delete --mkpath --exclude .git --exclude .build --exclude Vendor --exclude target \
    "${tree}/" "${MAC}:${MAC_DIR}/cndf-rdp/"
  log "Mac build of ${tree} (sources ${digest})"
  mac "set -euo pipefail; export ${MAC_PATH}; M=\$HOME/${MAC_DIR}
    lock=\$HOME/xcode-work/.swift.lock
    # Other sessions share the lock: wait for it (up to 40 min) instead of building beside them.
    for _ in \$(seq 1 160); do shlock -f \"\$lock\" -p \$\$ && break; sleep 15; done
    [[ \"\$(cat \"\$lock\" 2>/dev/null)\" == \$\$ ]] || { echo 'Mac Swift build lock is occupied' >&2; exit 1; }
    trap 'rm -f \"\$lock\"' EXIT
    mkdir -p \"\$M/tmp\"
    export TMPDIR=\$M/tmp
    cd \$M/cndf-rdp
    if [[ \"\$(cat \$M/built.digest 2>/dev/null)\" != ${digest} ]]; then
      rm -rf Vendor/IronRDP .build
    fi
    [[ -f Vendor/IronRDP/install/lib/libcndf_ironrdp.a ]] || bash Scripts/build-ironrdp.sh --features legacy-tls > \$M/ironrdp-build.log 2>&1
    swift build --build-system native -c release --product rdp-engine-harness -Xswiftc -enable-testing 2>&1 | tail -3
    echo ${digest} > \$M/built.digest"
}

# Starts B5 with the scenario's attack, runs the scenario on the Mac and judges it.
run_one() {
  local scenario="$1" out="$2" base args status
  base="$(basename "${scenario}" .json)"
  mkdir -p "${out}"
  args="$(python3 -c 'import json, sys
b5 = json.load(open(sys.argv[1]))["b5"]
flags = ["--attack", b5["attack"]]
for key, value in b5["args"].items():
    flags += ["--" + key, str(value)]
print(" ".join(flags))' "${scenario}")"
  docker rm -fv "${B5_NAME}" >/dev/null 2>&1 || true
  # shellcheck disable=SC2086
  docker run -d --label "${LABEL}" --name "${B5_NAME}" -m "${SERVER_MEMORY}" --memory-swap "${SERVER_MEMORY}" \
    -p "${BIND_IP}:${PORT_B5}:3389" -v "${WORK}/certs:/certs:ro" "${B5_IMAGE}" ${args} >/dev/null
  wait_port
  log "scenario ${base}: ${args}"
  rsync_mac --mkpath "${scenario}" "${MAC}:${MAC_DIR}/scenarios/"
  set +e
  mac "set -a; source \$HOME/${MAC_DIR}/secrets.env; set +a; M=\$HOME/${MAC_DIR}
    rm -rf \$M/home \$M/work; mkdir -p \$M/home \$M/results \$M/work
    rm -f \$M/results/${base}.json
    HOME=\$M/home \$M/cndf-rdp/.build/release/rdp-engine-harness \
      --scenario \$M/scenarios/${base}.json --out \$M/results/${base}.json --engine ironrdp \
      --trust-suite cndf.rdp-engine-harness.${HARNESS_BATCH} --work-dir \$M/work --reset-trust 1 --drop-trust 1" \
    > "${out}/${base}.stdout.log" 2> "${out}/${base}.stderr.log"
  status=$?
  set -e
  rsync_mac "${MAC}:${MAC_DIR}/results/${base}.json" "${out}/" 2>/dev/null || true
  rsync_mac "${MAC}:${MAC_DIR}/work/attack-1.session.log" "${out}/${base}.attack.session.log" 2>/dev/null || true
  docker logs "${B5_NAME}" > "${out}/${base}.server.log" 2>&1 || true
  docker rm -fv "${B5_NAME}" >/dev/null 2>&1 || true
  log "scenario ${base}: harness exit ${status}"
  if [[ ! -f "${out}/${base}.json" ]]; then
    log "scenario ${base}: no result JSON"
    printf '{"scenario": "%s", "passed": false, "error": "no result JSON"}\n' "${base}" > "${out}/${base}.verdict.json"
    return 1
  fi
  set +e
  python3 "${ROOT_DIR}/Harness/docker/b5-hostile/judge.py" "${scenario}" "${out}/${base}.json" \
    "${out}/${base}.server.log" "${out}/${base}.attack.session.log" > "${out}/${base}.verdict.json"
  status=$?
  set -e
  log "scenario ${base}: $(python3 -c 'import json, sys
v = json.load(open(sys.argv[1]))
print(("PASS" if v["passed"] else "FAIL"), "growth", v["growthMiB"], "MiB limit", v["limitMiB"], "MiB", v["checks"])' \
    "${out}/${base}.verdict.json")"
  return "${status}"
}

scenario_files() {
  if (( $# )); then
    local name
    for name in "$@"; do echo "${SCENARIOS}/${name%.json}.json"; done
  else
    ls "${SCENARIOS}"/mem-*.json
  fi
}

# Runs every scenario against one tree; prints "<scenario> <exit>" per scenario to stdout.
run_tree() {
  local tree="$1" tag="$2"; shift 2
  local scenario status
  # A failing build must stop this driver. `return` keeps the status visible to
  # the caller; `set -e` alone is dropped when the caller inspects $? .
  mac_build "${tree}" >&2 || return $?
  for scenario in $(scenario_files "$@"); do
    # run_one toggles errexit itself, so its status is taken in a condition.
    if run_one "${scenario}" "${WORK}/results/${tag}"; then status=0; else status=$?; fi
    echo "$(basename "${scenario}" .json) ${status}"
  done
}

down() {
  docker rm -fv "${B5_NAME}" >/dev/null 2>&1 || true
  docker image rm "${B5_IMAGE}" >/dev/null 2>&1 || true
  if [[ -f "${WORK}/tunnel.pid" ]]; then
    kill "$(cat "${WORK}/tunnel.pid")" 2>/dev/null || true
    rm -f "${WORK}/tunnel.pid"
  fi
  mac "defaults delete cndf.rdp-engine-harness.${HARNESS_BATCH} >/dev/null 2>&1; rm -f \"\$HOME/Library/Preferences/cndf.rdp-engine-harness.${HARNESS_BATCH}.plist\"; rm -rf \$HOME/${MAC_DIR}" || true
  rm -f "${WORK}/secrets.env"
  rm -rf "${WORK}/certs"
  log "down: container, image, tunnel, Mac work dir and secrets removed (results kept in ${WORK}/results)"
}

case "${1:-}" in
  run)
    [[ -d "${2:-}" ]] || { echo "usage: $0 run <client-tree> [scenario ...]" >&2; exit 2; }
    tree="$(cd "$2" && pwd)"; shift 2
    trap down EXIT
    check_memory; prepare; tunnel_up
    # run_tree's status must be kept. A process substitution hides a build
    # failure (no scenario lines, failed stays 0, the script exits 0).
    set +e
    run_tree "${tree}" run "$@" > "${WORK}/run.status"
    tree_status=$?
    set -e
    failed=0
    if [[ "${tree_status}" -ne 0 ]]; then
      log "client build or scenario driver failed (exit ${tree_status})"
      failed=1
    fi
    while read -r name status; do
      [[ -n "${name}" ]] || continue
      (( status == 0 )) || failed=1
    done < "${WORK}/run.status"
    log "results in ${WORK}/results/run"
    exit "${failed}"
    ;;
  compare)
    [[ -d "${2:-}" && -d "${3:-}" ]] || { echo "usage: $0 compare <control-tree> <fixed-tree> [scenario ...]" >&2; exit 2; }
    control="$(cd "$2" && pwd)" fixed="$(cd "$3" && pwd)"; shift 3
    trap down EXIT
    check_memory; prepare; tunnel_up
    failed=0
    run_tree "${control}" control "$@" > "${WORK}/control.status"
    run_tree "${fixed}" fixed "$@" > "${WORK}/fixed.status"
    while read -r name status; do
      # The control must exceed its budget; any other control failure is not evidence.
      if [[ "$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("checks", {}).get("budget"))' \
               "${WORK}/results/control/${name}.verdict.json" 2>/dev/null)" != False ]]; then
        log "control ${name}: did not exceed its budget"; failed=1
      fi
    done < "${WORK}/control.status"
    while read -r name status; do
      (( status == 0 )) || { log "fixed ${name}: FAIL"; failed=1; }
    done < "${WORK}/fixed.status"
    log "compare $( (( failed )) && echo FAIL || echo PASS ); results in ${WORK}/results/{control,fixed}"
    exit "${failed}"
    ;;
  down) down ;;
  *)
    echo "usage: $0 run <client-tree> [scenario ...] | compare <control-tree> <fixed-tree> [scenario ...] | down" >&2
    exit 2
    ;;
esac
