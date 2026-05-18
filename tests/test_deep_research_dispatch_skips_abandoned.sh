#!/usr/bin/env bash
# tests/test_deep_research_dispatch_skips_abandoned.sh
# v0.43.0 Lane D: experiment-send refuses to dispatch when trooper phase=abandoned.
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

TOPIC=deep-research-abandoned-dispatch
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
  exp_counter=6 phase=abandoned current_exp_id= lane_abandon_reason="encoder retired" \
  lane_abandon_ts=2026-05-18T00:00:00Z
: > "$TD/rex-codex/outbox.jsonl"

set +e
out=$("$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
        "$TOPIC" rex exp-007 dummy-approach "dummy brief" 2>&1)
rc=$?
set -e

[[ "$rc" -ne 0 ]] || { echo "FAIL: expected non-zero exit; got 0" >&2; echo "$out" >&2; exit 1; }
assert_contains "$out" "abandoned" "error message names the abandoned phase"
[[ ! -d "$ART/troopers/rex/experiments/exp-007" ]] \
  || { echo "FAIL: branch dir created for abandoned trooper" >&2; exit 1; }
pass "1. experiment-send refuses dispatch to abandoned trooper"

echo "test_deep_research_dispatch_skips_abandoned: 1 case passed"
