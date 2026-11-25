#!/usr/bin/env bash
# Compile the fixture in a disposable CNDF-Terminal checkout with its normal dependencies prepared.
set -euo pipefail
fixture="$(cd "$(dirname "$0")" && pwd)/IronShareVerifyTests.swift"
app="$(cd "${1:?pass a prepared, disposable CNDF-Terminal checkout}" && pwd)"
target="$app/Tests/CNDFTerminalToolsTests/IronShareVerifyTests.swift"
if [[ -e "$target" || -L "$target" ]]; then
  printf 'Fixture already exists: %s\n' "$target" >&2
  exit 1
fi
trap 'rm -f "$target"' EXIT
cp "$fixture" "$target"
cd "$app"
CODE_SIGNING_ALLOWED=NO swift build --build-tests --build-system native
