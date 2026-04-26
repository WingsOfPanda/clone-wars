#!/usr/bin/env bash
# bin/teardown.sh — kill panes and archive trooper state.
#
# Usage:
#   bin/teardown.sh <topic>                       — tear down every trooper on <topic>
#   bin/teardown.sh <commander> <topic>           — tear down just that trooper
#   bin/teardown.sh --all                          — tear down EVERYTHING (asks confirmation)
#
# Each kill goes through the graceful colored shutdown banner (8s countdown
# in the trooper's color) before the pane disappears. State dirs are moved
# to $CLONE_WARS_HOME/archive/<repo-hash>/<topic>/<commander>-<model>-<ts>/
# for forensics.

set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/tmux.sh"
source "$PLUGIN_ROOT/lib/colors.sh"
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

usage() {
  cat >&2 <<EOF
Usage: $0 <topic>
       $0 <commander> <topic>
       $0 --all
EOF
}

teardown_trooper() {
  local commander="$1" model="$2" topic="$3"
  local pane; pane=$(cw_pane_meta_read "$commander" "$model" "$topic" 2>/dev/null || echo '')
  if [[ -n "$pane" ]] && cw_pane_alive "$pane"; then
    log_info "graceful shutdown for $commander-$model on $topic (pane $pane)"
    cw_pane_kill_graceful "$pane"
    # The graceful banner runs ~8s; collect them in parallel by NOT sleeping
    # here — the caller sleeps once after dispatching all teardowns.
  fi
  local archived; archived=$(cw_state_archive "$commander" "$model" "$topic")
  log_ok "archived $commander-$model: $archived"
  # Clean up the topic's .last_pane pointer if it referenced this trooper.
  local last_file="$(cw_state_root)/state/$(cw_repo_hash)/$topic/.last_pane"
  if [[ -f "$last_file" ]] && [[ "$(cat "$last_file")" == "$pane" ]]; then
    rm -f "$last_file"
  fi
}

teardown_topic() {
  local topic="$1"
  local topic_dir="$(cw_state_root)/state/$(cw_repo_hash)/$topic"
  [[ -d "$topic_dir" ]] || { log_warn "topic '$topic' has no state dir"; return; }

  shopt -s nullglob
  local any_kicked=0
  local pending_panes=()
  for trooper_dir in "$topic_dir"/*/; do
    [[ -d "$trooper_dir" ]] || continue
    local _META; mapfile -t _META < <(cw_pane_meta_read_for_dir "$trooper_dir")
    local commander="${_META[0]}"
    local model="${_META[1]}"
    local pane="${_META[2]}"
    if [[ -n "$pane" ]] && cw_pane_alive "$pane"; then
      pending_panes+=("$pane")
      any_kicked=1
    fi
    teardown_trooper "$commander" "$model" "$topic"
  done

  if (( any_kicked )); then
    log_info "waiting 9s for graceful banners to finish"
    sleep 9
    for p in "${pending_panes[@]}"; do
      cw_pane_kill_now "$p"
    done
  fi

  # Remove now-empty topic dir if it was just .last_pane (or empty).
  rm -f "$topic_dir/.last_pane" 2>/dev/null
  rmdir "$topic_dir" 2>/dev/null || true
}

# ------------------------------------------------------------ Arg dispatch

case "${1:-}" in
  ''|-h|--help)
    usage; exit 2 ;;

  --all)
    log_warn "this will tear down EVERY active trooper across every topic in this repo."
    echo -n "type 'yes' to confirm: " >&2
    read -r confirm
    [[ "$confirm" == "yes" ]] || { log_info "aborted"; exit 0; }
    repo_dir="$(cw_state_root)/state/$(cw_repo_hash)"
    [[ -d "$repo_dir" ]] || { log_info "no state dirs to tear down"; exit 0; }
    shopt -s nullglob
    for tdir in "$repo_dir"/*/; do
      t="${tdir%/}"; t="${t##*/}"
      teardown_topic "$t"
    done
    ;;

  *)
    if [[ $# -eq 1 ]]; then
      # Single arg — treat as topic
      teardown_topic "$1"
    elif [[ $# -eq 2 ]]; then
      # Two args — commander + topic
      commander="$1" topic="$2"
      topic_dir="$(cw_state_root)/state/$(cw_repo_hash)/$topic"
      shopt -s nullglob
      hit=0
      pending_pane=""
      for d in "$topic_dir"/${commander}-*/; do
        [[ -d "$d" ]] || continue
        name="${d%/}"; name="${name##*/}"
        # Strip the known-commander prefix to recover the FULL model
        # (handles hyphenated models like claude-haiku correctly; the
        # last-dash strip ${name##*-} would have returned just 'haiku').
        model_hint="${name#${commander}-}"
        model=$(cw_pane_meta_model "$commander" "$model_hint" "$topic")
        pane=$(cw_pane_meta_read "$commander" "$model" "$topic" 2>/dev/null || echo '')
        if [[ -n "$pane" ]] && cw_pane_alive "$pane"; then
          pending_pane="$pane"
        fi
        teardown_trooper "$commander" "$model" "$topic"
        hit=1
      done
      (( hit )) || { log_error "no trooper '$commander' on topic '$topic'"; exit 1; }
      if [[ -n "$pending_pane" ]]; then
        log_info "waiting 9s for graceful banner"
        sleep 9
        cw_pane_kill_now "$pending_pane"
      fi
      # Remove topic dir if now empty
      rm -f "$topic_dir/.last_pane" 2>/dev/null
      rmdir "$topic_dir" 2>/dev/null || true
    else
      usage; exit 2
    fi
    ;;
esac
