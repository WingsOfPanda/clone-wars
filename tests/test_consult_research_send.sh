#!/usr/bin/env bash
# tests/test_consult_research_send.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# Static wiring: confirm the script exists, sources lib/consult.sh, calls bin/send.sh.
grep -qE 'cw_consult_(assert|topic_validate)' ../bin/consult-research-send.sh \
  || { echo "FAIL: missing topic validation" >&2; exit 1; }
grep -q 'consult_build_research_prompt' ../bin/consult-research-send.sh \
  || { echo "FAIL: missing research prompt builder" >&2; exit 1; }
grep -q 'cw_outbox_offset' ../bin/consult-research-send.sh \
  || { echo "FAIL: missing cw_outbox_offset capture" >&2; exit 1; }
grep -q 'OFFSET=' ../bin/consult-research-send.sh \
  || { echo "FAIL: missing OFFSET= write" >&2; exit 1; }
pass "research-send wiring"

# Build a fake topic with a stub trooper outbox so we can exercise idempotency.
RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=consult-fixture-rs
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_consult" "$TD/rex-codex"
touch "$TD/rex-codex/outbox.jsonl"
echo "rex" > "$TD/rex-codex/pane.json"   # placeholder; send.sh reads pane_id

# Idempotency: pre-populate research-rex.txt and assert second call refuses.
echo "OFFSET=0" > "$TD/_consult/research-rex.txt"
err=$(../bin/consult-research-send.sh "$TOPIC" rex codex 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$err" | grep -q 'already exists' \
  || { echo "FAIL: should refuse with existing state file. rc=$rc out=$err" >&2; exit 1; }
pass "research-send fails loud on existing state file"

# Bad commander rejected.
err=$(../bin/consult-research-send.sh "$TOPIC" "bad/commander" codex 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: bad commander accepted" >&2; exit 1; }
pass "bad commander rejected"

# Bad topic (path-traversal) rejected.
err=$(../bin/consult-research-send.sh "../bad" rex codex 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: bad topic accepted" >&2; exit 1; }
pass "path-traversal topic rejected"
