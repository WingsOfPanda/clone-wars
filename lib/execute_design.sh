# lib/execute_design.sh — /clone-wars:execute-design helpers.
# Sourced. Depends on lib/state.sh, lib/consult.sh (for slug regex re-use).

cw_execute_design_topic_dir() {
  printf '%s/state/%s/%s\n' "$(cw_state_root)" "$(cw_repo_hash)" "$1"
}

cw_execute_design_art_dir() {
  printf '%s/state/%s/%s/_execute\n' "$(cw_state_root)" "$(cw_repo_hash)" "$1"
}

# cw_execute_design_assert_topic <topic>
# Slug regex must match consult's so existing pipelines stay aligned.
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
