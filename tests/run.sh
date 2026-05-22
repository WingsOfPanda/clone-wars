#!/usr/bin/env bash
# tests/run.sh — parallel test runner.
#
# Discovers tests/test_*.sh, filters outer skips (manual dogfood gates),
# pipes them through `xargs -P $(nproc) -I{} bash run-one.sh {}`.
# Each test's output is wrapped atomically by run-one.sh (flock 1).
#
# Flags:
#   --jobs N        max parallel jobs (default: $(nproc))
#   --serial        equivalent to --jobs 1; for debugging flakes
#   --filter PAT    regex applied to filenames before scheduling
#   -h | --help     this help
#
# Exit codes:
#   0  all tests passed
#   1  one or more tests failed
#   2  audit-parallel-safety precondition failed (no tests dispatched)
#      OR unknown flag

set -euo pipefail

# Capture the script path BEFORE cd so --help can still read it.
SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || echo "$0")
cd "$(dirname "$0")"

JOBS=$(nproc 2>/dev/null || echo 4)
FILTER=""
SERIAL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs)    JOBS="$2"; shift 2 ;;
    --serial)  SERIAL=1; shift ;;
    --filter)  FILTER="$2"; shift 2 ;;
    -h|--help)
      sed -n '3,19p' "$SCRIPT_PATH" | sed 's/^# *//'
      exit 0 ;;
    *) echo "unknown flag: $1 (try --help)" >&2; exit 2 ;;
  esac
done
[[ "$SERIAL" -eq 1 ]] && JOBS=1

# --- Precondition: audit-parallel-safety must be clean ---
if ! bash audit-parallel-safety.sh > /tmp/cw-audit.log 2>&1; then
  echo "audit-parallel-safety FAILED — refusing to dispatch tests:" >&2
  cat /tmp/cw-audit.log >&2
  exit 2
fi

# --- Outer skips — preserved exactly from the v0.51 baseline ---
# These are manual release-gate tests that exercise live LLMs or require
# interactive input; never run in CI/automated suite.
should_skip() {
  case "$1" in
    test_consult_question_dogfood_*.sh) return 0 ;;
    test_consult_design_doc_walkthrough.sh) return 0 ;;
    test_consult_v050_dogfood.sh) return 0 ;;
    test_deploy_v070_dogfood.sh) return 0 ;;
    test_deploy_v07_dogfood.sh) return 0 ;;
    test_consult_v011_dogfood.sh) return 0 ;;
  esac
  return 1
}

# Build the dispatch list. Skip lines go to stderr (not piped into xargs).
TESTS=()
for t in test_*.sh; do
  if should_skip "$t"; then
    echo "=== $t === (SKIP — manual gate)" >&2
    continue
  fi
  if [[ -n "$FILTER" && ! "$t" =~ $FILTER ]]; then
    continue
  fi
  TESTS+=("$t")
done

if [[ ${#TESTS[@]} -eq 0 ]]; then
  echo "no tests matched filter: ${FILTER:-<none>}" >&2
  exit 0
fi

# --- Dispatch ---
START=$(date +%s)
# xargs returns 123 if any child exited non-zero. We want a non-zero
# return but translate to 1 for caller clarity.
set +e
printf '%s\n' "${TESTS[@]}" | xargs -P "$JOBS" -I{} bash run-one.sh {}
xargs_rc=$?
set -e
END=$(date +%s)
ELAPSED=$((END - START))

if [[ "$xargs_rc" -eq 0 ]]; then
  rc=0
elif [[ "$xargs_rc" -eq 123 ]]; then
  rc=1
else
  rc=$xargs_rc
fi

# --- Summary ---
echo
echo "--- summary ---"
total=${#TESTS[@]}
if [[ "$rc" -eq 0 ]]; then
  echo "$total tests dispatched, all ok"
else
  echo "$total tests dispatched; one or more failed (see ': FAIL' lines above)"
fi
mins=$((ELAPSED / 60))
secs=$((ELAPSED % 60))
printf 'real    %dm%02ds (jobs=%d)\n' "$mins" "$secs" "$JOBS"

exit "$rc"
