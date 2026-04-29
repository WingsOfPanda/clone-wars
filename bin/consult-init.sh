#!/usr/bin/env bash
# bin/consult-init.sh — derive consult-<slug> + create _consult/ + save topic.txt + pick a Jedi general.
# Prints CONSULT_TOPIC on line 1 of stdout, GENERAL on line 2; INFO logs to stderr.
#
# Usage: bin/consult-init.sh <topic-text>

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

[[ $# -ge 1 ]] || { echo "Usage: $0 <topic-text>" >&2; exit 2; }
TOPIC_TEXT="$*"

# Cap base slug to 20 chars so consult-<base>-NNN ≤ 32 (spawn.sh's regex limit).
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
printf '%s' "$TOPIC_TEXT" > "$TOPIC_DIR/_consult/topic.txt"

# Pick a Jedi general at random from the pool and persist for the rest of the run.
GENERAL=$(cw_consult_general_pick_random)
[[ -n "$GENERAL" ]] || { log_error "generals.yaml is empty — cannot pick a Jedi general"; exit 1; }
printf '%s' "$GENERAL" > "$TOPIC_DIR/_consult/general.txt"

log_info "consultation topic: $CONSULT_TOPIC"
log_info "  artifacts dir:    $TOPIC_DIR/_consult"
log_info "  Jedi general:     $GENERAL"

printf '%s\n' "$CONSULT_TOPIC"
printf '%s\n' "$GENERAL"
