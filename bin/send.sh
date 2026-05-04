#!/usr/bin/env bash
# bin/send.sh — write a task to a trooper's inbox and nudge the pane.
#
# Usage:
#   bin/send.sh <commander> <topic> <message-or-@file>
#
# Looks up the trooper's pane via pane.json (written by spawn). The model
# segment is inferred by listing state/<repo-hash>/<topic>/<commander>-* —
# there should be exactly one match (commander+topic uniqueness is enforced
# by spawn).

set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deps.sh"
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

# --from <sender> — pass-through to cw_inbox_write so messages are attributed.
# Default sender (when --from is omitted) is "master-yoda" (the conductor).
SENDER_ARGS=()
if [[ "${1:-}" == "--from" ]]; then
  [[ -n "${2:-}" ]] || { echo "--from requires a sender name" >&2; exit 2; }
  SENDER_ARGS=(--from "$2")
  shift 2
fi

usage() {
  echo "Usage: $0 [--from <sender>] <commander> <topic> <message-or-@file>" >&2
}

[[ $# -ge 3 ]] || { usage; exit 2; }

COMMANDER="$1"; TOPIC="$2"; shift 2
MSG_OR_FILE="$*"

# ------------------------------------------------------------ Resolve model
# Locate the state dir (its name's last segment is the model hint), then
# read the canonical model from pane.json (v0.0.4+); fallback to hint for
# legacy state dirs.

TOPIC_DIR="$(cw_topic_state_dir "$TOPIC")"
MODEL_HINT=""
if [[ -d "$TOPIC_DIR" ]]; then
  for d in "$TOPIC_DIR"/${COMMANDER}-*; do
    [[ -d "$d" ]] || continue
    MODEL_HINT="${d##*/${COMMANDER}-}"
    break
  done
fi
if [[ -z "$MODEL_HINT" ]]; then
  log_error "no trooper '$COMMANDER' on topic '$TOPIC' (state dir absent)"
  log_error "  spawn first: /clone-wars:spawn $COMMANDER <model> $TOPIC"
  exit 1
fi
MODEL=$(cw_pane_meta_model "$COMMANDER" "$MODEL_HINT" "$TOPIC")

# ------------------------------------------------------------ Resolve pane

PANE=$(cw_pane_meta_read "$COMMANDER" "$MODEL" "$TOPIC") || {
  log_error "pane.json missing for $COMMANDER-$MODEL on $TOPIC"
  exit 1
}
if ! cw_pane_alive "$PANE"; then
  log_error "$COMMANDER's pane $PANE is gone (orphan); run /clone-wars:teardown $COMMANDER $TOPIC"
  exit 1
fi

# ------------------------------------------------------------ Resolve task body

if [[ "$MSG_OR_FILE" == @* ]]; then
  task_file="${MSG_OR_FILE#@}"
  [[ -f "$task_file" ]] || { log_error "file not found: $task_file"; exit 1; }
  TASK="$(cat "$task_file")"
else
  TASK="$MSG_OR_FILE"
fi

# ------------------------------------------------------------ Write + nudge

cw_inbox_write "${SENDER_ARGS[@]+"${SENDER_ARGS[@]}"}" "$COMMANDER" "$MODEL" "$TOPIC" "$TASK"
INBOX=$(cw_inbox_path "$COMMANDER" "$MODEL" "$TOPIC")
log_info "wrote inbox at $INBOX; nudging pane $PANE"
cw_pane_send "$PANE" "Read $INBOX and execute the task. Reply when done."

cat <<EOF

  trooper:  $COMMANDER-$MODEL on $TOPIC
  pane:     $PANE
  inbox:    $INBOX
  status:   queued — use /clone-wars:collect $COMMANDER $TOPIC to wait for {done}
EOF
