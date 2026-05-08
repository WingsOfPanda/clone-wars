#!/usr/bin/env bash
# tests/test_consult_fast_path_design_shape.sh
#
# Fast-path smoke test: stubs the directive's "Yoda inline draft" by
# pre-staging .draft/<section>.md for all 6 sections, then verifies
# consult-walk-assemble.sh produces a doc that passes cw_deploy_audit_doc.
# This exercises the assembly + audit gate without needing tmux/troopers.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=consult-fastpath-e2e
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
DR="$TD/_consult/design-doc/.draft"
mkdir -p "$DR"
echo "What is the safest way to convert a Postgres DECIMAL column to FLOAT?" > "$TD/_consult/topic.txt"

# Yoda's inline draft (simulated).
printf '## Problem\n\nDECIMAL math is exact but slow.\n' > "$DR/problem.md"
printf '## Goal\n\nMigrate column type without write outage.\n' > "$DR/goal.md"
printf '## Architecture\n\nUse pg_repack-style copy + swap.\n' > "$DR/architecture.md"
printf '## Components\n\n- migration script\n- rollback script\n' > "$DR/components.md"
printf '## Testing\n\n- run on staging copy first\n- verify row counts\n' > "$DR/testing.md"
printf '## Success Criteria\n\n- [ ] zero writes lost\n- [ ] rollback path proven\n' > "$DR/success-criteria.md"

# Run walk-assemble.
DD=$(../bin/consult-walk-assemble.sh "$TOPIC")
assert_file_exists "$DD" "design-doc written"

# Audit independently.
source ../lib/log.sh
source ../lib/deploy.sh
cw_deploy_audit_doc "$DD" >/dev/null && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] || { echo "FAIL: audit returned $rc on fast-path output" >&2; exit 1; }

# Six H2 sections present.
COUNT=$(grep -cE '^## ' "$DD")
[[ "$COUNT" -eq 6 ]] || { echo "FAIL: expected 6 H2 sections, got $COUNT" >&2; exit 1; }

pass "fast-path end-to-end: 6-section doc passes cw_deploy_audit_doc"
