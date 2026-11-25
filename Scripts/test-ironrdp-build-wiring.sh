#!/usr/bin/env bash
# Offline regression checks for the client build, audit discovery and server pins.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$HOME/.cache"
scratch=$(mktemp -d "$HOME/.cache/ironrdp-build-wiring-tmp.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

rsync() { :; }
shlock() { :; }
ssh() { bash -c "${4//\$HOME/$scratch}"; }
swift() {
    [[ $(cat Vendor/IronRDP/install/lib/libcndf_ironrdp.a) == current &&
       ! -e .build/stale ]] || {
        echo 'Swift would use the stale IronRDP build' >&2
        return 1
    }
}
export -f rsync shlock ssh swift
export scratch

stale_build_cache() {
    local tree="$scratch/mac/cndf-rdp"
    mkdir -p "$tree/Scripts" "$tree/Vendor/IronRDP/"{src,install/lib} "$tree/.build"
    touch "$tree/.build/stale" "$tree/Vendor/IronRDP/src/stale"
    echo old > "$tree/Vendor/IronRDP/install/lib/libcndf_ironrdp.a"
    cat > "$tree/Scripts/build-ironrdp.sh" <<'BUILD'
set -euo pipefail
[[ $* == '--features legacy-tls' && ! -e Vendor/IronRDP/src/stale ]]
mkdir -p Vendor/IronRDP/install/lib
echo current > Vendor/IronRDP/install/lib/libcndf_ironrdp.a
BUILD
    HARNESS_BATCH=regression HARNESS_BIND_IP=127.0.0.1 HARNESS_MAC=stub HARNESS_MAC_DIR=mac \
        bash "$root/Scripts/run-engine-harness.sh" mac-build
}

audit_config_discovery() {
    (cd "$root/Rust/cndf-ironrdp" && [[ .cargo/audit.toml -ef "$root/.cargo/audit.toml" ]])
}

harness_server_pins() {
    local pin dockerfile
    pin=$(sed -n 's/^IRONRDP_COMMIT=//p' "$root/Scripts/build-ironrdp.sh")
    [[ $pin =~ ^[0-9a-f]{40}$ ]] || return 1
    for dockerfile in "$root"/Harness/docker/{b1-ironrdp,b5-hostile}/Dockerfile; do
        grep -Fxq "ARG IRONRDP_COMMIT=$pin" "$dockerfile" || return 1
    done
}

status=0
for test in stale_build_cache audit_config_discovery harness_server_pins; do
    if "$test"; then
        printf 'PASS %s\n' "$test"
    else
        printf 'FAIL %s\n' "$test" >&2
        status=1
    fi
done
exit "$status"
