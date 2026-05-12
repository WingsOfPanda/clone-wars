#!/usr/bin/env bash
# bin/deep-research-init.sh — initialize a /clone-wars:deep-research topic.
#
# Usage: bin/deep-research-init.sh [--max-rounds N] [--branches-per-round K]
#                                  [--time-budget DURATION] [--cost-warning USD]
#                                  [--allow-net] [--seed-from PATH] <topic-text>
#
# Refuses if codex is not in $state_root/providers-available.txt. Writes
# _deep-research/{topic,metric,budget,seed-from}.txt under the new topic
# state dir; prints the topic slug to stdout.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

# Defaults
MAX_ROUNDS=3
BRANCHES_PER_ROUND=4
TIME_BUDGET="1h"
COST_WARNING=5
ALLOW_NET=false
SEED_FROM=""
TOPIC=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-rounds)         MAX_ROUNDS="$2"; shift 2 ;;
    --max-rounds=*)       MAX_ROUNDS="${1#*=}"; shift ;;
    --branches-per-round) BRANCHES_PER_ROUND="$2"; shift 2 ;;
    --branches-per-round=*) BRANCHES_PER_ROUND="${1#*=}"; shift ;;
    --time-budget)        TIME_BUDGET="$2"; shift 2 ;;
    --time-budget=*)      TIME_BUDGET="${1#*=}"; shift ;;
    --cost-warning)       COST_WARNING="$2"; shift 2 ;;
    --cost-warning=*)     COST_WARNING="${1#*=}"; shift ;;
    --allow-net)          ALLOW_NET=true; shift ;;
    --seed-from)          SEED_FROM="$2"; shift 2 ;;
    --seed-from=*)        SEED_FROM="${1#*=}"; shift ;;
    --) shift; TOPIC="$*"; break ;;
    -*) log_error "unknown flag: $1"; exit 2 ;;
    *)  TOPIC="$*"; break ;;
  esac
done

[[ -n "$TOPIC" ]] || { log_error "topic required"; exit 2; }

# Codex availability gate (medic active-set is IGNORED for deep-research;
# user-selected roster is a consult/meditate construct).
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

# Parse time budget → seconds (h / m / s suffix; bare = seconds)
parse_duration() {
  local d="$1"
  case "$d" in
    *h) printf '%s\n' $(( ${d%h} * 3600 )) ;;
    *m) printf '%s\n' $(( ${d%m} * 60 )) ;;
    *s) printf '%s\n' "${d%s}" ;;
    *)  printf '%s\n' "$d" ;;
  esac
}
TIME_BUDGET_S=$(parse_duration "$TIME_BUDGET")
[[ "$TIME_BUDGET_S" =~ ^[1-9][0-9]*$ ]] \
  || { log_error "invalid --time-budget: $TIME_BUDGET"; exit 2; }

# Slug from topic — cap 20 chars so deep-research-<slug> ≤ 32 + room for -NNN
SLUG_BASE=$(printf '%s' "$TOPIC" \
  | tr '[:upper:]' '[:lower:]' \
  | tr -c 'a-z0-9-' '-' \
  | sed 's/--*/-/g; s/^-//; s/-$//' \
  | cut -c1-20 \
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
  TOPIC_DIR="$(cw_topic_state_dir "$TOPIC_NAME")"
  n=$((n + 1))
done

mkdir -p "$TOPIC_DIR/_deep-research"
ART_DIR="$TOPIC_DIR/_deep-research"

# topic.txt + metric.txt
printf '%s' "$TOPIC" > "$ART_DIR/topic.txt"
metric=$(cw_deep_research_extract_metric "$TOPIC")
printf '%s\n' "$metric" > "$ART_DIR/metric.txt"

# Per-branch timeout
per_branch=$(cw_deep_research_compute_per_branch_timeout "$TIME_BUDGET_S" "$MAX_ROUNDS" "$BRANCHES_PER_ROUND")

# budget.txt (KEY=VALUE lines)
cat > "$ART_DIR/budget.txt" <<EOF
max-rounds=$MAX_ROUNDS
branches-per-round=$BRANCHES_PER_ROUND
time-budget-s=$TIME_BUDGET_S
per-branch-timeout-s=$per_branch
cost-warning-usd=$COST_WARNING
allow-net=$ALLOW_NET
EOF

# seed-from.txt (only if used)
if [[ -n "$SEED_FROM" ]]; then
  printf '%s\n' "$SEED_FROM" > "$ART_DIR/seed-from.txt"
fi

log_info "deep-research topic: $TOPIC_NAME"
log_info "  artifacts dir:     $ART_DIR"
log_info "  metric:            ${metric:-(empty — Yoda will prompt)}"
log_info "  budget:            $MAX_ROUNDS rounds × $BRANCHES_PER_ROUND branches; ${TIME_BUDGET_S}s total; ${per_branch}s/branch"
[[ -n "$SEED_FROM" ]] && log_info "  seed-from:         $SEED_FROM"

printf '%s\n' "$TOPIC_NAME"
