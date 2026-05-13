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

# cw_deep_research_pick_roster <N>
# Returns first N commanders from the codex-eligible pool, deterministic
# order. Used once at preflight in /clone-wars:deep-research (v0.27.0
# advisor model; replaces v0.26.0's mod-rotated cw_deep_research_allocate_commanders).
# Valid N: 2 or 3 (narrow vs broad survey — judgment lives in directive
# prose, not bash). rc=2 if N is not 2 or 3.
cw_deep_research_pick_roster() {
  local n="${1:-}"
  [[ "$n" == "2" || "$n" == "3" ]] \
    || { echo "N must be 2 or 3; got '$n'" >&2; return 2; }
  local i
  for (( i = 0; i < n; i++ )); do
    printf '%s\n' "${_CW_DEEP_RESEARCH_CMDR_POOL[$i]}"
  done
}

# cw_deep_research_format_metric_block
# Reads K=V pairs on stdin, renders the structured metric.md body to stdout.
# Required keys: primary_metric, direction (maximize|minimize).
# Optional keys: target, acceptable, hard_constraints, notes.
# rc=2 if a required key is missing or direction is invalid.
cw_deep_research_format_metric_block() {
  local primary_metric="" direction="" target="" acceptable="" hard_constraints="" notes=""
  local line key val
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in
      primary_metric)    primary_metric="$val" ;;
      direction)         direction="$val" ;;
      target)            target="$val" ;;
      acceptable)        acceptable="$val" ;;
      hard_constraints)  hard_constraints="$val" ;;
      notes)             notes="$val" ;;
    esac
  done

  [[ -n "$primary_metric" ]] || { echo "missing required key: primary_metric" >&2; return 2; }
  [[ -n "$direction" ]] || { echo "missing required key: direction" >&2; return 2; }
  [[ "$direction" == "maximize" || "$direction" == "minimize" ]] \
    || { echo "direction must be 'maximize' or 'minimize'; got '$direction'" >&2; return 2; }

  printf '# Research goal\n\n'
  printf '**Primary metric:** %s\n' "$primary_metric"
  printf '**Direction:** %s\n' "$direction"
  [[ -n "$target" ]]           && printf '**Target (good):** %s\n' "$target"
  [[ -n "$acceptable" ]]       && printf '**Acceptable:** %s\n' "$acceptable"
  [[ -n "$hard_constraints" ]] && printf '**Hard constraints:** %s\n' "$hard_constraints"
  [[ -n "$notes" ]]            && printf '\n**Notes:** %s\n' "$notes"
  return 0
}

# cw_deep_research_check_stagnation <scoreboard-path> <cursor-path>
# Reads scoreboard.md (any sort order; we re-sort by exp-NNN chronologically)
# + stagnation-cursor.txt. Returns rc=0 if last 5 experiments after cursor
# all <1% over running best AND total post-cursor exp count >= 5. Returns
# rc=1 otherwise.
# Notes:
#   - Floor: never rc=0 when post-cursor exp count < 5.
#   - Direction: max-direction only (higher metric = better). Future
#     parameterization deferred to v0.28+.
#   - Cursor file format: single integer line. Missing file treated as '0'.
cw_deep_research_check_stagnation() {
  local sb="${1:-}" cursor_path="${2:-}"
  [[ -f "$sb" ]] || { echo "scoreboard missing: $sb" >&2; return 2; }

  local cursor=0
  [[ -f "$cursor_path" ]] && cursor=$(<"$cursor_path")
  [[ "$cursor" =~ ^[0-9]+$ ]] || cursor=0

  # Parse scoreboard rows. Each table row: "| rank | exp-id | metric | status |"
  local -a exp_nums=() metrics=() statuses=()
  local line exp_num metric status exp_id
  local -a fields=()
  while IFS= read -r line; do
    [[ "$line" =~ ^\|[[:space:]]+[0-9]+[[:space:]]+\| ]] || continue
    IFS='|' read -r -a fields <<<"$line"
    exp_id="${fields[2]//[[:space:]]/}"
    metric="${fields[3]//[[:space:]]/}"
    status="${fields[4]//[[:space:]]/}"
    exp_num="${exp_id#exp-}"
    exp_num="${exp_num#0}"; exp_num="${exp_num#0}"
    [[ -z "$exp_num" ]] && exp_num=0
    [[ "$exp_num" =~ ^[0-9]+$ ]] || continue
    exp_nums+=("$exp_num")
    metrics+=("$metric")
    statuses+=("$status")
  done < "$sb"

  # Build chronologically-ordered post-cursor list (only ok rows)
  local -a chron_nums=() chron_metrics=()
  local i n m s idx
  local -a sorted_idx=()
  while IFS=$'\t' read -r idx _; do
    sorted_idx+=("$idx")
  done < <(
    for i in "${!exp_nums[@]}"; do
      printf '%d\t%d\n' "$i" "${exp_nums[$i]}"
    done | sort -k2,2n
  )

  for idx in "${sorted_idx[@]}"; do
    n="${exp_nums[$idx]}"
    m="${metrics[$idx]}"
    s="${statuses[$idx]}"
    (( n > cursor )) || continue
    [[ "$s" == "ok" ]] || continue
    chron_nums+=("$n")
    chron_metrics+=("$m")
  done

  local post_count="${#chron_nums[@]}"
  (( post_count >= 5 )) || return 1

  # Find running-best across all post-cursor exps
  local best="${chron_metrics[0]}"
  for m in "${chron_metrics[@]}"; do
    awk -v a="$m" -v b="$best" 'BEGIN { exit !(a > b) }' && best="$m"
  done

  # Check the last 5 post-cursor exps: all must be <1% of best
  local start=$(( post_count - 5 ))
  for (( i = start; i < post_count; i++ )); do
    m="${chron_metrics[$i]}"
    if awk -v a="$m" -v b="$best" 'BEGIN {
      if (b == 0) exit 0;
      d = (a > b ? a - b : b - a);
      exit !(d / b * 100 < 1.0);
    }'; then
      continue
    else
      return 1
    fi
  done

  return 0
}

# cw_deep_research_check_time_budget <budget-path> <session-start-path>
# Reads time-budget.txt ('none' or integer seconds) + session-start.txt
# (ISO-8601 UTC). rc=0 if elapsed >= budget; rc=1 otherwise. rc=1 when
# budget is 'none'. rc=2 on missing/malformed inputs.
cw_deep_research_check_time_budget() {
  local budget_path="${1:-}" start_path="${2:-}"
  [[ -f "$budget_path" ]] || { echo "budget file missing: $budget_path" >&2; return 2; }
  [[ -f "$start_path" ]] || { echo "session-start file missing: $start_path" >&2; return 2; }

  local budget; budget=$(<"$budget_path"); budget="${budget//[[:space:]]/}"
  [[ "$budget" == "none" ]] && return 1
  [[ "$budget" =~ ^[1-9][0-9]*$ ]] \
    || { echo "malformed budget: '$budget' (expected 'none' or positive integer)" >&2; return 2; }

  local start_iso; start_iso=$(<"$start_path"); start_iso="${start_iso//[[:space:]]/}"
  local start_epoch
  start_epoch=$(date -u -d "$start_iso" +%s 2>/dev/null) \
    || start_epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$start_iso" +%s 2>/dev/null) \
    || { echo "could not parse session-start: '$start_iso'" >&2; return 2; }

  local now_epoch; now_epoch=$(date -u +%s)
  local elapsed=$(( now_epoch - start_epoch ))
  (( elapsed >= budget )) && return 0 || return 1
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

# cw_deep_research_hardware_probe <out-path>  [v0.27.2 P2]
# Writes either GPU rows or no-gpu marker to <out-path>. Format:
#   detected_at\t<iso-8601-utc>\n
#   gpu\t<name>\t<memory.total-mb>\t<memory.free-mb>\t<driver>\n   (one per GPU)
# OR:
#   detected_at\t<iso-8601-utc>\n
#   no-gpu\n
# Atomic via tmp+mv. rc=0 always when out-path given; rc=2 if missing.
cw_deep_research_hardware_probe() {
  local out="${1:-}"
  [[ -n "$out" ]] || { echo "cw_deep_research_hardware_probe: out-path required" >&2; return 2; }
  if command -v nvidia-smi >/dev/null 2>&1; then
    {
      printf 'detected_at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      nvidia-smi \
        --query-gpu=name,memory.total,memory.free,driver_version \
        --format=csv,noheader,nounits 2>/dev/null \
        | awk -F', ' '{ printf "gpu\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4 }'
    } > "$out.tmp" && mv "$out.tmp" "$out"
  else
    {
      printf 'detected_at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf 'no-gpu\n'
    } > "$out.tmp" && mv "$out.tmp" "$out"
  fi
}

# cw_deep_research_hardware_diff_alert <baseline-path> <current-path>  [v0.27.2 P2]
# Compares baseline vs current hardware probe files. Echoes ONE line to
# stdout per GPU whose memory.free dropped >50% (else nothing). Format:
#   "ALERT: gpu '<name>' memory.free <baseline-mb> -> <current-mb> (-X%)"
# rc=0 always. Missing baseline or current → silent (no output).
cw_deep_research_hardware_diff_alert() {
  local baseline="${1:-}" current="${2:-}"
  [[ -f "$baseline" && -f "$current" ]] || return 0
  awk -F'\t' -v base="$baseline" '
    BEGIN {
      while ((getline line < base) > 0) {
        split(line, f, "\t")
        if (f[1] == "gpu") { base_free[f[2]] = f[4] }
      }
      close(base)
    }
    $1 == "gpu" {
      name=$2; cur_free=$4
      b = base_free[name]
      if (b > 0 && cur_free < b * 0.5) {
        drop = int((1 - cur_free / b) * 100)
        printf "ALERT: gpu \047%s\047 memory.free %s -> %s MiB (-%d%%)\n", name, b, cur_free, drop
      }
    }
  ' "$current"
}

# cw_deep_research_trooper_state_read <art-dir> <commander>
# Print state.txt KV pairs, one per line. rc=2 on bad args, rc=1 if file missing.
cw_deep_research_trooper_state_read() {
  local art_dir="${1:-}" commander="${2:-}"
  [[ -n "$art_dir" && -n "$commander" ]] \
    || { echo "cw_deep_research_trooper_state_read: art-dir + commander required" >&2; return 2; }
  [[ -d "$art_dir" ]] \
    || { echo "cw_deep_research_trooper_state_read: art-dir missing: $art_dir" >&2; return 2; }
  local f="$art_dir/troopers/$commander/state.txt"
  [[ -f "$f" ]] || return 1
  cat "$f"
}

# cw_deep_research_trooper_state_write <art-dir> <commander> <k>=<v> [<k>=<v>...]
# Atomic update: preserves untouched keys, replaces touched ones.
# Creates state.txt + parent dirs if missing. rc=2 on bad args.
cw_deep_research_trooper_state_write() {
  local art_dir="${1:-}" commander="${2:-}"
  shift 2 || true
  [[ -n "$art_dir" && -n "$commander" ]] \
    || { echo "cw_deep_research_trooper_state_write: art-dir + commander required" >&2; return 2; }
  (( $# >= 1 )) \
    || { echo "cw_deep_research_trooper_state_write: need at least one KEY=VALUE" >&2; return 2; }
  local trooper_dir="$art_dir/troopers/$commander"
  mkdir -p "$trooper_dir"
  local f="$trooper_dir/state.txt" tmp="$trooper_dir/state.txt.tmp"
  declare -A kv
  if [[ -f "$f" ]]; then
    while IFS='=' read -r k v; do
      [[ -n "$k" ]] && kv["$k"]="$v"
    done < "$f"
  fi
  local pair k v
  for pair in "$@"; do
    k="${pair%%=*}"
    v="${pair#*=}"
    [[ -n "$k" ]] || continue
    kv["$k"]="$v"
  done
  : > "$tmp"
  for k in "${!kv[@]}"; do
    printf '%s=%s\n' "$k" "${kv[$k]}" >> "$tmp"
  done
  mv "$tmp" "$f"
}
