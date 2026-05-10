#!/usr/bin/env bash
# tests/test_consult_init_providers_remark.sh — v0.15.0 Task 4.
# Verifies consult-init reads $state_root/providers-available.txt (written by
# /clone-wars:medic), gates on N (consult-eligible providers), and writes
# _consult/troopers.txt (TSV: provider<TAB>commander) when N >= 2.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Resolve repo-hash once — same env as consult-init's cw_state_root.
REPO_HASH=$(bash -c "source '$PLUGIN_ROOT/lib/state.sh' && cw_repo_hash")

stage_remark() {
  local cw_dir="$1"; shift
  mkdir -p "$cw_dir"
  {
    echo "# fixture"
    for p in "$@"; do echo "$p"; done
  } > "$cw_dir/providers-available.txt"
}

# ---------------------------------------------------------------------------
# Case (a): missing remark → exit 2 with medic-redirect message.
# ---------------------------------------------------------------------------
mkdir -p "$TMP/case-a/cw"
out=$(CLONE_WARS_HOME="$TMP/case-a/cw" bash "$PLUGIN_ROOT/bin/consult-init.sh" "test topic" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "2" "missing remark -> rc=2"
assert_contains "$out" "run /clone-wars:medic" "stderr mentions medic"
pass "case (a) missing remark -> exit 2"

# ---------------------------------------------------------------------------
# Case (b): N=1 (only claude) → exit 1 with redirect message.
# ---------------------------------------------------------------------------
stage_remark "$TMP/case-b/cw" claude
out=$(CLONE_WARS_HOME="$TMP/case-b/cw" bash "$PLUGIN_ROOT/bin/consult-init.sh" "test topic" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "N=1 -> rc=1"
assert_contains "$out" "ask claude directly" "stderr suggests direct ask"
pass "case (b) N=1 -> exit 1 with redirect"

# ---------------------------------------------------------------------------
# Case (c): N=2 (claude + codex) → troopers.txt = cody, rex (input order).
# ---------------------------------------------------------------------------
stage_remark "$TMP/case-c/cw" claude codex
CLONE_WARS_HOME="$TMP/case-c/cw" bash "$PLUGIN_ROOT/bin/consult-init.sh" "test topic" >/dev/null 2>&1
TROOPERS=$(find "$TMP/case-c/cw/state/$REPO_HASH" -type f -name 'troopers.txt' | head -n1)
[[ -f "$TROOPERS" ]] || { echo "FAIL: troopers.txt not written under $TMP/case-c/cw/state/$REPO_HASH"; ls -la "$TMP/case-c/cw/state/$REPO_HASH" 2>&1; exit 1; }
mapfile -t lines < <(grep -vE '^[[:space:]]*(#|$)' "$TROOPERS")
assert_eq "${#lines[@]}" "2" "N=2 -> 2 trooper lines"
assert_contains "${lines[0]}" $'claude\tcody' "first line claude->cody"
assert_contains "${lines[1]}" $'codex\trex'   "second line codex->rex"
pass "case (c) N=2 (claude+codex) -> 2 troopers (cody, rex)"

# ---------------------------------------------------------------------------
# Case (d): N=2 (claude + opencode) → cody + wolffe.
# ---------------------------------------------------------------------------
stage_remark "$TMP/case-d/cw" claude opencode
CLONE_WARS_HOME="$TMP/case-d/cw" bash "$PLUGIN_ROOT/bin/consult-init.sh" "test topic" >/dev/null 2>&1
TROOPERS=$(find "$TMP/case-d/cw/state/$REPO_HASH" -type f -name 'troopers.txt' | head -n1)
[[ -f "$TROOPERS" ]] || { echo "FAIL: troopers.txt not written (case d)"; exit 1; }
mapfile -t lines < <(grep -vE '^[[:space:]]*(#|$)' "$TROOPERS")
assert_eq "${#lines[@]}" "2" "N=2 (claude+opencode) -> 2 lines"
assert_contains "${lines[0]}" $'claude\tcody'   "first line claude->cody"
assert_contains "${lines[1]}" $'opencode\twolffe'  "second line opencode->wolffe"
pass "case (d) N=2 (claude+opencode) -> cody + wolffe"

# ---------------------------------------------------------------------------
# Case (e): N=3 (all three) → 3 troopers in input order.
# ---------------------------------------------------------------------------
stage_remark "$TMP/case-e/cw" claude codex opencode
CLONE_WARS_HOME="$TMP/case-e/cw" bash "$PLUGIN_ROOT/bin/consult-init.sh" "test topic" >/dev/null 2>&1
TROOPERS=$(find "$TMP/case-e/cw/state/$REPO_HASH" -type f -name 'troopers.txt' | head -n1)
[[ -f "$TROOPERS" ]] || { echo "FAIL: troopers.txt not written (case e)"; exit 1; }
mapfile -t lines < <(grep -vE '^[[:space:]]*(#|$)' "$TROOPERS")
assert_eq "${#lines[@]}" "3" "N=3 -> 3 lines"
assert_contains "${lines[0]}" $'claude\tcody'
assert_contains "${lines[1]}" $'codex\trex'
assert_contains "${lines[2]}" $'opencode\twolffe'
pass "case (e) N=3 -> 3 troopers (cody, rex, wolffe)"

# ---------------------------------------------------------------------------
# Case (f): gemini in remark → filter drops it; behaves as N=3.
# ---------------------------------------------------------------------------
stage_remark "$TMP/case-f/cw" gemini claude codex opencode
CLONE_WARS_HOME="$TMP/case-f/cw" bash "$PLUGIN_ROOT/bin/consult-init.sh" "test topic" >/dev/null 2>&1
TROOPERS=$(find "$TMP/case-f/cw/state/$REPO_HASH" -type f -name 'troopers.txt' | head -n1)
[[ -f "$TROOPERS" ]] || { echo "FAIL: troopers.txt not written (case f)"; exit 1; }
mapfile -t lines < <(grep -vE '^[[:space:]]*(#|$)' "$TROOPERS")
assert_eq "${#lines[@]}" "3" "N=4 with gemini -> 3 lines (gemini filtered)"
if grep -qE '^gemini' "$TROOPERS"; then
  echo "FAIL: gemini should be filtered out of troopers.txt"
  cat "$TROOPERS"
  exit 1
fi
pass "case (f) gemini filtered out (N=4 in remark -> N=3 troopers)"
