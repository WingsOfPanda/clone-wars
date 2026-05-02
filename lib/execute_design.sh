# lib/execute_design.sh — /clone-wars:execute-design helpers.
# Sourced. Depends on lib/state.sh, lib/consult.sh (for slug regex re-use).

cw_execute_design_topic_dir() {
  printf '%s/state/%s/%s\n' "$(cw_state_root)" "$(cw_repo_hash)" "$1"
}

cw_execute_design_art_dir() {
  printf '%s/state/%s/%s/_execute\n' "$(cw_state_root)" "$(cw_repo_hash)" "$1"
}

# cw_execute_design_assert_topic <topic>
# Stricter than cw_consult_topic_validate's regex; execute-design topics are strict kebab-only.
cw_execute_design_assert_topic() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] \
    || { log_error "invalid topic slug: '$1' (must match ^[a-z0-9][a-z0-9-]{0,31}\$)"; exit 2; }
}

# cw_execute_design_derive_topic <design-path>
# Strip leading YYYY-MM-DD- and trailing -design.md (or .md). Print slug.
cw_execute_design_derive_topic() {
  local p="$1" base
  [[ -n "$p" ]] || { printf ''; return 0; }
  base="${p##*/}"                       # basename
  base="${base#????-??-??-}"            # strip YYYY-MM-DD-
  base="${base%-design.md}"             # strip -design.md
  base="${base%.md}"                    # strip .md if -design.md missed
  printf '%s\n' "$base"
}

# cw_execute_design_audit_doc <design-path>
# Heuristic checklist for design-doc readiness. Prints one VERDICT= line plus
# one ISSUE= line per detected issue. Returns 0 on PASS, 1 on FAIL, 2 on
# missing/unreadable file.
#
# Heuristic gates (each ISSUE= prints only if the gate fails):
#   no_goal_section       — no '^## Goal' heading
#   no_arch_section       — no '^## Architecture' or '^## Approach' heading
#   no_testing_section    — no heading containing 'Test' or 'test'
#   no_success_section    — no heading containing 'Success' or 'success'
#   tbd_marker            — file contains 'TBD' as a word
#   todo_marker           — file contains 'TODO' as a word (case-sensitive; lowercase
#                           'todo' is allowed since it commonly appears in field names)
#   fill_in_later_marker  — file matches /fill in later/i
#   to_be_determined_marker — file matches /to be determined/i
cw_execute_design_audit_doc() {
  local doc="$1"
  [[ -f "$doc" && -r "$doc" ]] || { log_error "design-doc unreadable: $doc"; return 2; }
  local fail=0
  local -a issues=()
  grep -qE '^##\s+Goal\b'                       "$doc" || { issues+=("no_goal_section"); fail=1; }
  grep -qE '^##\s+(Architecture|Approach)\b'    "$doc" || { issues+=("no_arch_section"); fail=1; }
  grep -qE '^##\s+.*[Tt]est'                    "$doc" || { issues+=("no_testing_section"); fail=1; }
  grep -qE '^##\s+.*[Ss]uccess'                 "$doc" || { issues+=("no_success_section"); fail=1; }
  grep -qE '\bTBD\b'                            "$doc" && { issues+=("tbd_marker"); fail=1; }
  grep -qE '\bTODO\b'                           "$doc" && { issues+=("todo_marker"); fail=1; }
  grep -qiE 'fill in later'                     "$doc" && { issues+=("fill_in_later_marker"); fail=1; }
  grep -qiE 'to be determined'                  "$doc" && { issues+=("to_be_determined_marker"); fail=1; }
  if (( fail == 0 )); then
    printf 'VERDICT=PASS\n'
    return 0
  fi
  printf 'VERDICT=FAIL\n'
  local i
  for i in "${issues[@]}"; do
    printf 'ISSUE=%s\n' "$i"
  done
  return 1
}
