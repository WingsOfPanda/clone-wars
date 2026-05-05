#!/usr/bin/env bash
# tests/test_consult_directive_extract_targets_wired.sh — static-wiring
# assertions for v0.11.1 Step 1.5 auto-extract + confirm-gate prelude.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

DIRECTIVE="$(cd .. && pwd)/commands/consult.md"

grep -q 'cw_consult_extract_targets_from_topic' "$DIRECTIVE" \
  || { echo "FAIL: extract_targets_from_topic not referenced in directive"; exit 1; }
grep -q 'KEYWORD_ALL' "$DIRECTIVE" \
  || { echo "FAIL: KEYWORD_ALL branch not documented"; exit 1; }
grep -qE 'Confirm.*Edit selection' "$DIRECTIVE" \
  || { echo "FAIL: confirm-or-edit AskUserQuestion text missing"; exit 1; }
grep -qE 'Edit selection.*open picker|legacy.*picker' "$DIRECTIVE" \
  || { echo "FAIL: fall-through to legacy picker not documented"; exit 1; }
pass "Step 1.5 auto-extract + confirm gate wired in directive"

echo "ALL: ok"
