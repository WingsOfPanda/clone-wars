#!/usr/bin/env bash
# tests/test_consult_directive_v019_static_wiring.sh
# Static-wiring asserts on commands/consult.md for v0.19.0:
# - Step 3a + Step 3b headings exist
# - preflight-layout.sh + --target-pane references present
# - Stage 1 / Stage 2 wording present
# - PREFLIGHT_PANES associative array referenced
# - Task table updated to 18 rows
# - Negative: no .last_pane references in the consult directive
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

DIR=../commands/consult.md
BODY=$(cat "$DIR")

# Step 3a + Step 3b headings
grep -qE '^### Step 3a ' "$DIR" || { echo "FAIL: missing '### Step 3a' heading" >&2; exit 1; }
grep -qE '^### Step 3b ' "$DIR" || { echo "FAIL: missing '### Step 3b' heading" >&2; exit 1; }

# Preflight + target-pane references
assert_contains "$BODY" "bin/preflight-layout.sh" "directive references preflight-layout.sh"
assert_contains "$BODY" "--target-pane"           "directive references --target-pane flag"
assert_contains "$BODY" "preflight-panes.txt"     "directive references preflight-panes.txt"
assert_contains "$BODY" "PREFLIGHT_PANES"          "directive declares PREFLIGHT_PANES array"

# Stage 1 / Stage 2 failure handling
assert_contains "$BODY" "Stage 1 retry-once"          "directive describes Stage 1 retry-once"
assert_contains "$BODY" "Stage 2 partial-success"     "directive describes Stage 2 partial-success"
assert_contains "$BODY" "Proceed degraded"            "directive describes degraded-mode option"
assert_contains "$BODY" "Abort all"                   "directive describes abort option"

# Task table updated to 18 rows
grep -qE 'TaskCreate × 18 BEFORE Step 0' "$DIR" \
  || { echo "FAIL: task-list heading not 'TaskCreate × 18 BEFORE Step 0'" >&2; exit 1; }
grep -qE '^\| 3a \| ' "$DIR" || { echo "FAIL: task table missing 3a row" >&2; exit 1; }
grep -qE '^\| 3b \| ' "$DIR" || { echo "FAIL: task table missing 3b row" >&2; exit 1; }

# Negative: no .last_pane references in consult.md (legacy state file
# should not appear in the consult flow — only in spawn.sh's legacy path)
! grep -qE '\.last_pane' "$DIR" \
  || { echo "FAIL: consult.md still references .last_pane (legacy state file)" >&2; exit 1; }

# Negative: old singular "Step 3 — Parallel spawn" heading should be gone
! grep -qE '^### Step 3 — Parallel spawn' "$DIR" \
  || { echo "FAIL: legacy '### Step 3 — Parallel spawn' heading still present" >&2; exit 1; }

pass "commands/consult.md v0.19.0 static wiring complete"
