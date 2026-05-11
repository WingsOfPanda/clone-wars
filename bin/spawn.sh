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
#      (Master Yoda uses /clone-wars:collect to wait for {done}.)
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
source "$PLUGIN_ROOT/lib/argsfile.sh"

# --args-file <path> — read tokens from <path> and replace positional args.
# Used by commands/*.md to fence off shell injection from $ARGUMENTS.
if [[ "${1:-}" == "--args-file" ]]; then
  [[ -n "${2:-}" ]] || { echo "--args-file requires a path" >&2; exit 2; }
  args_file="$2"
  shift 2
  mapfile -t _TOKENS < <(cw_args_file_load "$args_file")
  set -- "${_TOKENS[@]}" "$@"
fi

# ------------------------------------------------------------ Arg parsing

usage() {
  cat >&2 <<EOF
Usage: $0 <commander|random> <model> <topic> [--mode full|read-only] [--cwd <abs-path>] [initial-prompt]

  commander       — name from \$CLONE_WARS_HOME/commanders.yaml, or "random"
  model           — provider key in contracts.yaml (codex / gemini / claude)
  topic           — operation slug, [a-z0-9-] (≤ 32 chars)
  --mode          — full (default) or read-only; selects contracts.yaml mode
  --cwd <abs-path> — start the trooper pane in the given absolute directory
                     (default: inherit conductor's repo root). Used by
                     /clone-wars:deploy when the design doc declares
                     **Target Sub-Project**.
  --target-pane <id> — respawn into pre-allocated pane <id> (must appear
                     in <preflight-art-dir>/preflight-panes.txt). Used by
                     /clone-wars:consult v0.19.0 two-phase spawn and by
                     /clone-wars:deploy multi-repo Step 3b.
  --preflight-art-dir <abs-path> — explicit art-dir to look up
                     preflight-panes.txt (v0.22.0). When omitted, defaults
                     to cw_consult_art_dir(\$TOPIC). Deploy passes its
                     _deploy/<topic>/ art-dir.
  initial-prompt  — optional first task to send via inbox after spawn
EOF
}

[[ $# -ge 3 ]] || { usage; exit 2; }

COMMANDER="$1"; MODEL="$2"; TOPIC="$3"; shift 3
MODE=""
INITIAL_PROMPT=""
SPAWN_CWD=""
TARGET_PANE=""
PREFLIGHT_ART_DIR_OVERRIDE=""

# _kv_parse <var-name> "$@"
# Accepts both `--flag VALUE` and `--flag=VALUE` forms. On `--flag` form
# requires the next arg non-empty. Assigns to <var-name> via nameref and
# updates the global SHIFT_COUNT (1 or 2) so the caller knows how far to
# advance. Nameref + global avoids the subshell-loses-assignment trap.
_kv_parse() {
  local -n _ref="$1"
  local a1="$2" a2="${3:-}"
  if [[ "$a1" == *=* ]]; then
    _ref="${a1#*=}"
    SHIFT_COUNT=1
  else
    [[ -n "$a2" ]] || { echo "$a1 requires a value" >&2; exit 2; }
    _ref="$a2"
    SHIFT_COUNT=2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode|--mode=*)
      _kv_parse MODE "$1" "${2:-}"; shift "$SHIFT_COUNT" ;;
    --cwd|--cwd=*)
      _kv_parse SPAWN_CWD "$1" "${2:-}"; shift "$SHIFT_COUNT" ;;
    --target-pane|--target-pane=*)
      _kv_parse TARGET_PANE "$1" "${2:-}"; shift "$SHIFT_COUNT" ;;
    --preflight-art-dir|--preflight-art-dir=*)
      _kv_parse PREFLIGHT_ART_DIR_OVERRIDE "$1" "${2:-}"; shift "$SHIFT_COUNT" ;;
    -h|--help)              usage; exit 0 ;;
    *)                      INITIAL_PROMPT="$*"; break ;;
  esac
done

# --cwd validation (must precede tmux/state work so it fails fast).
if [[ -n "$SPAWN_CWD" ]]; then
  [[ "$SPAWN_CWD" == /* ]] || { log_error "spawn --cwd must be an absolute path: $SPAWN_CWD"; exit 1; }
  [[ -d "$SPAWN_CWD" ]] || { log_error "spawn --cwd target does not exist: $SPAWN_CWD"; exit 1; }
fi

# --target-pane validation (v0.19.0; v0.22.0 adds --preflight-art-dir):
# strict — must appear in <preflight-art-dir>/preflight-panes.txt. When
# --preflight-art-dir is omitted, resolves to cw_consult_art_dir($TOPIC)
# (byte-equal v0.21.0; consult invocations need no override). Deploy passes
# --preflight-art-dir "$ART_DIR" so this validates against the
# _deploy/<topic>/preflight-panes.txt that bin/preflight-layout.sh wrote.
if [[ -n "$TARGET_PANE" ]]; then
  if [[ -n "$PREFLIGHT_ART_DIR_OVERRIDE" ]]; then
    PFP="$PREFLIGHT_ART_DIR_OVERRIDE/preflight-panes.txt"
  else
    source "$PLUGIN_ROOT/lib/consult.sh"
    PFP="$(cw_consult_art_dir "$TOPIC")/preflight-panes.txt"
  fi
  if [[ ! -f "$PFP" ]]; then
    log_error "--target-pane requires preflight-panes.txt at: $PFP"
    exit 1
  fi
  if ! grep -qE "^[a-z0-9-]+	${TARGET_PANE}$" "$PFP"; then
    log_error "--target-pane $TARGET_PANE not in preflight-panes.txt for topic $TOPIC"
    exit 1
  fi
fi

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

[[ -n "$MODE" ]] || MODE=$(cw_contract_default_mode "$MODEL")
[[ -n "$MODE" ]] || MODE=full
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

# First trooper in topic = right-split of Master Yoda; subsequent = down-split of
# the most-recently-spawned trooper on the same topic (per DESIGN.md §Pane layout).
# When --cwd <abs-path> is set, the new pane is launched there via
# `tmux split-window ... -c "$SPAWN_CWD"`; otherwise the helpers default to
# cw_repo_root (the conductor's repo root).
if [[ -n "$TARGET_PANE" ]]; then
  # v0.19.0 preflight path: respawn into pre-allocated pane.
  cw_pane_alive "$TARGET_PANE" || { log_error "--target-pane $TARGET_PANE is not alive"; exit 1; }
  PANE=$(cw_pane_respawn "$TARGET_PANE" "$COMMANDER" "$MODEL" "$TOPIC" "$LAUNCH" "$SPAWN_CWD")
  # NOTE: no .last_pane writes — preflight-panes.txt is the source of truth.
else
  # Legacy path: byte-equal to v0.18.3.
  PRIOR_FILE="$(cw_topic_state_dir "$TOPIC")/.last_pane"
  PRIOR_PANE=""
  [[ -f "$PRIOR_FILE" ]] && PRIOR_PANE=$(cat "$PRIOR_FILE")
  if [[ -n "$PRIOR_PANE" ]] && cw_pane_alive "$PRIOR_PANE"; then
    PANE=$(cw_pane_spawn_down "$COMMANDER" "$MODEL" "$TOPIC" "$LAUNCH" "$PRIOR_PANE" "$SPAWN_CWD")
  else
    PANE=$(cw_pane_spawn_right "$COMMANDER" "$MODEL" "$TOPIC" "$LAUNCH" "" "$SPAWN_CWD")
  fi
  mkdir -p "$(dirname "$PRIOR_FILE")"
  printf '%s\n' "$PANE" > "$PRIOR_FILE"
fi
cw_pane_meta_write "$COMMANDER" "$MODEL" "$TOPIC" "$PANE"

LABEL=$(cw_label_for "$COMMANDER" "$MODEL" "$TOPIC")
log_ok "spawned $LABEL in pane $PANE (mode=$MODE)"

# ------------------------------------------------------------ Bootstrap + identity

BOOT_SLEEP=$(cw_contract_bootstrap_sleep "$MODEL")
log_info "sleeping ${BOOT_SLEEP}s for $MODEL bootstrap"
sleep "$BOOT_SLEEP"

IDENTITY=$(cw_identity_path "$COMMANDER" "$MODEL" "$TOPIC")
log_info "asking $COMMANDER to read identity"
cw_pane_send "$PANE" "Read $IDENTITY and follow its instructions exactly."

# ------------------------------------------------------------ Wait for {ready}

# _spawn_bootstrap_fail — shared cleanup for both timeout and {error} paths:
# capture the pane's last 25 lines (BEFORE kill so the buffer is still live),
# hard-kill the pane, archive state with FAILED suffix, and exit 1.
_spawn_bootstrap_fail() {
  log_error "pane content (last 25 lines, captured BEFORE kill):"
  tmux capture-pane -p -t "$PANE" 2>/dev/null | tail -n 25 >&2 || true
  cw_pane_kill_now "$PANE"
  local failed_archive
  failed_archive=$(cw_state_archive "$COMMANDER" "$MODEL" "$TOPIC" FAILED)
  log_error "state archived to: $failed_archive"
  exit 1
}

log_info "waiting for {ready,error} in outbox (timeout ${READY_TIMEOUT}s)"
event_line=$(cw_outbox_wait "$COMMANDER" "$MODEL" "$TOPIC" ready error "$READY_TIMEOUT") || event_line=""
if [[ -z "$event_line" ]]; then
  log_error "$COMMANDER timed out on {ready,error}"
  log_error "outbox:"; cw_outbox_dump "$COMMANDER" "$MODEL" "$TOPIC" >&2
  _spawn_bootstrap_fail
fi
if [[ "$event_line" == *'"event":"error"'* ]]; then
  log_error "$COMMANDER reported {error} during bootstrap: $event_line"
  _spawn_bootstrap_fail
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
