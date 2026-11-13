#!/bin/bash
# Keep normal job logs while surfacing a bounded failure tail as an annotation.
# This helps diagnose native CI failures even when log download is unavailable.
set -uo pipefail
if [ "$#" -eq 0 ]; then
  echo "usage: $0 command [argument ...]" >&2
  exit 2
fi
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT
"$@" 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
if [ "$status" -ne 0 ] && [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  output=$(tail -c 8192 "$LOG")
  output=${output//'%'/'%25'}
  output=${output//$'\r'/'%0D'}
  output=${output//$'\n'/'%0A'}
  printf '::error title=Command failed (exit %s)::%s\n' "$status" "$output"
fi
exit "$status"
