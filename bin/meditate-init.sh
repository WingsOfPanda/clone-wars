#!/usr/bin/env bash
# bin/meditate-init.sh — derive meditate-<slug> + create _meditate/ + save topic.txt.
# Prints MEDITATE_TOPIC to stdout; INFO logs to stderr.
#
# Usage: bin/meditate-init.sh <topic-text>
#
# v0.25.0: mirrors bin/consult-init.sh but writes under _meditate/ and uses
# the "meditate-" prefix. No --targets flag (multi-repo deferred). No
# --lit / --no-lit parsing — those are stripped by the directive before
# this script is called.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/meditate.sh"

[[ $# -ge 1 ]] || { echo "Usage: $0 <topic-text>" >&2; exit 2; }
TOPIC_TEXT="$*"

# Provider gate — prefer providers-active.txt (user-selected via medic)
PROVIDERS_FILE="$(cw_active_providers_path)"
[[ -f "$PROVIDERS_FILE" ]] || {
  log_error "$PROVIDERS_FILE not found"
  log_error "run /clone-wars:medic first to detect installed providers."
  exit 2
}
mapfile -t MEDITATE_PROVIDERS < <(
  grep -vE '^[[:space:]]*(#|$)' "$PROVIDERS_FILE" \
    | cw_consult_eligible_providers
)
N=${#MEDITATE_PROVIDERS[@]}

case "$N" in
  0|1)
    log_warn "/meditate requires >=2 eligible providers; got $N."
    log_warn "Just ask claude directly — no /meditate orchestration needed."
    exit 1 ;;
  2|3) ;;
  *)
    log_error "/meditate cap is 3 troopers; got $N (filter dropped non-eligible)"
    exit 1 ;;
esac

# Cap base slug to 20 chars so meditate-<base>-NNN ≤ 32 (spawn.sh's regex limit).
SLUG_BASE=$(printf '%s' "$TOPIC_TEXT" \
  | tr '[:upper:]' '[:lower:]' \
  | tr -c 'a-z0-9-' '-' \
  | sed 's/--*/-/g; s/^-//; s/-$//' \
  | cut -c1-20 \
  | sed 's/-$//')
[[ -n "$SLUG_BASE" ]] || { log_error "topic produced empty slug; provide alphanumerics"; exit 2; }

MEDITATE_TOPIC="meditate-$SLUG_BASE"
TOPIC_DIR="$(cw_topic_state_dir "$MEDITATE_TOPIC")"
n=2
while [[ -d "$TOPIC_DIR" ]]; do
  if (( n > 999 )); then
    log_error "more than 999 prior meditations on slug '$SLUG_BASE'; pick a different topic"
    exit 1
  fi
  MEDITATE_TOPIC="meditate-$SLUG_BASE-$n"
  TOPIC_DIR="$(cw_topic_state_dir "$MEDITATE_TOPIC")"
  n=$((n + 1))
done

# Pre-create _meditate/ subdir so all writers find it.
mkdir -p "$TOPIC_DIR/_meditate"
ART_DIR="$TOPIC_DIR/_meditate"
printf '%s' "$TOPIC_TEXT" > "$ART_DIR/topic.txt"

# Write troopers.txt (TSV: provider<TAB>commander).
{
  printf '# generated %s by bin/meditate-init.sh\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for prov in "${MEDITATE_PROVIDERS[@]}"; do
    cmdr=$(cw_consult_provider_to_commander "$prov")
    printf '%s\t%s\n' "$prov" "$cmdr"
  done
} > "$ART_DIR/troopers.txt"

log_info "meditation topic: $MEDITATE_TOPIC"
log_info "  artifacts dir:  $ART_DIR"
log_info "  trooper count:  $N"

printf '%s\n' "$MEDITATE_TOPIC"
