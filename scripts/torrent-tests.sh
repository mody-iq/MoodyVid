#!/bin/bash
# Runs the torrent core tests (bencode, SHA-1, magnet, metadata, tracker) on the
# build machine. These cover the parts where a mistake is silent and expensive: a
# wrong info-hash or a bad piece offset produces a download that never verifies.
#
# They need only Foundation, but the sources use ARC and object subscripting, so
# they run with the system clang on macOS — the same compiler and Foundation the
# device build uses. A Linux GNUstep with the legacy (gcc) runtime cannot build
# them, because that runtime predates both features.
set -e
cd "$(dirname "$0")/.."

if [ "$(uname -s)" != "Darwin" ]; then
  echo "The torrent core tests need macOS (the system clang and Foundation)." >&2
  exit 1
fi

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

SOURCES="Sources/MVBencode.m Sources/MVSHA1.m Sources/MVMagnet.m Sources/MVTorrentMetadata.m Sources/MVTorrentTracker.m Sources/MVTorrentStorage.m Sources/MVTorrentPolicy.c Sources/MVPaths.m"
TEST="tests/torrent_core_test.m"

clang -fobjc-arc -fblocks -I Sources $TEST $SOURCES -framework Foundation -o "$OUT/torrent_core_test"
"$OUT/torrent_core_test"

clang -fobjc-arc -fblocks -I Sources tests/torrent_peer_test.m \
  Sources/MVTorrentPeer.m Sources/MVBencode.m Sources/MVSHA1.m \
  -framework Foundation -o "$OUT/torrent_peer_test"
"$OUT/torrent_peer_test"

clang -fobjc-arc -fblocks -I Sources tests/torrent_engine_test.m tests/torrent_engine_stubs.m \
  Sources/MVTorrentDownloader.m Sources/MVTorrentPeer.m Sources/MVDownloadTask.m Sources/MVFileProtection.m $SOURCES \
  -framework Foundation -o "$OUT/torrent_engine_test"
"$OUT/torrent_engine_test"
