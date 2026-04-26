#!/usr/bin/env bash
# bin/spawn.sh — spawn a clone trooper as a tmux pane and dispatch it.
#
# Usage:
#   bin/spawn.sh <commander|random> <model> <topic> [--mode full|read-only] [initial-prompt]
#
# Steps (per docs/DESIGN.md §Slash commands → /clone-wars-spawn):
#   1. Validate commander/model/topic; reject duplicate <commander> within <topic>.
#   2. Resolve provider contract (binary, mode args, ready timeout) from contracts.yaml.
#   3. Initialize fresh state dir; write identity.md from template.
#   4. tmux split-window with the launch command; stamp @cw_label/@cw_color/@cw_label_fmt.
#   5. Sleep through provider-specific bootstrap.
#   6. Nudge the trooper to read its identity (single-line send-keys -l).
#   7. Poll outbox.jsonl for {ready} (timeout from contracts.yaml).
#   8. If <initial-prompt> given, write inbox.md and nudge — return after ready.
#      (Conductor uses /clone-wars:collect to wait for {done}.)
#   9. Print pane ID + state dir.

set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deps.sh"
source "$PLUGIN_ROOT/lib/colors.sh"
source "$PLUGIN_ROOT/lib/contracts.sh"
source "$PLUGIN_ROOT/lib/commanders.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/tmux.sh"

# ------------------------------------------------------------ Arg parsing

usage() {
  cat >&2 <<EOF
Usage: $0 <commander|random> <model> <topic> [--mode full|read-only] [initial-prompt]

  commander       — name from \$CLONE_WARS_HOME/commanders.yaml, or "random"
  model           — provider key in contracts.yaml (codex / gemini / claude)
  topic           — operation slug, [a-z0-9-] (≤ 32 chars)
  --mode          — full (default) or read-only; selects contracts.yaml mode
  initial-prompt  — optional first task to send via inbox after spawn
EOF
}

[[ $# -ge 3 ]] || { usage; exit 2; }

COMMANDER="$1"; MODEL="$2"; TOPIC="$3"; shift 3
MODE=""
INITIAL_PROMPT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)        MODE="$2"; shift 2 ;;
    --mode=*)      MODE="${1#*=}"; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             INITIAL_PROMPT="$*"; break ;;
  esac
done

# ------------------------------------------------------------ Input validation
# Run this FIRST so malformed args fail fast without depending on tmux/state.
# Both regexes match: lowercase, digits, hyphens; 1-32 chars.
if ! [[ "$TOPIC" =~ ^[a-z0-9-]+$ ]] || (( ${#TOPIC} > 32 )); then
  log_error "topic must match [a-z0-9-]+ and be <= 32 chars; got: '$TOPIC'"
  exit 2
fi
# 'random' is a sentinel — let it through; it's resolved against the pool below.
if [[ "$COMMANDER" != "random" ]]; then
  if ! [[ "$COMMANDER" =~ ^[a-z0-9-]+$ ]] || (( ${#COMMANDER} > 32 )) || [[ -z "$COMMANDER" ]]; then
    log_error "commander must match [a-z0-9-]+ and be <= 32 chars (or 'random'); got: '$COMMANDER'"
    exit 2
  fi
fi

# ------------------------------------------------------------ Environment validation

cw_in_tmux_session  || { log_error "must run inside a tmux session"; exit 1; }
cw_have_cmd tmux    || { log_error "tmux not on PATH"; exit 1; }
cw_tmux_version_ok  || { log_error "tmux >= 3.0 required"; exit 1; }

if [[ "$COMMANDER" == "random" ]]; then
  COMMANDER=$(cw_commander_pick_random "$TOPIC") || {
    log_error "no available commander in pool for topic '$TOPIC'"
    exit 1
  }
  log_info "random pick: $COMMANDER"
fi

if cw_commander_in_use "$COMMANDER" "$TOPIC"; then
  log_error "$COMMANDER is already deployed on $TOPIC; pick another commander"
  log_error "  or run: /clone-wars:teardown $COMMANDER $TOPIC"
  exit 1
fi

BINARY=$(cw_contract_binary "$MODEL") || {
  log_error "model '$MODEL' has no entry in contracts.yaml; expected one of: $(cw_contracts_providers | tr '\n' ' ')"
  exit 1
}
cw_have_cmd "$BINARY" || {
  log_error "$MODEL's binary '$BINARY' is not on PATH"
  exit 1
}

[[ -n "$MODE" ]] || MODE=$(cw_contract_default_mode "$MODEL") || MODE=full
mapfile -t MODE_ARGS < <(cw_contract_mode_args "$MODEL" "$MODE") || {
  log_error "mode '$MODE' not defined for $MODEL in contracts.yaml"
  exit 1
}

READY_TIMEOUT=$(cw_contract_ready_timeout "$MODEL")

# ------------------------------------------------------------ State + identity

log_info "preparing state for $COMMANDER-$MODEL on $TOPIC"
cw_state_init "$COMMANDER" "$MODEL" "$TOPIC"
cw_identity_write "$COMMANDER" "$MODEL" "$TOPIC"

# ------------------------------------------------------------ Spawn pane

LAUNCH="$BINARY"
for a in "${MODE_ARGS[@]}"; do
  LAUNCH+=" $a"
done

log_info "spawning $COMMANDER-$MODEL with: $LAUNCH"

# First trooper in topic = right-split of conductor; subsequent = down-split of
# the most-recently-spawned trooper on the same topic (per DESIGN.md §Pane layout).
PRIOR_FILE="$(cw_state_root)/state/$(cw_repo_hash)/$TOPIC/.last_pane"
PRIOR_PANE=""
[[ -f "$PRIOR_FILE" ]] && PRIOR_PANE=$(cat "$PRIOR_FILE")
if [[ -n "$PRIOR_PANE" ]] && cw_pane_alive "$PRIOR_PANE"; then
  PANE=$(cw_pane_spawn_down "$COMMANDER" "$MODEL" "$TOPIC" "$LAUNCH" "$PRIOR_PANE")
else
  PANE=$(cw_pane_spawn_right "$COMMANDER" "$MODEL" "$TOPIC" "$LAUNCH")
fi
mkdir -p "$(dirname "$PRIOR_FILE")"
printf '%s\n' "$PANE" > "$PRIOR_FILE"
cw_pane_meta_write "$COMMANDER" "$MODEL" "$TOPIC" "$PANE"

LABEL=$(cw_label_for "$COMMANDER" "$MODEL" "$TOPIC")
log_ok "spawned $LABEL in pane $PANE (mode=$MODE)"

# ------------------------------------------------------------ Bootstrap + identity

case "$MODEL" in
  claude) BOOT_SLEEP=12 ;;
  *)      BOOT_SLEEP=8  ;;
esac
log_info "sleeping ${BOOT_SLEEP}s for $MODEL bootstrap"
sleep "$BOOT_SLEEP"

IDENTITY=$(cw_identity_path "$COMMANDER" "$MODEL" "$TOPIC")
log_info "asking $COMMANDER to read identity"
cw_pane_send "$PANE" "Read $IDENTITY and follow its instructions exactly."

# ------------------------------------------------------------ Wait for {ready}

log_info "waiting for {ready} in outbox (timeout ${READY_TIMEOUT}s)"
if ! cw_outbox_wait "$COMMANDER" "$MODEL" "$TOPIC" ready "$READY_TIMEOUT" >/dev/null; then
  log_error "$COMMANDER timed out on {ready}"
  log_error "outbox:"; cw_outbox_dump "$COMMANDER" "$MODEL" "$TOPIC" >&2
  log_error "pane content (last 25 lines, captured BEFORE kill):"
  tmux capture-pane -p -t "$PANE" 2>/dev/null | tail -n 25 >&2 || true
  cw_pane_kill_now "$PANE"
  failed_archive=$(cw_state_archive "$COMMANDER" "$MODEL" "$TOPIC" FAILED)
  log_error "state archived to: $failed_archive"
  exit 1
fi
log_ok "$COMMANDER is ready"

# ------------------------------------------------------------ Optional initial prompt

if [[ -n "$INITIAL_PROMPT" ]]; then
  INITIAL_PROMPT="${INITIAL_PROMPT#\"}"; INITIAL_PROMPT="${INITIAL_PROMPT%\"}"
  log_info "dispatching initial prompt"
  cw_inbox_write "$COMMANDER" "$MODEL" "$TOPIC" "$INITIAL_PROMPT"
  INBOX=$(cw_inbox_path "$COMMANDER" "$MODEL" "$TOPIC")
  cw_pane_send "$PANE" "Read $INBOX and execute the task. Reply when done."
  log_info "use /clone-wars:collect $COMMANDER $TOPIC to wait for {done}"
fi

# ------------------------------------------------------------ Summary

cat <<EOF

  trooper:    $LABEL
  pane:       $PANE
  state:      $(cw_trooper_dir "$COMMANDER" "$MODEL" "$TOPIC")
  ready:      yes
EOF
