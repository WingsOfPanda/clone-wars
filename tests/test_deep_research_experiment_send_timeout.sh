#!/usr/bin/env bash
# tests/test_deep_research_experiment_send_timeout.sh — v0.52.0 #26
# Validates --timeout N flag on experiment-send.sh with precedence
# CLI flag > env var > cw_consult_timeout experiment default.
#
# Uses CW_DEEP_RESEARCH_DRY_RUN=1 to skip pane nudge + spawn; we only
# care about the resolved TIME_BUDGET_S value, which the script writes
# into the inbox/prompt template.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/contracts.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# Minimum fixture for experiment-send to not bail early.
TOPIC=deep-research-v052-timeout-test
# cw_topic_repo_hash hashes $PWD; the script runs from this test's cwd.
REPO_HASH=$(cw_topic_repo_hash)
TD="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC"
ART="$TD/_deep-research"
mkdir -p "$ART/troopers/rex/experiments"
mkdir -p "$TD/rex-codex"
# Outbox sentinel + state.txt as required by experiment-send.sh preconditions
touch "$TD/rex-codex/outbox.jsonl"
cat > "$ART/troopers/rex/state.txt" <<EOF
phase=idle
last_event_ts=2026-05-22T00:00:00Z
last_event=spawn
current_exp_id=
exp_counter=0
probe_sent_ts=
EOF
# metric.md
cat > "$ART/metric.md" <<EOF
# Research goal

**Primary metric:** test_metric
**Direction:** maximize
EOF
# topic.txt (used by experiment-send for {{TOPIC}} interpolation)
echo "$TOPIC" > "$ART/topic.txt"

# Default = cw_consult_timeout experiment
default_ts=$(cw_consult_timeout experiment)

# Case 1: no flag, no env → default
CW_DEEP_RESEARCH_DRY_RUN=1 bash "$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
  "$TOPIC" rex exp-001 label1 "brief1" > "$TMP/case1.out" 2>&1 || true
grep -q "time_budget=$default_ts\b" "$TMP/case1.out" \
  || { echo "FAIL case1: expected time_budget=$default_ts; got:"; cat "$TMP/case1.out"; exit 1; }
pass "case1: no flag, no env → cw_consult_timeout default ($default_ts)"

# Reset state for next dispatch (state.txt phase will have advanced).
cat > "$ART/troopers/rex/state.txt" <<EOF
phase=idle
last_event_ts=2026-05-22T00:00:00Z
last_event=spawn
current_exp_id=
exp_counter=0
probe_sent_ts=
EOF

# Case 2: --timeout 900 → 900
CW_DEEP_RESEARCH_DRY_RUN=1 bash "$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
  --timeout 900 "$TOPIC" rex exp-002 label2 "brief2" > "$TMP/case2.out" 2>&1 || true
grep -q "time_budget=900\b" "$TMP/case2.out" \
  || { echo "FAIL case2: expected time_budget=900; got:"; cat "$TMP/case2.out"; exit 1; }
pass "case2: --timeout 900 → 900"

# Reset
cat > "$ART/troopers/rex/state.txt" <<EOF
phase=idle
last_event_ts=2026-05-22T00:00:00Z
last_event=spawn
current_exp_id=
exp_counter=0
probe_sent_ts=
EOF

# Case 3: env=600 + --timeout 900 → 900 (CLI wins)
CW_DEEP_RESEARCH_DRY_RUN=1 CW_DEEP_RESEARCH_EXPERIMENT_TIMEOUT_OVERRIDE=600 \
  bash "$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
  --timeout 900 "$TOPIC" rex exp-003 label3 "brief3" > "$TMP/case3.out" 2>&1 || true
grep -q "time_budget=900\b" "$TMP/case3.out" \
  || { echo "FAIL case3: expected time_budget=900 (CLI > env); got:"; cat "$TMP/case3.out"; exit 1; }
pass "case3: CLI flag wins over env var"

# Case 4: --timeout abc → exit 2 with usage error
rc=0
CW_DEEP_RESEARCH_DRY_RUN=1 bash "$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
  --timeout abc "$TOPIC" rex exp-004 label4 "brief4" > "$TMP/case4.out" 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] || { echo "FAIL case4: expected exit 2; got $rc"; cat "$TMP/case4.out"; exit 1; }
grep -q "positive integer" "$TMP/case4.out" \
  || { echo "FAIL case4: expected usage error message; got:"; cat "$TMP/case4.out"; exit 1; }
pass "case4: --timeout abc → exit 2 with usage error"

echo "ALL: ok"
