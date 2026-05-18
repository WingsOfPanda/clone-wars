#!/usr/bin/env bash
# tests/test_deep_research_experiment_send_smoke_test_fail.sh
# v0.43.0 Lane C: --smoke-test exits non-zero → rc=2, smoke-test.err captured,
# trooper state unchanged (phase stays idle).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
cd "$SANDBOX"
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"
export CW_DEEP_RESEARCH_DRY_RUN=1

TOPIC=deep-research-smoke-fail
TD="$(cw_topic_state_dir "$TOPIC")"
ART="$TD/_deep-research"
mkdir -p "$ART/troopers/rex" "$TD/rex-codex"
echo "$TOPIC" > "$ART/topic.txt"
echo "rex" > "$ART/troopers.txt"
cat > "$ART/metric.md" <<'M'
# Research goal

**Primary metric:** test_metric
**Direction:** maximize
**min_acceptable:** >= 0.5
M
cw_deep_research_trooper_state_write "$ART" rex \
  exp_counter=0 phase=idle current_exp_id= last_event=spawn
: > "$TD/rex-codex/outbox.jsonl"

SCRIPT="$SANDBOX/smoke-fail.sh"
cat > "$SCRIPT" <<'EOF'
#!/usr/bin/env bash
echo "synthetic failure" >&2
exit 1
EOF
chmod +x "$SCRIPT"

set +e
out=$("$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
        --smoke-test "$SCRIPT" \
        "$TOPIC" rex exp-001 dummy-approach "dummy brief" 2>&1)
rc=$?
set -e

assert_eq "$rc" "2" "smoke-test failure should exit 2"
BRANCH_DIR="$ART/troopers/rex/experiments/exp-001"
assert_file_exists "$BRANCH_DIR/smoke-test.err" "smoke-test.err captured"
ERR_BODY=$(cat "$BRANCH_DIR/smoke-test.err")
assert_contains "$ERR_BODY" "synthetic failure" "stderr captured in smoke-test.err"
cur_phase=$(cw_deep_research_trooper_state_field "$ART" rex phase)
assert_eq "$cur_phase" "idle" "trooper state unchanged on smoke fail"
pass "1. smoke-test fails → rc=2, .err captured, state preserved"

echo "test_deep_research_experiment_send_smoke_test_fail: 1 case passed"
