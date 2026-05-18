#!/usr/bin/env bash
# tests/test_deep_research_finalize_renders_summary.sh
# v0.43.0 Lane A: finalize re-renders session-summary.md UNCONDITIONALLY
# before appending ## Halt section (not just when missing).
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

TOPIC=deep-research-finalize-test
TD="$(cw_topic_state_dir "$TOPIC")"
ART="$TD/_deep-research"
mkdir -p "$ART/troopers/rex"

# Seed minimal artefacts
echo "$TOPIC" > "$ART/topic.txt"
echo "rex" > "$ART/troopers.txt"
cat > "$ART/metric.md" <<'M'
# Research goal

**Primary metric:** test_metric
**Direction:** maximize
**min_acceptable:** >= 0.5
**target:** >= 0.9
**K_corroboration:** 1
**plateau_window:** 5
**plateau_threshold:** 0.01
M
date -u +%Y-%m-%dT%H:%M:%SZ > "$ART/session-start.txt"
echo "none" > "$ART/time-budget.txt"

# Trooper state: phase=idle (post-experiment)
cw_deep_research_trooper_state_write "$ART" rex \
  exp_counter=1 phase=idle current_exp_id= last_event=scored

# Write STALE session-summary that the trooper state contradicts
cat > "$ART/session-summary.md" <<'STALE'
# Research session — stale

| Trooper | Phase | Current | Last event |
|---|---|---|---|
| rex | working | exp-001 | stale-event |
STALE

echo "yoda-halted at $(date -u +%H:%M:%SZ)" > "$ART/halt.flag"

# Run finalize
"$PLUGIN_ROOT/bin/deep-research-finalize.sh" "$TOPIC"

# Assert: summary now reflects the FRESH trooper state (phase=complete after finalize)
SS=$(cat "$ART/session-summary.md")
assert_contains "$SS" '| rex |' "rex row present in summary"
[[ "$SS" != *"| rex | working | exp-001 |"* ]] \
  || { echo "FAIL: summary still contains stale working row" >&2; echo "$SS" >&2; exit 1; }
assert_contains "$SS" '## Halt' "Halt section appended"
pass "1. finalize re-renders summary with fresh state, then appends Halt"

echo "test_deep_research_finalize_renders_summary: 1 case passed"
