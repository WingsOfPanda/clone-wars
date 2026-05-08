#!/usr/bin/env bash
# tests/test_consult_audit_issue_mapping.sh
#
# cw_consult_audit_issue_to_section maps cw_deploy_audit_doc ISSUE= keys
# to the draft section file (under _consult/design-doc/.draft/) that the
# directive should re-walk. Pure lookup; no I/O.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

source ../lib/consult-walk.sh

# Hard mappings (from spec Error Handling table).
got=$(cw_consult_audit_issue_to_section no_goal_section);     [[ "$got" == "goal" ]]            || { echo "FAIL: no_goal_section -> $got" >&2; exit 1; }
got=$(cw_consult_audit_issue_to_section no_arch_section);     [[ "$got" == "architecture" ]]    || { echo "FAIL: no_arch_section -> $got" >&2; exit 1; }
got=$(cw_consult_audit_issue_to_section no_testing_section);  [[ "$got" == "testing" ]]         || { echo "FAIL: no_testing_section -> $got" >&2; exit 1; }
got=$(cw_consult_audit_issue_to_section no_success_section);  [[ "$got" == "success-criteria" ]] || { echo "FAIL: no_success_section -> $got" >&2; exit 1; }

# Marker issues — caller must AskUserQuestion to identify section, so map to ASK.
for marker in tbd_marker todo_marker fill_in_later_marker to_be_determined_marker; do
  got=$(cw_consult_audit_issue_to_section "$marker")
  [[ "$got" == "ASK" ]] || { echo "FAIL: $marker -> $got (expected ASK)" >&2; exit 1; }
done

# Target Sub-Project slug error → header re-emit, not section walk.
got=$(cw_consult_audit_issue_to_section target_subproject_when_invalid)
[[ "$got" == "header" ]] || { echo "FAIL: target_subproject_when_invalid -> $got (expected header)" >&2; exit 1; }

# Unknown issue → empty (caller treats as fatal).
got=$(cw_consult_audit_issue_to_section bogus_unknown_issue)
[[ -z "$got" ]] || { echo "FAIL: unknown issue -> $got (expected empty)" >&2; exit 1; }

# Missing arg → rc=2.
cw_consult_audit_issue_to_section >/dev/null 2>&1 && { echo "FAIL: empty arg should error" >&2; exit 1; } || rc=$?
[[ "$rc" -eq 2 ]] || { echo "FAIL: empty arg rc=$rc (expected 2)" >&2; exit 1; }

pass "cw_consult_audit_issue_to_section maps all 8 known ISSUE= keys"
