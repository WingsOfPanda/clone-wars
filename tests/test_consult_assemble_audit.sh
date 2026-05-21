#!/usr/bin/env bash
# tests/test_consult_assemble_audit.sh
# consult-walk-assemble.sh audit gate behavior.
# 1. PASS/FAIL gate: walk-assemble runs cw_deploy_audit_doc; on PASS exit 0,
#    write audit.log with VERDICT=PASS; on FAIL exit 1, write VERDICT=FAIL +
#    ISSUE= lines, echo ISSUE= lines to stderr.
# 2. Retry-mapping sanity: every ISSUE= key cw_deploy_audit_doc can emit must
#    map to a section via cw_consult_audit_issue_to_section.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

# --- Case 1: PASS/FAIL gate ---
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=consult-asm-audit-test
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
DR="$TD/_consult/design-doc/.draft"
mkdir -p "$DR"
echo "Audit gate test" > "$TD/_consult/topic.txt"

# Happy path: all 6 sections present + non-empty.
printf '## Problem\nx\n'           > "$DR/problem.md"
printf '## Goal\nx\n'              > "$DR/goal.md"
printf '## Architecture\nx\n'      > "$DR/architecture.md"
printf '## Components\nx\n'        > "$DR/components.md"
printf '## Testing\nx\n'           > "$DR/testing.md"
printf '## Success Criteria\nx\n'  > "$DR/success-criteria.md"

DD=$(../bin/consult-walk-assemble.sh "$TOPIC" 2>/dev/null)
assert_file_exists "$DD" "design-doc written on PASS"
assert_file_exists "$TD/_consult/design-doc/audit.log" "audit.log written"
grep -qE '^VERDICT=PASS$' "$TD/_consult/design-doc/audit.log" \
  || { echo "FAIL: audit.log doesn't say PASS" >&2; cat "$TD/_consult/design-doc/audit.log" >&2; exit 1; }

# Sad path: success-criteria draft is bare _(skipped)_ → audit fails with
# no_success_section because cw_deploy_audit_doc requires a heading containing
# "Success".
rm -f "$TD/_consult/design-doc"/*-design.md "$TD/_consult/design-doc/audit.log"
printf '_(skipped)_\n' > "$DR/success-criteria.md"
ERR=$(../bin/consult-walk-assemble.sh "$TOPIC" 2>&1 >/dev/null) && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: expected exit 1 on audit FAIL, got $rc; stderr: $ERR" >&2; exit 1; }
echo "$ERR" | grep -qE '^ISSUE=no_success_section$' \
  || { echo "FAIL: no_success_section ISSUE not on stderr; got=[$ERR]" >&2; exit 1; }
grep -qE '^VERDICT=FAIL$' "$TD/_consult/design-doc/audit.log" \
  || { echo "FAIL: audit.log doesn't say FAIL" >&2; exit 1; }
grep -qE '^ISSUE=no_success_section$' "$TD/_consult/design-doc/audit.log" \
  || { echo "FAIL: audit.log missing ISSUE row" >&2; exit 1; }
pass "1. walk-assemble audit gate: PASS exits 0 with path; FAIL exits 1 with ISSUE= lines"

# --- Case 2: every ISSUE= key has a section mapping ---
source ../lib/consult-walk.sh
source ../lib/log.sh
source ../lib/deploy.sh

ISSUE_KEYS=$(grep -oE 'issues\+=\("[a-z_]+"\)' ../lib/deploy.sh | sed 's/issues+=("//; s/")$//' | sort -u)
[[ -n "$ISSUE_KEYS" ]] || { echo "FAIL: couldn't extract any ISSUE keys from lib/deploy.sh" >&2; exit 1; }

while IFS= read -r key; do
  got=$(cw_consult_audit_issue_to_section "$key")
  [[ -n "$got" ]] || { echo "FAIL: cw_consult_audit_issue_to_section knows no mapping for ISSUE=$key" >&2; exit 1; }
done <<< "$ISSUE_KEYS"
pass "2. all cw_deploy_audit_doc ISSUE= keys map via cw_consult_audit_issue_to_section"

echo "test_consult_assemble_audit: 2 cases passed"
