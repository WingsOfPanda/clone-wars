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

# v0.34.0: --inputs (pre-flight readability probe) + --context-file
# (per-experiment task context interpolation). Both flags are optional;
# omitting them preserves v0.33.0 behavior (no probe, empty {{TASK_CONTEXT}}).
INPUTS=""
CONTEXT_FILE=""
SMOKE_TEST=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --inputs=*)        INPUTS="${1#*=}";       shift ;;
    --inputs)          INPUTS="$2";            shift 2 ;;
    --context-file=*)  CONTEXT_FILE="${1#*=}"; shift ;;
    --context-file)    CONTEXT_FILE="$2";      shift 2 ;;
    --smoke-test=*)    SMOKE_TEST="${1#*=}";   shift ;;
    --smoke-test)      SMOKE_TEST="$2";        shift 2 ;;
    --) shift; break ;;
    *)  break ;;
  esac
done

[[ $# -eq 5 ]] || { log_error "Usage: $0 [--inputs=<paths>] [--context-file=<path>] [--smoke-test=<script>] <topic> <commander> <exp-id> <approach-label> <approach-brief>"; exit 2; }
TOPIC="$1"
COMMANDER="$2"
EXP_ID="$3"
APPROACH_LABEL="$4"
APPROACH_BRIEF="$5"

cw_deep_research_normalize_topic TOPIC

# exp-id must match exp-NNN (1+ digit; 3-digit zero-padded suggested)
[[ "$EXP_ID" =~ ^exp-[0-9]+$ ]] \
  || { log_error "exp-id must match 'exp-[0-9]+'; got '$EXP_ID'"; exit 2; }

[[ "$COMMANDER" =~ ^[a-z][a-z0-9-]*$ ]] \
  || { log_error "commander must match [a-z][a-z0-9-]*; got '$COMMANDER'"; exit 2; }

# v0.34.0 D3: pre-flight readability probe for --inputs paths.
if [[ -n "$INPUTS" ]]; then
  IFS=',' read -ra _INPUT_PATHS <<< "$INPUTS"
  for _p in "${_INPUT_PATHS[@]}"; do
    [[ -r "$_p" ]] \
      || { log_error "pre-flight: cannot read input path '$_p'"; exit 2; }
  done
fi

# v0.43.0 Lane C: --smoke-test pre-flight validation. Optional. When passed,
# the script is invoked AFTER --inputs probe but BEFORE any state mutation
# (branch dir creation, state.txt update). Non-zero exit aborts with rc=2.
# Validation here: script must exist and be executable.
if [[ -n "$SMOKE_TEST" ]]; then
  [[ -x "$SMOKE_TEST" ]] \
    || { log_error "smoke-test: script not executable: $SMOKE_TEST"; exit 2; }
fi

ART_DIR="$(cw_deep_research_art_dir "$TOPIC")"
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
if [[ "$cur_phase" == "abandoned" ]]; then
  log_error "trooper $COMMANDER lane is abandoned; not dispatching (see lane_abandon_reason in state.txt)"
  exit 2
fi
[[ "$cur_phase" == "idle" ]] \
  || { log_error "trooper $COMMANDER not idle (phase=$cur_phase) — wait for completion or finalize first."; exit 1; }

# v0.28.0: per-trooper branch dir at troopers/<cmdr>/experiments/<exp-id>/
BRANCH_DIR="$ART_DIR/troopers/$COMMANDER/experiments/$EXP_ID"
mkdir -p "$BRANCH_DIR/code"

# v0.43.0 Lane C: execute --smoke-test in the freshly-created branch code dir.
# Captures stderr to smoke-test.err on failure (atomic). State.txt is NOT
# transitioned to phase=working until smoke-test passes.
# Timeout: 60s fixed (CW_SMOKE_TEST_TIMEOUT_OVERRIDE for tests).
if [[ -n "$SMOKE_TEST" ]]; then
  SMOKE_TIMEOUT="${CW_SMOKE_TEST_TIMEOUT_OVERRIDE:-60}"
  SMOKE_ERR="$BRANCH_DIR/smoke-test.err"
  SMOKE_TMP=$(mktemp)
  if ( cd "$BRANCH_DIR/code" && CW_SMOKE_TEST=1 timeout -k 1 "$SMOKE_TIMEOUT" "$SMOKE_TEST" ) 2>"$SMOKE_TMP"; then
    rm -f "$SMOKE_TMP"
    log_ok "smoke-test passed for $COMMANDER/$EXP_ID"
  else
    SMOKE_RC=$?
    mv "$SMOKE_TMP" "$SMOKE_ERR"
    log_error "smoke-test failed (rc=$SMOKE_RC) for $COMMANDER/$EXP_ID; stderr → $SMOKE_ERR"
    if [[ -s "$SMOKE_ERR" ]]; then
      log_error "--- smoke-test stderr ---"
      cat "$SMOKE_ERR" >&2
      log_error "--- end smoke-test stderr ---"
    fi
    exit 2
  fi
fi

# Trooper pane: trooper outbox must exist (means trooper was spawned)
OUTBOX="$(cw_outbox_path "$COMMANDER" codex "$TOPIC")"
[[ -f "$OUTBOX" ]] \
  || { log_error "trooper outbox missing: $OUTBOX (was spawn.sh run for $COMMANDER?)"; exit 1; }

# Compute current outbox offset (for cw_consult_wait OFFSET= state file)
offset=$(cw_outbox_offset "$OUTBOX")

# Per-experiment wall-clock cap. Defaults per lib/contracts.sh; env override.
TIME_BUDGET_S="${CW_DEEP_RESEARCH_EXPERIMENT_TIMEOUT_OVERRIDE:-$(cw_consult_timeout experiment)}"

# Metric name from metric.md's "**Primary metric:**" line.
METRIC_NAME=$(cw_deep_research_metric_primary "$METRIC_MD")
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
# v0.46.0: reuse $OUTBOX (same value, computed via cw_outbox_path above).
OUTBOX_PATH="$OUTBOX"

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

# v0.34.0 D4: optional per-experiment context interpolation.
TASK_CONTEXT_VAL=""
if [[ -n "$CONTEXT_FILE" ]]; then
  [[ -r "$CONTEXT_FILE" ]] \
    || { log_error "cannot read --context-file: $CONTEXT_FILE"; exit 2; }
  TASK_CONTEXT_VAL=$(<"$CONTEXT_FILE")
fi

# v0.44.0 Lane C: inline sota.md if present. Absent → empty (template
# gsub leaves a blank line). Yoda writes sota.md in Phase 1.5; tests
# may seed it directly.
SOTA_BLOCK_VAL=""
SOTA_MD="$ART_DIR/sota.md"
if [[ -f "$SOTA_MD" ]]; then
  SOTA_CONTENT=$(<"$SOTA_MD")
  SOTA_BLOCK_VAL=$'## Reference: SOTA\n\n'"$SOTA_CONTENT"$'\n\n### Web search affordance\n\nConsult this reference before starting. Web search (curl / pip install / arXiv / HuggingFace / etc.) is allowed when you hit a plateau or before scaling up. Record any consulted source in notes.md under a `## Sources consulted` heading.'
fi

# v0.45.0 Lane C: inline peer-status snapshot if ≥2 troopers. Absent
# (N=1 solo) → empty (helper emits nothing). Helper sources from
# $ART_DIR/troopers.txt + per-peer state.txt + most-recent
# exp-NNN/result.json — see lib/deep-research.sh.
PEERS_BLOCK_VAL=$(cw_deep_research_format_peers_block "$ART_DIR" "$COMMANDER" 2>/dev/null || true)

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
  -v time_budget="$(_awk_esc "$TIME_BUDGET_S")" \
  -v task_context="$(_awk_esc "$TASK_CONTEXT_VAL")" \
  -v sota_block="$(_awk_esc "$SOTA_BLOCK_VAL")" \
  -v peers_block="$(_awk_esc "$PEERS_BLOCK_VAL")" '
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
  gsub(/\{\{TASK_CONTEXT\}\}/,    task_context)
  gsub(/\{\{SOTA_BLOCK\}\}/,      sota_block)
  gsub(/\{\{PEERS_BLOCK\}\}/,     peers_block)
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
INBOX="$(cw_inbox_path "$COMMANDER" codex "$TOPIC")"
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
cw_deep_research_trooper_event "$ART_DIR" "$COMMANDER" dispatched \
  phase=working \
  current_exp_id="$EXP_ID" \
  exp_counter="$new_counter"

# Nudge the pane unless DRY_RUN
if [[ "${CW_DEEP_RESEARCH_DRY_RUN:-0}" != "1" ]]; then
  if pane_id=$(cw_pane_meta_read "$COMMANDER" codex "$TOPIC" 2>/dev/null) && [[ -n "$pane_id" ]]; then
    "$PLUGIN_ROOT/bin/send.sh" "$COMMANDER" "$TOPIC" "@$INBOX" >/dev/null \
      || log_warn "[experiment-send] send.sh nudge failed; trooper may not have noticed inbox"
    log_info "nudging pane $pane_id via send.sh"
  fi
fi

log_info "[experiment-send] $COMMANDER/$EXP_ID dispatched (offset=$offset)"
