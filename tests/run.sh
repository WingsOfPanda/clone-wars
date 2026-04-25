#!/usr/bin/env bash
# tests/run.sh — discover and run every tests/test_*.sh; non-zero on any failure.
set -euo pipefail
cd "$(dirname "$0")"

fail=0
for t in test_*.sh; do
  echo "=== $t ==="
  if bash "$t"; then
    echo "  $t: ok"
  else
    echo "  $t: FAIL"
    fail=1
  fi
done

exit "$fail"
