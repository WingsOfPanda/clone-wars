#!/usr/bin/env bash
# tests/test_deploy_dirty_intercept_directive.sh — v0.30.0 item 3
# Locks Step 0's rc=7 intercept (AskUserQuestion + 3 options) and
# Step 4's stash-pop cleanup block.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
DIRECTIVE="$PLUGIN_ROOT/commands/deploy.md"

# Capture sections up-front (avoids SIGPIPE under pipefail when piping
# awk into grep -q, which would early-exit and signal the producer).
STEP0=$(awk '/^### Step 0/,/^### Step 1/' "$DIRECTIVE")
STEP4=$(awk '/^### Step 4/,0' "$DIRECTIVE")

# Invariant 1: Step 0 references rc=7 dirty-tree intercept
grep -qE 'INIT_RC[[:space:]]*==[[:space:]]*7|INIT_RC[[:space:]]*=[[:space:]]*7|rc=7' <<<"$STEP0" \
  || { echo "FAIL: Step 0 doesn't reference rc=7 dirty-tree intercept" >&2; exit 1; }
pass "1. Step 0 references rc=7 dirty-tree intercept"

# Invariant 2: AskUserQuestion offers Stash / Commit / Abort
grep -qE 'Stash and continue|stash and continue' <<<"$STEP0" \
  || { echo "FAIL: Step 0 missing 'Stash and continue' option" >&2; exit 1; }
pass "2. Step 0 dirty-intercept offers Stash and continue"

grep -qE 'Commit first|commit first.*WIP' <<<"$STEP0" \
  || { echo "FAIL: Step 0 missing 'Commit first' option" >&2; exit 1; }
pass "3. Step 0 dirty-intercept offers Commit first as chore: WIP"

# Invariant 3: stash captured by SHA, not by index
grep -qE 'stash list -1 --format=%H' <<<"$STEP0" \
  || { echo "FAIL: Step 0 captures stash by index instead of SHA (race-prone)" >&2; exit 1; }
pass "4. Step 0 captures stash ref by SHA via 'stash list -1 --format=%H'"

# Invariant 4: Step 4 has stash-pop cleanup
grep -qE 'pre-deploy-stash\.txt|stash pop' <<<"$STEP4" \
  || { echo "FAIL: Step 4 missing stash-pop cleanup block" >&2; exit 1; }
pass "5. Step 4 has stash-pop cleanup block"

# Invariant 5: state files documented
grep -q 'pre-deploy-stash\.txt' "$DIRECTIVE" \
  || { echo "FAIL: directive doesn't reference _deploy/pre-deploy-stash.txt" >&2; exit 1; }
grep -q 'pre-deploy-commit\.txt' "$DIRECTIVE" \
  || { echo "FAIL: directive doesn't reference _deploy/pre-deploy-commit.txt" >&2; exit 1; }
pass "6. directive references both pre-deploy-stash.txt and pre-deploy-commit.txt"

echo "test_deploy_dirty_intercept_directive: 6 invariants locked"
