# lib/consult-validators.sh — format validators for hub-mode design-doc sections.
# Sourced by lib/consult.sh shim. Depends on lib/log.sh, lib/state.sh.

# _cw_consult_print_leaves <art-dir>
# Internal helper: prints leaf names (one per line) parsed from
# <art-dir>/targets.txt (each entry is "<hub>/<leaf>"; we keep just <leaf>).
# Missing/empty file → no output, rc=0. Caller reads via mapfile.
_cw_consult_print_leaves() {
  local art="$1"
  [[ -s "$art/targets.txt" ]] || return 0
  local line
  while IFS= read -r line; do
    printf '%s\n' "${line#*/}"
  done < "$art/targets.txt"
}

# cw_consult_dag_validate <art-dir>
# Reads stdin (the ## Execution DAG body), validates strict grammar:
#   Step <N>: <repo>  <description>
#           depends: Step <M>[, Step <K>...] | none
# Rejects: free-form prose, unknown step refs, cycles, repos outside
# targets.txt leaf set. Stderr carries human-readable ERROR: messages.
# rc=0 on success, rc=1 on validation failure, rc=2 on missing args.
cw_consult_dag_validate() {
  local art="${1:-}"
  [[ -n "$art" ]] || { echo "cw_consult_dag_validate: missing art-dir" >&2; return 2; }
  local -a leaves=()
  mapfile -t leaves < <(_cw_consult_print_leaves "$art")

  local body
  body=$(cat)
  [[ -n "$body" ]] || { echo "ERROR: DAG body is empty" >&2; return 1; }

  # Parse: walk lines, alternating Step + depends. Allow blank lines
  # between Step blocks. Reject anything else.
  local -A step_repo step_desc
  local -A step_deps   # value: comma-separated dep ids
  local -a step_ids=()
  local current=""
  local lineno=0
  local raw
  while IFS= read -r raw; do
    lineno=$((lineno + 1))
    # Trim trailing CR (POSIX)
    raw="${raw%$'\r'}"
    # Skip blank lines.
    [[ -z "${raw// }" ]] && { current=""; continue; }
    if [[ "$raw" =~ ^Step\ ([0-9]+):\ +(${CW_SLUG_REGEX_BASE})\ +(.+)$ ]]; then
      current="${BASH_REMATCH[1]}"
      step_repo[$current]="${BASH_REMATCH[2]}"
      step_desc[$current]="${BASH_REMATCH[3]}"
      step_ids+=("$current")
      continue
    fi
    if [[ "$raw" =~ ^[[:space:]]+depends:[[:space:]]*(.+)$ ]]; then
      [[ -n "$current" ]] || { echo "ERROR: line $lineno depends without preceding Step" >&2; return 1; }
      local deps="${BASH_REMATCH[1]}"
      if [[ "$deps" == "none" ]]; then
        step_deps[$current]=""
      else
        # "Step 1, Step 2" -> "1,2"
        local norm
        norm=$(echo "$deps" | sed -E 's/Step[[:space:]]+([0-9]+)/\1/g; s/[[:space:]]//g')
        if [[ ! "$norm" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
          echo "ERROR: line $lineno bad depends syntax: '$deps'" >&2
          return 1
        fi
        step_deps[$current]="$norm"
      fi
      current=""
      continue
    fi
    if [[ "$raw" =~ ^[[:space:]]+Step\ [0-9]+: ]]; then
      echo "ERROR: line $lineno: Step lines must not be indented (got leading whitespace): '$raw'" >&2
      return 1
    fi
    if [[ "$raw" =~ ^[[:space:]]+depends:[[:space:]]*$ ]]; then
      echo "ERROR: line $lineno: depends value missing (use 'none' for no dependencies): '$raw'" >&2
      return 1
    fi
    if [[ "$raw" =~ ^Step\ [0-9]+:\ +${CW_SLUG_REGEX_BASE}[[:space:]]*$ ]]; then
      echo "ERROR: line $lineno: Step line missing description: '$raw'" >&2
      return 1
    fi
    echo "ERROR: line $lineno is invalid (free-form prose or bad grammar): '$raw'" >&2
    return 1
  done <<< "$body"

  (( ${#step_ids[@]} > 0 )) || { echo "ERROR: no Step blocks found" >&2; return 1; }

  # Reference + repo-membership check.
  local id dep
  declare -A id_set=()
  for id in "${step_ids[@]}"; do id_set[$id]=1; done
  for id in "${step_ids[@]}"; do
    [[ -n "${step_deps[$id]+x}" ]] || { echo "ERROR: Step $id missing depends:" >&2; return 1; }
    if (( ${#leaves[@]} > 0 )); then
      local repo="${step_repo[$id]}"
      local found=0 leaf
      for leaf in "${leaves[@]}"; do
        [[ "$leaf" == "$repo" ]] && { found=1; break; }
      done
      (( found == 1 )) || { echo "ERROR: Step $id repo '$repo' not in targets" >&2; return 1; }
    fi
    if [[ -n "${step_deps[$id]}" ]]; then
      IFS=',' read -ra _deps <<< "${step_deps[$id]}"
      for dep in "${_deps[@]}"; do
        [[ -n "${id_set[$dep]+x}" ]] || { echo "ERROR: Step $id depends on unknown Step $dep" >&2; return 1; }
      done
    fi
  done

  # Kahn topological sort to detect cycles.
  declare -A indeg=()
  declare -A adj=()
  for id in "${step_ids[@]}"; do indeg[$id]=0; done
  for id in "${step_ids[@]}"; do
    if [[ -n "${step_deps[$id]}" ]]; then
      IFS=',' read -ra _deps <<< "${step_deps[$id]}"
      for dep in "${_deps[@]}"; do
        adj[$dep]+="$id "
        indeg[$id]=$((indeg[$id] + 1))
      done
    fi
  done
  local -a queue=()
  for id in "${step_ids[@]}"; do
    (( indeg[$id] == 0 )) && queue+=("$id")
  done
  local processed=0 head nbr
  while (( ${#queue[@]} > 0 )); do
    head="${queue[0]}"
    queue=("${queue[@]:1}")
    processed=$((processed + 1))
    for nbr in ${adj[$head]:-}; do
      indeg[$nbr]=$((indeg[$nbr] - 1))
      (( indeg[$nbr] == 0 )) && queue+=("$nbr")
    done
  done
  if (( processed != ${#step_ids[@]} )); then
    echo "ERROR: DAG has a cycle (processed $processed of ${#step_ids[@]} steps)" >&2
    return 1
  fi
  return 0
}

# cw_consult_xrepo_deps_validate <art-dir>
# Reads stdin (Cross-Repo Deps pipe-table body). Validates header row +
# 4 columns + Type ∈ {internal, external} + internal Producer/Consumer
# both in targets.txt leaf set. Stderr ERROR: messages; rc=0/1/2.
cw_consult_xrepo_deps_validate() {
  local art="${1:-}"
  [[ -n "$art" ]] || { echo "cw_consult_xrepo_deps_validate: missing art-dir" >&2; return 2; }
  local -a leaves=()
  mapfile -t leaves < <(_cw_consult_print_leaves "$art")
  local body
  body=$(cat)
  [[ -n "$body" ]] || { echo "ERROR: xrepo-deps body empty" >&2; return 1; }

  local lineno=0 saw_header=0 saw_sep=0
  local raw
  while IFS= read -r raw; do
    lineno=$((lineno + 1))
    raw="${raw%$'\r'}"
    [[ -z "${raw// }" ]] && continue
    if (( saw_header == 0 )); then
      [[ "$raw" =~ ^\|[[:space:]]*Producer[[:space:]]*\|[[:space:]]*Artifact[[:space:]]*\|[[:space:]]*Consumer[[:space:]]*\|[[:space:]]*Type[[:space:]]*\|$ ]] \
        || { echo "ERROR: line $lineno: missing or wrong header (need | Producer | Artifact | Consumer | Type |)" >&2; return 1; }
      saw_header=1
      continue
    fi
    if (( saw_sep == 0 )); then
      [[ "$raw" =~ ^\|[-:[:space:]|]+\|$ ]] \
        || { echo "ERROR: line $lineno: missing separator row" >&2; return 1; }
      saw_sep=1
      continue
    fi
    # X-sentinel: bash's `read -ra` strips a single trailing empty field, so a row
    # like `| A | B | C | D |` would yield 5 cells instead of the 6 we count on
    # (1 leading empty + 4 data + 1 trailing empty). Appending an `X` before
    # splitting preserves the trailing empty (it becomes ` X`), keeping cell
    # count at 6 and arithmetic stable. cells[5] holds ` X`, never used.
    IFS='|' read -ra cells <<< "${raw}X"
    if (( ${#cells[@]} != 6 )); then
      echo "ERROR: line $lineno: expected 4 columns, got $((${#cells[@]} - 2))" >&2
      return 1
    fi
    local producer artifact consumer typ
    producer=$(echo "${cells[1]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    artifact=$(echo "${cells[2]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    consumer=$(echo "${cells[3]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    typ=$(echo      "${cells[4]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -n "$producer" && -n "$artifact" && -n "$consumer" && -n "$typ" ]] \
      || { echo "ERROR: line $lineno: empty cell" >&2; return 1; }
    case "$typ" in
      internal|external) ;;
      *) echo "ERROR: line $lineno: Type='$typ' must be 'internal' or 'external'" >&2; return 1 ;;
    esac
    # external rows skip membership: producer/consumer may live outside the deploy
    # (already-shipped dependency that's still a real prereq).
    if [[ "$typ" == "internal" ]] && (( ${#leaves[@]} > 0 )); then
      local found_p=0 found_c=0 leaf
      for leaf in "${leaves[@]}"; do
        [[ "$leaf" == "$producer" ]] && found_p=1
        [[ "$leaf" == "$consumer" ]] && found_c=1
      done
      (( found_p == 1 )) || { echo "ERROR: line $lineno: Producer '$producer' marked internal but not in targets" >&2; return 1; }
      (( found_c == 1 )) || { echo "ERROR: line $lineno: Consumer '$consumer' marked internal but not in targets" >&2; return 1; }
    fi
  done <<< "$body"
  (( saw_header == 1 && saw_sep == 1 )) \
    || { echo "ERROR: xrepo-deps missing header or separator" >&2; return 1; }
  return 0
}

# cw_consult_acceptance_tests_validate <art-dir>
# Reads stdin (## Acceptance Tests body). Each top-level entry
# (line starting with `- `) must begin with `**Step N**` followed by
# `[<sub-project>]`. Cross-references against $art/design-doc/dag.md
# (Step ids, parsed via `^Step ([0-9]+):` regex — same shape as
# cw_consult_dag_validate emits) and $art/targets.txt (leaf names).
# Cross-refs are graceful: skipped when the source file is absent/empty.
# stderr ERROR: messages include both entry number and line number.
# rc=0 on success, rc=1 on validation failure, rc=2 on missing args.
cw_consult_acceptance_tests_validate() {
  local art="${1:-}"
  [[ -n "$art" ]] || { echo "cw_consult_acceptance_tests_validate: missing art-dir" >&2; return 2; }

  # Collect known Step ids from dag.md (if present) and known leaves.
  local -A known_ids=() known_leaves=()
  if [[ -s "$art/design-doc/dag.md" ]]; then
    local dline
    while IFS= read -r dline; do
      dline="${dline%$'\r'}"
      [[ "$dline" =~ ^Step\ ([0-9]+): ]] && known_ids[${BASH_REMATCH[1]}]=1
    done < "$art/design-doc/dag.md"
  else
    log_warn "acceptance-tests validator: dag.md absent — Step <N> tags will not be cross-checked"
  fi
  if [[ -s "$art/targets.txt" ]]; then
    local tline
    while IFS= read -r tline; do
      tline="${tline%$'\r'}"
      [[ -z "$tline" ]] && continue
      known_leaves["${tline#*/}"]=1
    done < "$art/targets.txt"
  fi

  local body lineno=0 entry_no=0 raw
  body=$(cat)
  [[ -n "$body" ]] || { echo "ERROR: acceptance-tests body empty" >&2; return 1; }

  while IFS= read -r raw; do
    lineno=$((lineno + 1))
    raw="${raw%$'\r'}"
    # Top-level entry line: starts with "- " (not "  -" sub-bullets).
    [[ "$raw" =~ ^-\  ]] || continue
    entry_no=$((entry_no + 1))
    local content="${raw#- }"
    if [[ ! "$content" =~ ^\*\*Step[[:space:]]+([0-9]+)\*\* ]]; then
      echo "ERROR: entry $entry_no (line $lineno): missing **Step N** tag" >&2
      return 1
    fi
    local sid="${BASH_REMATCH[1]}"
    if (( ${#known_ids[@]} > 0 )) && [[ -z "${known_ids[$sid]+x}" ]]; then
      echo "ERROR: entry $entry_no (line $lineno): tagged **Step $sid** which doesn't exist in DAG" >&2
      return 1
    fi
    if [[ ! "$content" =~ \[(${CW_SLUG_REGEX_BASE})\] ]]; then
      echo "ERROR: entry $entry_no (line $lineno): missing [sub-project] tag" >&2
      return 1
    fi
    local repo="${BASH_REMATCH[1]}"
    if (( ${#known_leaves[@]} > 0 )) && [[ -z "${known_leaves[$repo]+x}" ]]; then
      echo "ERROR: entry $entry_no (line $lineno): tagged [$repo] which isn't in targets" >&2
      return 1
    fi
  done <<< "$body"

  (( entry_no > 0 )) || { echo "ERROR: no acceptance-test entries found" >&2; return 1; }
  return 0
}
