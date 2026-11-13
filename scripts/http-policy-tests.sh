#!/bin/bash
# Cookie domain/path matching is portable C, so it can be tested on Linux and
# macOS without an iOS device. The native integration tests run on macOS.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -pedantic -I Sources \
  tests/http_policy_test.c Sources/MVHTTPPolicy.c -o "$OUT/http_policy_test"
"$OUT/http_policy_test"
