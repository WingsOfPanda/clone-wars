# lib/consult-hub.sh — hub-mode detection, persistence, target helpers.
# Sourced by lib/consult.sh shim. Depends on lib/state.sh (CW_SLUG_REGEX_BASE,
# cw_atomic_write), lib/log.sh.

# cw_consult_detect_hub <cwd>
# Classifies <cwd> into one of three modes and prints structured stdout:
#   MODE=single-repo|hub-subrepo|super-hub
#   HUBS=<comma-list>      (only when super-hub)
#   LEAVES=<comma-list>    (always when rc=0; <hub>/<leaf> form for super-hub,
#                           <self>/<leaf> form for hub-subrepo)
# Returns 0 when hub-mode (hub-subrepo or super-hub); rc=1 for single-repo
# (preserves v0.10 caller expectation).
cw_consult_detect_hub() {
  local cwd="${1:-}"
  [[ -n "$cwd" ]] || return 1
  [[ -d "$cwd/.git" || -f "$cwd/.git" ]] || return 1

  local self_name child base child_name
  self_name="${cwd##*/}"
  local -a immediate_git=() leaves_subrepo=() hubs=() leaves_super=()
  for child in "$cwd"/*/; do
    [[ -d "$child" ]] || continue
    if [[ -d "$child/.git" || -f "$child/.git" ]]; then
      base="${child%/}"
      child_name="${base##*/}"
      if [[ ! "$child_name" =~ ^${CW_SLUG_REGEX_BASE}$ ]]; then
        log_warn "cw_consult_detect_hub: dropped '$child_name' (non-slug-safe directory name)"
        continue
      fi
      immediate_git+=("$child_name")
    fi
  done
  [[ ${#immediate_git[@]} -gt 0 ]] || return 1

  # For each immediate git child, scan its subdirectories:
  #   - any git grandchild  → child is a hub (collect each leaf)
  #   - no git grandchild but has at least one non-git subdir → child is a leaf
  #   - no subdirectories at all → drop (not a meaningful sub-project node)
  local hub leaf grandchild has_grand has_any_subdir grand_name
  for hub in "${immediate_git[@]}"; do
    has_grand=0
    has_any_subdir=0
    for grandchild in "$cwd/$hub"/*/; do
      [[ -d "$grandchild" ]] || continue
      has_any_subdir=1
      if [[ -d "$grandchild/.git" || -f "$grandchild/.git" ]]; then
        leaf="${grandchild%/}"
        grand_name="${leaf##*/}"
        if [[ ! "$grand_name" =~ ^${CW_SLUG_REGEX_BASE}$ ]]; then
          log_warn "cw_consult_detect_hub: dropped '$grand_name' (non-slug-safe directory name)"
          continue
        fi
        leaves_super+=("$hub/$grand_name")
        has_grand=1
      fi
    done
    if (( has_grand == 1 )); then
      hubs+=("$hub")
    elif (( has_any_subdir == 1 )); then
      leaves_subrepo+=("$self_name/$hub")
    else
      # bare git repo (no subdirectories) → drop per spec error-handling
      log_warn "cw_consult_detect_hub: dropped '$hub' (bare git child with no subdirectories)"
    fi
  done

  # Classification:
  # - any immediate git child is a hub (has git grandchildren) → super-hub
  # - all immediate git children are leaves → hub-subrepo
  # - mixed: super-hub mode, leaf-less hubs are dropped (per spec error-handling)
  if (( ${#hubs[@]} > 0 )); then
    [[ ${#leaves_super[@]} -gt 0 ]] || return 1
    printf 'MODE=super-hub\n'
    printf 'HUBS=%s\n' "$(IFS=,; echo "${hubs[*]}")"
    printf 'LEAVES=%s\n' "$(IFS=,; echo "${leaves_super[*]}")"
    return 0
  fi
  if (( ${#leaves_subrepo[@]} > 0 )); then
    printf 'MODE=hub-subrepo\n'
    printf 'LEAVES=%s\n' "$(IFS=,; echo "${leaves_subrepo[*]}")"
    return 0
  fi
  return 1
}

# cw_consult_hub_mode_persist <art-dir> <mode>
# Atomic-writes <art-dir>/hub-mode.txt. Mode must be one of the three
# detector outputs: single-repo | hub-subrepo | super-hub.
cw_consult_hub_mode_persist() {
  local art="${1:-}" mode="${2:-}"
  [[ -n "$art" ]]  || { echo "cw_consult_hub_mode_persist: missing art-dir" >&2; return 2; }
  [[ -n "$mode" ]] || { echo "cw_consult_hub_mode_persist: missing mode" >&2; return 2; }
  case "$mode" in
    single-repo|hub-subrepo|super-hub) ;;
    *) echo "cw_consult_hub_mode_persist: invalid mode '$mode'" >&2; return 2 ;;
  esac
  printf '%s\n' "$mode" | cw_atomic_write "$art/hub-mode.txt"
}

# cw_consult_hub_mode_load <art-dir>
# Echoes the persisted mode; defaults to single-repo when file is absent.
cw_consult_hub_mode_load() {
  local art="${1:-}"
  [[ -n "$art" ]] || { echo "cw_consult_hub_mode_load: missing art-dir" >&2; return 2; }
  if [[ -f "$art/hub-mode.txt" ]]; then
    # tr -d strips defensively in case the file was hand-edited with CR/LF
    # or trailing whitespace; printf '\n' re-adds the canonical terminator.
    tr -d '[:space:]' < "$art/hub-mode.txt"
    printf '\n'
  else
    printf 'single-repo\n'
  fi
}

# cw_consult_targets_persist <art-dir>
# Reads stdin (one <hub>/<leaf> line per target), validates each line
# against ^${CW_SLUG_REGEX_BASE}/${CW_SLUG_REGEX_BASE}$, atomic-writes
# <art-dir>/targets.txt.
# Empty stdin or any invalid line → rc=1 + log_error, no file written.
cw_consult_targets_persist() {
  local art="${1:-}"
  [[ -n "$art" ]] || { echo "cw_consult_targets_persist: missing art-dir" >&2; return 2; }
  local -a lines=()
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ ! "$line" =~ ^${CW_SLUG_REGEX_BASE}/${CW_SLUG_REGEX_BASE}$ ]]; then
      echo "cw_consult_targets_persist: invalid target '$line' (need <hub>/<leaf>)" >&2
      return 1
    fi
    lines+=("$line")
  done
  (( ${#lines[@]} > 0 )) \
    || { echo "cw_consult_targets_persist: stdin empty" >&2; return 1; }
  printf '%s\n' "${lines[@]}" | cw_atomic_write "$art/targets.txt"
}

# cw_consult_targets_load <art-dir>
# Echoes targets one per line. rc=1 if file missing or empty.
cw_consult_targets_load() {
  local art="${1:-}"
  [[ -n "$art" ]] || { echo "cw_consult_targets_load: missing art-dir" >&2; return 2; }
  [[ -s "$art/targets.txt" ]] || return 1
  cat "$art/targets.txt"
}

# cw_consult_targets_to_header_pair <art-dir>
# Reads targets.txt and emits exactly two lines suitable for design-doc
# header insertion:
#   **Target Hub(s):** <comma-separated unique hubs>
#   **Target Sub-Project(s):** <comma-separated unique leaves>
# Hubs are extracted as the prefix before '/'; leaves as the suffix after.
# rc=1 if targets.txt is missing/empty.
cw_consult_targets_to_header_pair() {
  local art="${1:-}"
  [[ -n "$art" ]] || { echo "cw_consult_targets_to_header_pair: missing art-dir" >&2; return 2; }
  [[ -s "$art/targets.txt" ]] || return 1
  local hubs leaves
  hubs=$(cut -d/ -f1 "$art/targets.txt" | awk '!seen[$0]++' | paste -sd, -)
  leaves=$(cut -d/ -f2- "$art/targets.txt" | awk '!seen[$0]++' | paste -sd, -)
  # Convert "a,b" → "a, b" for human-readable headers.
  hubs=$(echo "$hubs" | sed 's/,/, /g')
  leaves=$(echo "$leaves" | sed 's/,/, /g')
  printf '**Target Hub(s):** %s\n' "$hubs"
  printf '**Target Sub-Project(s):** %s\n' "$leaves"
}

# cw_consult_extract_targets_from_topic <topic-text> <available-leaves-csv>
# Heuristic target inference from the topic text. Returns 2-line stdout:
#   INFERRED=<comma-leaves>
#   KEYWORD_ALL=<0|1>
# rc=0 when >=1 inference (or KEYWORD_ALL=1), rc=1 when no matches.
#
# Inference rules:
# - Word-boundary match each leaf basename against topic text -> add to INFERRED
# - Word-boundary match each hub name against topic text -> add ALL leaves
#   under that hub to INFERRED
# - "all" / "every" / "everything" / "across all" anywhere in topic ->
#   KEYWORD_ALL=1
# Word-boundary = surrounded by non-slug-character or string boundary.
cw_consult_extract_targets_from_topic() {
  local topic="${1:-}" leaves_csv="${2:-}"
  [[ -n "$topic" && -n "$leaves_csv" ]] || { echo "cw_consult_extract_targets_from_topic: missing args" >&2; return 2; }

  # Lowercase topic for case-insensitive keyword matching.
  local topic_lower
  topic_lower=$(printf '%s' "$topic" | tr '[:upper:]' '[:lower:]')

  # KEYWORD_ALL detection -- surrounded by spaces or string boundaries.
  local keyword_all=0
  local fenced=" $topic_lower "
  fenced=${fenced//[[:punct:]]/ }
  fenced=$(printf '%s' "$fenced" | tr -s ' ')
  if [[ "$fenced" =~ \ (all|every|everything|across\ all)\  ]]; then
    keyword_all=1
  fi

  # Word-boundary match leaves and hubs.
  local -a leaves=() hubs_seen=()
  IFS=',' read -ra leaves <<< "$leaves_csv"
  local leaf hub bare
  declare -A inferred=()
  for leaf in "${leaves[@]}"; do
    hub="${leaf%%/*}"
    bare="${leaf#*/}"
    # Match bare leaf name with word boundary (surround by non-slug or boundary).
    if [[ " $topic " =~ [^A-Za-z0-9._-]"$bare"[^A-Za-z0-9._-] ]]; then
      inferred[$leaf]=1
    fi
    # Track unique hubs.
    local seen=0 h
    for h in "${hubs_seen[@]:-}"; do
      [[ "$h" == "$hub" ]] && { seen=1; break; }
    done
    (( seen == 0 )) && hubs_seen+=("$hub")
  done
  # Hub-name match -> add all leaves under that hub
  for hub in "${hubs_seen[@]}"; do
    if [[ " $topic " =~ [^A-Za-z0-9._-]"$hub"[^A-Za-z0-9._-] ]]; then
      for leaf in "${leaves[@]}"; do
        [[ "${leaf%%/*}" == "$hub" ]] && inferred[$leaf]=1
      done
    fi
  done

  # Build INFERRED comma-list preserving original leaves order.
  local result=""
  for leaf in "${leaves[@]}"; do
    [[ -n "${inferred[$leaf]+x}" ]] && result+="${result:+,}$leaf"
  done

  printf 'INFERRED=%s\n' "$result"
  printf 'KEYWORD_ALL=%s\n' "$keyword_all"
  if [[ -z "$result" && "$keyword_all" -eq 0 ]]; then
    return 1
  fi
  return 0
}

# cw_consult_findings_active_subproject <findings-md>
# Parses findings.md, returns the last `### <leaf>` heading text (just the
# bare leaf name, no `### ` prefix). rc=0 + leaf name on stdout.
# rc=1 when file missing or no ### headings found.
cw_consult_findings_active_subproject() {
  local file="${1:-}"
  [[ -n "$file" ]] || { echo "cw_consult_findings_active_subproject: missing file arg" >&2; return 2; }
  [[ -f "$file" ]] || return 1
  local last
  last=$(awk '/^### / { sub(/^### /, ""); name=$0 } END { if (name != "") print name }' "$file")
  [[ -n "$last" ]] || return 1
  printf '%s\n' "$last"
}
