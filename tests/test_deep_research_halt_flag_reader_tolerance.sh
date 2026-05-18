#!/usr/bin/env bash
# tests/test_deep_research_halt_flag_reader_tolerance.sh
# v0.43.0 Lane E: finalize.sh reads halt.flag without crashing on either:
#   - new structured key=value lines (preferred)
#   - legacy free-form prose (one-line from older archives)
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

run_case() {
  local LABEL="$1" HALT_BODY="$2"
  local SANDBOX
  SANDBOX=$(mktemp -d)
  export CLONE_WARS_HOME="$SANDBOX/.clone-wars"
  cd "$SANDBOX"
  local TOPIC="deep-research-halt-read-$LABEL"
  local TD ART
  TD="$(cw_topic_state_dir "$TOPIC")"
  ART="$TD/_deep-research"
  mkdir -p "$ART/troopers/rex"
  echo "$TOPIC" > "$ART/topic.txt"
  echo "rex" > "$ART/troopers.txt"
  cat > "$ART/metric.md" <<'M'
# Research goal

**Primary metric:** test_metric
**Direction:** maximize
M
  cw_deep_research_trooper_state_write "$ART" rex phase=idle exp_counter=1 last_event=scored
  date -u +%Y-%m-%dT%H:%M:%SZ > "$ART/session-start.txt"
  printf '%s' "$HALT_BODY" > "$ART/halt.flag"

  "$PLUGIN_ROOT/bin/deep-research-finalize.sh" "$TOPIC" \
    || { echo "FAIL: finalize rc!=0 on case $LABEL" >&2; exit 1; }
  grep -q '## Halt' "$ART/session-summary.md" \
    || { echo "FAIL: ## Halt missing after finalize on case $LABEL" >&2; exit 1; }
  pass "$LABEL: finalize tolerates halt.flag body"
  rm -rf "$SANDBOX"
}

run_case "structured" "$(printf 'halted_by=yoda\nhalted_at=2026-05-18T05:00:00Z\nreason=target met\n')"
run_case "legacy-prose" "yoda-halted at 16:15:34Z: target met across 3 runs"

echo "test_deep_research_halt_flag_reader_tolerance: 2 cases passed"
