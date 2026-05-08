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
