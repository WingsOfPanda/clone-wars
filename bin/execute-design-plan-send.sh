#!/usr/bin/env bash
# bin/execute-design-plan-send.sh — Phase 1 plan dispatch (codex).
#
# Usage: bin/execute-design-plan-send.sh <topic>
#
# Writes _execute/plan-cody.txt with one line: OFFSET=<n>.
# Refuses if the file already exists (idempotency-fail-loud).

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/execute_design.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <topic>" >&2; exit 2; }
TOPIC="$1"
cw_execute_design_assert_topic "$TOPIC"

ART_DIR="$(cw_execute_design_art_dir "$TOPIC")"
[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR not found — run execute-design-init first"; exit 1; }

STATE_FILE="$ART_DIR/plan-cody.txt"
[[ ! -e "$STATE_FILE" ]] || { log_error "$STATE_FILE already exists; rm to retry"; exit 1; }

DESIGN="$ART_DIR/design.md"
PLAN_OUT="$ART_DIR/plan.md"
TROOPER_DIR=$(cw_trooper_dir cody codex "$TOPIC")
OUTBOX="$TROOPER_DIR/outbox.jsonl"
[[ -f "$OUTBOX" ]] || { log_error "outbox not found at $OUTBOX — was cody spawned?"; exit 1; }

PROMPT_FILE="$ART_DIR/cody_plan_prompt.md"
cw_execute_design_build_plan_prompt "$DESIGN" "$PLAN_OUT" > "$PROMPT_FILE"

OFFSET=$(wc -c < "$OUTBOX" | tr -d ' ')
printf 'OFFSET=%s\n' "$OFFSET" > "$STATE_FILE"

if ! "$PLUGIN_ROOT/bin/send.sh" cody "$TOPIC" "@$PROMPT_FILE" >/dev/null; then
  log_error "send.sh failed; state file kept for retry"
  exit 1
fi

log_info "[plan-send] cody offset=$OFFSET"
