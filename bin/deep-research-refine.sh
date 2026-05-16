#!/usr/bin/env bash
# bin/deep-research-refine.sh — v0.34.0 D2
# Mid-experiment scope-narrowing primitive. Writes numbered refine-N.md
# into the trooper's current branch dir and nudges the pane.
#
# Usage: bin/deep-research-refine.sh <topic> <commander> <exp-id> <refinement-text>
#
# Exit codes:
#   0 = ok
#   1 = trooper or experiment dir missing
#   2 = usage error / invalid topic / invalid commander / invalid exp-id

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

[[ $# -eq 4 ]] || { log_error "Usage: $0 <topic> <commander> <exp-id> <refinement-text>"; exit 2; }
TOPIC="$1"
COMMANDER="$2"
EXP_ID="$3"
TEXT="$4"

cw_deep_research_normalize_topic TOPIC

[[ "$COMMANDER" =~ ^[a-z][a-z0-9-]*$ ]] \
  || { log_error "commander must match [a-z][a-z0-9-]*; got '$COMMANDER'"; exit 2; }

[[ "$EXP_ID" =~ ^exp-[0-9]+$ ]] \
  || { log_error "exp-id must match 'exp-[0-9]+'; got '$EXP_ID'"; exit 2; }

TOPIC_DIR="$(cw_topic_state_dir "$TOPIC")"
BRANCH_DIR="$TOPIC_DIR/_deep-research/troopers/$COMMANDER/experiments/$EXP_ID"
[[ -d "$BRANCH_DIR" ]] || { log_error "branch dir missing: $BRANCH_DIR"; exit 1; }

# Find next refine slot
n=1
while [[ -f "$BRANCH_DIR/refine-$n.md" ]]; do
  n=$((n + 1))
done
REFINE="$BRANCH_DIR/refine-$n.md"

printf '%s\n' "$TEXT" | cw_atomic_write "$REFINE"
log_info "[refine] wrote $REFINE"

# Nudge unless DRY_RUN. Use bin/send.sh which v0.33.0 D5 emits a
# mid-experiment warning for — that's expected and intentional here.
if [[ "${CW_DEEP_RESEARCH_DRY_RUN:-0}" != "1" ]]; then
  "$PLUGIN_ROOT/bin/send.sh" "$COMMANDER" "$TOPIC" \
    "REFINE: read $REFINE before continuing your current experiment ($EXP_ID)." \
    >/dev/null 2>&1 \
    || log_warn "[refine] send.sh nudge failed; trooper may not have noticed refine-$n.md"
fi

log_ok "[refine] $COMMANDER/$EXP_ID refine-$n.md sent"
