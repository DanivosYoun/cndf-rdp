#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
export CARGO_TARGET_DIR="$root/Vendor/IronRDP/target"
export MACOSX_DEPLOYMENT_TARGET=13.0
cd "$root/Rust/cndf-ironrdp"
cargo test --locked "$@"
cbindgen --config cbindgen.toml . | diff -u "$root/Sources/IronRDPBridge/include/CNDFIronRDP.h" -
