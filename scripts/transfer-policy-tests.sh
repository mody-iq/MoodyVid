#!/bin/bash
# Portable recovery/admission and HTTP byte-range rules, on Linux or macOS.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -pedantic -I Sources \
  tests/queue_policy_test.c Sources/MVQueuePolicy.c -o "$OUT/queue_policy_test"
"$OUT/queue_policy_test"
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -pedantic -I Sources \
  tests/byte_range_test.c Sources/MVByteRange.c -o "$OUT/byte_range_test"
"$OUT/byte_range_test"
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -pedantic -I Sources \
  tests/throttle_test.c Sources/MVThrottle.c -lm -o "$OUT/throttle_test"
"$OUT/throttle_test"
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -pedantic -I Sources \
  tests/torrent_policy_test.c Sources/MVTorrentPolicy.c -o "$OUT/torrent_policy_test"
"$OUT/torrent_policy_test"
