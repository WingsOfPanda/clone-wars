#!/usr/bin/env bash
# bin/consult-drilldown.sh — dispatch + await drill-down for one or two troopers.
#
# Usage:
#   bin/consult-drilldown.sh <consult-topic> <section-title> <dd-dir> <focus> \
#       <commander1> <model1> [<commander2> <model2>]
#
# Single-trooper:
#   bin/consult-drilldown.sh consult-foo "Architecture" /path/to/dd "more depth" rex codex
#
# Both-trooper (parallel):
#   bin/consult-drilldown.sh consult-foo "Architecture" /path/to/dd "more depth" \
#       rex codex cody claude
#
# Output:
#   - drilldown-<section-slug>-<commander>.md per trooper at <dd-dir>/
#   - rc=0 if at least one trooper produced a non-empty drilldown file
#   - rc=1 if all troopers timed out / errored / produced empty files
#   - rc=2 on bad args
#
# Extracted from commands/consult.md Step 8.5 to bypass the slash-command
# renderer's $1/$2/$3 positional substitution (which clobbered bash
# function args with topic words on multi-word topics).

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

usage() {
  echo "Usage: $0 <topic> <section-title> <dd-dir> <focus> <commander1> <model1> [<commander2> <model2>]" >&2
}

[[ $# -eq 6 || $# -eq 8 ]] || { usage; exit 2; }

TOPIC="$1"
TITLE="$2"
DD_DIR="$3"
FOCUS="$4"
COMMANDER1="$5"
MODEL1="$6"
COMMANDER2="${7:-}"
MODEL2="${8:-}"

cw_consult_topic_validate "$TOPIC" || { log_error "invalid topic: $TOPIC"; exit 2; }
[[ -d "$DD_DIR" ]] || { log_error "dd_dir not found: $DD_DIR"; exit 2; }

TOPIC_DIR="$(cw_state_root)/state/$(cw_repo_hash)/$TOPIC"
SYNTHESIS="$TOPIC_DIR/_consult/synthesis.md"
[[ -f "$SYNTHESIS" ]] || { log_error "synthesis.md not found: $SYNTHESIS"; exit 2; }

# Read drill timeout from contracts.yaml (findings_timeout_s); default 90s.
TIMEOUT=$(awk -F: '/findings_timeout_s/{gsub(/[^0-9]/,"",$2); print $2; exit}' \
  "$(cw_state_root)/contracts.yaml" 2>/dev/null)
TIMEOUT=${TIMEOUT:-90}

SECTION_SLUG=$(printf '%s' "$TITLE" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

# dispatch_drill <commander> <model> — capture pre-send offset, send the drill
# prompt, print the offset on stdout. Caller captures it for the await step.
dispatch_drill() {
  local commander="$1" model="$2"
  local trooper_dir offset prompt
  trooper_dir=$(cw_trooper_dir "$commander" "$model" "$TOPIC")
  offset=$(wc -c < "$trooper_dir/outbox.jsonl" 2>/dev/null || echo 0)
  prompt=$(cw_consult_design_doc_drilldown_prompt \
    "$TITLE" "$SYNTHESIS" "$commander" "$DD_DIR" "$FOCUS")
  "$PLUGIN_ROOT/bin/send.sh" "$commander" "$TOPIC" "$prompt" >/dev/null
  printf '%s\n' "$offset"
}

# await_drill <commander> <model> <offset> — block until done|error event past
# offset, or timeout. rc=0 on done/error event matched, rc=1 on timeout.
await_drill() {
  local commander="$1" model="$2" offset="$3"
  cw_outbox_wait_since "$commander" "$model" "$TOPIC" \
    "$offset" done error "$TIMEOUT" >/dev/null
}

# Dispatch (parallel — sends are fast, both troopers receive nudges before
# either response arrives).
OFF1=$(dispatch_drill "$COMMANDER1" "$MODEL1")
log_info "[drilldown] dispatched $COMMANDER1 (offset=$OFF1, timeout=${TIMEOUT}s)"

if [[ -n "$COMMANDER2" ]]; then
  OFF2=$(dispatch_drill "$COMMANDER2" "$MODEL2")
  log_info "[drilldown] dispatched $COMMANDER2 (offset=$OFF2, timeout=${TIMEOUT}s)"
fi

# Await — single OR both.
SUCCESS=0
DRILL1="$DD_DIR/drilldown-${SECTION_SLUG}-${COMMANDER1}.md"
if await_drill "$COMMANDER1" "$MODEL1" "$OFF1"; then
  if [[ -s "$DRILL1" ]]; then
    log_info "[drilldown] $COMMANDER1: wrote $DRILL1"
    SUCCESS=$((SUCCESS + 1))
  else
    log_warn "[drilldown] $COMMANDER1: terminal event but drill file empty/missing"
  fi
else
  log_warn "[drilldown] $COMMANDER1: timed out after ${TIMEOUT}s"
fi

if [[ -n "$COMMANDER2" ]]; then
  DRILL2="$DD_DIR/drilldown-${SECTION_SLUG}-${COMMANDER2}.md"
  if await_drill "$COMMANDER2" "$MODEL2" "$OFF2"; then
    if [[ -s "$DRILL2" ]]; then
      log_info "[drilldown] $COMMANDER2: wrote $DRILL2"
      SUCCESS=$((SUCCESS + 1))
    else
      log_warn "[drilldown] $COMMANDER2: terminal event but drill file empty/missing"
    fi
  else
    log_warn "[drilldown] $COMMANDER2: timed out after ${TIMEOUT}s"
  fi
fi

if (( SUCCESS == 0 )); then
  log_error "[drilldown] all troopers timed out or produced empty files"
  exit 1
fi

log_info "[drilldown] complete ($SUCCESS trooper(s) produced output)"
exit 0
