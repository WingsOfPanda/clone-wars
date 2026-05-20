#!/usr/bin/env bash
# tests/test_deep_research_score_v028_state.sh — v0.28.0 score updates state.txt
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
mkdir -p "$CLONE_WARS_HOME"
echo "codex" > "$CLONE_WARS_HOME/providers-available.txt"

SLUG=$("$PLUGIN_ROOT/bin/deep-research-init.sh" "score state test")
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"
REPO_HASH=$(cw_repo_hash)
TD="$CLONE_WARS_HOME/state/$REPO_HASH/$SLUG"
ART="$TD/_deep-research"

# Mimic post-dispatch state (phase=working) with a result.json on disk
mkdir -p "$ART/troopers/rex/experiments/exp-001"
cw_deep_research_trooper_state_write "$ART" rex \
  phase=working current_exp_id=exp-001 exp_counter=1 \
  last_event_ts=2026-05-13T08:00:00Z last_event=dispatched probe_sent_ts=

# Synthesize a valid result.json + log paths
EXP_DIR="$ART/troopers/rex/experiments/exp-001"
: > "$EXP_DIR/stdout.log"
: > "$EXP_DIR/stderr.log"
cat > "$EXP_DIR/result.json" <<'EOF'
{
  "branch_id": "exp-001",
  "approach_label": "test-approach",
  "metric_name": "accuracy",
  "metric_value": 0.95,
  "status": "ok",
  "runtime_s": 100,
  "log_paths": ["./stdout.log", "./stderr.log"],
  "notes": "test"
}
EOF

# Score (stay in tests/ — same cwd as init.sh used for repo-hash)
"$PLUGIN_ROOT/bin/deep-research-score.sh" "$SLUG"

# state.txt should now have phase=idle, current_exp_id cleared
phase=$(awk -F= '/^phase=/{print $2}' "$ART/troopers/rex/state.txt")
[[ "$phase" == "idle" ]] || { echo "FAIL: phase should be idle after score, got $phase" >&2; exit 1; }
pass "score updates state.txt phase to idle"

cur=$(awk -F= '/^current_exp_id=/{print $2}' "$ART/troopers/rex/state.txt")
[[ -z "$cur" ]] || { echo "FAIL: current_exp_id should be empty, got '$cur'" >&2; exit 1; }
pass "current_exp_id cleared"

# scoreboard.md updated with the row
grep -qE '\| exp-001 \| rex \| 0\.9500 \| ok' "$ART/scoreboard.md" \
  || { echo "FAIL: scoreboard row missing or wrong:" >&2; cat "$ART/scoreboard.md" >&2; exit 1; }
pass "scoreboard.md updated with exp-001 row"
