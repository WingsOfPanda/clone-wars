#!/usr/bin/env bash
# tests/test_consult_teardown_bin.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# Topic must exist; teardown should be safe (no panes alive in test env).
RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=consult-fixture-td
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_consult"

../bin/consult-teardown.sh "$TOPIC" 2>&1 >/dev/null
# The script delegates to bin/teardown.sh; with no panes/commanders, it's a no-op.
pass "teardown is a thin wrapper; safe on no-pane state"

# Bad topic rejected.
err=$(../bin/consult-teardown.sh "../bad" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: bad topic accepted" >&2; exit 1; }
pass "bad topic rejected"
