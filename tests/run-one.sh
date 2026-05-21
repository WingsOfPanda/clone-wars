#!/usr/bin/env bash
# tests/run-one.sh — runs one test_*.sh, captures stdout/stderr to a
# tempfile, prints "=== test_X ===" + log + "  test_X: ok|FAIL" footer
# atomically via flock. Exit code is the test's rc (0=ok, non-zero=fail).
#
# Usage: bash tests/run-one.sh <test_file>
#
# Output: a single atomic block per test. Concurrent run-one.sh
# processes coordinate by opening this script ($0) as fd 200 and flock'ing
# fd 200 — every parallel invocation locks the same inode (this file).
# Block order is completion-time, not argv order.

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

# Atomic print: open this script as fd 200, take an exclusive flock on
# it. The lock is held as long as the shell keeps fd 200 open. All
# parallel run-one.sh invocations open the same inode → the kernel
# serializes them. Lock releases when fd 200 closes (shell exit).
exec 200<"$0"
flock 200
echo "=== $t ==="
cat "$log"
echo "  $t: $status"

exit "$rc"
