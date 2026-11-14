#!/bin/bash
# Foundation-only player tests. Does not replace AVPlayer and device testing.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != "Darwin" ]; then
  echo "The player model tests need macOS (system clang and Foundation)." >&2
  exit 1
fi
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
clang -fobjc-arc -fblocks -Wall -Werror -Wno-deprecated-declarations -I Sources \
  tests/player_models_test.m Sources/MVPlaybackHistory.m Sources/MVSubtitleTrack.m Sources/MVSubtitleStore.m \
  -framework Foundation -o "$OUT/player_models_test"
"$OUT/player_models_test"
