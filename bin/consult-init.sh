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

# v0.15.0: provider gate — read medic's remark.
PROVIDERS_FILE="$(cw_state_root)/providers-available.txt"
[[ -f "$PROVIDERS_FILE" ]] || {
  log_error "providers-available.txt not found at $PROVIDERS_FILE"
  log_error "run /clone-wars:medic first to detect installed providers."
  exit 2
}
mapfile -t CONSULT_PROVIDERS < <(
  grep -vE '^[[:space:]]*(#|$)' "$PROVIDERS_FILE" \
    | cw_consult_eligible_providers
)
N=${#CONSULT_PROVIDERS[@]}

case "$N" in
  0|1)
    log_warn "/consult requires >=2 consult-eligible providers; got $N."
    log_warn "Just ask claude directly (this Claude Code session) -- no /consult orchestration needed."
    exit 1 ;;
  2|3) ;;  # supported
  *)
    log_error "/consult cap is 3 troopers; got $N (filter dropped non-eligible)"
    exit 1 ;;
esac

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

# v0.15.0: write troopers.txt (TSV: provider<TAB>commander) for downstream scripts.
{
  printf '# generated %s by bin/consult-init.sh\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for prov in "${CONSULT_PROVIDERS[@]}"; do
    cmdr=$(cw_consult_provider_to_commander "$prov")
    printf '%s\t%s\n' "$prov" "$cmdr"
  done
} > "$ART_DIR/troopers.txt"

log_info "consultation topic: $CONSULT_TOPIC"
log_info "  artifacts dir:    $ART_DIR"
log_info "  skill hint:       $SKILL"

printf '%s\n' "$CONSULT_TOPIC"
