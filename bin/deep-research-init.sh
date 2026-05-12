#!/usr/bin/env bash
# bin/deep-research-init.sh — initialize a /clone-wars:deep-research topic.
#
# Usage: bin/deep-research-init.sh [--seed-from PATH] <topic-text>
#
# Refuses if codex is not in $state_root/providers-available.txt. Writes
# _deep-research/{topic,metric,seed-from}.txt under the new topic state
# dir; prints the topic slug to stdout.
#
# v0.27.0: all budget flags (--max-rounds, --branches-per-round,
# --time-budget, --cost-warning, --allow-net) are gone. Budget decisions
# move to the directive (Phase 2 time-limit AskUserQuestion); roster is
# advisor-decided. Slug cap tightened from 20 → 18 chars so the full
# topic name ('deep-research-' + slug = 32 chars max) fits bin/spawn.sh's
# topic regex.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

SEED_FROM=""
TOPIC=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --seed-from)   SEED_FROM="$2"; shift 2 ;;
    --seed-from=*) SEED_FROM="${1#*=}"; shift ;;
    --) shift; TOPIC="$*"; break ;;
    -*) log_error "unknown flag: $1 (v0.27.0 dropped --max-rounds, --branches-per-round, --time-budget, --cost-warning, --allow-net)"; exit 2 ;;
    *)  TOPIC="$*"; break ;;
  esac
done

[[ -n "$TOPIC" ]] || { log_error "topic required"; exit 2; }

# Codex availability gate (medic active-set is IGNORED for deep-research;
# roster size is advisor-decided in directive Phase 2).
state_root="${CLONE_WARS_HOME:-$HOME/.clone-wars}"
providers_file="$state_root/providers-available.txt"
if [[ ! -f "$providers_file" ]] || ! grep -qE '^codex$' "$providers_file"; then
  log_error "/clone-wars:deep-research requires codex provider."
  log_error "Install codex CLI and run /clone-wars:medic to refresh providers-available.txt."
  exit 1
fi

# Validate seed-from if given
if [[ -n "$SEED_FROM" ]]; then
  [[ -f "$SEED_FROM" ]] || { log_error "--seed-from path not found: $SEED_FROM"; exit 1; }
fi

# Slug from topic — cap 18 chars so 'deep-research-' + slug ≤ 32 chars
# (BLOCKER #1 fix; matches bin/spawn.sh:143 topic regex).
SLUG_BASE=$(printf '%s' "$TOPIC" \
  | tr '[:upper:]' '[:lower:]' \
  | tr -c 'a-z0-9-' '-' \
  | sed 's/--*/-/g; s/^-//; s/-$//' \
  | cut -c1-18 \
  | sed 's/-$//')
[[ -n "$SLUG_BASE" ]] || { log_error "topic produced empty slug; provide alphanumerics"; exit 2; }

TOPIC_NAME="deep-research-$SLUG_BASE"
TOPIC_DIR="$(cw_topic_state_dir "$TOPIC_NAME")"
n=2
while [[ -d "$TOPIC_DIR" ]]; do
  if (( n > 999 )); then
    log_error "more than 999 prior deep-research topics on slug '$SLUG_BASE'; pick a different topic"
    exit 1
  fi
  TOPIC_NAME="deep-research-$SLUG_BASE-$n"
  # If the -NNN suffix pushes us past 32, truncate the slug base further.
  if (( ${#TOPIC_NAME} > 32 )); then
    trim=$(( ${#TOPIC_NAME} - 32 ))
    SLUG_BASE="${SLUG_BASE:0:$((${#SLUG_BASE} - trim))}"
    TOPIC_NAME="deep-research-$SLUG_BASE-$n"
  fi
  TOPIC_DIR="$(cw_topic_state_dir "$TOPIC_NAME")"
  n=$((n + 1))
done

mkdir -p "$TOPIC_DIR/_deep-research"
ART_DIR="$TOPIC_DIR/_deep-research"

# topic.txt + metric.txt (metric.txt = heuristic seed for Phase 1 dialogue,
# not the source of truth. Directive writes metric.md after Phase 1.)
printf '%s' "$TOPIC" > "$ART_DIR/topic.txt"
metric=$(cw_deep_research_extract_metric "$TOPIC")
printf '%s\n' "$metric" > "$ART_DIR/metric.txt"

# seed-from.txt (only if used)
if [[ -n "$SEED_FROM" ]]; then
  printf '%s\n' "$SEED_FROM" > "$ART_DIR/seed-from.txt"
fi

# v0.27.2 P2: init-time hardware probe baseline. Per-experiment probe
# + diff alert lives in bin/deep-research-experiment-send.sh; this
# snapshot lets the diff helper detect mid-session memory.free drops.
cw_deep_research_hardware_probe "$ART_DIR/hardware.txt"

log_info "deep-research topic: $TOPIC_NAME"
log_info "  artifacts dir:     $ART_DIR"
log_info "  metric (seed):     ${metric:-(empty — directive will discuss in Phase 1)}"
log_info "  hardware:          $(head -2 "$ART_DIR/hardware.txt" 2>/dev/null | tr '\n' ' ' | sed 's/  *$//')"
[[ -n "$SEED_FROM" ]] && log_info "  seed-from:         $SEED_FROM"

printf '%s\n' "$TOPIC_NAME"
