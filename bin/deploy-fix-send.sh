#!/usr/bin/env bash
# bin/deploy-fix-send.sh — Phase 5 fix dispatch.
# Usage: bin/deploy-fix-send.sh <topic> <round> [<variant>]
#
# Looks for $ART_DIR/fix-prompt-<round>[-<variant>].md and tells codex to
# read it. The slash directive must have written that file (with a skill
# preamble) before invoking. Optionally bumps the verify-cody-N.txt to
# next round for the directive's wait flow — but that's the directive's
# responsibility, not this script's.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

[[ $# -ge 2 && $# -le 3 ]] || { echo "Usage: $0 <topic> <round> [<variant>]" >&2; exit 2; }
TOPIC="$1"; ROUND="$2"; VARIANT="${3:-}"
cw_deploy_assert_topic "$TOPIC"
[[ "$ROUND" =~ ^[1-9][0-9]*$ ]] || { log_error "round must be a positive integer; got '$ROUND'"; exit 2; }

ART_DIR="$(cw_deploy_art_dir "$TOPIC")"
[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR not found"; exit 1; }

if [[ -n "$VARIANT" ]]; then
  FIX="$ART_DIR/fix-prompt-$ROUND-$VARIANT.md"
else
  FIX="$ART_DIR/fix-prompt-$ROUND.md"
fi
[[ -f "$FIX" && -s "$FIX" ]] || { log_error "fix-prompt missing/empty: $FIX (the directive must write it before invoking)"; exit 1; }

TROOPER_DIR=$(cw_trooper_dir cody codex "$TOPIC")
OUTBOX="$TROOPER_DIR/outbox.jsonl"
[[ -f "$OUTBOX" ]] || { log_error "outbox not found at $OUTBOX"; exit 1; }

PROMPT_FILE="$ART_DIR/cody_fix_prompt-$ROUND${VARIANT:+-$VARIANT}.md"
cw_deploy_build_fix_prompt "$FIX" > "$PROMPT_FILE"

log_info "[fix-send] cody round=$ROUND variant=${VARIANT:-<none>} ($FIX)"

if ! "$PLUGIN_ROOT/bin/send.sh" cody "$TOPIC" "@$PROMPT_FILE" >/dev/null; then
  log_error "send.sh failed"
  exit 1
fi
