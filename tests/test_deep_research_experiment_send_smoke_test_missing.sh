#!/usr/bin/env bash
# tests/test_deep_research_experiment_send_smoke_test_missing.sh
# v0.43.0 Lane C: --smoke-test pointing at a non-existent script is rejected
# at flag-validation (before any state mutation).
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

TOPIC=deep-research-smoke-missing
TD="$(cw_topic_state_dir "$TOPIC")"
ART="$TD/_deep-research"
mkdir -p "$ART/troopers/rex" "$TD/rex-codex"
echo "$TOPIC" > "$ART/topic.txt"
echo "rex" > "$ART/troopers.txt"
cat > "$ART/metric.md" <<'M'
# Research goal

**Primary metric:** test_metric
**Direction:** maximize
M
cw_deep_research_trooper_state_write "$ART" rex \
  exp_counter=0 phase=idle current_exp_id= last_event=spawn
: > "$TD/rex-codex/outbox.jsonl"

set +e
out=$("$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
        --smoke-test "$SANDBOX/does-not-exist.sh" \
        "$TOPIC" rex exp-001 dummy-approach "dummy brief" 2>&1)
rc=$?
set -e

assert_eq "$rc" "2" "missing smoke-test script should exit 2"
assert_contains "$out" "smoke-test" "error mentions smoke-test"
# State mutation should NOT have happened
[[ ! -d "$ART/troopers/rex/experiments/exp-001" ]] \
  || { echo "FAIL: branch dir created before smoke-test validation" >&2; exit 1; }
pass "1. missing smoke-test script → rc=2 before any state mutation"

echo "test_deep_research_experiment_send_smoke_test_missing: 1 case passed"
