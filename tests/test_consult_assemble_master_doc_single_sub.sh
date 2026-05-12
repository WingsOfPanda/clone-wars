#!/usr/bin/env bash
# tests/test_consult_assemble_master_doc_single_sub.sh
#
# bin/consult-walk-assemble.sh <topic>
# In single-sub mode (multi-repo.txt = "single-sub" + targets.txt with 1 slug),
# the assembled design-doc has:
#   - the 6-section single-repo shape (NO Execution DAG, NO Cross-Repo Notes)
#   - a singular **Target Sub-Project:** <slug> header (NOT plural)
# so /clone-wars:deploy's v0.10.0 cw_deploy_extract_target redirects
# target_cwd / branch / state into the sub-repo.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=consult-asm-single-sub-test
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
DR="$TD/_consult/design-doc/.draft"
mkdir -p "$DR"

echo "Move frame selection BEFORE motion correction in arsperfusion CTP pipeline" \
  > "$TD/_consult/topic.txt"

# Stage 6 approved sections.
printf '## Problem\n\nStep 2 motion-corrects 30 frames when halftime only needs 9.\n' > "$DR/problem.md"
printf '## Goal\n\nDrop motion-correction wall-clock from 30s to ~10s in halftime mode.\n' > "$DR/goal.md"
printf '## Architecture\n\nPre-select frames after DICOM load when ctp_protocol in {halftime, two_phase}.\n' > "$DR/architecture.md"
printf '## Components\n\n- arsperfusion/construct/engine.py (modified)\n' > "$DR/components.md"
printf '## Testing\n\n- arsperfusion unit tests + AD0332-T3-0001 reference dataset\n' > "$DR/testing.md"
printf '## Success Criteria\n\n- [ ] halftime motion-correction wall-clock < 12s\n- [ ] TTP regression resolved\n' > "$DR/success-criteria.md"

# Stage single-sub state files.
printf 'single-sub\n' > "$TD/_consult/multi-repo.txt"
printf '# generated %s by test\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TD/_consult/targets.txt"
printf 'arsperfusion\t%s/hub/arsperfusion/CLAUDE.md\n' "$TMP" >> "$TD/_consult/targets.txt"

# Run.
DD_PATH=$(../bin/consult-walk-assemble.sh "$TOPIC")
assert_file_exists "$DD_PATH" "design-doc written"

# Singular Target Sub-Project header (NOT plural).
grep -qE '^\*\*Target Sub-Project:\*\* arsperfusion$' "$DD_PATH" \
  || { echo "FAIL: singular Target Sub-Project header missing or wrong; doc head:" >&2; head -5 "$DD_PATH" >&2; exit 1; }

# Plural header MUST NOT be present (would route deploy as multi-repo).
grep -qE '^\*\*Target Sub-Project\(s\):\*\*' "$DD_PATH" \
  && { echo "FAIL: plural Target Sub-Project(s) header present in single-sub mode" >&2; exit 1; } || true

# 6-section shape (no Execution DAG, no Cross-Repo Notes).
ACTUAL_ORDER=$(grep -E '^## ' "$DD_PATH")
[[ "$ACTUAL_ORDER" == "## Problem
## Goal
## Architecture
## Components
## Testing
## Success Criteria" ]] || { echo "FAIL: section order wrong; got: $ACTUAL_ORDER" >&2; exit 1; }

# Audit gate PASSES (singular header with valid slug passes cw_deploy_audit_doc).
# walk-assemble.sh exits 1 on audit FAIL, so reaching this point already confirms.
assert_file_exists "$TD/_consult/design-doc/audit.log" "audit.log written"
grep -q '^VERDICT=PASS' "$TD/_consult/design-doc/audit.log" \
  || { echo "FAIL: audit did not pass; audit.log:" >&2; cat "$TD/_consult/design-doc/audit.log" >&2; exit 1; }

pass "consult-walk-assemble.sh single-sub: singular header + 6 sections + audit PASS"
