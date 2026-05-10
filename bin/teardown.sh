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

# _teardown_batch <topic> <commander1>:<model1> <commander2>:<model2> ...
# Run the full graceful-shutdown + archive flow for each (commander, model)
# pair on <topic>. One graceful-banner phase fires in parallel across all
# live panes; one 9s sleep covers all banners; then hard-kill + archive.
#
# Pair encoding: "<commander>:<model>". Pane IDs start with '%' and never
# contain ':', and commander/model are validated to ^[a-z0-9-]+$, so the
# colon delimiter is unambiguous.
_teardown_batch() {
  local topic="$1"; shift
  local pairs=("$@")
  local pair commander model pane
  local pending_panes=()
  local last_file last_pane=""

  # Phase 1: graceful-kick each live pane (non-blocking — banner runs in pane).
  for pair in "${pairs[@]}"; do
    commander="${pair%:*}"
    model="${pair##*:}"
    pane=$(cw_pane_meta_read "$commander" "$model" "$topic" 2>/dev/null || echo '')
    if [[ -n "$pane" ]] && cw_pane_alive "$pane"; then
      log_info "graceful shutdown for $commander-$model on $topic (pane $pane)"
      cw_pane_kill_graceful "$pane"
      pending_panes+=("$pane")
    fi
  done

  # Phase 2: one sleep + hard-kill batch.
  if (( ${#pending_panes[@]} > 0 )); then
    log_info "waiting 9s for graceful banners to finish"
    sleep 9
    for pane in "${pending_panes[@]}"; do
      cw_pane_kill_now "$pane"
    done
  fi

  # Phase 3: archive each (state dirs are now safe to move).
  for pair in "${pairs[@]}"; do
    commander="${pair%:*}"
    model="${pair##*:}"
    local archived; archived=$(cw_state_archive "$commander" "$model" "$topic")
    log_ok "archived $commander-$model: $archived"
  done

  # Phase 4: clean topic .last_pane if it pointed at a killed pane.
  last_file="$(cw_topic_state_dir "$topic")/.last_pane"
  if [[ -f "$last_file" ]]; then
    last_pane=$(cat "$last_file")
    for pane in "${pending_panes[@]}"; do
      if [[ "$last_pane" == "$pane" ]]; then
        rm -f "$last_file"
        break
      fi
    done
  fi
}

teardown_topic() {
  local topic="$1"
  local topic_dir
  topic_dir=$(cw_topic_state_dir "$topic")
  [[ -d "$topic_dir" ]] || { log_warn "topic '$topic' has no state dir"; return; }

  shopt -s nullglob
  local pairs=()
  local trooper_dir
  for trooper_dir in "$topic_dir"/*/; do
    [[ -d "$trooper_dir" ]] || continue
    # Skip _-prefixed sibling dirs (e.g. _consult/) — not trooper state.
    cw_is_artifact_dir "$trooper_dir" && continue
    local _META; mapfile -t _META < <(cw_pane_meta_read_for_dir "$trooper_dir")
    pairs+=("${_META[0]}:${_META[1]}")
  done

  if (( ${#pairs[@]} > 0 )); then
    _teardown_batch "$topic" "${pairs[@]}"
  fi

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
    repo_dir="$(cw_repo_state_dir)"
    [[ -d "$repo_dir" ]] || { log_info "no state dirs to tear down"; exit 0; }
    shopt -s nullglob
    for tdir in "$repo_dir"/*/; do
      t="${tdir%/}"; t="${t##*/}"
      teardown_topic "$t"
    done
    ;;

  --pairs)
    # v0.20.5: bin/teardown.sh --pairs <topic> <cmdr1> [cmdr2] ...
    # Batch teardown for an explicit commander list (typically from
    # consult-teardown.sh's troopers.txt iteration). Single 9s graceful
    # banner shared across all panes via _teardown_batch. Skips any
    # commander whose state dir is missing — intentional, mirrors the
    # 2-arg path's "no such trooper" tolerance.
    shift
    [[ $# -ge 2 ]] || { log_error "--pairs requires <topic> <cmdr1> [cmdr2] ..."; exit 2; }
    topic="$1"; shift
    topic_dir="$(cw_topic_state_dir "$topic")"
    shopt -s nullglob
    pairs=()
    for commander in "$@"; do
      for d in "$topic_dir"/${commander}-*/; do
        [[ -d "$d" ]] || continue
        name="${d%/}"; name="${name##*/}"
        model_hint="${name#${commander}-}"
        model=$(cw_pane_meta_model "$commander" "$model_hint" "$topic")
        pairs+=("$commander:$model")
      done
    done
    if (( ${#pairs[@]} > 0 )); then
      _teardown_batch "$topic" "${pairs[@]}"
    else
      log_warn "no matching trooper dirs found for any of: $*"
    fi
    rm -f "$topic_dir/.last_pane" 2>/dev/null
    rmdir "$topic_dir" 2>/dev/null || true
    ;;

  *)
    if [[ $# -eq 1 ]]; then
      # Single arg — treat as topic
      teardown_topic "$1"
    elif [[ $# -eq 2 ]]; then
      # Two args — commander + topic
      commander="$1" topic="$2"
      topic_dir="$(cw_topic_state_dir "$topic")"
      shopt -s nullglob
      pairs=()
      for d in "$topic_dir"/${commander}-*/; do
        [[ -d "$d" ]] || continue
        name="${d%/}"; name="${name##*/}"
        # Strip the known-commander prefix to recover the FULL model
        # (handles hyphenated models like claude-haiku correctly).
        model_hint="${name#${commander}-}"
        model=$(cw_pane_meta_model "$commander" "$model_hint" "$topic")
        pairs+=("$commander:$model")
      done
      (( ${#pairs[@]} > 0 )) || { log_error "no trooper '$commander' on topic '$topic'"; exit 1; }
      _teardown_batch "$topic" "${pairs[@]}"
      rm -f "$topic_dir/.last_pane" 2>/dev/null
      rmdir "$topic_dir" 2>/dev/null || true
    else
      usage; exit 2
    fi
    ;;
esac
