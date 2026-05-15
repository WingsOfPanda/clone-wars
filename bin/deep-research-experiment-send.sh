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
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

[[ $# -eq 5 ]] || { log_error "Usage: $0 <topic> <commander> <exp-id> <approach-label> <approach-brief>"; exit 2; }
TOPIC="$1"
COMMANDER="$2"
EXP_ID="$3"
APPROACH_LABEL="$4"
APPROACH_BRIEF="$5"

# v0.32.0 #7: auto-prefix common typo (passing commander name as topic)
[[ "$TOPIC" == deep-research-* ]] || TOPIC="deep-research-$TOPIC"
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

# v0.28.0: per-trooper state.txt (KV: exp_counter, phase, current_exp_id,
# last_event_ts, last_event, probe_sent_ts). Refuse to dispatch if the
# trooper is already working on something (phase != idle).
STATE_FILE="$ART_DIR/troopers/$COMMANDER/state.txt"
[[ -f "$STATE_FILE" ]] \
  || { log_error "trooper state.txt missing: $STATE_FILE (directive Phase 4.a must run before first dispatch)"; exit 1; }
cur_phase=$(cw_deep_research_trooper_state_field "$ART_DIR" "$COMMANDER" phase)
[[ "$cur_phase" == "idle" ]] \
  || { log_error "trooper $COMMANDER not idle (phase=$cur_phase) — wait for completion or finalize first."; exit 1; }

# v0.28.0: per-trooper branch dir at troopers/<cmdr>/experiments/<exp-id>/
BRANCH_DIR="$ART_DIR/troopers/$COMMANDER/experiments/$EXP_ID"
mkdir -p "$BRANCH_DIR/code"

# Trooper pane: trooper outbox must exist (means trooper was spawned)
OUTBOX="$TOPIC_DIR/$COMMANDER-codex/outbox.jsonl"
[[ -f "$OUTBOX" ]] \
  || { log_error "trooper outbox missing: $OUTBOX (was spawn.sh run for $COMMANDER?)"; exit 1; }

# Compute current outbox offset (for cw_consult_wait OFFSET= state file)
offset=$(cw_outbox_offset "$OUTBOX")

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

# v0.27.2 P2: per-experiment hardware probe + diff alert.
# Baseline hardware.txt is written once at session start by
# bin/deep-research-init.sh. Current hardware-current.txt is overwritten
# every dispatch. ALERT lines appended to HARDWARE_BLOCK so trooper sees
# any mid-session GPU memory pressure.
HW_CURRENT="$ART_DIR/hardware-current.txt"
cw_deep_research_hardware_probe "$HW_CURRENT"
ALERT=$(cw_deep_research_hardware_diff_alert "$ART_DIR/hardware.txt" "$HW_CURRENT" 2>/dev/null || true)
[[ -n "$ALERT" ]] && log_warn "$ALERT"
HARDWARE_BLOCK=$(cat "$HW_CURRENT")
[[ -n "$ALERT" ]] && HARDWARE_BLOCK="$HARDWARE_BLOCK"$'\n'"$ALERT"

# v0.27.2 BUG #5: OUTBOX_PATH placeholder so trooper doesn't need to
# string-concat the outbox path themselves. Resolved absolute path.
OUTBOX_PATH="$TOPIC_DIR/$COMMANDER-codex/outbox.jsonl"

# Render prompt from template
TEMPLATE="$PLUGIN_ROOT/config/prompt-templates/deep-research/experiment.md"
[[ -f "$TEMPLATE" ]] || { log_error "template missing: $TEMPLATE"; exit 1; }

PROMPT_FILE="$BRANCH_DIR/prompt.md"

# v0.27.2 BUG #4 fix: single awk pass replaces sed substitution. Awk's
# gsub handles multi-line content natively (via -v) but treats `&` and
# `\` specially in the replacement string: `&` means "matched substring"
# and `\` is escape-context. Pre-escape these in every var via bash
# parameter expansion (safe on multi-line content) so substitution is
# truly literal — JSON-like braces, regex metachars, unicode all just work.
_awk_esc() {
  # Double-escape: awk -v processes backslash escapes (`\\` → `\`,
  # `\&` → `&` with warning), then gsub interprets `&` as matched-text
  # and `\&` as literal `&`. To get a literal byte through both layers:
  #   original `\` → emit `\\\\` (4 bytes) → -v parses to `\\` → gsub
  #     treats as literal `\`
  #   original `&` → emit `\\&` (3 bytes) → -v parses to `\&` → gsub
  #     treats as literal `&`
  local s="$1"
  s="${s//\\/\\\\\\\\}"   # \ → \\\\ (4 bytes; awk needs 4 → 2 → 1)
  s="${s//&/\\\\&}"       # & → \\& (3 bytes; awk needs 3 → 2 → 1 literal)
  printf '%s' "$s"
}
TOPIC_TEXT_VAL=$(cat "$ART_DIR/topic.txt")
awk \
  -v topic="$(_awk_esc "$TOPIC_TEXT_VAL")" \
  -v exp_id="$(_awk_esc "$EXP_ID")" \
  -v approach_label="$(_awk_esc "$APPROACH_LABEL")" \
  -v approach_brief="$(_awk_esc "$APPROACH_BRIEF")" \
  -v branch_dir="$(_awk_esc "$BRANCH_DIR")" \
  -v metric_name="$(_awk_esc "$METRIC_NAME")" \
  -v metric_block="$(_awk_esc "$METRIC_BLOCK")" \
  -v hardware_block="$(_awk_esc "$HARDWARE_BLOCK")" \
  -v outbox_path="$(_awk_esc "$OUTBOX_PATH")" \
  -v time_budget="$(_awk_esc "$TIME_BUDGET_S")" '
{
  gsub(/\{\{METRIC_BLOCK\}\}/,    metric_block)
  gsub(/\{\{HARDWARE_BLOCK\}\}/,  hardware_block)
  gsub(/\{\{OUTBOX_PATH\}\}/,     outbox_path)
  gsub(/\{\{TOPIC\}\}/,           topic)
  gsub(/\{\{EXP_ID\}\}/,          exp_id)
  gsub(/\{\{APPROACH_LABEL\}\}/,  approach_label)
  gsub(/\{\{APPROACH_BRIEF\}\}/,  approach_brief)
  gsub(/\{\{BRANCH_DIR\}\}/,      branch_dir)
  gsub(/\{\{METRIC_NAME\}\}/,     metric_name)
  gsub(/\{\{TIME_BUDGET_S\}\}/,   time_budget)
  print
}' "$TEMPLATE" | cw_atomic_write "$PROMPT_FILE"

# v0.27.2 BUG #4 followup: tighten sanity check. Previous grep-only
# check silently passed a 0-byte file because grep finds no placeholders
# in an empty file. Add a -s (non-empty) check first.
[[ -s "$PROMPT_FILE" ]] \
  || { log_error "$PROMPT_FILE rendered empty (template substitution failed)"; exit 1; }
if grep -qE '\{\{[A-Z_]+\}\}' "$PROMPT_FILE"; then
  log_error "unrendered placeholders remain in $PROMPT_FILE:"
  grep -E '\{\{[A-Z_]+\}\}' "$PROMPT_FILE" >&2
  exit 1
fi

# Write inbox.md (one inbox at a time; trooper reads it on nudge)
INBOX="$TOPIC_DIR/$COMMANDER-codex/inbox.md"
{
  cat "$PROMPT_FILE"
  printf '\nEND_OF_INSTRUCTION\n'
} | cw_atomic_write "$INBOX"
log_info "wrote inbox at $INBOX"

# v0.28.0: update per-trooper state.txt atomically. exp_counter increments
# from prior value (init seeded 0; first dispatch → 1). phase=working until
# score sets phase=idle on done event.
prev_counter=$(cw_deep_research_trooper_state_field "$ART_DIR" "$COMMANDER" exp_counter)
[[ "$prev_counter" =~ ^[0-9]+$ ]] || prev_counter=0
new_counter=$((prev_counter + 1))
cw_deep_research_trooper_state_write "$ART_DIR" "$COMMANDER" \
  phase=working \
  current_exp_id="$EXP_ID" \
  exp_counter="$new_counter" \
  last_event_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  last_event=dispatched

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
