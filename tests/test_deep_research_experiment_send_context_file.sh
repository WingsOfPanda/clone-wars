#!/usr/bin/env bash
# v0.34.0 D4 — --context-file interpolation into rendered prompt
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP"

source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"

TOPIC=deep-research-v034ctx
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
_reset_state() {
  cat > "$ART/troopers/rex/state.txt" <<EOF
phase=idle
current_exp_id=
exp_counter=0
last_event_ts=
last_event=spawn
probe_sent_ts=
EOF
}
_reset_state
touch "$TOPIC_DIR/rex-codex/outbox.jsonl"
printf '%s' "topic text" > "$ART/topic.txt"

# Case 1: --context-file with existing file → content interpolated into prompt.md
CTX="$TMP/ctx.md"
cat > "$CTX" <<'EOF'
## Background

This experiment must satisfy GDPR data minimization. Anonymize emails before scoring.
EOF
CW_DEEP_RESEARCH_DRY_RUN=1 "$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
  --context-file="$CTX" \
  "$TOPIC" rex exp-010 'gdpr-respecting' 'minimal-pii pipeline' 2>/dev/null
PROMPT="$ART/troopers/rex/experiments/exp-010/prompt.md"
assert_file_exists "$PROMPT" "case 1 prompt.md should exist"
grep -q "GDPR data minimization" "$PROMPT" \
  || { echo "FAIL: case 1 --context-file content not in prompt. dumping:"; cat "$PROMPT"; exit 1; }
pass "1. --context-file content interpolated into prompt.md"

_reset_state

# Case 2: --context-file unreadable → rc=2
rc=0
out=$( "$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
  --context-file="$TMP/NO-SUCH-FILE.md" \
  "$TOPIC" rex exp-011 'label-x' 'brief-x' 2>&1 ) || rc=$?
[[ "$rc" == 2 ]] \
  || { echo "FAIL: case 2 unreadable --context-file should rc=2 (got $rc)"; exit 1; }
echo "$out" | grep -q "cannot read --context-file" \
  || { echo "FAIL: case 2 reason missing. got: $out"; exit 1; }
pass "2. --context-file unreadable → rc=2 with specific error"

_reset_state

# Case 3: --context-file omitted → {{TASK_CONTEXT}} placeholder removed (not leaked)
CW_DEEP_RESEARCH_DRY_RUN=1 "$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
  "$TOPIC" rex exp-012 'label-y' 'brief-y' 2>/dev/null
PROMPT="$ART/troopers/rex/experiments/exp-012/prompt.md"
grep -q '{{TASK_CONTEXT}}' "$PROMPT" \
  && { echo "FAIL: case 3 {{TASK_CONTEXT}} placeholder leaked into prompt"; exit 1; }
pass "3. --context-file omitted → no {{TASK_CONTEXT}} leak"

echo "test_deep_research_experiment_send_context_file: 3 cases passed"
