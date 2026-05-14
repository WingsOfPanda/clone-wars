#!/usr/bin/env bash
# tests/test_consult_step10_corpus_swap.sh — v0.30.0 item 1
# Locks Step 10's corpus source: must read adjudicated.md (with topic.txt fallback).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
DIRECTIVE="$PLUGIN_ROOT/commands/consult.md"

# Invariant 1: Step 10 references adjudicated.md (the new corpus)
grep -q 'adjudicated\.md' "$DIRECTIVE" \
  || { echo "FAIL: commands/consult.md doesn't reference adjudicated.md (Step 10 corpus swap missing)" >&2; exit 1; }
pass "1. Step 10 references adjudicated.md"

# Invariant 2: cw_consult_detect_multi_repo is still called from Step 10
awk '/^### Step 10/,/^### Step 11/' "$DIRECTIVE" \
  | grep -q 'cw_consult_detect_multi_repo' \
  || { echo "FAIL: Step 10 doesn't call cw_consult_detect_multi_repo" >&2; exit 1; }
pass "2. Step 10 still calls cw_consult_detect_multi_repo"

# Invariant 3: corpus passed to detector is adjudicated.md, not topic.txt
awk '/^### Step 10/,/^### Step 11/' "$DIRECTIVE" \
  | grep -E 'cw_consult_detect_multi_repo[[:space:]]*"\$PWD"' \
  | grep -q 'adjudicated\.md' \
  || { echo "FAIL: Step 10's cw_consult_detect_multi_repo call doesn't pass adjudicated.md as corpus" >&2; exit 1; }
pass "3. Step 10's detector call passes adjudicated.md"

# Invariant 4: topic.txt fallback documented when adjudicated.md missing
awk '/^### Step 10/,/^### Step 11/' "$DIRECTIVE" \
  | grep -qE 'fallback|fall.back|topic\.txt' \
  || { echo "FAIL: Step 10 missing topic.txt fallback path for missing adjudicated.md" >&2; exit 1; }
pass "4. Step 10 documents topic.txt fallback when adjudicated.md missing"

echo "test_consult_step10_corpus_swap: 4 invariants locked"
