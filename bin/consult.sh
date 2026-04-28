#!/usr/bin/env bash
# bin/consult.sh — orchestrate /clone-wars:consult Phases 1-5.
# Writes adjudicated.md with PENDING items; the slash directive drives the
# conductor through PENDING resolution; bin/consult-finalize.sh handles 6-7.
#
# This is the v0.1.0 skeleton: arg parsing, slug derivation, conflict
# resolver, dry-run path, and exit. Phases 1-5 land in subsequent commits.

set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deps.sh"
source "$PLUGIN_ROOT/lib/contracts.sh"
source "$PLUGIN_ROOT/lib/commanders.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/tmux.sh"
source "$PLUGIN_ROOT/lib/argsfile.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

# --args-file <path> — read tokens from <path> and replace positional args.
# Used by commands/*.md to fence off shell injection from $ARGUMENTS.
if [[ "${1:-}" == "--args-file" ]]; then
  [[ -n "${2:-}" ]] || { echo "--args-file requires a path" >&2; exit 2; }
  args_file="$2"; shift 2
  mapfile -t _TOKENS < <(cw_args_file_load "$args_file")
  set -- "${_TOKENS[@]}" "$@"
fi

usage() { echo "Usage: $0 <topic>" >&2; }

[[ $# -ge 1 ]] || { usage; exit 2; }
TOPIC_TEXT="$*"

# ---------------------------------------------------------- Slug derivation
# Cap base slug to 20 chars so consult-<base>-NNN <= 32 (spawn.sh's limit).
# 8 ("consult-") + 20 (base) + 4 ("-999") = 32 exactly.
SLUG_BASE=$(printf '%s' "$TOPIC_TEXT" \
  | tr '[:upper:]' '[:lower:]' \
  | tr -c 'a-z0-9-' '-' \
  | sed 's/--*/-/g; s/^-//; s/-$//' \
  | cut -c1-20 \
  | sed 's/-$//')
[[ -n "$SLUG_BASE" ]] || { log_error "topic produced empty slug; provide alphanumerics"; exit 2; }

CONSULT_TOPIC="consult-$SLUG_BASE"
TOPIC_DIR="$(cw_state_root)/state/$(cw_repo_hash)/$CONSULT_TOPIC"
n=2
while [[ -d "$TOPIC_DIR" ]]; do
  if (( n > 999 )); then
    log_error "more than 999 prior consults on slug '$SLUG_BASE'; pick a different topic"
    exit 1
  fi
  CONSULT_TOPIC="consult-$SLUG_BASE-$n"
  TOPIC_DIR="$(cw_state_root)/state/$(cw_repo_hash)/$CONSULT_TOPIC"
  n=$((n + 1))
done

mkdir -p "$TOPIC_DIR/_consult"
ART_DIR="$TOPIC_DIR/_consult"
# Save topic text for finalize to recover later.
printf '%s' "$TOPIC_TEXT" > "$ART_DIR/topic.txt"

# Print resolved topic on STDOUT (not via log_info, which goes to stderr) so
# tests can capture it cleanly without mixing log noise. Other progress lines
# stay on stderr.
printf 'consultation topic: %s\n' "$CONSULT_TOPIC"
log_info "  artifacts dir: $ART_DIR"

# Dry-run path (test harness): print and exit before spawning.
if [[ "${CW_CONSULT_DRY_RUN:-0}" == "1" ]]; then
  exit 0
fi

# (Phase 1 spawn + Phases 2-5 in subsequent commits.)
exit 0
