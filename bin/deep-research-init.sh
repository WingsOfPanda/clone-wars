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

TIME_BUDGET=""
METRIC_KV=""
SLUG_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --seed-from)     SEED_FROM="$2"; shift 2 ;;
    --seed-from=*)   SEED_FROM="${1#*=}"; shift ;;
    --time-budget)   TIME_BUDGET="$2"; shift 2 ;;
    --time-budget=*) TIME_BUDGET="${1#*=}"; shift ;;
    --metric)        METRIC_KV="$2"; shift 2 ;;
    --metric=*)      METRIC_KV="${1#*=}"; shift ;;
    --slug)          SLUG_OVERRIDE="$2"; shift 2 ;;
    --slug=*)        SLUG_OVERRIDE="${1#*=}"; shift ;;
    --) shift; TOPIC="$*"; break ;;
    -*) log_error "unknown flag: $1 (v0.34.0 added --slug; v0.32.0 added --time-budget + --metric; v0.27.0 dropped --max-rounds, --branches-per-round, --cost-warning, --allow-net)"; exit 2 ;;
    *)  TOPIC="$*"; break ;;
  esac
done

# v0.32.0 #23: resolve --time-budget value. Empty = unset = directive Phase 2 prompts.
if [[ -n "$TIME_BUDGET" ]]; then
  case "$TIME_BUDGET" in
    none) RESOLVED_BUDGET=none ;;
    *h)
      h="${TIME_BUDGET%h}"
      [[ "$h" =~ ^[1-9][0-9]*$ ]] \
        || { log_error "invalid --time-budget hours: '$TIME_BUDGET'"; exit 2; }
      RESOLVED_BUDGET=$(( h * 3600 ))
      ;;
    *s)
      s="${TIME_BUDGET%s}"
      [[ "$s" =~ ^[1-9][0-9]*$ ]] \
        || { log_error "invalid --time-budget seconds: '$TIME_BUDGET'"; exit 2; }
      RESOLVED_BUDGET="$s"
      ;;
    *)
      [[ "$TIME_BUDGET" =~ ^[1-9][0-9]*$ ]] \
        || { log_error "--time-budget must be 'none', '<N>h', or positive seconds; got '$TIME_BUDGET'"; exit 2; }
      RESOLVED_BUDGET="$TIME_BUDGET"
      ;;
  esac
fi

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

# v0.34.0: --slug override (strict regex). Otherwise auto-derive from topic
# with a 18-char cap so 'deep-research-' + slug ≤ 32 chars (BLOCKER #1 fix;
# matches bin/spawn.sh:143 topic regex).
if [[ -n "$SLUG_OVERRIDE" ]]; then
  [[ "$SLUG_OVERRIDE" =~ ^[a-z][a-z0-9-]{0,17}$ ]] \
    || { log_error "--slug must match ^[a-z][a-z0-9-]{0,17}\$; got '$SLUG_OVERRIDE'"; exit 2; }
  SLUG_BASE="$SLUG_OVERRIDE"
else
  SLUG_BASE=$(printf '%s' "$TOPIC" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9-' '-' \
    | sed 's/--*/-/g; s/^-//; s/-$//' \
    | cut -c1-18 \
    | sed 's/-$//')
fi
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

# v0.32.0 #23: if --metric was passed, pre-write metric.md via the
# existing helper. Directive prose skips Phase 1 steps 3/4/6
# AskUserQuestions when metric.md exists.
if [[ -n "$METRIC_KV" ]]; then
  metric_out=$(printf '%s\n' "${METRIC_KV//,/$'\n'}" \
    | cw_deep_research_format_metric_block 2>"$ART_DIR/metric.err") \
    || { log_error "--metric: $(cat "$ART_DIR/metric.err")"; exit 2; }
  printf '%s\n' "$metric_out" > "$ART_DIR/metric.md"
  rm -f "$ART_DIR/metric.err"
fi

# v0.32.0 #23: if --time-budget was passed, pre-write the state files
# Phase 2 step 2 would normally produce. Directive prose skips the
# AskUserQuestion when time-budget.txt exists.
if [[ -n "${RESOLVED_BUDGET:-}" ]]; then
  printf '%s\n' "$RESOLVED_BUDGET" > "$ART_DIR/time-budget.txt"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$ART_DIR/session-start.txt"
fi

# v0.28.0: touch active.txt. The UserPromptSubmit hook scans for this
# file under $CLONE_WARS_HOME/state/ to detect an in-progress session
# and inject handler 3.b context (commands/deep-research-resume.md).
# Per-trooper dirs (troopers/<cmdr>/state.txt) are created by the
# directive in Phase 4.a after Phase 2 picks the roster.
printf '%s\n' "$TOPIC_NAME" > "$ART_DIR/active.txt"

log_info "deep-research topic: $TOPIC_NAME"
log_info "  artifacts dir:     $ART_DIR"
log_info "  metric (seed):     ${metric:-(empty — directive will discuss in Phase 1)}"
log_info "  hardware:          $(head -2 "$ART_DIR/hardware.txt" 2>/dev/null | tr '\n' ' ' | sed 's/  *$//')"
[[ -n "$SEED_FROM" ]] && log_info "  seed-from:         $SEED_FROM"

printf '%s\n' "$TOPIC_NAME"
