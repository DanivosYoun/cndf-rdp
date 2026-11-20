#!/usr/bin/env bash
# RDP engine harness driver (design D7 H-A/H-B, D8 C5). Runs on the Linux Docker host.
#
#   Scripts/run-engine-harness.sh all        # build images, start B1-B3, build + run the
#                                             # harness on the Mac, collect JSON, clean up
#   Scripts/run-engine-harness.sh images|up|mac-build|scenarios|down
#
# Servers (Linux Docker, published on the LAN IP only):
#   B1  IronRDP examples/server, --sec hybrid      :33891 (cert A, later B)  :33892 (chain)
#   B2  FreeRDP 3.33.1 shadow + Xvfb + Tk probe    :33893
#   B3  xrdp (danielguerra/ubuntu-xrdp, pinned)    :33894
# The Mac cannot open connections to the Linux host, so the ports reach the Mac through one
# reverse ssh tunnel (Linux -> Mac, -R 127.0.0.1:<port>:<lan-ip>:<port>); its PID is
# recorded and only that PID is killed.
#
# Environment:
#   HARNESS_BATCH   label value for roster.batch (required; containers carry it)
#   HARNESS_ENGINE  freerdp (default) | ironrdp (needs C2; the harness refuses it today)
#   HARNESS_WORK    Linux state dir   (default ~/.cache/rdp-engine-harness-$HARNESS_BATCH)
#   HARNESS_MAC     ssh target        (default danivosy@192.168.3.105)
#   HARNESS_MAC_DIR dir under Mac ~   (default xcode-work/rdp-engine-harness-$HARNESS_BATCH)
#   HARNESS_BIND_IP LAN IP to publish on (default: source IP of the default route)
# Everything is disposable: one-time passwords and certificates live in $HARNESS_WORK and
# in the Mac work dir, and `down` removes containers (docker rm -fv), the tunnel and the
# Mac work dir. No tmpfs (host rule): containers use their default disk.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${HARNESS_BATCH:?set HARNESS_BATCH (roster batch id, used as the container label)}"
ENGINE="${HARNESS_ENGINE:-freerdp}"
WORK="${HARNESS_WORK:-${HOME}/.cache/rdp-engine-harness-${HARNESS_BATCH}}"
MAC="${HARNESS_MAC:-danivosy@192.168.3.105}"
MAC_DIR="${HARNESS_MAC_DIR:-xcode-work/rdp-engine-harness-${HARNESS_BATCH}}"
BIND_IP="${HARNESS_BIND_IP:-$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p')}"
LABEL="roster.batch=${HARNESS_BATCH}"
B1_IMAGE="cndf-harness-b1-ironrdp:${HARNESS_BATCH}"
B2_IMAGE="cndf-harness-b2-freerdp-shadow:${HARNESS_BATCH}"
B3_IMAGE="danielguerra/ubuntu-xrdp@sha256:1a00da32f4e486f2f5fd8f656fc23bb235987c219153a587894469cad300b12d"
PORT_B1=33891 PORT_B1_CHAIN=33892 PORT_B2=33893 PORT_B3=33894
MAC_PATH='PATH=$HOME/.cargo/bin:/opt/homebrew/bin:$PATH'

mac() { ssh -o BatchMode=yes "${MAC}" "$@"; }
log() { printf '[harness %s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
name() { echo "rdp-harness-$1-${HARNESS_BATCH}"; }

images() {
  docker build --label "${LABEL}" -t "${B1_IMAGE}" "${ROOT_DIR}/Harness/docker/b1-ironrdp"
  docker build --label "${LABEL}" -t "${B2_IMAGE}" "${ROOT_DIR}/Harness/docker/b2-freerdp-shadow"
  docker pull -q "${B3_IMAGE}"
}

# One-time credentials and three certificate sets: A and B (self-signed leaves) and a chain
# (root CA -> intermediate -> leaf; the server sends leaf + intermediate).
secrets() {
  mkdir -p "${WORK}/certs"
  chmod 700 "${WORK}"
  local c="${WORK}/certs"
  if [[ ! -f "${WORK}/secrets.env" ]]; then
    {
      echo "HARNESS_B1_PASS=$(openssl rand -hex 12)"
      echo "HARNESS_B2_PASS=$(openssl rand -hex 12)"
      echo "HARNESS_B3_PASS=$(openssl rand -hex 12)"
    } > "${WORK}/secrets.env"
    chmod 600 "${WORK}/secrets.env"
  fi
  [[ -f "${c}/a.pem" ]] && return
  local subj
  for subj in a b; do
    openssl req -x509 -newkey rsa:2048 -nodes -days 7 -subj "/CN=harness-${subj}" \
      -keyout "${c}/${subj}-key.pem" -out "${c}/${subj}.pem" 2>/dev/null
  done
  openssl req -x509 -newkey rsa:2048 -nodes -days 7 -subj "/CN=harness-root-ca" \
    -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign \
    -keyout "${c}/root-key.pem" -out "${c}/root.pem" 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -subj "/CN=harness-intermediate-ca" \
    -keyout "${c}/int-key.pem" -out "${c}/int.csr" 2>/dev/null
  openssl x509 -req -in "${c}/int.csr" -CA "${c}/root.pem" -CAkey "${c}/root-key.pem" -CAcreateserial \
    -days 7 -out "${c}/int.pem" \
    -extfile <(printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n') 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -subj "/CN=harness-chain-leaf" \
    -keyout "${c}/chain-key.pem" -out "${c}/chain.csr" 2>/dev/null
  openssl x509 -req -in "${c}/chain.csr" -CA "${c}/int.pem" -CAkey "${c}/int-key.pem" -CAcreateserial \
    -days 7 -out "${c}/chain-leaf.pem" \
    -extfile <(printf 'subjectAltName=DNS:harness-chain-leaf\nextendedKeyUsage=serverAuth\n') 2>/dev/null
  cat "${c}/chain-leaf.pem" "${c}/int.pem" > "${c}/chain.pem"
  chmod 644 "${c}"/*.pem
}

# B1 on PORT_B1 with cert set $1 (a|b). Restarting swaps the certificate behind the same
# host:port, which is how the "changed" and "rejected" scenarios are produced.
start_b1() {
  local cert="$1" pass
  pass="$(sed -n 's/^HARNESS_B1_PASS=//p' "${WORK}/secrets.env")"
  docker rm -fv "$(name b1)" >/dev/null 2>&1 || true
  docker run -d --label "${LABEL}" --name "$(name b1)" -p "${BIND_IP}:${PORT_B1}:3389" \
    -v "${WORK}/certs:/certs:ro" "${B1_IMAGE}" \
    --sec hybrid --user harness --pass "${pass}" --cert "/certs/${cert}.pem" --key "/certs/${cert}-key.pem" >/dev/null
  wait_port "${PORT_B1}"
}

up() {
  local avail
  avail="$(free -g | awk '/^Mem:/ {print $7}')"
  log "host available memory ${avail}G"
  if (( avail < 20 )); then
    log "less than 20G available; not starting servers"
    exit 1
  fi
  secrets
  # shellcheck disable=SC1091
  source "${WORK}/secrets.env"
  start_b1 a
  docker rm -fv "$(name b1chain)" >/dev/null 2>&1 || true
  docker run -d --label "${LABEL}" --name "$(name b1chain)" -p "${BIND_IP}:${PORT_B1_CHAIN}:3389" \
    -v "${WORK}/certs:/certs:ro" "${B1_IMAGE}" \
    --sec hybrid --user harness --pass "${HARNESS_B1_PASS}" --cert /certs/chain.pem --key /certs/chain-key.pem >/dev/null
  docker rm -fv "$(name b2)" >/dev/null 2>&1 || true
  docker run -d --label "${LABEL}" --name "$(name b2)" -p "${BIND_IP}:${PORT_B2}:3389" \
    -e HARNESS_USER=harness -e HARNESS_PASS="${HARNESS_B2_PASS}" "${B2_IMAGE}" >/dev/null
  printf '999 harness %s sudo\n' "$(openssl passwd -6 "${HARNESS_B3_PASS}")" > "${WORK}/users.list"
  chmod 644 "${WORK}/users.list"
  docker rm -fv "$(name b3)" >/dev/null 2>&1 || true
  docker run -d --label "${LABEL}" --name "$(name b3)" -p "${BIND_IP}:${PORT_B3}:3389" --shm-size 1g \
    -v "${WORK}/users.list:/etc/users.list:ro" "${B3_IMAGE}" >/dev/null
  wait_port "${PORT_B1_CHAIN}"
  wait_port "${PORT_B2}"
  wait_port "${PORT_B3}"
  tunnel_up
}

wait_port() {
  local port="$1"
  for _ in $(seq 1 60); do
    if (exec 3<>"/dev/tcp/${BIND_IP}/${port}") 2>/dev/null; then return 0; fi
    sleep 1
  done
  log "port ${port} did not open"
  return 1
}

tunnel_up() {
  [[ -f "${WORK}/tunnel.pid" ]] && kill -0 "$(cat "${WORK}/tunnel.pid")" 2>/dev/null && return
  local forwards=() port
  for port in "${PORT_B1}" "${PORT_B1_CHAIN}" "${PORT_B2}" "${PORT_B3}"; do
    forwards+=(-R "127.0.0.1:${port}:${BIND_IP}:${port}")
  done
  ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 "${forwards[@]}" "${MAC}" \
    > "${WORK}/tunnel.log" 2>&1 &
  echo $! > "${WORK}/tunnel.pid"
  sleep 3
  kill -0 "$(cat "${WORK}/tunnel.pid")" || { cat "${WORK}/tunnel.log" >&2; return 1; }
  log "tunnel pid $(cat "${WORK}/tunnel.pid")"
}

# Builds the harness on the Mac as a throwaway wrapper package that depends on this checkout
# by path. Once C2 adds the RDPEngineHarness target to Package.swift this becomes
# `swift build --product rdp-engine-harness` in the checkout itself.
mac_build() {
  rsync -a --delete --mkpath --exclude .git --exclude .build --exclude Vendor \
    --rsync-path=/opt/homebrew/bin/rsync "${ROOT_DIR}/" "${MAC}:${MAC_DIR}/cndf-rdp/"
  mac "set -euo pipefail; export ${MAC_PATH}; M=\$HOME/${MAC_DIR}
    cd \$M/cndf-rdp
    [[ -f Vendor/FreeRDP/install/lib/libfreerdp3.dylib ]] || bash Scripts/build-freerdp.sh > \$M/freerdp-build.log 2>&1
    mkdir -p \$M/harness-pkg/Sources
    ln -sfn \$M/cndf-rdp/Sources/RDPEngineHarness \$M/harness-pkg/Sources/RDPEngineHarness
    cat > \$M/harness-pkg/Package.swift <<EOF
// swift-tools-version: 5.10
import PackageDescription
let package = Package(
    name: \"RDPEngineHarnessBuild\",
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: \"RDPMac\", path: \"\$M/cndf-rdp\")],
    targets: [
        .executableTarget(
            name: \"RDPEngineHarness\",
            dependencies: [
                .product(name: \"RDPClientCore\", package: \"RDPMac\"),
                .product(name: \"RDPMacView\", package: \"RDPMac\")
            ]
        )
    ]
)
EOF
    cd \$M/harness-pkg && swift build -c release 2>&1 | tail -3"
}

# Runs one scenario on the Mac. FreeRDP's own known_hosts lives under \$HOME, so the
# harness runs with an isolated HOME shared by all scenarios of this invocation.
run_scenario() {
  local scenario="$1"; shift
  local base
  base="$(basename "${scenario}" .json)"
  log "scenario ${base} (engine ${ENGINE})"
  rsync -a --mkpath --rsync-path=/opt/homebrew/bin/rsync "${scenario}" "${MAC}:${MAC_DIR}/scenarios/"
  set +e
  mac "set -a; source \$HOME/${MAC_DIR}/secrets.env; set +a; M=\$HOME/${MAC_DIR}
    mkdir -p \$M/home \$M/results \$M/work
    HOME=\$M/home \$M/harness-pkg/.build/release/RDPEngineHarness \
      --scenario \$M/scenarios/${base}.json --out \$M/results/${base}.json --engine ${ENGINE} \
      --trust-suite cndf.rdp-engine-harness.${HARNESS_BATCH} --work-dir \$M/work $*" \
    > "${WORK}/results/${base}.stdout.log" 2> "${WORK}/results/${base}.stderr.log"
  local status=$?
  set -e
  rsync -a --rsync-path=/opt/homebrew/bin/rsync "${MAC}:${MAC_DIR}/results/${base}.json" "${WORK}/results/" 2>/dev/null || true
  log "scenario ${base} exit ${status}: $(tail -1 "${WORK}/results/${base}.stdout.log" 2>/dev/null)"
  return 0
}

scenarios() {
  local s="${ROOT_DIR}/Harness/docker/scenarios"
  mkdir -p "${WORK}/results"
  rsync -a --mkpath --rsync-path=/opt/homebrew/bin/rsync "${WORK}/secrets.env" "${MAC}:${MAC_DIR}/secrets.env"
  mac "chmod 600 \$HOME/${MAC_DIR}/secrets.env; rm -rf \$HOME/${MAC_DIR}/home"
  # Certificate trust: new -> same (A, chain), then A->B changed (approve), then B->A (deny).
  start_b1 a
  run_scenario "${s}/cert-1-new-same.json" --reset-trust 1
  start_b1 b
  run_scenario "${s}/cert-2-changed.json"
  start_b1 a
  run_scenario "${s}/cert-3-rejected.json" --drop-trust 1
  # Baselines: connect, first frame, idle, (B2: input latency), tap, resize, shutdown x5.
  # A fresh HOME and trust store, so B1's certificate is simply "new" again here.
  mac "rm -rf \$HOME/${MAC_DIR}/home"
  run_scenario "${s}/baseline-b1.json" --reset-trust 1
  run_scenario "${s}/baseline-b2.json"
  run_scenario "${s}/baseline-b3.json"
  # Pins a known interop gap: FreeRDP 3.33.1 client with networkAutoDetect off (the app
  # default) fails against the 3.33.1 shadow server at capabilities ("MCS message channel
  # id == 0"); baseline-b2 therefore turns auto-detect on.
  run_scenario "${s}/interop-b2-autodetect-off.json" --drop-trust 1
  log "results in ${WORK}/results"
}

down() {
  local n
  for n in b1 b1chain b2 b3; do
    docker rm -fv "$(name "${n}")" >/dev/null 2>&1 || true
  done
  if [[ -f "${WORK}/tunnel.pid" ]]; then
    kill "$(cat "${WORK}/tunnel.pid")" 2>/dev/null || true
    rm -f "${WORK}/tunnel.pid"
  fi
  mac "defaults delete cndf.rdp-engine-harness.${HARNESS_BATCH} >/dev/null 2>&1; rm -rf \$HOME/${MAC_DIR}" || true
  rm -f "${WORK}/secrets.env" "${WORK}/users.list"
  rm -rf "${WORK}/certs"
  log "down: containers, tunnel, Mac work dir and secrets removed (results kept in ${WORK}/results)"
}

case "${1:-}" in
  images) images ;;
  up) up ;;
  mac-build) mac_build ;;
  scenarios) scenarios ;;
  down) down ;;
  all)
    trap down EXIT
    images
    up
    mac_build
    scenarios
    ;;
  *)
    echo "usage: $0 all|images|up|mac-build|scenarios|down" >&2
    exit 2
    ;;
esac
