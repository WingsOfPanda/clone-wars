#!/usr/bin/env bash
# tests/test_consult_verify_send.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')

# 1. Empty peer file → VS=skipped, no OFFSET, no send.
TOPIC=consult-fixture-vs1
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_consult" "$TD/rex-codex" "$TD/cody-claude"
touch "$TD/rex-codex/outbox.jsonl"
touch "$TD/_consult/cody_only_items.txt"  # EMPTY

../bin/consult-verify-send.sh "$TOPIC" rex codex
[[ -f "$TD/_consult/verify-rex.txt" ]] || { echo "FAIL: verify-rex.txt missing" >&2; exit 1; }
grep -q '^VS=skipped' "$TD/_consult/verify-rex.txt" || { echo "FAIL: VS not skipped" >&2; cat "$TD/_consult/verify-rex.txt" >&2; exit 1; }
grep -q '^OFFSET='   "$TD/_consult/verify-rex.txt" && { echo "FAIL: OFFSET should not be present in skipped state" >&2; exit 1; }
pass "empty peer file → VS=skipped"

# 2. Idempotency: second call refuses.
err=$(../bin/consult-verify-send.sh "$TOPIC" rex codex 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: second call should refuse" >&2; exit 1; }
pass "verify-send fails loud on existing state"

# 3. Bad commander rejected.
TOPIC2=consult-fixture-vs2
mkdir -p "$CLONE_WARS_HOME/state/$RH/$TOPIC2/_consult"
touch "$CLONE_WARS_HOME/state/$RH/$TOPIC2/_consult/cody_only_items.txt"
err=$(../bin/consult-verify-send.sh "$TOPIC2" "bad/cmd" codex 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: bad commander accepted" >&2; exit 1; }
pass "bad commander rejected"

# Static wiring check: verify the rex-side reads cody_only_items.txt and vice versa.
grep -q 'cody_only_items.txt' ../bin/consult-verify-send.sh \
  || { echo "FAIL: rex-branch must read cody_only_items.txt" >&2; exit 1; }
grep -q 'rex_only_items.txt'  ../bin/consult-verify-send.sh \
  || { echo "FAIL: cody-branch must read rex_only_items.txt" >&2; exit 1; }
pass "verify-send reads PEER's _only_items.txt"
