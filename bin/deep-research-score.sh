#!/usr/bin/env bash
# bin/deep-research-score.sh — parse all branch result.json files in a round
# and produce scoreboard.md (sorted descending by metric_value, failed
# branches grouped at bottom). Yoda's select phase reads scoreboard.md to
# pick survivors.
#
# Usage: bin/deep-research-score.sh <topic> <round>

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

[[ $# -eq 2 ]] || { echo "Usage: $0 <topic> <round>" >&2; exit 2; }
TOPIC="$1"; ROUND="$2"

[[ "$TOPIC" == deep-research-* ]] || { log_error "bad topic: $TOPIC"; exit 2; }
[[ "$ROUND" =~ ^[1-9][0-9]*$ ]] || { log_error "bad round: $ROUND"; exit 2; }

ART_DIR=$(cw_consult_art_dir "$TOPIC")
ROUND_DIR="$ART_DIR/round-$ROUND"
BRANCHES_FILE="$ROUND_DIR/branches.txt"
[[ -f "$BRANCHES_FILE" ]] || { log_error "no branches.txt for round $ROUND"; exit 1; }

# Build rows: branch_label\tcommander\tmetric_value\tstatus\truntime_s\tlabel
declare -a OK_ROWS=() BAD_ROWS=()
while IFS=$'\t' read -r bid cmdr label _brief; do
  [[ -n "$bid" ]] || continue
  bd="$ART_DIR/round-$ROUND-$cmdr-$bid"
  result="$bd/result.json"
  branch_label="${cmdr}-${bid}"

  if [[ ! -f "$result" ]]; then
    BAD_ROWS+=("${branch_label}"$'\t'"${cmdr}"$'\t'"null"$'\t'"missing"$'\t'"0"$'\t'"${label}")
    continue
  fi
  if ! ( cd "$bd" && cw_deep_research_validate_result_json result.json 2>/dev/null ); then
    BAD_ROWS+=("${branch_label}"$'\t'"${cmdr}"$'\t'"null"$'\t'"invalid"$'\t'"0"$'\t'"${label}")
    continue
  fi

  if command -v jq >/dev/null 2>&1; then
    mv=$(jq -r '.metric_value // "null"' "$result")
    st=$(jq -r '.status' "$result")
    rt=$(jq -r '.runtime_s' "$result")
  else
    mv=$(grep -oE '"metric_value"[[:space:]]*:[[:space:]]*[^,}]+' "$result" \
      | sed 's/.*://; s/[[:space:]]*//g')
    st=$(grep -oE '"status"[[:space:]]*:[[:space:]]*"[^"]+"' "$result" \
      | sed -E 's/.*"([^"]+)"$/\1/')
    rt=$(grep -oE '"runtime_s"[[:space:]]*:[[:space:]]*[0-9]+' "$result" \
      | sed 's/.*://; s/[[:space:]]*//g')
  fi

  if [[ "$st" == "ok" ]]; then
    OK_ROWS+=("${branch_label}"$'\t'"${cmdr}"$'\t'"${mv}"$'\t'"${st}"$'\t'"${rt}"$'\t'"${label}")
  else
    BAD_ROWS+=("${branch_label}"$'\t'"${cmdr}"$'\t'"${mv}"$'\t'"${st}"$'\t'"${rt}"$'\t'"${label}")
  fi
done < "$BRANCHES_FILE"

# Sort ok rows descending by metric_value (column 3); bad rows alpha by branch_label
SORTED_OK=""
if [[ ${#OK_ROWS[@]} -gt 0 ]]; then
  SORTED_OK=$(printf '%s\n' "${OK_ROWS[@]}" | sort -t$'\t' -k3,3rg)
fi
SORTED_BAD=""
if [[ ${#BAD_ROWS[@]} -gt 0 ]]; then
  SORTED_BAD=$(printf '%s\n' "${BAD_ROWS[@]}" | sort -t$'\t' -k1,1)
fi

# Render scoreboard.md (atomic tmp + rename)
SCOREBOARD="$ROUND_DIR/scoreboard.md"
TMP_OUT=$(mktemp)
{
  echo "# Round $ROUND scoreboard"
  echo ""
  echo "| Rank | Branch | Commander | Metric | Status | Runtime | Approach |"
  echo "|---|---|---|---|---|---|---|"
  rank=1
  if [[ -n "$SORTED_OK" ]]; then
    while IFS=$'\t' read -r bid cmdr mv st rt label; do
      [[ -n "$bid" ]] || continue
      printf '| %d | %s | %s | %s | %s | %ss | %s |\n' \
        "$rank" "$bid" "$cmdr" "$mv" "$st" "$rt" "$label"
      rank=$((rank + 1))
    done <<< "$SORTED_OK"
  fi
  if [[ -n "$SORTED_BAD" ]]; then
    while IFS=$'\t' read -r bid cmdr mv st rt label; do
      [[ -n "$bid" ]] || continue
      printf '| %d | %s | %s | %s | %s | %ss | %s |\n' \
        "$rank" "$bid" "$cmdr" "$mv" "$st" "$rt" "$label"
      rank=$((rank + 1))
    done <<< "$SORTED_BAD"
  fi
} > "$TMP_OUT"

mv "$TMP_OUT" "$SCOREBOARD"
log_ok "[score] round $ROUND scoreboard at $SCOREBOARD"
