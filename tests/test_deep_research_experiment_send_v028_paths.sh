#!/usr/bin/env bash
# tests/test_deep_research_experiment_send_v028_paths.sh — v0.28.0 path schema
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
export CW_DEEP_RESEARCH_DRY_RUN=1
mkdir -p "$CLONE_WARS_HOME"
echo "codex" > "$CLONE_WARS_HOME/providers-available.txt"

source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

SLUG=$("$PLUGIN_ROOT/bin/deep-research-init.sh" "optimize tiny mnist")
REPO_HASH=$(cw_repo_hash)
TD="$CLONE_WARS_HOME/state/$REPO_HASH/$SLUG"
ART="$TD/_deep-research"

# Seed the per-trooper state (would normally be done by directive Phase 4.a)
mkdir -p "$ART/troopers/rex/experiments"
cw_deep_research_trooper_state_write "$ART" rex \
  exp_counter=0 phase=idle current_exp_id= \
  last_event_ts=2026-05-13T08:00:00Z last_event=spawn probe_sent_ts=

# Seed metric.md
cat > "$ART/metric.md" <<'EOF'
**Primary metric:** accuracy
**Direction:** maximize
**min_acceptable:** >= 0.90
**target:** >= 0.99
**K_corroboration:** 1
**plateau_window:** 5
**plateau_threshold:** 0.01
EOF

# Mock trooper pane (DRY_RUN skips the send.sh nudge but still needs outbox)
mkdir -p "$TD/rex-codex"
echo '{"event":"ready","ts":"2026-05-13T08:00:00Z"}' > "$TD/rex-codex/outbox.jsonl"
echo '{"pane_id":"%99","spawned_at":"2026-05-13T08:00:00Z"}' > "$TD/rex-codex/pane.json"

# Dispatch exp-001 to rex
rc=0; "$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
  "$SLUG" rex exp-001 "test-approach" "test direction" 2>/tmp/dispatch.err || rc=$?
[[ "$rc" == "0" ]] \
  || { echo "FAIL: dispatch rc=$rc" >&2; cat /tmp/dispatch.err >&2; exit 1; }

# Per-trooper experiment dir exists
[[ -d "$ART/troopers/rex/experiments/exp-001" ]] \
  || { echo "FAIL: per-trooper experiment dir missing" >&2; ls -la "$ART/troopers/rex/" >&2; exit 1; }
pass "experiment dir created at troopers/rex/experiments/exp-001"

# state.txt updated atomically: phase=working, current_exp_id=exp-001, exp_counter=1
phase=$(awk -F= '/^phase=/{print $2}' "$ART/troopers/rex/state.txt")
current=$(awk -F= '/^current_exp_id=/{print $2}' "$ART/troopers/rex/state.txt")
counter=$(awk -F= '/^exp_counter=/{print $2}' "$ART/troopers/rex/state.txt")
[[ "$phase" == "working" ]] \
  || { echo "FAIL: state phase should be working, got $phase" >&2; exit 1; }
[[ "$current" == "exp-001" ]] \
  || { echo "FAIL: current_exp_id should be exp-001, got $current" >&2; exit 1; }
[[ "$counter" == "1" ]] \
  || { echo "FAIL: exp_counter should be 1, got $counter" >&2; exit 1; }
pass "state.txt updated: phase=working, current_exp_id=exp-001, counter=1"

# Legacy experiment-<commander>.txt MUST NOT exist (replaced by state.txt)
[[ ! -f "$ART/experiment-rex.txt" ]] \
  || { echo "FAIL: legacy experiment-rex.txt should not exist" >&2; exit 1; }
pass "legacy experiment-<commander>.txt schema removed"

# Re-dispatch while phase=working should fail
rc=0; "$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
  "$SLUG" rex exp-002 "another" "another direction" 2>/dev/null || rc=$?
[[ "$rc" != "0" ]] \
  || { echo "FAIL: re-dispatch while phase=working should fail; rc=$rc" >&2; exit 1; }
pass "re-dispatch while phase=working refused"
