#!/usr/bin/env bash
# bin/consult-init.sh — derive consult-<slug> + create _consult/ + save topic.txt.
# Prints CONSULT_TOPIC to stdout; INFO logs to stderr.
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
TOPIC_DIR="$(cw_consult_topic_dir "$CONSULT_TOPIC")"
n=2
while [[ -d "$TOPIC_DIR" ]]; do
  if (( n > 999 )); then
    log_error "more than 999 prior consults on slug '$SLUG_BASE'; pick a different topic"
    exit 1
  fi
  CONSULT_TOPIC="consult-$SLUG_BASE-$n"
  TOPIC_DIR="$(cw_consult_topic_dir "$CONSULT_TOPIC")"
  n=$((n + 1))
done

mkdir -p "$TOPIC_DIR/_consult"
ART_DIR="$TOPIC_DIR/_consult"
printf '%s' "$TOPIC_TEXT" > "$ART_DIR/topic.txt"

# Classify topic and persist skill hint for send-scripts.
SKILL=$(cw_consult_classify_topic "$TOPIC_TEXT")
printf '%s' "$SKILL" > "$ART_DIR/skill.txt"

# Hub-mode classification (v0.11). Persist before any further work so
# downstream sub-scripts can branch on it. Detector returns rc=1 for
# single-repo (the default); rc=0 with MODE= line for hub-subrepo/super-hub.
HUB_OUT=$(cw_consult_detect_hub "$(pwd)") && HUB_RC=0 || HUB_RC=$?
if (( HUB_RC == 0 )); then
  HUB_MODE=$(grep '^MODE=' <<< "$HUB_OUT" | head -1 | cut -d= -f2)
else
  HUB_MODE="single-repo"
fi
cw_consult_hub_mode_persist "$ART_DIR" "$HUB_MODE" \
  || log_warn "hub-mode persist failed for $ART_DIR"

log_info "consultation topic: $CONSULT_TOPIC"
log_info "  artifacts dir:    $ART_DIR"
log_info "  skill hint:       $SKILL"
log_info "  hub mode:         $HUB_MODE"

printf '%s\n' "$CONSULT_TOPIC"
