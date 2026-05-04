#!/usr/bin/env bash
# tests/test_consult_verify_prompt_with_targets.sh — verify the verify-round
# prompt gains a "## Per-sub-project structure" block when TARGETS is non-empty
# and stays byte-equal to the v0.10/v0.4.2 baseline when TARGETS is empty.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/state.sh
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"; PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
source ../lib/consult.sh

TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
printf '[file:1] x\n[file:2] y\n' > "$TMP"

# Hub mode: 3rd arg targets non-empty → per-sub-project block present
out=$(cw_consult_build_verify_prompt "$TMP" /tmp/v.md "hub/A,hub/B")
grep -q 'Per-sub-project structure' <<< "$out" \
  || { echo "FAIL: build_verify_prompt(targets) missing block"; exit 1; }
grep -q 'hub/A' <<< "$out" \
  || { echo "FAIL: build_verify_prompt(targets) leaf A missing"; exit 1; }
grep -q 'hub/B' <<< "$out" \
  || { echo "FAIL: build_verify_prompt(targets) leaf B missing"; exit 1; }
pass "build_verify_prompt(items, write_to, targets) emits per-sub-project block"

# Bullet-shape regression guard: every leaf must render as a markdown bullet,
# including the first one (the comma-substitution used to leave it bare).
grep -qE '^- hub/A' <<< "$out" \
  || { echo "FAIL: first leaf must render as bullet"; exit 1; }
grep -qE '^- hub/B' <<< "$out" \
  || { echo "FAIL: subsequent leaf must render as bullet"; exit 1; }
pass "all leaves render as markdown bullets (no bare first leaf)"

# Single-repo: explicit empty 3rd arg
out=$(cw_consult_build_verify_prompt "$TMP" /tmp/v.md "")
grep -q 'Per-sub-project structure' <<< "$out" \
  && { echo "FAIL: build_verify_prompt('') must strip the block"; exit 1; } || true
pass "build_verify_prompt(items, write_to, '') strips block (single-repo)"

# Backward-compat: 2-arg call defaults to single-repo
out=$(cw_consult_build_verify_prompt "$TMP" /tmp/v.md)
grep -q 'Per-sub-project structure' <<< "$out" \
  && { echo "FAIL: 2-arg call must default to single-repo"; exit 1; } || true
pass "build_verify_prompt 2-arg default = single-repo unchanged"
