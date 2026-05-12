#!/usr/bin/env bash
# bin/deep-research-experiment-send.sh — dispatch ONE experiment to a codex
# trooper in /clone-wars:deep-research.
#
# Usage: bin/deep-research-experiment-send.sh \
#          <topic> <commander> <exp-id> <approach-label> <approach-brief>
#
# Renders the experiment prompt by interpolating
# config/prompt-templates/deep-research/experiment.md with topic + metric
# block + experiment-specific fields. Writes the inbox + nudges the pane
# (unless CW_DEEP_RESEARCH_DRY_RUN=1).
#
# Creates _deep-research/experiments/exp-NNN-<cmdr>/code/ + prompt.md.
# Writes experiment-<commander>.txt state file (consult-shape) for the
# wait shim.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/contracts.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

[[ $# -eq 5 ]] || { log_error "Usage: $0 <topic> <commander> <exp-id> <approach-label> <approach-brief>"; exit 2; }
TOPIC="$1"
COMMANDER="$2"
EXP_ID="$3"
APPROACH_LABEL="$4"
APPROACH_BRIEF="$5"

[[ "$TOPIC" == deep-research-* ]] \
  || { log_error "topic must start with 'deep-research-': $TOPIC"; exit 2; }
cw_consult_topic_validate "$TOPIC" || { log_error "invalid topic: $TOPIC"; exit 2; }

# exp-id must match exp-NNN (1+ digit; 3-digit zero-padded suggested)
[[ "$EXP_ID" =~ ^exp-[0-9]+$ ]] \
  || { log_error "exp-id must match 'exp-[0-9]+'; got '$EXP_ID'"; exit 2; }

[[ "$COMMANDER" =~ ^[a-z][a-z0-9-]*$ ]] \
  || { log_error "commander must match [a-z][a-z0-9-]*; got '$COMMANDER'"; exit 2; }

state_root="${CLONE_WARS_HOME:-$HOME/.clone-wars}"
repo_hash=$(cw_repo_hash)
TOPIC_DIR="$state_root/state/$repo_hash/$TOPIC"
ART_DIR="$TOPIC_DIR/_deep-research"
[[ -d "$ART_DIR" ]] || { log_error "topic state dir missing: $ART_DIR (was deep-research-init.sh run?)"; exit 1; }

METRIC_MD="$ART_DIR/metric.md"
[[ -f "$METRIC_MD" ]] \
  || { log_error "metric.md missing at $METRIC_MD (directive's Phase 1 must run before dispatch)"; exit 1; }

# State file at consult-shape path (one per commander; cw_consult_wait reads here)
STATE_FILE="$ART_DIR/experiment-$COMMANDER.txt"
[[ -f "$STATE_FILE" ]] \
  && { log_error "state file $STATE_FILE already exists — trooper has an in-flight dispatch. Wait or teardown first."; exit 1; }

# Branch dir at flat experiments/exp-NNN-<cmdr>/
BRANCH_DIR="$ART_DIR/experiments/$EXP_ID-$COMMANDER"
mkdir -p "$BRANCH_DIR/code"

# Trooper pane: trooper outbox must exist (means trooper was spawned)
OUTBOX="$TOPIC_DIR/$COMMANDER-codex/outbox.jsonl"
[[ -f "$OUTBOX" ]] \
  || { log_error "trooper outbox missing: $OUTBOX (was spawn.sh run for $COMMANDER?)"; exit 1; }

# Compute current outbox offset (for cw_consult_wait OFFSET= state file)
offset=$(wc -c < "$OUTBOX" | tr -d '[:space:]')

# Per-experiment wall-clock cap. Defaults per lib/contracts.sh; env override.
TIME_BUDGET_S="${CW_DEEP_RESEARCH_EXPERIMENT_TIMEOUT_OVERRIDE:-$(cw_consult_timeout experiment)}"

# Metric name = first non-bold non-section line under "**Primary metric:**" header
METRIC_NAME=$(awk '
  /^\*\*Primary metric:\*\*/ {
    sub(/^\*\*Primary metric:\*\*[[:space:]]+/, "")
    print
    exit
  }
' "$METRIC_MD")
[[ -n "$METRIC_NAME" ]] \
  || { log_error "could not parse Primary metric from $METRIC_MD"; exit 1; }

# Metric block = entire metric.md body (interpolated as-is)
METRIC_BLOCK=$(<"$METRIC_MD")

# Render prompt from template
TEMPLATE="$PLUGIN_ROOT/config/prompt-templates/deep-research/experiment.md"
[[ -f "$TEMPLATE" ]] || { log_error "template missing: $TEMPLATE"; exit 1; }

PROMPT_FILE="$BRANCH_DIR/prompt.md"

# Substitute METRIC_BLOCK (multi-line) via awk, then single-line tokens via sed.
TOPIC_TEXT_VAL=$(cat "$ART_DIR/topic.txt")
awk -v block="$METRIC_BLOCK" '
  { gsub(/\{\{METRIC_BLOCK\}\}/, block); print }
' "$TEMPLATE" \
  | sed \
      -e "s|{{TOPIC}}|$(printf '%s' "$TOPIC_TEXT_VAL" | sed 's/[\\&|]/\\&/g')|g" \
      -e "s|{{EXP_ID}}|$EXP_ID|g" \
      -e "s|{{APPROACH_LABEL}}|$(printf '%s' "$APPROACH_LABEL" | sed 's/[\\&|]/\\&/g')|g" \
      -e "s|{{APPROACH_BRIEF}}|$(printf '%s' "$APPROACH_BRIEF" | sed 's/[\\&|]/\\&/g')|g" \
      -e "s|{{BRANCH_DIR}}|$BRANCH_DIR|g" \
      -e "s|{{METRIC_NAME}}|$METRIC_NAME|g" \
      -e "s|{{TIME_BUDGET_S}}|$TIME_BUDGET_S|g" \
  > "$PROMPT_FILE.tmp"
mv "$PROMPT_FILE.tmp" "$PROMPT_FILE"

# Sanity: no unrendered placeholders
if grep -qE '\{\{[A-Z_]+\}\}' "$PROMPT_FILE"; then
  log_error "unrendered placeholders remain in $PROMPT_FILE:"
  grep -E '\{\{[A-Z_]+\}\}' "$PROMPT_FILE" >&2
  exit 1
fi

# Write inbox.md (one inbox at a time; trooper reads it on nudge)
INBOX="$TOPIC_DIR/$COMMANDER-codex/inbox.md"
cat "$PROMPT_FILE" > "$INBOX.tmp"
printf '\nEND_OF_INSTRUCTION\n' >> "$INBOX.tmp"
mv "$INBOX.tmp" "$INBOX"
log_info "wrote inbox at $INBOX"

# State file: cw_consult_wait expects OFFSET=
cat > "$STATE_FILE.tmp" <<EOF
OFFSET=$offset
EXP_ID=$EXP_ID
EOF
mv "$STATE_FILE.tmp" "$STATE_FILE"

# Nudge the pane unless DRY_RUN
if [[ "${CW_DEEP_RESEARCH_DRY_RUN:-0}" != "1" ]]; then
  pane_id_file="$TOPIC_DIR/$COMMANDER-codex/pane.json"
  if [[ -f "$pane_id_file" ]]; then
    pane_id=$(grep -oE '"pane_id"[[:space:]]*:[[:space:]]*"%[0-9]+"' "$pane_id_file" \
      | grep -oE '%[0-9]+' | head -1)
    if [[ -n "${pane_id:-}" ]]; then
      "$PLUGIN_ROOT/bin/send.sh" "$COMMANDER" "$TOPIC" "@$INBOX" >/dev/null \
        || log_warn "[experiment-send] send.sh nudge failed; trooper may not have noticed inbox"
      log_info "nudging pane $pane_id via send.sh"
    fi
  fi
fi

log_info "[experiment-send] $COMMANDER/$EXP_ID dispatched (offset=$offset)"
