#!/usr/bin/env bash
# Regression: Scripts/run-hostile-harness.sh run used to exit 0 when the Mac
# swift build failed. The driver runs inside a process substitution, so a
# non-zero status from mac_build produced no scenario lines and the parent
# treated that as success.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
batch="k4file07fc34bc"
work="${HOME}/.cache/file-k4-07fc34bc/hostile-red"
stub=$(mktemp -d "${HOME}/.cache/file-k4-07fc34bc/hostile-stub.XXXXXX")
tree=$(mktemp -d "${HOME}/.cache/file-k4-07fc34bc/hostile-tree.XXXXXX")
cleanup() {
  if [[ -f "${work}/tunnel.pid" ]]; then
    kill "$(cat "${work}/tunnel.pid")" 2>/dev/null || true
  fi
  rm -rf -- "${stub}" "${tree}" "${work}"
}
trap cleanup EXIT

mkdir -p "${tree}/Rust" "${tree}/Sources"
echo "package" > "${tree}/Package.swift"
echo "rust" > "${tree}/Rust/lib.rs"
echo "swift" > "${tree}/Sources/main.swift"

cat > "${stub}/ssh" << 'EOF'
#!/bin/bash
if [[ "$*" == *"swift build"* ]]; then
  echo "stub: swift build failed" >&2
  exit 1
fi
if [[ "${1:-}" == "-N" ]]; then
  while true; do sleep 1; done
fi
exit 0
EOF
cat > "${stub}/docker" << 'EOF'
#!/bin/bash
exit 0
EOF
cat > "${stub}/rsync" << 'EOF'
#!/bin/bash
exit 0
EOF
cat > "${stub}/free" << 'EOF'
#!/bin/bash
echo "Mem: 121 20 15 0 80 40"
EOF
cat > "${stub}/ip" << 'EOF'
#!/bin/bash
echo "1.1.1.1 via 10.0.0.1 dev eth0 src 10.0.0.8"
EOF
chmod 755 "${stub}/ssh" "${stub}/docker" "${stub}/rsync" "${stub}/free" "${stub}/ip"

export PATH="${stub}:${PATH}"
export HARNESS_BATCH="${batch}"
export HARNESS_WORK="${work}"
export HARNESS_MAC="stub@invalid"
export HARNESS_MAC_DIR="xcode-work/file-k4-hostile-stub"

set +e
timeout 45 "${root}/Scripts/run-hostile-harness.sh" run "${tree}"
status=$?
set -e
printf 'run-hostile-harness exit %s\n' "${status}"
if [[ "${status}" -eq 0 ]]; then
  echo "build failure was reported as success" >&2
  exit 1
fi
if [[ "${status}" -eq 124 ]]; then
  echo "harness driver timed out" >&2
  exit 1
fi
