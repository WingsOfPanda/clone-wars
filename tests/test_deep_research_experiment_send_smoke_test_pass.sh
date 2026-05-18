#!/usr/bin/env bash
# tests/test_deep_research_experiment_send_smoke_test_pass.sh
# v0.43.0 Lane C: --smoke-test <script> exits 0 → dispatch proceeds normally.
# Uses CW_DEEP_RESEARCH_DRY_RUN=1 to skip the actual tmux send.
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

TOPIC=deep-research-smoke-pass
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
**target:** >= 0.9
M
cw_deep_research_trooper_state_write "$ART" rex \
  exp_counter=0 phase=idle current_exp_id= last_event=spawn
: > "$TD/rex-codex/outbox.jsonl"

SCRIPT="$SANDBOX/smoke-pass.sh"
cat > "$SCRIPT" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$SCRIPT"

"$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
  --smoke-test "$SCRIPT" \
  "$TOPIC" rex exp-001 dummy-approach "dummy brief"

BRANCH_DIR="$ART/troopers/rex/experiments/exp-001"
assert_file_exists "$BRANCH_DIR/prompt.md" "prompt.md rendered after smoke pass"
[[ ! -f "$BRANCH_DIR/smoke-test.err" ]] \
  || { echo "FAIL: smoke-test.err present after successful smoke" >&2; exit 1; }
pass "1. smoke-test exits 0 → dispatch proceeds (prompt.md written)"

echo "test_deep_research_experiment_send_smoke_test_pass: 1 case passed"
