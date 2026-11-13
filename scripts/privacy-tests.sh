#!/bin/bash
# Foundation-only cookie, redirect and log tests. They use the macOS system
# compiler; actual WebKit behavior and on-device downloads still need iOS.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != "Darwin" ]; then
  echo "The native privacy tests need macOS (system clang and Foundation)." >&2
  exit 1
fi
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
clang -std=c11 -Wall -Wextra -Werror -I Sources -c Sources/MVHTTPPolicy.c -o "$OUT/MVHTTPPolicy.o"
clang -fobjc-arc -fblocks -I Sources tests/privacy_test.m \
  Sources/MVCookiePolicy.m Sources/MVDownloadTask.m Sources/MVLog.m "$OUT/MVHTTPPolicy.o" \
  -framework Foundation -o "$OUT/privacy_test"
"$OUT/privacy_test"

# Drive the actual snapshot/clear race with a fake WebKit cookie store. No real
# website data is read or modified by the test.
clang -fobjc-arc -fblocks -I Sources tests/cookie_cache_test.m \
  Sources/MVMediaProbe.m Sources/MVCookiePolicy.m Sources/MVSnifferItem.m "$OUT/MVHTTPPolicy.o" \
  -framework Foundation -framework WebKit -o "$OUT/cookie_cache_test"
"$OUT/cookie_cache_test"

# A real NSURLSession follows local redirects; the WebKit cookie source is a
# deterministic fake so these tests never touch the developer's cookie store.
clang -fobjc-arc -fblocks -I Sources tests/redirect_integration.m \
  Sources/MVCookiePolicy.m Sources/MVHTTPSession.m "$OUT/MVHTTPPolicy.o" \
  -framework Foundation -o "$OUT/redirect_integration"
python3 tests/redirect_server.py "$OUT/redirect_integration"
