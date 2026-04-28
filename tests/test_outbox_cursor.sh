#!/usr/bin/env bash
# tests/test_outbox_cursor.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/ipc.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

cw_state_init alpha codex demo
OUTBOX=$(cw_outbox_path alpha codex demo)

echo '{"event":"done","ts":"t1","summary":"first"}' >> "$OUTBOX"
got=$(cw_outbox_wait_since alpha codex demo 0 done 5)
[[ "$got" == *'"summary":"first"'* ]] || { echo "FAIL: first done at offset 0" >&2; exit 1; }
pass "match at offset 0"

OFFSET=$(stat -c '%s' "$OUTBOX")
echo '{"event":"done","ts":"t2","summary":"second"}' >> "$OUTBOX"
got=$(cw_outbox_wait_since alpha codex demo "$OFFSET" done 5)
[[ "$got" == *'"summary":"second"'* ]] || { echo "FAIL: second done after offset" >&2; exit 1; }
pass "skip events before offset"

OFFSET=$(stat -c '%s' "$OUTBOX")
out=$(cw_outbox_wait_since alpha codex demo "$OFFSET" done 1) && rc=0 || rc=$?
assert_eq "$out" "" "no event past EOF"
[[ "$rc" -eq 1 ]] || { echo "FAIL: expected rc=1 on timeout" >&2; exit 1; }
pass "rc=1 on timeout"

# Multi-event varargs.
OFFSET=$(stat -c '%s' "$OUTBOX")
echo '{"event":"error","ts":"t3","message":"boom"}' >> "$OUTBOX"
got=$(cw_outbox_wait_since alpha codex demo "$OFFSET" done error 5)
[[ "$got" == *'"event":"error"'* ]] || { echo "FAIL: error in multi-event call" >&2; exit 1; }
pass "multi-event varargs"
