#!/usr/bin/env bash
# bin/deep-research-score.sh — write rolling scoreboard for a /clone-wars:deep-research topic.
#
# Usage: bin/deep-research-score.sh <topic>
#
# Reads all _deep-research/experiments/exp-*/result.json, validates each
# via cw_deep_research_validate_result_json, writes
# _deep-research/scoreboard.md (atomic tmp+mv). OK rows sorted desc by
# metric_value; failed/timeout/cost_blown rows grouped at the bottom in
# experiment-id order.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

[[ $# -eq 1 ]] || { log_error "Usage: $0 <topic>"; exit 2; }
TOPIC="$1"
[[ "$TOPIC" == deep-research-* ]] \
  || { log_error "topic must start with 'deep-research-': $TOPIC"; exit 2; }
cw_consult_topic_validate "$TOPIC" || { log_error "invalid topic: $TOPIC"; exit 2; }

state_root="${CLONE_WARS_HOME:-$HOME/.clone-wars}"
repo_hash=$(cw_repo_hash)
TOPIC_DIR="$state_root/state/$repo_hash/$TOPIC"
ART_DIR="$TOPIC_DIR/_deep-research"
TROOPERS_DIR="$ART_DIR/troopers"
[[ -d "$TROOPERS_DIR" ]] || { log_error "troopers dir missing: $TROOPERS_DIR"; exit 1; }

SB_TMP=$(mktemp)
OK_ROWS=$(mktemp)
FAIL_ROWS=$(mktemp)
trap 'rm -f "$SB_TMP" "$OK_ROWS" "$FAIL_ROWS"' EXIT

# v0.28.0: per-trooper layout. Iterate _deep-research/troopers/<cmdr>/experiments/<exp-id>/.
# Commander comes from the parent dir; exp-id is the leaf basename.
shopt -s nullglob
for branch_dir in "$TROOPERS_DIR"/*/experiments/*/; do
  branch_dir="${branch_dir%/}"
  result="$branch_dir/result.json"
  [[ -f "$result" ]] || continue

  exp_id=$(basename "$branch_dir")                                # exp-007
  cmdr=$(basename "$(dirname "$(dirname "$branch_dir")")")        # rex

  # Validate schema (sets stderr message on failure)
  (cd "$branch_dir" && cw_deep_research_validate_result_json result.json) 2>/dev/null \
    || { log_warn "result.json schema invalid: $result (skipping)"; continue; }

  # Extract fields (prefer jq, fall back to grep)
  if command -v jq >/dev/null 2>&1; then
    metric=$(jq -r '.metric_value' "$result")
    status=$(jq -r '.status' "$result")
    runtime=$(jq -r '.runtime_s' "$result")
    label=$(jq -r '.approach_label' "$result")
  else
    metric=$(grep -oE '"metric_value"[[:space:]]*:[[:space:]]*[^,}]+' "$result" \
      | sed 's/.*:[[:space:]]*//' | tr -d ' "')
    status=$(grep -oE '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$result" \
      | sed 's/.*"\([^"]*\)"/\1/')
    runtime=$(grep -oE '"runtime_s"[[:space:]]*:[[:space:]]*[0-9.]+' "$result" \
      | sed 's/.*:[[:space:]]*//')
    label=$(grep -oE '"approach_label"[[:space:]]*:[[:space:]]*"[^"]*"' "$result" \
      | sed 's/.*"\([^"]*\)"/\1/')
  fi

  if [[ "$status" == "ok" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$metric" "$exp_id" "$cmdr" "$status" "$runtime" "$label" >> "$OK_ROWS"
  else
    printf '%s\t%s\t%s\t%s\t%s\n' "$exp_id" "$cmdr" "$status" "$runtime" "$label" >> "$FAIL_ROWS"
  fi
done

{
  printf '# Scoreboard\n\n'
  printf '| Rank | Experiment | Commander | Metric | Status | Runtime | Approach |\n'
  printf '|---|---|---|---|---|---|---|\n'
  rank=1
  if [[ -s "$OK_ROWS" ]]; then
    while IFS=$'\t' read -r metric exp cmdr status runtime label; do
      printf '| %d | %s | %s | %s | %s | %ss | %s |\n' \
        "$rank" "$exp" "$cmdr" "$metric" "$status" "$runtime" "$label"
      rank=$((rank + 1))
    done < <(sort -t$'\t' -k1,1 -rn "$OK_ROWS")
  fi
  if [[ -s "$FAIL_ROWS" ]]; then
    while IFS=$'\t' read -r exp cmdr status runtime label; do
      printf '| %d | %s | %s | n/a | %s | %ss | %s |\n' \
        "$rank" "$exp" "$cmdr" "$status" "$runtime" "$label"
      rank=$((rank + 1))
    done < <(sort -t$'\t' -k1,1 "$FAIL_ROWS")
  fi
} > "$SB_TMP"

SB="$ART_DIR/scoreboard.md"
mv "$SB_TMP" "$SB"
log_ok "[score] scoreboard at $SB"

# v0.28.0: clear phase=idle ONLY for troopers whose CURRENT experiment has a
# result.json on disk. The previous gate used `ls <glob> >/dev/null` which —
# under `shopt -s nullglob` — silently degrades to `ls` with no args (lists
# the cwd, returns 0). That race-condition (v0.28.0 dogfood BUG #2) flipped
# still-working troopers to idle whenever a peer trooper emitted `done`,
# corrupting the next dispatch.
#
# v0.28.1: check `current_exp_id` from state.txt + verify that specific
# experiment's result.json exists. Skip troopers with empty current_exp_id
# (already idle) or whose current experiment hasn't finished yet.
shopt -s nullglob
for cmdr_dir in "$TROOPERS_DIR"/*/; do
  cmdr=$(basename "${cmdr_dir%/}")
  state_file="$cmdr_dir/state.txt"
  [[ -f "$state_file" ]] || continue

  current_exp_id=$(awk -F= '/^current_exp_id=/{print $2}' "$state_file")
  [[ -n "$current_exp_id" ]] || continue

  # Only flip state if the trooper's CURRENT experiment has a result.json.
  if [[ -f "$cmdr_dir/experiments/$current_exp_id/result.json" ]]; then
    cw_deep_research_trooper_state_write "$ART_DIR" "$cmdr" \
      phase=idle \
      current_exp_id= \
      last_event_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      last_event=scored
  fi
done
