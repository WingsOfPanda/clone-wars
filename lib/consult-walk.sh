#!/usr/bin/env bash
# lib/consult-walk.sh
#
# Helpers for the v0.17.0 design-walk phase of /clone-wars:consult:
#   - cw_consult_audit_issue_to_section: map cw_deploy_audit_doc ISSUE= → section file
#   - cw_consult_emit_soft_dag:          format soft DAG section text from TSV
#   - cw_consult_detect_multi_repo:      cwd siblings + topic prose grep
#   - cw_consult_walk_section_state:     resume state for re-walked sections
#
# Sourcing-only file. No top-level side effects.

# cw_consult_audit_issue_to_section <issue-key>
# Echoes the draft-section name (without .md) that should be re-walked, OR
# the literal string "ASK" when the directive must AskUserQuestion to identify
# the offending section, OR "header" when the issue is in the assembled header
# (not a walked section), OR empty when the issue is unknown.
# rc=0 always on a non-empty arg; rc=2 on missing arg.
cw_consult_audit_issue_to_section() {
  local key="${1:-}"
  [[ -n "$key" ]] || { echo "cw_consult_audit_issue_to_section: issue-key required" >&2; return 2; }
  case "$key" in
    no_goal_section)               printf 'goal\n' ;;
    no_arch_section)               printf 'architecture\n' ;;
    no_testing_section)            printf 'testing\n' ;;
    no_success_section)            printf 'success-criteria\n' ;;
    tbd_marker|todo_marker|fill_in_later_marker|to_be_determined_marker)
                                   printf 'ASK\n' ;;
    target_subproject_when_invalid) printf 'header\n' ;;
    *)                             printf '\n' ;;
  esac
}

# cw_consult_emit_soft_dag <tsv-path>
# Formats a numbered prose DAG from a TSV file with columns:
#   <step-num>\t<repo>\t<description>\t<deps-csv|none>
# Each output line: "<n>. <repo> — <description>" optionally followed by
# " (depends on M, N, ...)" when deps != "none".
# Empty input → empty output. Missing file → rc=1. Missing arg → rc=2.
cw_consult_emit_soft_dag() {
  local tsv="${1:-}"
  [[ -n "$tsv" ]] || { echo "cw_consult_emit_soft_dag: tsv-path required" >&2; return 2; }
  [[ -f "$tsv" ]] || { echo "cw_consult_emit_soft_dag: file not found: $tsv" >&2; return 1; }
  local step repo desc deps
  while IFS=$'\t' read -r step repo desc deps; do
    [[ -n "$step" ]] || continue
    if [[ "$deps" == "none" || -z "$deps" ]]; then
      printf '%s. %s — %s\n' "$step" "$repo" "$desc"
    else
      # Reformat "1,2" → "1, 2" for readability.
      local pretty_deps
      pretty_deps=$(printf '%s' "$deps" | sed 's/,/, /g')
      printf '%s. %s — %s (depends on %s)\n' "$step" "$repo" "$desc" "$pretty_deps"
    fi
  done < "$tsv"
}

# cw_consult_detect_multi_repo <cwd> <corpus>
# Walks $cwd's first-level subdirs (skipping dotfiles), keeps those that
# contain a CLAUDE.md or AGENTS.md, and filters them by case-insensitive
# substring match against $corpus.
#
# CORPUS EXPECTATION (v0.30.0): callers should pass the troopers' adjudicated
# findings (adjudicated.md content) as the corpus, NOT the user's raw topic
# prose (topic.txt). The adjudicated content captures cross-repo dependencies
# that emerged during research; the topic prose only captures what the user
# named at invocation time. Step 10 of /clone-wars:consult enforces this; the
# topic.txt fallback is defensive (kept for edge cases when adjudicated.md
# hasn't been written yet).
#
# Emits TSV "<slug>\t<absolute-path>" to stdout, one match per line.
# rc=0 always on valid args (zero hits prints nothing).
# rc=1 if $cwd doesn't exist; rc=2 if either arg empty.
cw_consult_detect_multi_repo() {
  local cwd="${1:-}" topic="${2:-}"
  [[ -n "$cwd"   ]] || { echo "cw_consult_detect_multi_repo: cwd required"   >&2; return 2; }
  [[ -n "$topic" ]] || { echo "cw_consult_detect_multi_repo: topic required" >&2; return 2; }
  [[ -d "$cwd"   ]] || { echo "cw_consult_detect_multi_repo: not a directory: $cwd" >&2; return 1; }
  local topic_lower
  topic_lower=$(printf '%s' "$topic" | tr '[:upper:]' '[:lower:]')
  local entry slug abs marker
  for entry in "$cwd"/*/; do
    [[ -d "$entry" ]] || continue
    slug=$(basename "$entry")
    [[ "$slug" != .* ]] || continue   # skip hidden
    if   [[ -f "$entry/CLAUDE.md" ]]; then marker="$entry/CLAUDE.md"
    elif [[ -f "$entry/AGENTS.md" ]]; then marker="$entry/AGENTS.md"
    else continue
    fi
    # Case-insensitive substring match (slug → topic-lower).
    local slug_lower
    slug_lower=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')
    [[ "$topic_lower" == *"$slug_lower"* ]] || continue
    abs=$(cd "$entry" && pwd)/$(basename "$marker")
    printf '%s\t%s\n' "$slug" "$abs"
  done
}

# cw_consult_walk_section_state [--with-status] <draft-dir>
# Lists section names that already have draft files in $draft-dir, sorted
# alphabetically. With --with-status, emits TSV "<name>\t<approved|skipped>".
# A draft file whose contents are exactly "_(skipped)_" (one line, with or
# without trailing newline) is "skipped"; anything else is "approved".
# rc=0 on success; rc=1 if dir missing; rc=2 if arg missing.
cw_consult_walk_section_state() {
  local with_status=0
  if [[ "${1:-}" == "--with-status" ]]; then
    with_status=1; shift
  fi
  local dir="${1:-}"
  [[ -n "$dir" ]] || { echo "cw_consult_walk_section_state: draft-dir required" >&2; return 2; }
  [[ -d "$dir" ]] || { echo "cw_consult_walk_section_state: not a directory: $dir" >&2; return 1; }
  local f name body
  for f in "$dir"/*.md; do
    [[ -f "$f" ]] || continue
    name=$(basename "$f" .md)
    if (( with_status )); then
      body=$(tr -d '[:space:]' < "$f")
      if [[ "$body" == "_(skipped)_" ]]; then
        printf '%s\tskipped\n' "$name"
      else
        printf '%s\tapproved\n' "$name"
      fi
    else
      printf '%s\n' "$name"
    fi
  done | sort
}
