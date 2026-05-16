#!/usr/bin/env bash
# bin/deep-research-consensus.sh — v0.33.0 D4
# Per-field consensus across each trooper's LATEST ok result.json.
#
# Usage: bin/deep-research-consensus.sh <topic> [--epsilon=<float>]
#
# Writes $ART_DIR/consensus.md with ## Agreed / ## Contested / ## All-missing
# sections. Fields inspected: branch_id, approach_label, metric_name,
# metric_value (numeric, epsilon-aware), status, runtime_s, notes.
#
# Exit codes:
#   0 = ok
#   1 = no ok result.json files found under any commander
#   2 = usage error

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

EPSILON=0.01
TOPIC=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --epsilon=*) EPSILON="${1#*=}"; shift ;;
    --epsilon)   EPSILON="$2"; shift 2 ;;
    -*)          log_error "unknown flag: $1"; exit 2 ;;
    *)           TOPIC="$1"; shift ;;
  esac
done

[[ -n "$TOPIC" ]] || { log_error "Usage: $0 <topic> [--epsilon=<float>]"; exit 2; }
cw_deep_research_assert_topic "$TOPIC"

TOPIC_DIR="$(cw_topic_state_dir "$TOPIC")"
ART="$TOPIC_DIR/_deep-research"
[[ -d "$ART/troopers" ]] || { log_error "troopers dir missing: $ART/troopers"; exit 1; }

# Collect latest ok result.json per commander (sorted exp-NNN lex). Use a
# parallel counter — empty `declare -A LATEST` under set -u trips
# unbound-variable on `${#LATEST[@]}`.
declare -A LATEST
LATEST_COUNT=0
shopt -s nullglob
for cmdr_dir in "$ART/troopers"/*/; do
  cmdr=$(basename "${cmdr_dir%/}")
  newest=""
  for exp_dir in "$cmdr_dir/experiments"/exp-[0-9]*/; do
    base=$(basename "${exp_dir%/}")
    r="$exp_dir/result.json"
    [[ -f "$r" ]] || continue
    if grep -qE '"status"[[:space:]]*:[[:space:]]*"ok"' "$r"; then
      if [[ "$base" > "$newest" ]]; then
        if [[ -z "$newest" ]]; then
          LATEST_COUNT=$((LATEST_COUNT + 1))
        fi
        newest="$base"
        LATEST[$cmdr]="$r"
      fi
    fi
  done
done
shopt -u nullglob

(( LATEST_COUNT > 0 )) || { log_error "no ok result.json files found"; exit 1; }

# Field extractor (jq if available, else grep)
_field() {
  local f="$1" k="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$k" '
      if has($k) and (.[$k] != null) then
        (.[$k] | tostring)
      else
        ""
      end
    ' "$f" 2>/dev/null
  else
    grep -oE "\"$k\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|[0-9.eE+-]+|true|false|null)" "$f" \
      | head -1 \
      | sed -E "s/^\"$k\"[[:space:]]*:[[:space:]]*\"?([^\"]*)\"?$/\1/"
  fi
}

# Numeric epsilon-aware equality
_num_eq() {
  awk -v a="$1" -v b="$2" -v e="$EPSILON" 'BEGIN {
    d = (a + 0) - (b + 0); if (d < 0) d = -d
    exit !(d <= e + 0)
  }'
}

FIELDS=(branch_id approach_label metric_name metric_value status runtime_s notes)

# Sorted commanders for deterministic output. mapfile avoids the SC2207
# word-splitting trap and works correctly when LATEST is empty (already
# guarded above).
CMDRS=()
for c in "${!LATEST[@]}"; do CMDRS+=("$c"); done
mapfile -t CMDRS < <(printf '%s\n' "${CMDRS[@]}" | sort)

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
{
  printf '# Consensus — %s\n\n' "$TOPIC"
  printf 'Generated: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'Epsilon for metric_value: %s\n\n' "$EPSILON"

  agreed_rows=""
  contested_rows=""
  missing_rows=""

  for field in "${FIELDS[@]}"; do
    vals=()
    srcs=()
    missing=0
    for c in "${CMDRS[@]}"; do
      v=$(_field "${LATEST[$c]}" "$field")
      if [[ -z "$v" ]]; then
        missing=$((missing + 1))
      else
        vals+=("$v")
        srcs+=("$c")
      fi
    done
    if (( missing == ${#CMDRS[@]} )); then
      missing_rows+="- $field"$'\n'
      continue
    fi
    # All-agree across present values?
    all_agree=1
    first="${vals[0]}"
    is_numeric=0
    [[ "$first" =~ ^-?[0-9.eE+-]+$ ]] && is_numeric=1
    if (( ${#vals[@]} > 1 )); then
      for v in "${vals[@]:1}"; do
        if (( is_numeric == 1 )) && [[ "$v" =~ ^-?[0-9.eE+-]+$ ]]; then
          _num_eq "$first" "$v" || { all_agree=0; break; }
        else
          [[ "$v" == "$first" ]] || { all_agree=0; break; }
        fi
      done
    fi
    # If some commanders are missing while others have a value, treat as contested
    if (( missing > 0 )); then
      all_agree=0
    fi
    src_list=$(IFS=', '; printf '%s' "${srcs[*]}")
    if (( all_agree == 1 )); then
      agreed_rows+="| $field | $first | $src_list |"$'\n'
    else
      row="| $field"
      for c in "${CMDRS[@]}"; do
        v=$(_field "${LATEST[$c]}" "$field")
        [[ -z "$v" ]] && v="—"
        row+=" | $v"
      done
      row+=" |"
      contested_rows+="$row"$'\n'
    fi
  done

  printf '## Agreed\n\n'
  if [[ -n "$agreed_rows" ]]; then
    printf '| Field | Value | Proposed by |\n'
    printf '|---|---|---|\n'
    printf '%s' "$agreed_rows"
  else
    printf '_(none)_\n'
  fi
  printf '\n'

  printf '## Contested\n\n'
  if [[ -n "$contested_rows" ]]; then
    header="| Field"
    sep="|---"
    for c in "${CMDRS[@]}"; do
      header+=" | ${c}'s value"
      sep+="|---"
    done
    header+=" |"
    sep+="|"
    printf '%s\n%s\n' "$header" "$sep"
    printf '%s' "$contested_rows"
  else
    printf '_(none)_\n'
  fi
  printf '\n'

  printf '## All-missing\n\n'
  if [[ -n "$missing_rows" ]]; then
    printf '%s' "$missing_rows"
  else
    printf '_(none)_\n'
  fi
} > "$TMP"

cw_atomic_write "$ART/consensus.md" < "$TMP"
log_ok "[consensus] wrote $ART/consensus.md (${#CMDRS[@]} troopers)"
