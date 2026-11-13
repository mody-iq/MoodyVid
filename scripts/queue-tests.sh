#!/bin/bash
# Tests persisted queue models and recovery without touching the user's data.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != "Darwin" ]; then
  echo "The native queue tests need macOS (system clang and Foundation)." >&2
  exit 1
fi
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
clang -fobjc-arc -fblocks -I Sources tests/queue_models_test.m \
  Sources/MVDownloadTask.m Sources/MVDownloadStore.m Sources/MVTaskStore.m Sources/MVQueuePolicy.c \
  -framework Foundation -o "$OUT/queue_models_test"
"$OUT/queue_models_test"
