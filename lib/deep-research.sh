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
#   cw_deep_research_trooper_state_field <art-dir> <cmdr> <key>
#       — single-field read; preserves embedded '='; rc=1 on missing state.txt
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
# v0.28.0+ fields: min_acceptable (floor), K_corroboration (default 1),
#   plateau_window (default 5), plateau_threshold (default 0.01).
# Optional keys: target, acceptable (v0.27.x — preserved for back-compat),
#   hard_constraints, notes.
# rc=2 if a required key is missing or direction is invalid.
cw_deep_research_format_metric_block() {
  local primary_metric="" direction="" target="" acceptable="" hard_constraints="" notes=""
  local min_acceptable="" K_corroboration="" plateau_window="" plateau_threshold=""
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
      min_acceptable)    min_acceptable="$val" ;;
      K_corroboration)   K_corroboration="$val" ;;
      plateau_window)    plateau_window="$val" ;;
      plateau_threshold) plateau_threshold="$val" ;;
      hard_constraints)  hard_constraints="$val" ;;
      notes)             notes="$val" ;;
    esac
  done

  [[ -n "$primary_metric" ]] || { echo "missing required key: primary_metric" >&2; return 2; }
  [[ -n "$direction" ]] || { echo "missing required key: direction" >&2; return 2; }
  [[ "$direction" == "maximize" || "$direction" == "minimize" ]] \
    || { echo "direction must be 'maximize' or 'minimize'; got '$direction'" >&2; return 2; }

  : "${min_acceptable:=(not set)}"
  : "${K_corroboration:=1}"
  : "${plateau_window:=5}"
  : "${plateau_threshold:=0.01}"

  printf '# Research goal\n\n'
  printf '**Primary metric:** %s\n' "$primary_metric"
  printf '**Direction:** %s\n' "$direction"
  printf '**min_acceptable:** %s\n' "$min_acceptable"
  [[ -n "$target" ]]           && printf '**target:** %s\n' "$target"
  printf '**K_corroboration:** %s\n' "$K_corroboration"
  printf '**plateau_window:** %s\n' "$plateau_window"
  printf '**plateau_threshold:** %s\n' "$plateau_threshold"
  [[ -n "$acceptable" ]]       && printf '**acceptable (legacy):** %s\n' "$acceptable"
  [[ -n "$hard_constraints" ]] && printf '**Hard constraints:** %s\n' "$hard_constraints"
  [[ -n "$notes" ]]            && printf '\n**Notes:** %s\n' "$notes"
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
    } | cw_atomic_write "$out"
  else
    {
      printf 'detected_at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf 'no-gpu\n'
    } | cw_atomic_write "$out"
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

# cw_deep_research_trooper_state_field <art-dir> <commander> <key>
#
# Single-field reader for hot-path callers. Preserves embedded '=' in values
# (returns everything after the first '='). Returns rc=1 if state.txt is
# missing; returns empty string for missing field or empty value.
#
# Use this for hot-path single-field reads. For multi-field reads, prefer
# cw_deep_research_trooper_state_read (one awk pass over the whole block).
cw_deep_research_trooper_state_field() {
  local art_dir="$1" cmdr="$2" key="$3"
  local f="$art_dir/troopers/$cmdr/state.txt"
  [[ -f "$f" ]] || { log_error "state.txt missing: $f"; return 1; }
  awk -F= -v k="$key" '$1==k{print substr($0, index($0,"=")+1); exit}' "$f"
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
  local f="$trooper_dir/state.txt"
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
  {
    for k in "${!kv[@]}"; do
      printf '%s=%s\n' "$k" "${kv[$k]}"
    done
  } | cw_atomic_write "$f"
}

# cw_deep_research_check_completion <scoreboard.md> <metric.md>
# Compute completion signals from scoreboard rows + metric thresholds.
# Prints TSV-shape KV block on stdout:
#   floor_met=yes|no
#   target_met=yes|no
#   K_so_far=<int>
#   K_required=<int>
#   plateau=yes|no
# rc=2 on missing files. K_so_far is capped at K_required for display.
cw_deep_research_check_completion() {
  local sb="${1:-}" m="${2:-}"
  [[ -f "$sb" ]] || { echo "cw_deep_research_check_completion: scoreboard missing: $sb" >&2; return 2; }
  [[ -f "$m" ]]  || { echo "cw_deep_research_check_completion: metric missing: $m" >&2; return 2; }

  # Parse metric.md — fields are `**KEY:** VALUE`, so the field separator is `:** `.
  local min_op min_val tgt_op tgt_val K_req plateau_window plateau_threshold
  min_op=$(awk -F':\\*\\* ' '/^\*\*min_acceptable:/{print $2}' "$m" | awk '{print $1}')
  min_val=$(awk -F':\\*\\* ' '/^\*\*min_acceptable:/{print $2}' "$m" | awk '{$1=""; sub(/^ /, ""); print}')
  tgt_op=$(awk -F':\\*\\* ' '/^\*\*target:/{print $2}' "$m" | awk '{print $1}')
  tgt_val=$(awk -F':\\*\\* ' '/^\*\*target:/{print $2}' "$m" | awk '{$1=""; sub(/^ /, ""); print}')
  K_req=$(awk -F':\\*\\* ' '/^\*\*K_corroboration:/{print $2}' "$m" | tr -d ' ')
  plateau_window=$(awk -F':\\*\\* ' '/^\*\*plateau_window:/{print $2}' "$m" | tr -d ' ')
  plateau_threshold=$(awk -F':\\*\\* ' '/^\*\*plateau_threshold:/{print $2}' "$m" | tr -d ' ')
  K_req="${K_req:-1}"
  plateau_window="${plateau_window:-5}"
  plateau_threshold="${plateau_threshold:-0.01}"

  # Helper: numeric compare $1 (op) $2 against threshold $3 via awk.
  # File-scope-prefixed name; defined inside the function for context-locality
  # but bash hoists it to file scope. Caller uses _cw_deep_research_cmp.
  _cw_deep_research_cmp() {
    awk -v a="$1" -v op="$2" -v b="$3" 'BEGIN{
      a+=0; b+=0;
      if (op==">=")  exit !(a >= b);
      if (op=="<=")  exit !(a <= b);
      if (op==">")   exit !(a > b);
      if (op=="<")   exit !(a < b);
      if (op=="==")  exit !(a == b);
      exit 1;
    }'
  }

  # Walk scoreboard.md rows. Production schema (bin/deep-research-score.sh:77):
  #   | Rank | Experiment | Commander | Metric | Status | Runtime | Approach |
  # awk -F'|' field indices (1-based, leading empty field at $1):
  #   $2=Rank  $3=Experiment  $4=Commander  $5=Metric  $6=Status  $7=Runtime  $8=Approach
  # Data rows match `| <rank-int> | exp-<int> | …`; header + separator rows skipped.
  local floor_met=no target_met=no K_so_far=0
  local metrics=()
  local line metric status
  while IFS= read -r line; do
    [[ "$line" =~ ^\|[[:space:]]+[0-9]+[[:space:]]+\|[[:space:]]+exp- ]] || continue
    metric=$(printf '%s' "$line" | awk -F'|' '{gsub(/^ +| +$/, "", $5); print $5}')
    status=$(printf '%s' "$line" | awk -F'|' '{gsub(/^ +| +$/, "", $6); print $6}')
    [[ "$status" == "ok" ]] || continue
    [[ "$metric" =~ ^[0-9.]+$ ]] || continue
    metrics+=("$metric")
    if [[ -n "$min_op" && -n "$min_val" ]] && _cw_deep_research_cmp "$metric" "$min_op" "$min_val"; then
      floor_met=yes
    fi
    if [[ -n "$tgt_op" && -n "$tgt_val" ]] && _cw_deep_research_cmp "$metric" "$tgt_op" "$tgt_val"; then
      target_met=yes
      K_so_far=$((K_so_far + 1))
    fi
  done < "$sb"

  # Plateau: last plateau_window ok-rows have max-min spread < plateau_threshold.
  local plateau=no
  if (( ${#metrics[@]} >= plateau_window )); then
    local last_n=("${metrics[@]: -$plateau_window}")
    local mn mx v
    mn="${last_n[0]}"; mx="${last_n[0]}"
    for v in "${last_n[@]}"; do
      awk -v a="$v" -v b="$mn" 'BEGIN{exit !(a+0 < b+0)}' && mn="$v"
      awk -v a="$v" -v b="$mx" 'BEGIN{exit !(a+0 > b+0)}' && mx="$v"
    done
    if awk -v M="$mx" -v m="$mn" -v t="$plateau_threshold" 'BEGIN{exit !((M-m) < t)}'; then
      plateau=yes
    fi
  fi

  # Cap K_so_far at K_required for cleaner display.
  (( K_so_far > K_req )) && K_so_far="$K_req"

  printf 'floor_met=%s\n' "$floor_met"
  printf 'target_met=%s\n' "$target_met"
  printf 'K_so_far=%s\n' "$K_so_far"
  printf 'K_required=%s\n' "$K_req"
  printf 'plateau=%s\n' "$plateau"
}

# cw_deep_research_render_summary <art-dir>
# Renders sections 1, 2, 4, 5 of session-summary.md mechanically from disk.
# Yoda fills in Direction + Recent decisions sections via Write tool after this.
# Caller redirects stdout to "$art_dir/session-summary.md" via atomic write.
#
# Consumes production scoreboard schema (bin/deep-research-score.sh:77):
#   | Rank | Experiment | Commander | Metric | Status | Runtime | Approach |
cw_deep_research_render_summary() {
  local art_dir="${1:-}"
  [[ -d "$art_dir" ]] \
    || { echo "cw_deep_research_render_summary: art-dir missing: $art_dir" >&2; return 2; }

  local topic now started budget
  topic=$(cat "$art_dir/topic.txt" 2>/dev/null || echo "(unknown)")
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  started=$(cat "$art_dir/session-start.txt" 2>/dev/null || echo "(unknown)")
  budget=$(cat "$art_dir/time-budget.txt" 2>/dev/null || echo "none")

  printf '# Research session — %s\n' "$topic"
  printf 'Updated: %s\n' "$now"
  printf 'Started: %s\n' "$started"
  printf 'Time budget: %s\n\n' "$budget"

  # Section: Status
  printf '## Status\n\n'
  printf '| Trooper | Phase | Current | Last event |\n'
  printf '|---|---|---|---|\n'
  if [[ -f "$art_dir/troopers.txt" ]]; then
    local cmdr state_file phase cur last_ts last_event
    while read -r cmdr; do
      [[ -n "$cmdr" ]] || continue
      state_file="$art_dir/troopers/$cmdr/state.txt"
      phase="?"; cur="—"; last_ts="?"; last_event="?"
      if [[ -f "$state_file" ]]; then
        phase=$(cw_deep_research_trooper_state_field "$art_dir" "$cmdr" phase)
        cur=$(cw_deep_research_trooper_state_field "$art_dir" "$cmdr" current_exp_id)
        last_ts=$(cw_deep_research_trooper_state_field "$art_dir" "$cmdr" last_event_ts)
        last_event=$(cw_deep_research_trooper_state_field "$art_dir" "$cmdr" last_event)
        [[ -z "$cur" ]] && cur="—"
      fi
      printf '| %s | %s | %s | %s %s |\n' "$cmdr" "$phase" "$cur" "$last_ts" "$last_event"
    done < "$art_dir/troopers.txt"
  fi
  printf '\n'

  # Section: Scoreboard top 5
  # Production schema starts data rows with `| <rank-int> | exp-<int> |`
  # (not `| exp-…` from the original 6-col fixture).
  printf '## Scoreboard top 5\n\n'
  if [[ -f "$art_dir/scoreboard.md" ]]; then
    printf '| Rank | Experiment | Commander | Metric | Status | Runtime | Approach |\n'
    printf '|---|---|---|---|---|---|---|\n'
    grep -E '^\|[[:space:]]+[0-9]+[[:space:]]+\|[[:space:]]+exp-' "$art_dir/scoreboard.md" | head -5
  else
    printf '_(scoreboard empty)_\n'
  fi
  printf '\n'

  # Section: Completion check
  printf '## Completion check\n\n'
  if [[ -f "$art_dir/scoreboard.md" && -f "$art_dir/metric.md" ]]; then
    local signals
    signals=$(cw_deep_research_check_completion "$art_dir/scoreboard.md" "$art_dir/metric.md" 2>/dev/null || true)
    local floor target K_so K_req plateau
    floor=$(echo "$signals" | awk -F= '/^floor_met=/{print $2}')
    target=$(echo "$signals" | awk -F= '/^target_met=/{print $2}')
    K_so=$(echo "$signals" | awk -F= '/^K_so_far=/{print $2}')
    K_req=$(echo "$signals" | awk -F= '/^K_required=/{print $2}')
    plateau=$(echo "$signals" | awk -F= '/^plateau=/{print $2}')
    if [[ "$floor" == "yes" ]]; then
      printf -- '- Floor: MET\n'
    else
      printf -- '- Floor: not met\n'
    fi
    if [[ "$target" == "yes" ]]; then
      printf -- '- Target: MET\n'
    else
      printf -- '- Target: not met\n'
    fi
    printf -- '- K corroboration: %s/%s\n' "$K_so" "$K_req"
    if [[ "$plateau" == "yes" ]]; then
      printf -- '- Plateau: YES\n'
    else
      printf -- '- Plateau: no\n'
    fi
    # Hard cap: reuse cw_deep_research_check_time_budget rather than duplicating.
    if [[ -f "$art_dir/time-budget.txt" && -f "$art_dir/session-start.txt" ]]; then
      local cap
      cap=$(cw_deep_research_check_time_budget "$art_dir/time-budget.txt" "$art_dir/session-start.txt" 2>/dev/null || echo "no")
      if [[ "$cap" == "yes" ]]; then
        printf -- '- Hard cap: YES\n'
      else
        printf -- '- Hard cap: NO\n'
      fi
    fi
  else
    printf '_(missing scoreboard or metric)_\n'
  fi
  printf '\n'

  # Section: Recent events (last 10 across troopers' outboxes by ts)
  printf '## Recent events\n\n'
  local merged="$art_dir/.events-merged.tmp"
  : > "$merged"
  if [[ -f "$art_dir/troopers.txt" ]]; then
    local cmdr outbox topic_dir
    topic_dir=$(dirname "$art_dir")
    while read -r cmdr; do
      [[ -n "$cmdr" ]] || continue
      outbox="$topic_dir/$cmdr-codex/outbox.jsonl"
      if [[ -f "$outbox" ]]; then
        tail -10 "$outbox" | while IFS= read -r line; do
          local ts ev
          ts=$(printf '%s' "$line" | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p')
          ev=$(printf '%s' "$line" | sed -n 's/.*"event":"\([^"]*\)".*/\1/p')
          [[ -n "$ev" ]] && printf '%s\t%s\t%s\n' "$ts" "$cmdr" "$ev" >> "$merged"
        done
      fi
    done < "$art_dir/troopers.txt"
  fi
  if [[ -s "$merged" ]]; then
    sort -r "$merged" | head -10 | awk -F'\t' '{printf "- %s %s/%s\n", $1, $2, $3}'
  else
    printf '_(no events yet)_\n'
  fi
  rm -f "$merged"
}

# cw_deep_research_list_commanders <art-dir>
# Returns one commander per line. Prefers $art_dir/troopers.txt; falls back
# to `troopers/*/` filesystem discovery when troopers.txt is missing
# (v0.28.0 had read-but-never-written troopers.txt — defensive against that).
cw_deep_research_list_commanders() {
  local art_dir="${1:-}"
  [[ -d "$art_dir" ]] \
    || { echo "cw_deep_research_list_commanders: art-dir missing: $art_dir" >&2; return 2; }
  if [[ -f "$art_dir/troopers.txt" ]]; then
    grep -vE '^[[:space:]]*(#|$)' "$art_dir/troopers.txt"
    return 0
  fi
  if [[ -d "$art_dir/troopers" ]]; then
    local d
    shopt -s nullglob
    for d in "$art_dir/troopers"/*/; do
      basename "${d%/}"
    done
    shopt -u nullglob
  fi
}

# cw_deep_research_render_status_brief <art-dir> [<latest-cmdr>] [<latest-exp-id>]
# Emits a compact chat-shaped status form to stdout:
#   - Title (optionally naming the just-landed exp)
#   - Per-trooper status table (Phase / Current-or-last / Approach / Metric)
#   - Scoreboard top 3
#   - Completion-check signal line
#
# Trigger: resume handler Step 3 calls this after deep-research-score.sh
# returns, so the user sees a structured update after every done/error.
# v0.28.2.
cw_deep_research_render_status_brief() {
  local art_dir="${1:-}" latest_cmdr="${2:-}" latest_exp="${3:-}"
  [[ -d "$art_dir" ]] \
    || { echo "cw_deep_research_render_status_brief: art-dir missing: $art_dir" >&2; return 2; }

  if [[ -n "$latest_cmdr" && -n "$latest_exp" ]]; then
    printf '## Experiment status — %s (%s) just landed\n\n' "$latest_exp" "$latest_cmdr"
  else
    printf '## Experiment status\n\n'
  fi

  # Per-trooper status table.
  printf '| Trooper | Phase | Current/last | Approach | Metric |\n'
  printf '|---------|-------|--------------|----------|--------|\n'
  local cmdrs cmdr state_file phase cur last_exp result prompt approach metric
  cmdrs=$(cw_deep_research_list_commanders "$art_dir" 2>/dev/null)
  if [[ -n "$cmdrs" ]]; then
    while IFS= read -r cmdr; do
      [[ -n "$cmdr" ]] || continue
      state_file="$art_dir/troopers/$cmdr/state.txt"
      phase="?"; cur=""; last_exp="—"; approach="—"; metric="—"
      if [[ -f "$state_file" ]]; then
        phase=$(cw_deep_research_trooper_state_field "$art_dir" "$cmdr" phase)
        cur=$(cw_deep_research_trooper_state_field "$art_dir" "$cmdr" current_exp_id)
      fi
      if [[ -n "$cur" ]]; then
        last_exp="$cur"
      else
        # Most-recent scored experiment from filesystem (lexical sort works on exp-NNN)
        local newest="" exp_dir base
        shopt -s nullglob
        for exp_dir in "$art_dir/troopers/$cmdr/experiments"/exp-[0-9]*/; do
          base=$(basename "${exp_dir%/}")
          [[ "$base" =~ ^exp-[0-9]+$ ]] || continue
          [[ "$base" > "$newest" ]] && newest="$base"
        done
        shopt -u nullglob
        [[ -n "$newest" ]] && last_exp="$newest"
      fi
      # Pull approach + metric. For working troopers, result.json doesn't
      # exist yet — fall back to prompt.md, written at dispatch time
      # (bin/deep-research-experiment-send.sh renders it from
      # config/prompt-templates/deep-research/experiment.md with the
      # `Approach label:  <slug>` line).
      result="$art_dir/troopers/$cmdr/experiments/$last_exp/result.json"
      prompt="$art_dir/troopers/$cmdr/experiments/$last_exp/prompt.md"
      if [[ "$phase" == "working" ]]; then
        approach=$(_cw_dr_approach_from_prompt "$prompt" 2>/dev/null)
        [[ -z "$approach" ]] && approach="—"
        metric="(running)"
      elif [[ -f "$result" ]]; then
        approach=$(_cw_dr_json_field "$result" approach_label)
        # Result.json missing approach_label is unexpected — fall back to prompt.md.
        [[ -z "$approach" && -f "$prompt" ]] && approach=$(_cw_dr_approach_from_prompt "$prompt")
        [[ -z "$approach" ]] && approach="—"
        local m s
        m=$(_cw_dr_json_field "$result" metric_value)
        s=$(_cw_dr_json_field "$result" status)
        metric="$m $s"
      fi
      printf '| %s | %s | %s | %s | %s |\n' "$cmdr" "$phase" "$last_exp" "$approach" "$metric"
    done <<<"$cmdrs"
  else
    printf '| _(no troopers)_ | — | — | — | — |\n'
  fi
  printf '\n'

  # Scoreboard top 3.
  printf '**Scoreboard top 3:**\n'
  if [[ -f "$art_dir/scoreboard.md" ]]; then
    local rows
    rows=$(grep -E '^\|[[:space:]]+[0-9]+[[:space:]]+\|[[:space:]]+exp-' "$art_dir/scoreboard.md" | head -3)
    if [[ -n "$rows" ]]; then
      printf '%s\n' "$rows" | awk -F'|' '{
        for (i=1;i<=NF;i++) gsub(/^[ \t]+|[ \t]+$/,"",$i)
        printf "%s. %s/%s — %s — %s\n", $2, $4, $3, $5, $8
      }'
    else
      printf '_(no scored experiments yet)_\n'
    fi
  else
    printf '_(scoreboard absent)_\n'
  fi
  printf '\n'

  # Completion-check signal line (single row).
  printf '**Completion check:** '
  if [[ -f "$art_dir/scoreboard.md" && -f "$art_dir/metric.md" ]]; then
    local sig f t Kn Kr p
    sig=$(cw_deep_research_check_completion "$art_dir/scoreboard.md" "$art_dir/metric.md" 2>/dev/null || true)
    f=$(awk -F= '/^floor_met=/{print $2}' <<<"$sig")
    t=$(awk -F= '/^target_met=/{print $2}' <<<"$sig")
    Kn=$(awk -F= '/^K_so_far=/{print $2}' <<<"$sig")
    Kr=$(awk -F= '/^K_required=/{print $2}' <<<"$sig")
    p=$(awk -F= '/^plateau=/{print $2}' <<<"$sig")
    printf 'floor_met=%s  target_met=%s  K_so_far=%s/%s  plateau=%s\n' \
      "${f:-?}" "${t:-?}" "${Kn:-?}" "${Kr:-?}" "${p:-?}"
  else
    printf '_(scoreboard or metric absent)_\n'
  fi
}

# _cw_dr_json_field <result.json> <key>
# Tiny JSON-field reader for status_brief (no jq dependency).
#
# LIMITATIONS (acceptable for our flat result.json schema in
# bin/deep-research-experiment-send.sh's template):
#   - Does not handle escaped quotes inside string values
#     (`"notes": "He said \"hi\""` → returns up to the first `\`).
#   - Does not handle nested objects or arrays of objects.
#   - Returns empty string if key is missing (no error).
# For our flat schema (branch_id / approach_label / metric_name /
# metric_value / status / runtime_s / log_paths / notes), these are
# non-issues — notes is short single-line free text per the template.
_cw_dr_json_field() {
  local f="${1:-}" k="${2:-}"
  [[ -f "$f" && -n "$k" ]] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$k" '.[$k] // empty' "$f"
  else
    # Match "key": <value> where <value> is either "string", number, true/false, or null.
    grep -oE "\"$k\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|[0-9.eE+-]+|true|false|null)" "$f" \
      | head -1 \
      | sed -E "s/^\"$k\"[[:space:]]*:[[:space:]]*\"?([^\"]*)\"?$/\1/"
  fi
}

# _cw_dr_approach_from_prompt <prompt.md-path>
# Extract the `Approach label:` value rendered by
# bin/deep-research-experiment-send.sh into the experiment's prompt.md
# (template line: `Approach label:  {{APPROACH_LABEL}}`). Used by
# cw_deep_research_render_status_brief to show the approach for a
# working trooper before result.json lands. v0.28.2.
_cw_dr_approach_from_prompt() {
  local f="${1:-}"
  [[ -f "$f" ]] || return 1
  # Template renders the line with a 2-space leading indent
  # (`  Approach label:  <slug>`); allow optional leading whitespace and
  # collapse any amount of trailing whitespace.
  awk '/^[[:space:]]*Approach label:/ {
    sub(/^[[:space:]]*Approach label:[[:space:]]+/, "")
    sub(/[[:space:]]+$/, "")
    print
    exit
  }' "$f"
}

# cw_deep_research_write_preflight_sidecar <art-dir> <cmdr1> [<cmdr2> ...]
# Writes consult-shaped 2-col TSV (codex\t<commander>) to <art-dir>/troopers-preflight.txt.
# Deep-research is codex-only, so the provider column is always "codex". The file
# exists solely to satisfy bin/preflight-layout.sh --troopers-from, which expects
# the consult schema. Native deep-research troopers.txt remains 1-col commander-only
# (locked by test_v0_28_2_static_wiring.sh invariant 5).
#
# Atomic (tmp + mv). Idempotent. rc=1 on missing art-dir or zero commanders.
cw_deep_research_write_preflight_sidecar() {
  local art_dir="$1"; shift
  [[ -d "$art_dir" ]] || { log_error "art-dir not found: $art_dir"; return 1; }
  (( $# >= 1 )) || { log_error "need at least 1 commander"; return 1; }
  local cmdr
  {
    for cmdr in "$@"; do
      printf 'codex\t%s\n' "$cmdr"
    done
  } | cw_atomic_write "$art_dir/troopers-preflight.txt"
}
