# lib/deep-research.sh — helpers for /clone-wars:deep-research.
# Sourced. Depends on lib/log.sh, lib/state.sh, lib/consult.sh, lib/commanders.sh.
#
# Public:
#   cw_deep_research_extract_metric <topic-text>
#       — heuristic metric name extraction; empty string if ambiguous
#   cw_deep_research_validate_result_json <relative-path>
#       — schema check; rc=0 valid; rc>0 invalid (stderr); call from branch dir
#   cw_deep_research_extract_approaches <landscape-md-path>
#       — TSV "label\tbrief\n" from meditate landscape ## Approaches section
#   cw_deep_research_pick_roster <N>
#       — first N codex-eligible commanders (N=2 or N=3); deterministic
#   cw_deep_research_format_metric_block
#       — render metric.md from K=V pairs on stdin
#   cw_deep_research_check_stagnation <scoreboard> <cursor-path>
#       — rc=0 if last 5 post-cursor exps all <1% of running best AND
#         exp_count >= 5; rc!=0 otherwise
#   cw_deep_research_check_time_budget <budget-path> <session-start-path>
#       — rc=0 if elapsed >= budget seconds; rc=1 on 'none' or not yet hit

# Canonical metric vocabulary. Whole-word case-insensitive match in topic
# text; first-by-position wins.
_CW_DEEP_RESEARCH_METRIC_VOCAB=(
  accuracy auc cost f1 latency loss memory params precision recall throughput
)

# cw_deep_research_extract_metric <topic-text>
# Returns first metric vocabulary match (lexically by topic position).
# Empty string if no match (caller should AskUserQuestion-prompt user).
cw_deep_research_extract_metric() {
  local topic="${1:-}"
  [[ -n "$topic" ]] || { echo ""; return 0; }
  local lower; lower=$(printf '%s' "$topic" | tr '[:upper:]' '[:lower:]')
  local best_pos=999999 best_word=""
  local word
  for word in "${_CW_DEEP_RESEARCH_METRIC_VOCAB[@]}"; do
    # Whole-word match using bash regex with non-word-character borders
    if [[ " $lower " =~ [^a-z0-9]"$word"[^a-z0-9] ]]; then
      local pre="${lower%%"$word"*}"
      local pos=${#pre}
      if (( pos < best_pos )); then
        best_pos=$pos
        best_word=$word
      fi
    fi
  done
  printf '%s\n' "$best_word"
}

# cw_deep_research_validate_result_json <relative-path>
# Caller must have cd'd to the branch dir (log_paths are relative).
# Returns 0 on valid; >0 on invalid (stderr message).
# Prefers jq when available; falls back to grep-based validation.
cw_deep_research_validate_result_json() {
  local path="${1:-}"
  [[ -f "$path" ]] || { echo "result.json not found: $path" >&2; return 1; }
  if command -v jq >/dev/null 2>&1; then
    _cw_deep_research_validate_result_jq "$path"
  else
    _cw_deep_research_validate_result_grep "$path"
  fi
}

_cw_deep_research_validate_result_jq() {
  local path="$1"
  jq empty "$path" 2>/dev/null || { echo "malformed JSON" >&2; return 1; }
  local f
  for f in branch_id approach_label metric_name metric_value status runtime_s log_paths; do
    if [[ "$(jq -r "has(\"$f\")" "$path")" != "true" ]]; then
      echo "missing required field: $f" >&2; return 1
    fi
  done
  local status; status=$(jq -r '.status' "$path")
  case "$status" in
    ok|fail|timeout|cost_blown) ;;
    *) echo "invalid status: $status" >&2; return 1 ;;
  esac
  local mv_null; mv_null=$(jq -r '.metric_value == null' "$path")
  if [[ "$status" == "ok" && "$mv_null" == "true" ]]; then
    echo "status=ok requires non-null metric_value" >&2; return 1
  fi
  if [[ "$status" != "ok" && "$mv_null" == "false" ]]; then
    echo "status=$status requires null metric_value" >&2; return 1
  fi
  local p
  while IFS= read -r p; do
    [[ -f "$p" ]] || { echo "log_path missing: $p" >&2; return 1; }
  done < <(jq -r '.log_paths[]' "$path")
  return 0
}

# Codex-eligible commander pool — ordered (first allocated first).
# rex is canonical codex commander; cody/bly/wolffe excluded because they
# canonically map to claude/opencode in lib/consult.sh:cw_consult_provider_to_commander.
# 17 commanders total: 5 Captain + 7 Commander + 1 Sergeant + 4 Lieutenant.
_CW_DEEP_RESEARCH_CMDR_POOL=(
  rex keeli colt trauma blackout
  fox gree ponds bacara neyo doom faie
  hunter
  havoc thorn thire stone
)

# cw_deep_research_allocate_commanders <round> <K>
# K unique commanders for one round; mod-rotated across rounds (positions
# (round-1)*K .. round*K - 1 in the pool).
# rc=2 if K or (round*K) exceeds pool, or args invalid.
cw_deep_research_allocate_commanders() {
  local round="${1:-}" k="${2:-}"
  [[ "$round" =~ ^[1-9][0-9]*$ ]] || { echo "round must be positive integer" >&2; return 2; }
  [[ "$k" =~ ^[1-9][0-9]*$ ]] || { echo "K must be positive integer" >&2; return 2; }
  local pool_size=${#_CW_DEEP_RESEARCH_CMDR_POOL[@]}
  if (( k > pool_size )); then
    echo "K=$k exceeds codex-eligible pool size ($pool_size)" >&2; return 2
  fi
  local total_slots=$(( round * k ))
  if (( total_slots > pool_size )); then
    echo "round=$round × K=$k = $total_slots exceeds pool size $pool_size; reduce --max-rounds or --branches-per-round" >&2
    return 2
  fi
  local start=$(( (round - 1) * k ))
  local i
  for (( i = 0; i < k; i++ )); do
    printf '%s\n' "${_CW_DEEP_RESEARCH_CMDR_POOL[$((start + i))]}"
  done
}

# cw_deep_research_extract_approaches <landscape-md-path>
# Parses ## Approaches section from a meditate landscape doc.
# Expected format:
#   ## Approaches
#   N. **<label>** — <brief>
#   N. **<label>** — <brief>
# Output: TSV "label\tbrief\n" per line; empty if no Approaches section.
# Returns 1 if path missing.
cw_deep_research_extract_approaches() {
  local path="${1:-}"
  [[ -f "$path" ]] || { echo "landscape doc not found: $path" >&2; return 1; }
  awk '
    /^##[[:space:]]+Approaches[[:space:]]*$/ { in_section=1; next }
    /^##[[:space:]]/ && in_section { in_section=0 }
    in_section && /^[0-9]+\.[[:space:]]+\*\*/ {
      line = $0
      sub(/^[0-9]+\.[[:space:]]+\*\*/, "", line)
      idx = index(line, "**")
      if (idx == 0) next
      label = substr(line, 1, idx - 1)
      rest = substr(line, idx + 2)
      sub(/^[[:space:]]*[—–-][[:space:]]*/, "", rest)
      printf "%s\t%s\n", label, rest
    }
  ' "$path"
}

_cw_deep_research_validate_result_grep() {
  local path="$1"
  local body; body=$(<"$path")
  local f
  for f in branch_id approach_label metric_name metric_value status runtime_s log_paths; do
    grep -qE "\"$f\"" <<<"$body" || { echo "missing required field: $f" >&2; return 1; }
  done
  grep -qE '"status"[[:space:]]*:[[:space:]]*"(ok|fail|timeout|cost_blown)"' <<<"$body" \
    || { echo "invalid status enum" >&2; return 1; }
  local is_ok=0 is_null=0
  grep -qE '"status"[[:space:]]*:[[:space:]]*"ok"' <<<"$body" && is_ok=1
  grep -qE '"metric_value"[[:space:]]*:[[:space:]]*null' <<<"$body" && is_null=1
  if (( is_ok == 1 && is_null == 1 )); then
    echo "status=ok requires non-null metric_value" >&2; return 1
  fi
  # Crude log_paths existence check
  local log_line; log_line=$(grep -oE '"log_paths"[[:space:]]*:[[:space:]]*\[[^]]*\]' <<<"$body")
  local p
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    [[ -f "$p" ]] || { echo "log_path missing: $p" >&2; return 1; }
  done < <(grep -oE '"\.\/[^"]+"' <<<"$log_line" | tr -d '"')
  return 0
}
