#!/usr/bin/env bash
# v0.34.0 D3 — --inputs flag probes file readability before dispatch
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP"

source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"

# Set up a minimal valid topic state (so the script reaches the flag parser)
TOPIC=deep-research-v034in
TOPIC_DIR="$(cw_topic_state_dir "$TOPIC")"
ART="$TOPIC_DIR/_deep-research"
mkdir -p "$ART/troopers/rex" "$TOPIC_DIR/rex-codex"
cat > "$ART/metric.md" <<'EOF'
# Research goal

**Primary metric:** accuracy
**Direction:** maximize
**min_acceptable:** >= 0.90
**K_corroboration:** 1
**plateau_window:** 5
**plateau_threshold:** 0.01
EOF
cat > "$ART/troopers/rex/state.txt" <<'EOF'
phase=idle
current_exp_id=
exp_counter=0
last_event_ts=
last_event=spawn
probe_sent_ts=
EOF
touch "$TOPIC_DIR/rex-codex/outbox.jsonl"
printf '%s' "topic text" > "$ART/topic.txt"

# Case 1: --inputs with all-readable paths → no pre-flight error in stderr
readable1="$TMP/in1.txt"; touch "$readable1"
readable2="$TMP/in2.txt"; touch "$readable2"
out=$( CW_DEEP_RESEARCH_DRY_RUN=1 "$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
  --inputs="$readable1,$readable2" \
  "$TOPIC" rex exp-001 'label-1' 'brief one' 2>&1 ) || true
echo "$out" | grep -q "pre-flight: cannot read" \
  && { echo "FAIL: case 1 readable paths should NOT trip probe. got: $out"; exit 1; }
pass "1. --inputs with readable paths passes probe"

# Case 2: --inputs with one unreadable path → rc=2 with specific path
rc=0
out=$( "$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
  --inputs="$readable1,$TMP/MISSING.txt" \
  "$TOPIC" rex exp-002 'label-2' 'brief two' 2>&1 ) || rc=$?
[[ "$rc" == 2 ]] \
  || { echo "FAIL: case 2 missing input should rc=2 (got $rc). out: $out"; exit 1; }
echo "$out" | grep -q "pre-flight: cannot read" \
  || { echo "FAIL: case 2 probe message missing. got: $out"; exit 1; }
echo "$out" | grep -q "MISSING.txt" \
  || { echo "FAIL: case 2 specific path missing from message. got: $out"; exit 1; }
pass "2. --inputs with unreadable path → rc=2 with specific path"

# Case 3: --inputs omitted → no pre-flight probe message ever surfaces
# (reset rex state because case 1 may have flipped it)
cat > "$ART/troopers/rex/state.txt" <<'EOF'
phase=idle
current_exp_id=
exp_counter=0
last_event_ts=
last_event=spawn
probe_sent_ts=
EOF
out=$( CW_DEEP_RESEARCH_DRY_RUN=1 "$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
  "$TOPIC" rex exp-003 'label-3' 'brief three' 2>&1 ) || true
echo "$out" | grep -q "pre-flight: cannot read" \
  && { echo "FAIL: case 3 no --inputs should never emit pre-flight message"; exit 1; }
pass "3. --inputs omitted → no probe (back-compat)"

echo "test_deep_research_experiment_send_inputs_flag: 3 cases passed"
