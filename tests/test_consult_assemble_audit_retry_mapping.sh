#!/usr/bin/env bash
# tests/test_consult_assemble_audit_retry_mapping.sh
#
# Sanity check: every ISSUE= cw_deploy_audit_doc emits maps to a section
# (or ASK or header) via cw_consult_audit_issue_to_section. Catches drift
# if either side adds a key the other doesn't know about.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

source ../lib/consult-walk.sh
source ../lib/log.sh
source ../lib/deploy.sh

# Extract every literal ISSUE= key cw_deploy_audit_doc can emit.
ISSUE_KEYS=$(grep -oE 'issues\+=\("[a-z_]+"\)' ../lib/deploy.sh | sed 's/issues+=("//; s/")$//' | sort -u)
[[ -n "$ISSUE_KEYS" ]] || { echo "FAIL: couldn't extract any ISSUE keys from lib/deploy.sh" >&2; exit 1; }

while IFS= read -r key; do
  got=$(cw_consult_audit_issue_to_section "$key")
  [[ -n "$got" ]] || { echo "FAIL: cw_consult_audit_issue_to_section knows no mapping for ISSUE=$key" >&2; exit 1; }
done <<< "$ISSUE_KEYS"

pass "all cw_deploy_audit_doc ISSUE= keys are mapped by cw_consult_audit_issue_to_section"
