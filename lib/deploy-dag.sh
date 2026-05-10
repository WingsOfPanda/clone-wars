# lib/deploy-dag.sh — DAG helpers for /clone-wars:deploy multi-repo path.
#
# Sourcing-only file. Parses the soft-DAG prose format produced by
# cw_consult_emit_soft_dag (lib/consult-walk.sh) into TSV, runs Kahn's
# topological sort to compute waves (parallel-execution levels), and
# exposes utility queries for the multi-repo deploy directive.
#
# Format produced by cw_consult_emit_soft_dag (matches what shows up
# in the assembled design doc's "## Execution DAG" section):
#   1. <repo> — <description>
#   2. <repo> — <description> (depends on 1)
#   3. <repo> — <description> (depends on 1, 2)

# cw_deploy_dag_parse_line <prose-line>
# Echoes TSV: <step>\t<repo>\t<path|none>\t<desc>\t<deps-csv|none>
# rc=0 on valid line; rc=1 on malformed.
#
# v0.21.0: regex extended for CapWords/underscore slugs ([A-Za-z0-9_-]+) +
# optional `(/abspath)` group between slug and em-dash. Path field is `none`
# when the optional group is absent. Backward-compat: every v0.20.5 valid
# slug still matches; only the field count grew (4 → 5).
cw_deploy_dag_parse_line() {
  local line="$1"
  if [[ "$line" =~ ^([0-9]+)\.[[:space:]]+([A-Za-z0-9_-]+)([[:space:]]+\((/[^\)]+)\))?[[:space:]]+—[[:space:]]+(.+)$ ]]; then
    local step="${BASH_REMATCH[1]}"
    local repo="${BASH_REMATCH[2]}"
    local path="${BASH_REMATCH[4]:-none}"
    local rest="${BASH_REMATCH[5]}"
    local deps="none"
    local desc="$rest"
    if [[ "$rest" =~ ^(.+)[[:space:]]+\(depends[[:space:]]+on[[:space:]]+([0-9, ]+)\)[[:space:]]*$ ]]; then
      desc="${BASH_REMATCH[1]}"
      deps=$(printf '%s' "${BASH_REMATCH[2]}" | tr -d ' ')
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$step" "$repo" "$path" "$desc" "$deps"
    return 0
  fi
  log_error "cw_deploy_dag_parse_line: malformed line: $line"
  return 1
}

# cw_deploy_dag_topological <edges-tsv> <node1> <node2> ...
# Reads edges TSV (each line: <from>\t<to>) + list of all node ids.
# Echoes TSV: <wave-num>\t<node-id> (wave 1 = no incoming deps).
# rc=0 on success; rc=1 on cycle.
cw_deploy_dag_topological() {
  local edges_file="$1"; shift
  declare -A indegree
  declare -A children
  local n
  for n in "$@"; do
    indegree["$n"]=0
    children["$n"]=""
  done
  if [[ -s "$edges_file" ]]; then
    while IFS=$'\t' read -r from to; do
      [[ -n "$from" && -n "$to" ]] || continue
      indegree["$to"]=$(( ${indegree["$to"]:-0} + 1 ))
      children["$from"]="${children["$from"]} $to"
    done < "$edges_file"
  fi
  local wave=1
  local emitted=0
  local total=$#
  while (( emitted < total )); do
    local current_wave=()
    for n in "${!indegree[@]}"; do
      [[ "${indegree[$n]}" == "0" ]] || continue
      [[ "${indegree[$n]}" == "DONE" ]] && continue
      current_wave+=( "$n" )
    done
    if (( ${#current_wave[@]} == 0 )); then
      log_error "cw_deploy_dag_topological: cycle detected (no zero-indegree nodes left, ${emitted}/${total} processed)"
      return 1
    fi
    local sorted
    sorted=$(printf '%s\n' "${current_wave[@]}" | sort -n)
    while IFS= read -r n; do
      printf '%s\t%s\n' "$wave" "$n"
      indegree["$n"]="DONE"
      emitted=$(( emitted + 1 ))
      local c
      for c in ${children["$n"]:-}; do
        [[ "${indegree[$c]:-DONE}" == "DONE" ]] && continue
        indegree["$c"]=$(( ${indegree["$c"]} - 1 ))
      done
    done <<< "$sorted"
    wave=$(( wave + 1 ))
  done
  return 0
}

# cw_deploy_dag_unique_repos <waves-tsv>
# Reads waves TSV (<wave>\t<step>\t<repo>\t<desc> per line); echoes
# unique repo slugs sorted alphabetically.
cw_deploy_dag_unique_repos() {
  local waves_file="$1"
  [[ -f "$waves_file" ]] || { log_error "cw_deploy_dag_unique_repos: file not found: $waves_file"; return 1; }
  awk -F'\t' '{ print $3 }' "$waves_file" | sort -u
}

# cw_deploy_dag_fan_in_repos <edges-tsv> <waves-tsv>
# Echoes the list of repo slugs whose corresponding step has 2+ incoming
# dependencies. Used by the "feels unsafe" heuristic in commands/deploy.md
# Step 4 — a repo with multiple upstream waves is more likely to be
# affected by interactions between earlier waves.
cw_deploy_dag_fan_in_repos() {
  local edges_file="$1" waves_file="$2"
  [[ -f "$edges_file" ]] || { log_error "cw_deploy_dag_fan_in_repos: edges file not found: $edges_file"; return 1; }
  [[ -f "$waves_file" ]] || { log_error "cw_deploy_dag_fan_in_repos: waves file not found: $waves_file"; return 1; }
  declare -A indegree
  while IFS=$'\t' read -r from to; do
    [[ -n "$to" ]] || continue
    indegree["$to"]=$(( ${indegree["$to"]:-0} + 1 ))
  done < "$edges_file"
  while IFS=$'\t' read -r wave step repo desc; do
    [[ -n "$step" ]] || continue
    if (( ${indegree[$step]:-0} >= 2 )); then
      printf '%s\n' "$repo"
    fi
  done < "$waves_file"
}
