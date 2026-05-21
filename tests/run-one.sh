#!/usr/bin/env bash
# tests/run-one.sh — runs one test_*.sh, captures stdout/stderr to a
# tempfile, prints "=== test_X ===" + log + "  test_X: ok|FAIL" footer
# atomically via flock(1). Exit code is the test's rc (0=ok, non-zero=fail).
#
# Usage: bash tests/run-one.sh <test_file>
#
# Output: a single atomic block per test. Concurrent run-one.sh
# processes coordinate via flock 1 (a kernel-level lock on stdout's
# file descriptor); blocks never interleave. Block order is
# completion-time, not argv order.

set -uo pipefail
[[ $# -eq 1 ]] || { echo "Usage: $0 <test_file>" >&2; exit 2; }

t="$1"
log=$(mktemp)
trap 'rm -f "$log"' EXIT

if bash "$t" > "$log" 2>&1; then
  status="ok"
  rc=0
else
  status="FAIL"
  rc=1
fi

# Atomic print: flock 1 holds an exclusive kernel lock on stdout's fd
# for the duration of the brace group. Released when the group exits.
{
  flock 1
  echo "=== $t ==="
  cat "$log"
  echo "  $t: $status"
}

exit "$rc"
