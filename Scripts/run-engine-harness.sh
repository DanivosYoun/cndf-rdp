#!/usr/bin/env bash
# RDP engine harness driver (design D7 H-A/H-B, D8 C5). Runs on the Linux Docker host.
#
#   Scripts/run-engine-harness.sh all        # build images, start B1 and B3, build + run the
#                                             # harness on the Mac, collect JSON, clean up
#   Scripts/run-engine-harness.sh images|up|mac-build|scenarios|down
#   Scripts/run-engine-harness.sh legacy-tls # B4 only: legacy-tls-ironrdp, clean up
#
# Servers (Linux Docker, published on the LAN IP only):
#   B1  IronRDP examples/server, --sec hybrid      :33891 (cert A, later B)  :33892 (chain)
#   B3  xrdp (danielguerra/ubuntu-xrdp, pinned)    :33894
#   B4  xrdp 0.9.17, one TLS window per container  :33895 (TLS 1.0)  :33896 (TLS 1.1)
#                                                   :33897 (TLS 1.2+1.3)
# The Mac cannot open connections to the Linux host, so the ports reach the Mac through one
# reverse ssh tunnel (Linux -> Mac, -R 127.0.0.1:<port>:<lan-ip>:<port>); its PID is
# recorded and only that PID is killed.
#
# Environment:
#   HARNESS_BATCH   label value for roster.batch (required; containers carry it)
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
WORK="${HARNESS_WORK:-${HOME}/.cache/rdp-engine-harness-${HARNESS_BATCH}}"
MAC="${HARNESS_MAC:-danivosy@192.168.3.105}"
MAC_DIR="${HARNESS_MAC_DIR:-xcode-work/rdp-engine-harness-${HARNESS_BATCH}}"
BIND_IP="${HARNESS_BIND_IP:-$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p')}"
LABEL="roster.batch=${HARNESS_BATCH}"
B1_IMAGE="cndf-harness-b1-ironrdp:${HARNESS_BATCH}"
B3_IMAGE="danielguerra/ubuntu-xrdp@sha256:1a00da32f4e486f2f5fd8f656fc23bb235987c219153a587894469cad300b12d"
B3_M3_IMAGE="cndf-harness-b3-xrdp:${HARNESS_BATCH}"
PORT_B3_FIXTURE=33898
B4_IMAGE="cndf-harness-b4-legacy-tls:${HARNESS_BATCH}"
PORT_B1=33891 PORT_B1_CHAIN=33892 PORT_B3=33894
PORT_B4_TLS10=33895 PORT_B4_TLS11=33896 PORT_B4_TLS12=33897
MAC_PATH='PATH=$HOME/.cargo/bin:/opt/homebrew/bin:$PATH'

mac() { ssh -o BatchMode=yes "${MAC}" "$@"; }
log() { printf '[harness %s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
name() { echo "rdp-harness-$1-${HARNESS_BATCH}"; }

images() {
  docker build --label "${LABEL}" -t "${B1_IMAGE}" "${ROOT_DIR}/Harness/docker/b1-ironrdp"
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
      echo "HARNESS_B3_PASS=$(openssl rand -hex 12)"
    } > "${WORK}/secrets.env"
    chmod 600 "${WORK}/secrets.env"
  fi
  if ! grep -q '^HARNESS_B3_FIXTURE_TOKEN=' "${WORK}/secrets.env"; then
    printf 'HARNESS_B3_FIXTURE_TOKEN=%s\n' "$(openssl rand -hex 24)" >> "${WORK}/secrets.env"
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
    -e IRONRDP_LOG=info -e NO_COLOR=1 \
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
  printf '999 harness %s sudo\n' "$(openssl passwd -6 "${HARNESS_B3_PASS}")" > "${WORK}/users.list"
  chmod 644 "${WORK}/users.list"
  docker rm -fv "$(name b3)" >/dev/null 2>&1 || true
  docker run -d --label "${LABEL}" --name "$(name b3)" -p "${BIND_IP}:${PORT_B3}:3389" --shm-size 1g \
    -v "${WORK}/users.list:/etc/users.list:ro" "${B3_IMAGE}" >/dev/null
  wait_port "${PORT_B1_CHAIN}"
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

# Forwards the given ports (default B1 and B3).
tunnel_up() {
  [[ -f "${WORK}/tunnel.pid" ]] && kill -0 "$(cat "${WORK}/tunnel.pid")" 2>/dev/null && return
  local forwards=() port ports=("$@")
  (( ${#ports[@]} )) || ports=("${PORT_B1}" "${PORT_B1_CHAIN}" "${PORT_B3}")
  for port in "${ports[@]}"; do
    forwards+=(-R "127.0.0.1:${port}:${BIND_IP}:${port}")
  done
  ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 "${forwards[@]}" "${MAC}" \
    > "${WORK}/tunnel.log" 2>&1 &
  echo $! > "${WORK}/tunnel.pid"
  sleep 3
  kill -0 "$(cat "${WORK}/tunnel.pid")" || { cat "${WORK}/tunnel.log" >&2; return 1; }
  log "tunnel pid $(cat "${WORK}/tunnel.pid")"
}

# Builds IronRDP and the rdp-engine-harness product on the Mac.
mac_build() {
  rsync -a --delete --mkpath --exclude .git --exclude .build --exclude Vendor \
    --rsync-path=/opt/homebrew/bin/rsync "${ROOT_DIR}/" "${MAC}:${MAC_DIR}/cndf-rdp/"
  mac "set -euo pipefail; export ${MAC_PATH}; M=\$HOME/${MAC_DIR}
    lock=\$HOME/xcode-work/.swift.lock
    shlock -f \"\$lock\" -p \$\$ || { echo 'Mac Swift build lock is occupied' >&2; exit 1; }
    trap 'rm -f \"\$lock\"' EXIT
    mkdir -p \"\$M/tmp\"
    export TMPDIR=\$M/tmp
    cd \$M/cndf-rdp
    [[ -f Vendor/IronRDP/install/lib/libcndf_ironrdp.a ]] || bash Scripts/build-ironrdp.sh --features legacy-tls > \$M/ironrdp-build.log 2>&1
    swift build --build-system native -c release --product rdp-engine-harness -Xswiftc -enable-testing 2>&1 | tail -3"
}

# Runs one IronRDP scenario on the Mac.
run_scenario() {
  local scenario="$1"; shift
  local base
  base="$(basename "${scenario}" .json)"
  log "scenario ${base}"
  rsync -a --mkpath --rsync-path=/opt/homebrew/bin/rsync "${scenario}" "${MAC}:${MAC_DIR}/scenarios/"
  set +e
  mac "set -a; source \$HOME/${MAC_DIR}/secrets.env; set +a; M=\$HOME/${MAC_DIR}
    mkdir -p \$M/home \$M/results \$M/work
    rm -f \$M/results/${base}.json
    HOME=\$M/home \$M/cndf-rdp/.build/release/rdp-engine-harness \
      --scenario \$M/scenarios/${base}.json --out \$M/results/${base}.json \
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
  # Baselines: connect, first frame, idle, tap, resize, shutdown x5.
  # A fresh HOME and trust store, so B1's certificate is simply "new" again here.
  mac "rm -rf \$HOME/${MAC_DIR}/home"
  run_scenario "${s}/baseline-b1.json" --reset-trust 1
  run_scenario "${s}/baseline-b3.json" --drop-trust 1
  log "results in ${WORK}/results"
}

# B4 (legacy TLS design C5): three xrdp containers, one TLS protocol window each, with the
# same one-time self-signed certificate. Only the B4 ports are tunnelled.
legacy_tls_up() {
  local avail profile port
  avail="$(free -g | awk '/^Mem:/ {print $7}')"
  log "host available memory ${avail}G"
  if (( avail < 20 )); then
    log "less than 20G available; not starting servers"
    exit 1
  fi
  docker build --label "${LABEL}" -t "${B4_IMAGE}" "${ROOT_DIR}/Harness/docker/b4-legacy-tls"
  secrets
  if [[ ! -f "${WORK}/certs/b4.pem" ]]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 7 -subj "/CN=harness-b4" \
      -keyout "${WORK}/certs/b4-key.pem" -out "${WORK}/certs/b4.pem" 2>/dev/null
    chmod 644 "${WORK}/certs/b4.pem" "${WORK}/certs/b4-key.pem"
  fi
  for profile in tls10:"${PORT_B4_TLS10}" tls11:"${PORT_B4_TLS11}" tls12:"${PORT_B4_TLS12}"; do
    port="${profile#*:}" profile="${profile%%:*}"
    docker rm -fv "$(name "b4${profile}")" >/dev/null 2>&1 || true
    docker run -d --label "${LABEL}" --name "$(name "b4${profile}")" -p "${BIND_IP}:${port}:3389" \
      -e TLS_PROFILE="${profile}" -v "${WORK}/certs:/certs:ro" "${B4_IMAGE}" >/dev/null
    wait_port "${port}"
  done
  tunnel_up "${PORT_B4_TLS10}" "${PORT_B4_TLS11}" "${PORT_B4_TLS12}"
}

# B4 checks first frames for each TLS profile at the xrdp login screen.
legacy_tls_scenarios() {
  local s="${ROOT_DIR}/Harness/docker/b4-legacy-tls/scenarios"
  mkdir -p "${WORK}/results"
  rsync -a --mkpath --rsync-path=/opt/homebrew/bin/rsync "${WORK}/secrets.env" "${MAC}:${MAC_DIR}/secrets.env"
  mac "chmod 600 \$HOME/${MAC_DIR}/secrets.env; rm -rf \$HOME/${MAC_DIR}/home"
  run_scenario "${s}/legacy-tls-ironrdp.json" --reset-trust 1 --drop-trust 1
  rsync -a --rsync-path=/opt/homebrew/bin/rsync "${MAC}:${MAC_DIR}/work/b4-*.session.log" "${WORK}/results/" 2>/dev/null || true
  log "results in ${WORK}/results"
}

m3_channels() {
  local scenario="${ROOT_DIR}/Harness/docker/scenarios/m3-b1-channels.json"
  mkdir -p "${WORK}/results/ironrdp"
  # Start a fresh B1 for this scenario.
  start_b1 a || return
  run_scenario "$scenario" --reset-trust 1 --drop-trust 1
  docker logs "$(name b1)" > "${WORK}/results/ironrdp/b1-server.log" 2>&1
  mv "${WORK}/results"/m3-b1-channels.* "${WORK}/results/ironrdp/"
  python3 "${ROOT_DIR}/Harness/docker/b1-ironrdp/channel-results.py" \
    "$scenario" "${WORK}/results/ironrdp/b1-server.log" > "${WORK}/results/ironrdp/b1-channels.json" || return
  python3 -c 'import json, sys; sys.exit(not json.load(open(sys.argv[1]))["passed"])' \
    "${WORK}/results/ironrdp/m3-b1-channels.json"
}

m3_b1() {
  local avail
  avail="$(free -g | awk '/^Mem:/ {print $7}')"
  (( avail >= 20 )) || { log "less than 20G available"; return 1; }
  docker build --label "${LABEL}" -t "${B1_IMAGE}" "${ROOT_DIR}/Harness/docker/b1-ironrdp"
  secrets
  mac_build
  rsync -a --mkpath --rsync-path=/opt/homebrew/bin/rsync "${WORK}/secrets.env" "${MAC}:${MAC_DIR}/secrets.env"
  tunnel_up "${PORT_B1}"
  m3_channels
}

m3_b3() {
  local avail failed=0
  avail="$(free -g | awk '/^Mem:/ {print $7}')"
  (( avail >= 20 )) || { log "less than 20G available"; return 1; }
  [[ -c /dev/fuse ]] || { log "B3 drive requires /dev/fuse"; return 1; }
  docker build --label "${LABEL}" -t "${B3_M3_IMAGE}" "${ROOT_DIR}/Harness/docker/b3-xrdp"
  secrets
  # shellcheck disable=SC1091
  source "${WORK}/secrets.env"
  mac_build
  rsync -a --mkpath --rsync-path=/opt/homebrew/bin/rsync "${WORK}/secrets.env" "${MAC}:${MAC_DIR}/secrets.env"
  tunnel_up "${PORT_B3}" "${PORT_B3_FIXTURE}"
  printf '999 harness %s sudo\n' "$(openssl passwd -6 "${HARNESS_B3_PASS}")" > "${WORK}/users.list"
  chmod 644 "${WORK}/users.list"
  docker rm -fv "$(name b3)" >/dev/null 2>&1 || true
  docker run -d --label "${LABEL}" --name "$(name b3)" --device /dev/fuse --cap-add SYS_ADMIN \
    -p "${BIND_IP}:${PORT_B3}:3389" -p "${BIND_IP}:${PORT_B3_FIXTURE}:8080" \
    -e HARNESS_B3_FIXTURE_TOKEN="${HARNESS_B3_FIXTURE_TOKEN}" \
    -v "${WORK}/users.list:/etc/users.list:ro" "${B3_M3_IMAGE}" >/dev/null
  wait_port "${PORT_B3}"
  docker exec -d "$(name b3)" python3 /opt/harness-fixture.py
  wait_port "${PORT_B3_FIXTURE}"
  mkdir -p "${WORK}/results/ironrdp"
  run_scenario "${ROOT_DIR}/Harness/docker/scenarios/m3-b3-home.json" --reset-trust 1 --drop-trust 1
  mv "${WORK}/results"/m3-b3-home.* "${WORK}/results/ironrdp/"
  docker exec "$(name b3)" sh -c 'for file in /var/log/xrdp.log /var/log/xrdp-sesman.log /home/harness/.local/share/xrdp/xrdp-chansrv*.log; do
    [ ! -f "$file" ] || tail -100 "$file"
  done' > "${WORK}/results/ironrdp/b3-server.log" 2>&1
  python3 -c 'import json, sys; sys.exit(not json.load(open(sys.argv[1]))["passed"])' \
    "${WORK}/results/ironrdp/m3-b3-home.json" || failed=1
  return "$failed"
}

# K1: record the GCC keyboard fields and the xrdp keymaps for both profiles.
keyboard_fields() {
  local avail failed=0
  avail="$(free -g | awk '/^Mem:/ {print $7}')"
  (( avail >= 20 )) || { log "less than 20G available"; return 1; }
  docker build --label "${LABEL}" -t "${B1_IMAGE}" "${ROOT_DIR}/Harness/docker/b1-ironrdp"
  docker pull -q "${B3_IMAGE}" >/dev/null
  secrets
  # shellcheck disable=SC1091
  source "${WORK}/secrets.env"
  mac_build
  rsync -a --mkpath --rsync-path=/opt/homebrew/bin/rsync "${WORK}/secrets.env" "${MAC}:${MAC_DIR}/secrets.env"
  mac "chmod 600 \$HOME/${MAC_DIR}/secrets.env"
  tunnel_up "${PORT_B1}" "${PORT_B3}"
  printf '999 harness %s sudo\n' "$(openssl passwd -6 "${HARNESS_B3_PASS}")" > "${WORK}/users.list"
  chmod 644 "${WORK}/users.list"
  mkdir -p "${WORK}/results/ironrdp"
  docker rm -fv "$(name b1)" >/dev/null 2>&1 || true
  docker run -d --label "${LABEL}" --name "$(name b1)" -p "${BIND_IP}:${PORT_B1}:3389" \
    -e IRONRDP_LOG=info,ironrdp_acceptor=debug -e NO_COLOR=1 -v "${WORK}/certs:/certs:ro" "${B1_IMAGE}" \
    --sec hybrid --user harness --pass "${HARNESS_B1_PASS}" --cert /certs/a.pem --key /certs/a-key.pem >/dev/null
  wait_port "${PORT_B1}"
  run_scenario "${ROOT_DIR}/Harness/docker/scenarios/k1-b1-keyboard.json" --reset-trust 1 --drop-trust 1
  docker logs "$(name b1)" > "${WORK}/results/ironrdp/b1-server.log" 2>&1
  { grep -oE 'keyboard_layout: [0-9]+|keyboard_type: KeyboardType\([0-9]+\)|keyboard_subtype: [0-9]+|keyboard_functional_keys_count: [0-9]+|ime_file_name: "[^"]*"' \
      "${WORK}/results/ironrdp/b1-server.log" || true; } | paste -d' ' - - - - - > "${WORK}/results/ironrdp/b1-keyboard.txt"
  docker rm -fv "$(name b3)" >/dev/null 2>&1 || true
  docker run -d --label "${LABEL}" --name "$(name b3)" -p "${BIND_IP}:${PORT_B3}:3389" --shm-size 1g \
    -v "${WORK}/users.list:/etc/users.list:ro" "${B3_IMAGE}" >/dev/null
  wait_port "${PORT_B3}"
  run_scenario "${ROOT_DIR}/Harness/docker/scenarios/k1-b3-keyboard.json" --reset-trust 1 --drop-trust 1
  docker exec "$(name b3)" cat /var/log/xrdp.log > "${WORK}/results/ironrdp/b3-xrdp.log" 2>&1
  { grep -oE '(Loading|Cannot find) keymap file [^ ]+' "${WORK}/results/ironrdp/b3-xrdp.log" || true; } \
    > "${WORK}/results/ironrdp/b3-keyboard.txt"
  mv "${WORK}/results"/k1-b[13]-keyboard.* "${WORK}/results/ironrdp/"
  local scenario
  for scenario in k1-b1-keyboard k1-b3-keyboard; do
    python3 -c 'import json, sys; sys.exit(not json.load(open(sys.argv[1]))["passed"])' \
      "${WORK}/results/ironrdp/${scenario}.json" || failed=1
  done
  rsync -a --mkpath --rsync-path=/opt/homebrew/bin/rsync --include '*keyboard*.session.log' --exclude '*' \
    "${MAC}:${MAC_DIR}/work/" "${WORK}/results/ironrdp/sessions/" || failed=1
  { grep -ohE 'RDP keyboard profile=[a-z]+ layout=0x[0-9a-f]+ type=[0-9]+ subtype=[0-9]+ fn=[0-9]+' \
      "${WORK}/results/ironrdp/sessions/"*.session.log || true; } | sort -u > "${WORK}/results/ironrdp/client-keyboard.txt"
  return "$failed"
}

down() {
  local n
  for n in b1 b1chain b3 b4tls10 b4tls11 b4tls12; do
    docker rm -fv "$(name "${n}")" >/dev/null 2>&1 || true
  done
  if [[ -f "${WORK}/tunnel.pid" ]]; then
    kill "$(cat "${WORK}/tunnel.pid")" 2>/dev/null || true
    rm -f "${WORK}/tunnel.pid"
  fi
  mac "defaults delete cndf.rdp-engine-harness.${HARNESS_BATCH} >/dev/null 2>&1; rm -f \"\$HOME/Library/Preferences/cndf.rdp-engine-harness.${HARNESS_BATCH}.plist\"; rm -rf \$HOME/${MAC_DIR}" || true
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
  m3-b3)
    trap down EXIT
    m3_b3
    ;;
  keyboard)
    trap down EXIT
    keyboard_fields
    ;;
  m3-b1)
    trap down EXIT
    m3_b1
    ;;
  legacy-tls)
    trap down EXIT
    legacy_tls_up
    mac_build
    legacy_tls_scenarios
    ;;
  all)
    trap down EXIT
    images
    up
    mac_build
    scenarios
    ;;
  *)
    echo "usage: $0 all|images|up|mac-build|scenarios|down|legacy-tls|m3-b1|m3-b3|keyboard" >&2
    exit 2
    ;;
esac
