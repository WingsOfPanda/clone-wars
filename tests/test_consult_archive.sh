#!/usr/bin/env bash
# tests/test_consult_archive.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=consult-fixture-arch
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_consult"
echo "synthesis content" > "$TD/_consult/synthesis.md"

# 1. Archive moves _consult to archive/, removes topic dir.
../bin/consult-archive.sh "$TOPIC"
[[ ! -d "$TD/_consult" ]] || { echo "FAIL: _consult survived" >&2; exit 1; }
[[ ! -d "$TD"           ]] || { echo "FAIL: topic dir survived" >&2; exit 1; }
arch=$(find "$CLONE_WARS_HOME/archive/$RH/$TOPIC" -maxdepth 1 -type d -name '_consult-*' 2>/dev/null | head -n1)
[[ -n "$arch" ]] || { echo "FAIL: _consult not archived" >&2; exit 1; }
[[ -f "$arch/synthesis.md" ]] || { echo "FAIL: synthesis.md not in archive" >&2; exit 1; }
pass "archive moves _consult, removes topic dir"

# 2. Re-running archive on missing _consult → rc=1.
err=$(../bin/consult-archive.sh "$TOPIC" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: missing _consult should reject" >&2; exit 1; }
pass "archive fails loud on missing _consult"

# 3. Bad topic rejected.
err=$(../bin/consult-archive.sh "../bad" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: bad topic accepted" >&2; exit 1; }
pass "bad topic rejected"
