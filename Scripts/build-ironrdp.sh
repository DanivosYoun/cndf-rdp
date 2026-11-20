#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
export CARGO_TARGET_DIR="$root/Vendor/IronRDP/target"
export MACOSX_DEPLOYMENT_TARGET=13.0
target=${IRONRDP_TARGETS:-aarch64-apple-darwin}
cd "$root/Rust/cndf-ironrdp"
cargo build --locked --release --target "$target" "$@"
install -d "$root/Vendor/IronRDP/install/lib"
install -m 644 "$CARGO_TARGET_DIR/$target/release/libcndf_ironrdp.a" \
    "$root/Vendor/IronRDP/install/lib/libcndf_ironrdp.a"
