#!/usr/bin/env bash
# tests/test_consult_directive_v017_static_wiring.sh
#
# Static-wiring asserts on commands/consult.md: confirms the v0.17.0
# directive has exactly 17 step labels (0-16), references the v0.17 lib
# helpers + bin scripts, and contains no orphan v0.16 references or /spec
# pointers.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

DIR=../commands/consult.md

# 17 step headings: Step 0, Step 1, ..., Step 16.
for i in $(seq 0 16); do
  grep -qE "^### Step ${i} —" "$DIR" || { echo "FAIL: missing '### Step $i —' heading" >&2; exit 1; }
done

# v0.17 helpers wired.
assert_contains "$(cat $DIR)" "cw_consult_detect_multi_repo"      "Step 10 references multi-repo detector"
assert_contains "$(cat $DIR)" "cw_consult_walk_section_state"     "Step 11 references walk-state helper"
assert_contains "$(cat $DIR)" "cw_consult_audit_issue_to_section" "Step 12 references issue mapper"
assert_contains "$(cat $DIR)" "consult-walk-assemble.sh"          "Step 12 calls walk-assemble"

# v0.17 doc shape (6-section single-repo, 8 multi-repo).
assert_contains "$(cat $DIR)" "SECTIONS=(problem goal architecture components testing success-criteria)"   "single-repo 6 sections"
assert_contains "$(cat $DIR)" "SECTIONS=(problem goal architecture components execution-dag cross-repo-notes testing success-criteria)" "multi-repo 8 sections"

# /spec pointers must be gone (other than the back-compat removal hint
# in the obsolete-flag warn message).
LIVE_SPEC_REFS=$(grep -nE '/clone-wars:spec\b' "$DIR" | grep -v 'spec was removed' || true)
[[ -z "$LIVE_SPEC_REFS" ]] || { echo "FAIL: live /clone-wars:spec refs in directive: $LIVE_SPEC_REFS" >&2; exit 1; }

! grep -qE 'cw_consult_design_doc_resume_state' "$DIR" || { echo "FAIL: legacy cw_consult_design_doc_resume_state still referenced" >&2; exit 1; }

# v0.16 step labels must be gone (0.4, 0.5, fractional).
! grep -qE '\bStep 0\.[0-9]'  "$DIR" || { echo "FAIL: v0.16 fractional step labels still present" >&2; exit 1; }
! grep -qE '^### Step 8\.4 ' "$DIR" || { echo "FAIL: legacy Step 8.4 still present" >&2; exit 1; }

# Yoda fast-path emits 6-section deploy-audit doc, not the v0.16 research synthesis shape.
assert_contains "$(cat $DIR)" "## Problem"           "fast-path emits ## Problem"
assert_contains "$(cat $DIR)" "## Success Criteria"  "fast-path emits ## Success Criteria"
! grep -qE 'Summary / Findings / Tradeoffs / Recommendation / Open Questions / Sources' "$DIR" \
  || { echo "FAIL: fast-path still mentions v0.16 6-section research shape" >&2; exit 1; }

pass "commands/consult.md static wiring complete (v0.17.0)"
