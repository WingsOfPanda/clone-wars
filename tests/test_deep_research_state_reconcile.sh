#!/usr/bin/env bash
# tests/test_deep_research_state_reconcile.sh — 5 cases for
# cw_deep_research_trooper_state_reconcile.
# Covers all 4 branches of the helper plus idempotency.
set -uo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
# shellcheck disable=SC1091
source "$PLUGIN_ROOT/lib/log.sh"
# shellcheck disable=SC1091
source "$PLUGIN_ROOT/lib/state.sh"
# shellcheck disable=SC1091
source "$PLUGIN_ROOT/lib/deep-research.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Helper: seed a trooper state tree under $TMP with the given fields.
# Usage: _seed_trooper <cmdr> <current_exp_id> <phase> <outbox_lines>
# <outbox_lines> is a heredoc-style multi-line string with one JSONL per line.
_seed_trooper() {
  local cmdr="$1" exp="$2" phase="$3" outbox="$4"
  local td="$TMP/troopers/$cmdr"
  mkdir -p "$td/experiments/$exp"
  cat > "$td/state.txt" <<EOF
current_exp_id=$exp
phase=$phase
EOF
  printf '%s' "$outbox" > "$td/outbox.jsonl"
  : > "$td/liveness-cursor.txt"
}

# --- Case 1: LAST event = done + result.json exists → phase=idle
_seed_trooper rex exp-001 stale '{"event":"progress","note":"running"}
{"event":"done","summary":"exp-001 complete"}
'
printf '{}' > "$TMP/troopers/rex/experiments/exp-001/result.json"
cw_deep_research_trooper_state_reconcile "$TMP" rex
assert_eq "$?" "0" "case1a: reconcile exit 0"
phase=$(cw_deep_research_trooper_state_field "$TMP" rex phase)
assert_eq "$phase" "idle" "case1b: phase=idle after done+result.json"

# --- Case 2: LAST event = done + result.json MISSING → phase unchanged
_seed_trooper cody exp-002 stale '{"event":"done","summary":"exp-002 complete"}
'
# Note: NO result.json written
cw_deep_research_trooper_state_reconcile "$TMP" cody
assert_eq "$?" "0" "case2a: reconcile exit 0"
phase=$(cw_deep_research_trooper_state_field "$TMP" cody phase)
assert_eq "$phase" "stale" "case2b: phase unchanged (no result.json)"

# --- Case 3: LAST event = error → phase=failed (regardless of earlier done)
_seed_trooper bly exp-003 working '{"event":"progress","note":"start"}
{"event":"done","summary":"premature done"}
{"event":"progress","note":"more work"}
{"event":"error","reason":"crash"}
'
cw_deep_research_trooper_state_reconcile "$TMP" bly
assert_eq "$?" "0" "case3a: reconcile exit 0"
phase=$(cw_deep_research_trooper_state_field "$TMP" bly phase)
assert_eq "$phase" "failed" "case3b: phase=failed when LAST event is error"

# --- Case 4: No terminal event in tail → phase unchanged
_seed_trooper colt exp-004 stale '{"event":"progress","note":"long run"}
{"event":"heartbeat","ts":"2026-05-21T10:00:00Z"}
'
cw_deep_research_trooper_state_reconcile "$TMP" colt
assert_eq "$?" "0" "case4a: reconcile exit 0"
phase=$(cw_deep_research_trooper_state_field "$TMP" colt phase)
assert_eq "$phase" "stale" "case4b: phase unchanged (no done/error)"

# --- Case 5: Idempotency — second call after case 1 still produces phase=idle
cw_deep_research_trooper_state_reconcile "$TMP" rex
assert_eq "$?" "0" "case5a: second reconcile exit 0"
phase=$(cw_deep_research_trooper_state_field "$TMP" rex phase)
assert_eq "$phase" "idle" "case5b: phase still idle after second reconcile"

echo "test_deep_research_state_reconcile: 5 cases passed"
