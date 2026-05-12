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

# v0.17.0: parse --targets a,b,c (and --targets=a,b,c) BEFORE topic resolution.
# Stripped tokens never reach $TOPIC_TEXT.
TARGETS_RAW=""
TARGETS_FLAG_SEEN=0
NEW_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --targets)
      shift
      [[ $# -gt 0 ]] || { log_error "--targets: missing value"; exit 1; }
      TARGETS_RAW="$1"
      TARGETS_FLAG_SEEN=1
      shift ;;
    --targets=*)
      TARGETS_RAW="${1#--targets=}"
      TARGETS_FLAG_SEEN=1
      shift ;;
    *)
      NEW_ARGS+=("$1")
      shift ;;
  esac
done
set -- "${NEW_ARGS[@]:-}"

# v0.17.0: validate --targets BEFORE topic resolution (fail fast on bad slug).
if (( TARGETS_FLAG_SEEN )); then
  [[ -n "$TARGETS_RAW" ]] || { log_error "--targets: empty value"; exit 1; }
  source "$PLUGIN_ROOT/lib/deploy.sh"   # for CW_SLUG_REGEX_BASE
  IFS=',' read -ra TARGET_SLUGS <<< "$TARGETS_RAW"
  [[ ${#TARGET_SLUGS[@]} -gt 0 ]] || { log_error "--targets: empty list"; exit 1; }
  declare -A SEEN
  for s in "${TARGET_SLUGS[@]}"; do
    [[ -n "$s" ]] || { log_error "--targets: empty slug in list"; exit 1; }
    [[ "$s" =~ ^${CW_SLUG_REGEX_BASE}$ ]] || { log_error "--targets: invalid slug '$s' (must match ${CW_SLUG_REGEX_BASE})"; exit 1; }
    [[ -z "${SEEN[$s]:-}" ]] || { log_error "--targets: duplicate slug '$s'"; exit 1; }
    SEEN[$s]=1
    [[ -d "$PWD/$s" ]] || { log_error "--targets: directory not found: $PWD/$s"; exit 1; }
    [[ -f "$PWD/$s/CLAUDE.md" || -f "$PWD/$s/AGENTS.md" ]] \
      || { log_error "--targets: $PWD/$s lacks CLAUDE.md or AGENTS.md"; exit 1; }
  done
fi

[[ $# -ge 1 ]] || { echo "Usage: $0 [--targets a,b,c] <topic-text>" >&2; exit 2; }
TOPIC_TEXT="$*"

# v0.18.0: provider gate — prefer providers-active.txt (user-selected
# via /clone-wars:medic) over providers-available.txt (medic-detected).
PROVIDERS_FILE="$(cw_active_providers_path)"
[[ -f "$PROVIDERS_FILE" ]] || {
  log_error "$PROVIDERS_FILE not found"
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

# v0.16.0: pre-create design-doc/ subdir so downstream writers
# (Yoda fast-path + trooper-path consult-synthesize) don't need their own
# mkdir logic. The _consult/ parent is auto-created.
mkdir -p "$TOPIC_DIR/_consult/design-doc"
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

# v0.17.0: materialize --targets if provided. Auto-detection (Step 10 in
# directive) is skipped when these files already exist.
if [[ -n "$TARGETS_RAW" ]]; then
  TARGETS_FILE="$ART_DIR/targets.txt"
  TMPF=$(mktemp)
  printf '# generated %s by bin/consult-init.sh --targets\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TMPF"
  for s in "${TARGET_SLUGS[@]}"; do
    if   [[ -f "$PWD/$s/CLAUDE.md" ]]; then marker_path="$PWD/$s/CLAUDE.md"
    elif [[ -f "$PWD/$s/AGENTS.md" ]]; then marker_path="$PWD/$s/AGENTS.md"
    fi
    abs=$(cd "$PWD/$s" && pwd)/$(basename "$marker_path")
    printf '%s\t%s\n' "$s" "$abs" >> "$TMPF"
  done
  mv "$TMPF" "$TARGETS_FILE"
  # 1 slug → single-sub (single-repo shape, singular Target Sub-Project header).
  # 2+ slugs → multi (multi-repo DAG flow). Distinction matters for
  # bin/consult-walk-assemble.sh's header form and section list.
  if (( ${#TARGET_SLUGS[@]} == 1 )); then
    printf 'single-sub\n' > "$ART_DIR/multi-repo.txt"
  else
    printf 'multi\n' > "$ART_DIR/multi-repo.txt"
  fi
  log_info "  --targets:        ${#TARGET_SLUGS[@]} slugs → $TARGETS_FILE"
fi

log_info "consultation topic: $CONSULT_TOPIC"
log_info "  artifacts dir:    $ART_DIR"
log_info "  skill hint:       $SKILL"

printf '%s\n' "$CONSULT_TOPIC"
