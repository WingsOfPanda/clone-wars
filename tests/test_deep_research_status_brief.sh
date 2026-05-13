#!/usr/bin/env bash
# tests/test_deep_research_status_brief.sh — v0.28.2 helper coverage.
#
# cw_deep_research_render_status_brief emits a compact chat-shaped status
# form to stdout. Cases:
#   1. Both troopers idle with results: rows show metric + status; scoreboard top-3.
#   2. One trooper working, one idle: working trooper shows (running) + approach hint.
#   3. troopers.txt missing: helper falls back to filesystem discovery.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

# --- Case 1: both troopers idle with scored results ---
ART=$(mktemp -d); trap 'rm -rf "$ART"' EXIT
mkdir -p "$ART/troopers/rex/experiments/exp-001"
mkdir -p "$ART/troopers/keeli/experiments/exp-001"
printf 'rex\nkeeli\n' > "$ART/troopers.txt"

cat > "$ART/metric.md" <<'EOF'
# Research goal

**Primary metric:** accuracy
**Direction:** maximize
**min_acceptable:** >= 0.97
**target:** >= 0.995
**K_corroboration:** 1
**plateau_window:** 5
**plateau_threshold:** 0.01
EOF

cat > "$ART/scoreboard.md" <<'EOF'
# Scoreboard

| Rank | Experiment | Commander | Metric | Status | Runtime | Approach |
|---|---|---|---|---|---|---|
| 1 | exp-001 | keeli | 0.9971 | ok | 162.81s | compact-resnet-group-conv |
| 2 | exp-001 | rex | 0.9968 | ok | 173.0s | depthwise-separable-cnn |
EOF

cat > "$ART/troopers/rex/state.txt" <<'EOF'
phase=idle
current_exp_id=
exp_counter=1
last_event_ts=2026-05-13T06:18:43Z
last_event=scored
probe_sent_ts=
EOF
cat > "$ART/troopers/keeli/state.txt" <<'EOF'
phase=idle
current_exp_id=
exp_counter=1
last_event_ts=2026-05-13T06:19:21Z
last_event=scored
probe_sent_ts=
EOF
cat > "$ART/troopers/rex/experiments/exp-001/result.json" <<'EOF'
{"branch_id":"exp-001","approach_label":"depthwise-separable-cnn","metric_name":"accuracy","metric_value":0.9968,"status":"ok","runtime_s":173.0,"log_paths":["./stdout.log","./stderr.log"],"notes":"rex"}
EOF
cat > "$ART/troopers/keeli/experiments/exp-001/result.json" <<'EOF'
{"branch_id":"exp-001","approach_label":"compact-resnet-group-conv","metric_name":"accuracy","metric_value":0.9971,"status":"ok","runtime_s":162.81,"log_paths":["./stdout.log","./stderr.log"],"notes":"keeli"}
EOF

out=$(cw_deep_research_render_status_brief "$ART" keeli exp-001)
assert_contains "$out" "## Experiment status — exp-001 (keeli) just landed" "title cites latest"
assert_contains "$out" "| Trooper |" "table header present"
assert_contains "$out" "| rex | idle | exp-001 | depthwise-separable-cnn | 0.9968 ok |" "rex row"
assert_contains "$out" "| keeli | idle | exp-001 | compact-resnet-group-conv | 0.9971 ok |" "keeli row"
assert_contains "$out" "**Scoreboard top 3:**" "scoreboard section"
assert_contains "$out" "1. keeli/exp-001 — 0.9971 — compact-resnet-group-conv" "scoreboard top row"
assert_contains "$out" "**Completion check:** floor_met=yes  target_met=yes  K_so_far=1/1  plateau=no" "completion line"
pass "Case 1: both idle + scored renders complete table + scoreboard + completion check"

# --- Case 2 (v0.28.2 F1 lock): rex working with prompt.md present, keeli idle ---
# Working trooper's approach must be parsed from prompt.md when result.json is
# not yet on disk. Previous "(see prompt.md)" fallback was user-hostile.
cat > "$ART/troopers/rex/state.txt" <<'EOF'
phase=working
current_exp_id=exp-002
exp_counter=2
last_event_ts=2026-05-13T07:00:00Z
last_event=dispatched
probe_sent_ts=
EOF
mkdir -p "$ART/troopers/rex/experiments/exp-002"
# F1 fix: experiment-send.sh writes prompt.md at dispatch with the
# `Approach label:  <slug>` line; status_brief must parse it.
cat > "$ART/troopers/rex/experiments/exp-002/prompt.md" <<'EOF'
You are a codex trooper executing one experiment in /clone-wars:deep-research.

Topic: test topic

Your experiment:
  Experiment ID:   exp-002
  Approach label:  squeezenet-style-fire-modules
  Approach brief:  short brief here

END_OF_INSTRUCTION
EOF

out=$(cw_deep_research_render_status_brief "$ART" keeli exp-001)
assert_contains "$out" "| rex | working | exp-002 | squeezenet-style-fire-modules | (running) |" "rex working row with approach from prompt.md (F1)"
assert_contains "$out" "| keeli | idle | exp-001 | compact-resnet-group-conv | 0.9971 ok |" "keeli still idle/scored"
pass "Case 2: working trooper approach parsed from prompt.md (F1 lock); idle trooper shows metric"

# --- Case 6 (NEW v0.28.2 F1 lock): working trooper with prompt.md ABSENT ---
# Fallback when prompt.md is also missing (e.g. dispatch failed mid-write) —
# approach column degrades to "—" not the user-hostile "(see prompt.md)".
rm "$ART/troopers/rex/experiments/exp-002/prompt.md"
out_nop=$(cw_deep_research_render_status_brief "$ART" keeli exp-001)
assert_contains "$out_nop" "| rex | working | exp-002 | — | (running) |" "working trooper without prompt.md degrades to em-dash, not '(see prompt.md)'"
[[ "$out_nop" == *"(see prompt.md)"* ]] \
  && { echo "FAIL: legacy '(see prompt.md)' fallback should be gone after F1 fix" >&2; exit 1; }
pass "Case 6: working trooper without prompt.md → approach=— (F1 fallback chain works)"
# Restore prompt.md for downstream cases that walk this state.
cat > "$ART/troopers/rex/experiments/exp-002/prompt.md" <<'EOF'
Approach label:  squeezenet-style-fire-modules
EOF

# --- Case 3: troopers.txt missing → fallback to filesystem ---
rm "$ART/troopers.txt"
out_fb=$(cw_deep_research_render_status_brief "$ART")
assert_contains "$out_fb" "| rex |" "rex row via filesystem fallback"
assert_contains "$out_fb" "| keeli |" "keeli row via filesystem fallback"
pass "Case 3: troopers.txt absent → cw_deep_research_list_commanders falls back to troopers/*/"

# --- Case 4: no latest args → generic title ---
out_gen=$(cw_deep_research_render_status_brief "$ART")
assert_contains "$out_gen" "## Experiment status" "generic title"
[[ "$out_gen" == *"just landed"* ]] \
  && { echo "FAIL: generic header should NOT include 'just landed'" >&2; exit 1; }
pass "Case 4: no latest args produces generic title"

# --- Case 5: empty art-dir rejection ---
err=$(cw_deep_research_render_status_brief /nonexistent/path 2>&1) && {
  echo "FAIL: should reject missing art-dir" >&2; exit 1
}
assert_contains "$err" "art-dir missing" "error mentions missing art-dir"
pass "Case 5: missing art-dir rejected"

echo "test_deep_research_status_brief: 18 assertions green"
