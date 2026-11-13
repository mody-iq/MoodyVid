#!/bin/bash
# Exercise the real transfer parsers and a local HTTP server on macOS.
# Converter, cookie and filesystem dependencies are isolated with test stubs;
# this is not a substitute for actual media playback or on-device networking.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != "Darwin" ]; then
  echo "The native transfer tests need macOS (system clang and Foundation)." >&2
  exit 1
fi
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
SOURCES=(tests/transfer_test_stubs.m Sources/MVDownloadTask.m Sources/MVFileProtection.m Sources/MVFastDownloader.m
         Sources/MVHLSDownloader.m Sources/MVMPDDownloader.m Sources/MVByteRange.c Sources/MVThrottle.c)
for test in stream_manifest_test transfer_integration; do
  clang -fobjc-arc -fblocks -I Sources "tests/$test.m" "${SOURCES[@]}" \
    -framework Foundation -framework AVFoundation -o "$OUT/$test"
done
"$OUT/stream_manifest_test"
python3 tests/transfer_server.py "$OUT/transfer_integration"
