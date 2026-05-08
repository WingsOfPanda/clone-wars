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

# v0.18.3: review-polish patches.
BODY=$(cat "$DIR")

# Frontmatter must declare allowed-tools (was missing entirely pre-v0.18.3).
grep -qE '^allowed-tools:' "$DIR" \
  || { echo "FAIL: frontmatter missing allowed-tools line" >&2; exit 1; }
grep -qE '^allowed-tools:.*AskUserQuestion' "$DIR" \
  || { echo "FAIL: allowed-tools missing AskUserQuestion" >&2; exit 1; }
grep -qE '^allowed-tools:.*WebSearch' "$DIR" \
  || { echo "FAIL: allowed-tools missing WebSearch (fast-path uses it)" >&2; exit 1; }

# argument-hint must advertise --use-force and --targets (P0-1).
grep -qE '^argument-hint:.*--use-force' "$DIR" \
  || { echo "FAIL: argument-hint missing --use-force" >&2; exit 1; }
grep -qE '^argument-hint:.*--targets' "$DIR" \
  || { echo "FAIL: argument-hint missing --targets" >&2; exit 1; }

# "TaskCreate × 17 BEFORE Step 0" (P0-3 — was incorrectly "BEFORE step 1").
grep -qE 'TaskCreate × 17 BEFORE Step 0' "$DIR" \
  || { echo "FAIL: task-list heading not 'BEFORE Step 0'" >&2; exit 1; }

# v0.17.0 spec must be cited (P1-1).
assert_contains "$BODY" "2026-05-08-consult-spec-merge-design.md" "v0.17.0 spec cited"

# "When to use this command" trigger-phrases block (P2-2).
assert_contains "$BODY" "When to use this command" "directive has When-to-use block"

# v0.14.0 default stamp must be gone (P1-2).
! grep -qE 'v0\.14\.0 default' "$DIR" \
  || { echo "FAIL: stale 'v0.14.0 default' stamp still present" >&2; exit 1; }

# Step 13 must NOT have duplicate "5b." numbering (P1-8).
! grep -qE '^5b\.' "$DIR" \
  || { echo "FAIL: Step 13 still has duplicate 5b. numbering" >&2; exit 1; }

# Step 16 must point user to /clone-wars:deploy and /executeorder66 (P2-7).
assert_contains "$BODY" "/clone-wars:deploy <path-to-design-doc>" "Step 16 points to /clone-wars:deploy"
assert_contains "$BODY" "/executeorder66 <path-to-design-doc>"     "Step 16 points to /executeorder66 for multi-repo"

# Step 11 critical-section list must include all four (P1-7 — was just goal+architecture).
grep -Pzo '(?s)Critical-section skip block.*?testing.*?success-criteria' "$DIR" >/dev/null \
  || { echo "FAIL: Step 11 critical-section list missing testing+success-criteria" >&2; exit 1; }

# Step 5 must forward-ref the CW_CONSULT_SKILL_OVERRIDE kill switch (P2-6).
# Check the "kill switch" mention appears between the Step 5 and Step 6 headings.
awk '/^### Step 5 /{f=1} /^### Step 6 /{f=0} f && /kill switch/' "$DIR" | grep -q . \
  || { echo "FAIL: Step 5 missing forward-ref to kill switch (between Step 5 and Step 6 headings)" >&2; exit 1; }

# --design-doc deprecation surfaced via chat (P2-8).
assert_contains "$BODY" "obsolete in v0.17.0" "directive surfaces --design-doc deprecation to user via chat"

# Step 9 must clarify PENDING resolution operates on adjudicated.md, not design-doc (P0-4).
assert_contains "$BODY" "intermediate artifact" "Step 9 labels adjudicated.md as intermediate artifact"

pass "commands/consult.md v0.18.3 static wiring complete"
