#!/usr/bin/env bash
# tests/test_deep_research_score_state_race.sh — v0.28.1 BUG #2 lock.
#
# v0.28.0 dogfood race: when trooper-A emits done (result.json present) and
# trooper-B is still working (no result.json, only stdout.log), score.sh
# wrongly flipped trooper-B to phase=idle, current_exp_id="". This corrupted
# downstream dispatches.
#
# v0.28.1 guard: only flip state for troopers whose CURRENT current_exp_id
# has a result.json. Working troopers stay working.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
mkdir -p "$CLONE_WARS_HOME"
echo "codex" > "$CLONE_WARS_HOME/providers-available.txt"

TOPIC=$("$PLUGIN_ROOT/bin/deep-research-init.sh" "v028 1 bug2 state race")
source "$PLUGIN_ROOT/lib/state.sh"
REPO_HASH=$(cw_repo_hash)
TD="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC"
ART="$TD/_deep-research"
source "$PLUGIN_ROOT/lib/deep-research.sh"

# Set up two troopers — rex (done, result.json present) + keeli (working).
mkdir -p "$ART/troopers/rex/experiments/exp-001"
mkdir -p "$ART/troopers/keeli/experiments/exp-001"

# rex result.json (ok)
cat > "$ART/troopers/rex/experiments/exp-001/result.json" <<'EOF'
{
  "branch_id": "exp-001",
  "approach_label": "rex-approach",
  "metric_name": "accuracy",
  "metric_value": 0.9968,
  "status": "ok",
  "runtime_s": 100.0,
  "log_paths": ["./stdout.log", "./stderr.log"],
  "notes": "rex finished"
}
EOF
: > "$ART/troopers/rex/experiments/exp-001/stdout.log"
: > "$ART/troopers/rex/experiments/exp-001/stderr.log"

# keeli — only stdout.log + stderr.log (no result.json), still working
: > "$ART/troopers/keeli/experiments/exp-001/stdout.log"
: > "$ART/troopers/keeli/experiments/exp-001/stderr.log"

# Seed both states: rex working on exp-001, keeli working on exp-001
NOW=2026-05-13T00:00:00Z
cw_deep_research_trooper_state_write "$ART" rex \
  exp_counter=1 phase=working current_exp_id=exp-001 \
  last_event_ts="$NOW" last_event=dispatched probe_sent_ts=
cw_deep_research_trooper_state_write "$ART" keeli \
  exp_counter=1 phase=working current_exp_id=exp-001 \
  last_event_ts="$NOW" last_event=dispatched probe_sent_ts=

# Run score.sh — simulates rex's done event arriving first.
"$PLUGIN_ROOT/bin/deep-research-score.sh" "$TOPIC"

# Rex must be flipped to idle (its current_exp_id=exp-001 has a result.json).
rex_phase=$(awk -F= '/^phase=/{print $2}' "$ART/troopers/rex/state.txt")
rex_exp=$(awk -F= '/^current_exp_id=/{print $2}' "$ART/troopers/rex/state.txt")
rex_event=$(awk -F= '/^last_event=/{print $2}' "$ART/troopers/rex/state.txt")
assert_eq "$rex_phase" "idle" "rex.phase after score (done trooper flipped to idle)"
assert_eq "$rex_exp" "" "rex.current_exp_id cleared"
assert_eq "$rex_event" "scored" "rex.last_event=scored"
pass "rex correctly flipped to idle/scored"

# Keeli must STAY working (its current_exp_id=exp-001 has NO result.json yet).
keeli_phase=$(awk -F= '/^phase=/{print $2}' "$ART/troopers/keeli/state.txt")
keeli_exp=$(awk -F= '/^current_exp_id=/{print $2}' "$ART/troopers/keeli/state.txt")
keeli_event=$(awk -F= '/^last_event=/{print $2}' "$ART/troopers/keeli/state.txt")
assert_eq "$keeli_phase" "working" "keeli.phase preserved (no result.json yet)"
assert_eq "$keeli_exp" "exp-001" "keeli.current_exp_id preserved"
assert_eq "$keeli_event" "dispatched" "keeli.last_event preserved"
pass "keeli correctly preserved as working/exp-001 (no result.json → no state flip)"

# Now keeli emits done — write its result.json + re-run score.sh.
cat > "$ART/troopers/keeli/experiments/exp-001/result.json" <<'EOF'
{
  "branch_id": "exp-001",
  "approach_label": "keeli-approach",
  "metric_name": "accuracy",
  "metric_value": 0.9971,
  "status": "ok",
  "runtime_s": 90.0,
  "log_paths": ["./stdout.log", "./stderr.log"],
  "notes": "keeli finished"
}
EOF
"$PLUGIN_ROOT/bin/deep-research-score.sh" "$TOPIC"

keeli_phase=$(awk -F= '/^phase=/{print $2}' "$ART/troopers/keeli/state.txt")
keeli_event=$(awk -F= '/^last_event=/{print $2}' "$ART/troopers/keeli/state.txt")
assert_eq "$keeli_phase" "idle" "keeli.phase=idle after its own done"
assert_eq "$keeli_event" "scored" "keeli.last_event=scored after own done"
pass "keeli flipped to idle/scored after its own result.json appeared"

# Idle trooper (current_exp_id empty) gets skipped on subsequent score calls.
"$PLUGIN_ROOT/bin/deep-research-score.sh" "$TOPIC"
rex_phase=$(awk -F= '/^phase=/{print $2}' "$ART/troopers/rex/state.txt")
assert_eq "$rex_phase" "idle" "rex stays idle on re-score (empty current_exp_id → skip)"
pass "idle trooper skipped on subsequent score calls (no spurious touch)"

echo "test_deep_research_score_state_race: 9 assertions green"
