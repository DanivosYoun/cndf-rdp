#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
vendor="$root/Vendor/IronRDP"
source_dir="$vendor/src"
patches=("$root"/Rust/cndf-ironrdp/patches/*.patch)
IRONRDP_REPO=https://github.com/Devolutions/IronRDP.git
IRONRDP_COMMIT=293cb4bee90baddfd7b8ea08d2f46e31947a3888

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
# Tentative C definitions (aws-lc, OpenSSL) stay global common symbols through `ld -r` below,
# so C dependencies are compiled with real definitions.
cflags_var="CFLAGS_${target//-/_}"
export "$cflags_var=${!cflags_var:-} -fno-common"
cd "$root/Rust/cndf-ironrdp"
cargo build --locked --release --target "$target" "$@"

# Prelink into one object that exports only the C ABI, so bundled Rust and C dependencies
# (vendored OpenSSL with the legacy-tls feature) become local symbols (design L8).
case "$target" in
    aarch64-apple-darwin) arch=arm64 ;;
    x86_64-apple-darwin) arch=x86_64 ;;
    *) printf '%s\n' "Unsupported IronRDP target $target" >&2; exit 1 ;;
esac
prelink=$(mktemp -d "$root/Vendor/IronRDP/.prelink.XXXXXXXX")
trap 'rm -rf -- "$prelink"' EXIT
ld -r -arch "$arch" -platform_version macos "$MACOSX_DEPLOYMENT_TARGET" "$(xcrun --sdk macosx --show-sdk-version)" \
    -exported_symbols_list "$root/Rust/cndf-ironrdp/cndf_iron.exports" \
    -all_load "$CARGO_TARGET_DIR/$target/release/libcndf_ironrdp.a" -o "$prelink/cndf_ironrdp.o"
libtool -static -o "$prelink/libcndf_ironrdp.a" "$prelink/cndf_ironrdp.o"
symbols=$(nm -gUj "$prelink/libcndf_ironrdp.a")
exported=$(printf '%s\n' "$symbols" | grep -v -e '^$' -e ':$' -e '^_cndf_iron_' || true)
if [[ -n $exported ]]; then
    printf '%s\n' "libcndf_ironrdp.a exports symbols outside _cndf_iron_*:" "$exported" >&2
    exit 1
fi
while IFS= read -r symbol; do
    if ! grep -Fxq "$symbol" <<< "$symbols"; then
        printf 'libcndf_ironrdp.a does not export %s\n' "$symbol" >&2
        exit 1
    fi
done < "$root/Rust/cndf-ironrdp/cndf_iron.exports"
install -d "$root/Vendor/IronRDP/install/lib"
install -m 644 "$prelink/libcndf_ironrdp.a" "$root/Vendor/IronRDP/install/lib/libcndf_ironrdp.a"
rm -rf -- "$prelink"
trap - EXIT
