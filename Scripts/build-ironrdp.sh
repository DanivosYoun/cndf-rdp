#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
vendor="$root/Vendor/IronRDP"
source_dir="$vendor/src"
patches=("$root"/Rust/cndf-ironrdp/patches/*.patch)
IRONRDP_REPO=https://github.com/Devolutions/IronRDP.git
IRONRDP_COMMIT=15b4a03ff552b80463287495ff940de3c1989807

if [[ ! -e "$source_dir" ]]; then
    mkdir -p "$vendor"
    checkout=$(mktemp -d "$vendor/.src.XXXXXXXX")
    trap 'rm -rf -- "$checkout"' EXIT
    git -C "$checkout" init -q
    git -C "$checkout" fetch --depth 1 "$IRONRDP_REPO" "$IRONRDP_COMMIT"
    git -C "$checkout" checkout --detach FETCH_HEAD
    for patch in "${patches[@]}"; do
        git -C "$checkout" apply "$patch"
    done
    mv "$checkout" "$source_dir"
    trap - EXIT
fi
if [[ ! -d "$source_dir/.git" ]] || [[ $(git -C "$source_dir" rev-parse HEAD) != "$IRONRDP_COMMIT" ]]; then
    printf '%s\n' "Unexpected IronRDP source checkout at $source_dir" >&2
    exit 1
fi

# Compare the worktree with the pinned commit plus the ordered patch series.
check_dir=$(mktemp -d "$vendor/.check.XXXXXXXX")
trap 'rm -rf -- "$check_dir"' EXIT
(
    export GIT_INDEX_FILE="$check_dir/index"
    git -C "$source_dir" read-tree "$IRONRDP_COMMIT" || exit 1
    for patch in "${patches[@]}"; do
        git -C "$source_dir" apply --cached "$patch" || exit 1
    done
    git -C "$source_dir" update-index -q --refresh || exit 1
    git -C "$source_dir" diff-files --quiet -- &&
        [[ -z $(git -C "$source_dir" ls-files -o --exclude-standard) ]]
) || {
    printf '%s\n' "Unexpected patched IronRDP source at $source_dir" >&2
    exit 1
}
rm -rf -- "$check_dir"
trap - EXIT

if [[ ${1:-} == --prepare-only ]]; then
    exit 0
fi

export CARGO_TARGET_DIR="$root/Vendor/IronRDP/target"
export MACOSX_DEPLOYMENT_TARGET=13.0
target=${IRONRDP_TARGETS:-aarch64-apple-darwin}
cd "$root/Rust/cndf-ironrdp"
cargo build --locked --release --target "$target" "$@"
install -d "$root/Vendor/IronRDP/install/lib"
install -m 644 "$CARGO_TARGET_DIR/$target/release/libcndf_ironrdp.a" \
    "$root/Vendor/IronRDP/install/lib/libcndf_ironrdp.a"
