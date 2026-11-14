#!/bin/bash
# Read-only scanner and recoverable trash tests on isolated temporary files.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != "Darwin" ]; then
  echo "The storage tests need macOS (system clang and Foundation)." >&2
  exit 1
fi
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
clang -fobjc-arc -fblocks -Wall -Werror -Wno-deprecated-declarations -I Sources \
  tests/storage_test.m tests/storage_test_stubs.m Sources/MVStorageScanner.m \
  Sources/MVTrashStore.m Sources/MVFileProtection.m Sources/MVPaths.m \
  -framework Foundation -o "$OUT/storage_test"
"$OUT/storage_test"
