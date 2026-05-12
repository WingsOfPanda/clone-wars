#!/usr/bin/env bash
# bin/deep-research-experiment-send.sh — dispatch one codex trooper for one branch.
#
# Usage: bin/deep-research-experiment-send.sh <topic> <round> <commander> <branch_id>
#
# Renders experiment.md template with branch context + budget knobs from
# _deep-research/budget.txt; writes prompt to <branch-dir>/prompt.md; writes
# state file _deep-research/experiment-<commander>.txt (consult-shaped path
# so cw_consult_wait can find it); calls bin/send.sh @prompt-path to nudge
# the trooper pane (skipped under CW_DEEP_RESEARCH_DRY_RUN=1 for unit tests).

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

[[ $# -eq 4 ]] || { echo "Usage: $0 <topic> <round> <commander> <branch_id>" >&2; exit 2; }
TOPIC="$1"; ROUND="$2"; COMMANDER="$3"; BRANCH_ID="$4"

[[ "$TOPIC" == deep-research-* ]] \
  || { log_error "topic must start with 'deep-research-': $TOPIC"; exit 2; }
[[ "$TOPIC" =~ ^[a-z0-9-]+$ ]] || { log_error "invalid topic: $TOPIC"; exit 2; }
[[ "$ROUND" =~ ^[1-9][0-9]*$ ]] || { log_error "invalid round: $ROUND"; exit 2; }
cw_consult_assert_commander "$COMMANDER"
[[ "$BRANCH_ID" =~ ^[a-z0-9]+$ ]] || { log_error "invalid branch_id (lowercase alnum): $BRANCH_ID"; exit 2; }

ART_DIR="$(cw_consult_art_dir "$TOPIC")"
[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR not found — run deep-research-init first"; exit 1; }

ROUND_DIR="$ART_DIR/round-$ROUND"
BRANCHES_FILE="$ROUND_DIR/branches.txt"
[[ -f "$BRANCHES_FILE" ]] || { log_error "branches.txt missing for round $ROUND"; exit 1; }

# Look up branch row: TSV branch_id\tcommander\tlabel\tbrief
ROW=$(awk -F'\t' -v b="$BRANCH_ID" -v c="$COMMANDER" '$1==b && $2==c {print; exit}' "$BRANCHES_FILE")
[[ -n "$ROW" ]] || { log_error "branch '$BRANCH_ID' for '$COMMANDER' not in $BRANCHES_FILE"; exit 1; }
APPROACH_LABEL=$(printf '%s' "$ROW" | awk -F'\t' '{print $3}')
APPROACH_BRIEF=$(printf '%s' "$ROW" | awk -F'\t' '{print $4}')

BRANCH_DIR="$ART_DIR/round-$ROUND-$COMMANDER-$BRANCH_ID"
mkdir -p "$BRANCH_DIR/code"

# Read budget
BUDGET="$ART_DIR/budget.txt"
[[ -f "$BUDGET" ]] || { log_error "budget.txt missing"; exit 1; }
PER_BRANCH_TIMEOUT=$(grep '^per-branch-timeout-s=' "$BUDGET" | cut -d= -f2)
COST_WARNING=$(grep '^cost-warning-usd=' "$BUDGET" | cut -d= -f2)
ALLOW_NET=$(grep '^allow-net=' "$BUDGET" | cut -d= -f2)

# NET_GUIDANCE block (depends on --allow-net)
case "$ALLOW_NET" in
  true)  NET_GUIDANCE="  Net access is permitted; use it only as needed." ;;
  *)     NET_GUIDANCE="  Do NOT fetch external resources (no curl, wget, pip install of new packages, web fetches)." ;;
esac

TOPIC_TEXT=$(cat "$ART_DIR/topic.txt")
METRIC=$(cat "$ART_DIR/metric.txt")

# Trooper outbox path — must exist (spawned via bin/spawn.sh upstream)
TROOPER_DIR=$(cw_trooper_dir "$COMMANDER" codex "$TOPIC")
OUTBOX="$TROOPER_DIR/outbox.jsonl"
[[ -f "$OUTBOX" ]] || { log_error "outbox not found at $OUTBOX — was the trooper spawned?"; exit 1; }

# State file at the canonical consult-shape path so cw_consult_wait kind=experiment finds it
STATE_FILE="$ART_DIR/experiment-$COMMANDER.txt"
[[ ! -e "$STATE_FILE" ]] || {
  log_error "$STATE_FILE already exists; remove it (or run teardown) before retry"
  exit 1
}

# Render prompt from template
PROMPT_FILE="$BRANCH_DIR/prompt.md"
cw_consult_load_prompt deep-research/experiment.md \
  "TOPIC=$TOPIC_TEXT" \
  "METRIC=$METRIC" \
  "TIME_BUDGET_S=$PER_BRANCH_TIMEOUT" \
  "COST_WARNING=$COST_WARNING" \
  "ALLOW_NET=$ALLOW_NET" \
  "BRANCH_ID=$BRANCH_ID" \
  "APPROACH_LABEL=$APPROACH_LABEL" \
  "APPROACH_BRIEF=$APPROACH_BRIEF" \
  "BRANCH_DIR=$BRANCH_DIR" \
  "NET_GUIDANCE=$NET_GUIDANCE" \
  > "$PROMPT_FILE"

# Capture outbox offset for wait shim
OFFSET=$(wc -c < "$OUTBOX" | tr -d ' ')
printf 'OFFSET=%s\n' "$OFFSET" > "$STATE_FILE"

# DRY_RUN: skip the actual send.sh nudge so unit tests work without tmux
if [[ "${CW_DEEP_RESEARCH_DRY_RUN:-0}" == "1" ]]; then
  log_info "[experiment-send] $COMMANDER/$BRANCH_ID DRY_RUN — prompt rendered to $PROMPT_FILE"
  exit 0
fi

if ! "$PLUGIN_ROOT/bin/send.sh" "$COMMANDER" "$TOPIC" "@$PROMPT_FILE" >/dev/null; then
  log_error "send.sh failed; state file kept for retry"
  exit 1
fi

log_info "[experiment-send] $COMMANDER/$BRANCH_ID dispatched (round=$ROUND offset=$OFFSET)"
