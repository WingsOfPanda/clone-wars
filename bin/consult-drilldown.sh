#!/usr/bin/env bash
# bin/consult-drilldown.sh — dispatch + await drill-down for one or two troopers.
#
# Usage:
#   bin/consult-drilldown.sh <consult-topic> <section-title> <dd-dir> <focus> \
#       <commander1> <model1> [<commander2> <model2>] [<subproject>]
#
# Single-trooper:
#   bin/consult-drilldown.sh consult-foo "Architecture" /path/to/dd "more depth" rex codex
#
# Single-trooper with sub-project (hub mode):
#   bin/consult-drilldown.sh consult-foo "Architecture" /path/to/dd "more depth" \
#       rex codex backend
#
# Both-trooper (parallel):
#   bin/consult-drilldown.sh consult-foo "Architecture" /path/to/dd "more depth" \
#       rex codex cody claude
#
# Both-trooper (parallel) with sub-project (hub mode):
#   bin/consult-drilldown.sh consult-foo "Architecture" /path/to/dd "more depth" \
#       rex codex cody claude backend
#
# Output:
#   - drilldown-<section-slug>[-<subproject>]-<commander>.md per trooper at
#     <dd-dir>/_scratch/ (kept out of the user-facing design-doc dir so only
#     the final assembled spec is visible there)
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
  echo "Usage: $0 <topic> <section-title> <dd-dir> <focus> <commander1> <model1> [<commander2> <model2>] [<subproject>]" >&2
}

# Argument shapes:
#   6 → single-trooper, no subproject
#   7 → single-trooper + subproject (last arg)
#   8 → both-trooper, no subproject
#   9 → both-trooper + subproject (last arg)
[[ $# -eq 6 || $# -eq 7 || $# -eq 8 || $# -eq 9 ]] || { usage; exit 2; }

TOPIC="$1"
TITLE="$2"
DD_DIR="$3"
FOCUS="$4"
COMMANDER1="$5"
MODEL1="$6"
COMMANDER2=""
MODEL2=""
SUBPROJECT=""
case "$#" in
  6) ;;
  7) SUBPROJECT="$7" ;;
  8) COMMANDER2="$7"; MODEL2="$8" ;;
  9) COMMANDER2="$7"; MODEL2="$8"; SUBPROJECT="$9" ;;
esac

cw_consult_assert_topic "$TOPIC"
[[ -d "$DD_DIR" ]] || { log_error "dd_dir not found: $DD_DIR"; exit 2; }

# Stage scratch dir for trooper drilldown outputs (kept out of dd-dir so the
# final assembled spec is the only user-facing file there).
mkdir -p "$DD_DIR/_scratch" \
  || { log_error "failed to create scratch dir: $DD_DIR/_scratch"; exit 1; }

TOPIC_DIR="$(cw_consult_topic_dir "$TOPIC")"
SYNTHESIS="$TOPIC_DIR/_consult/synthesis.md"
[[ -f "$SYNTHESIS" ]] || { log_error "synthesis.md not found: $SYNTHESIS"; exit 2; }

# Read drill timeout from contracts.yaml (findings_timeout_s); default 90s.
TIMEOUT=$(awk -F: '/findings_timeout_s/{gsub(/[^0-9]/,"",$2); print $2; exit}' \
  "$(cw_state_root)/contracts.yaml" 2>/dev/null)
TIMEOUT=${TIMEOUT:-90}

SECTION_SLUG=$(printf '%s' "$TITLE" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

# dispatch_drill <commander> <model> <out_path> — capture pre-send offset, send
# the drill prompt with the explicit out_path (collision-resolved by caller),
# print the offset on stdout. Caller captures it for the await step.
dispatch_drill() {
  local commander="$1" model="$2" out_path="$3"
  local trooper_dir offset prompt
  trooper_dir=$(cw_trooper_dir "$commander" "$model" "$TOPIC")
  offset=$(wc -c < "$trooper_dir/outbox.jsonl" 2>/dev/null || echo 0)
  prompt=$(cw_consult_design_doc_drilldown_prompt \
    "$TITLE" "$SYNTHESIS" "$commander" "$DD_DIR" "$FOCUS" "$SUBPROJECT" "$out_path")
  "$PLUGIN_ROOT/bin/send.sh" "$commander" "$TOPIC" "$prompt" >/dev/null
  printf '%s\n' "$offset"
}

# resolve_out_path <commander> — compute the drilldown OUT_PATH for <commander>
# applying the v0.11.1 collision counter. Mirrors bin/consult-archive.sh's
# -N suffix pattern: first collision → -2, second → -3, ..., capped at -99.
# Strips any prior -N suffix before re-appending so re-runs don't compound
# (-2 → -2-3 → -2-3-4 ...). Echoes resolved path on stdout.
resolve_out_path() {
  local commander="$1"
  local OUT_PATH="$DD_DIR/_scratch/drilldown-${DRILL_INFIX}-${commander}.md"
  # Collision counter: append -N suffix when output file exists. Mirrors
  # bin/consult-archive.sh's same-second collision pattern. Caps at -99 to
  # prevent runaway loops.
  local n=2 base
  while [[ -e "$OUT_PATH" ]]; do
    base="${OUT_PATH%.md}"
    # Strip any prior -N suffix before re-appending (otherwise -2 → -2-3 → ...)
    base="${base%-[0-9]*}"
    OUT_PATH="${base}-${n}.md"
    n=$((n + 1))
    (( n > 99 )) && { log_error "too many same-section drilldown collisions; aborting"; exit 1; }
  done
  printf '%s\n' "$OUT_PATH"
}

# await_drill <commander> <model> <offset> — block until done|error event past
# offset, or timeout. rc=0 on done/error event matched, rc=1 on timeout.
await_drill() {
  local commander="$1" model="$2" offset="$3"
  cw_outbox_wait_since "$commander" "$model" "$TOPIC" \
    "$offset" done error "$TIMEOUT" >/dev/null
}

# Output filename mirrors cw_consult_design_doc_drilldown_prompt: when a
# sub-project is set, the slug is interpolated between section and commander.
if [[ -n "$SUBPROJECT" ]]; then
  DRILL_INFIX="${SECTION_SLUG}-${SUBPROJECT}"
else
  DRILL_INFIX="${SECTION_SLUG}"
fi

# Resolve per-trooper OUT_PATH BEFORE dispatch so the collision-counter
# decisions are baked into the prompt the trooper receives. Without this,
# both troopers would independently target the same path and clobber each
# other on multi-round drills.
DRILL1=$(resolve_out_path "$COMMANDER1")
if [[ -n "$COMMANDER2" ]]; then
  DRILL2=$(resolve_out_path "$COMMANDER2")
fi

# Dispatch (parallel — sends are fast, both troopers receive nudges before
# either response arrives).
OFF1=$(dispatch_drill "$COMMANDER1" "$MODEL1" "$DRILL1")
log_info "[drilldown] dispatched $COMMANDER1 → $DRILL1 (offset=$OFF1, timeout=${TIMEOUT}s)"

if [[ -n "$COMMANDER2" ]]; then
  OFF2=$(dispatch_drill "$COMMANDER2" "$MODEL2" "$DRILL2")
  log_info "[drilldown] dispatched $COMMANDER2 → $DRILL2 (offset=$OFF2, timeout=${TIMEOUT}s)"
fi

# Await — single OR both.
SUCCESS=0
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
