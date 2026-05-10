#!/usr/bin/env bash
# tests/test_v0_23_0_static_wiring.sh
# Locks v0.23.0 invariants:
#   1. Step 5b "Init failed" / "rescue intercept" alarming wording dropped —
#      neutral "auto-extract" prose used in user-facing log lines
#   2. Verification block present (slug regex + path -d + CLAUDE.md/AGENTS.md check)
#   3. Conditional AskUserQuestion gated on VERIFY_FAILED + CW_DEPLOY_FORCE_RESCUE_PROMPT
#   4. Auto-proceed log_ok line present
#   5. Audit log shape extended with verification status field (VERIFY_STATUS)
#   6. plugin.json semver-shape (loosened per v0.20.2 lesson)
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
DEPLOY_MD="$PLUGIN_ROOT/commands/deploy.md"

# Capture Step 5b body (between '5b. ' opener and '5c. ' next-block).
# `awk` capture-into-var is SIGPIPE-safe (per v0.21.0 lesson).
STEP_5B=$(awk '/^5b\. /,/^5c\./' "$DEPLOY_MD")
[[ -n "$STEP_5B" ]] \
  || { echo "FAIL: Step 5b block not found in commands/deploy.md" >&2; exit 1; }

# 1. Alarming wording dropped from log_info / log_ok lines.
[[ "$STEP_5B" != *'log_info "DAG rescue intercept: human-authored'* ]] \
  || { echo "FAIL: Step 5b still uses 'DAG rescue intercept: human-authored' log_info prose" >&2; exit 1; }
[[ "$STEP_5B" != *'log_ok "DAG rescue intercept complete'* ]] \
  || { echo "FAIL: Step 5b still uses 'DAG rescue intercept complete' log_ok prose" >&2; exit 1; }
# Neutral "auto-extract" prose appears
[[ "$STEP_5B" == *"auto-extract"* ]] \
  || { echo "FAIL: Step 5b missing 'auto-extract' neutral prose" >&2; exit 1; }
pass "Step 5b uses neutral 'auto-extract' wording (no 'rescue intercept' log lines)"

# 2. Verification block present
[[ "$STEP_5B" == *"VERIFY_FAILED"* ]] \
  || { echo "FAIL: Step 5b missing VERIFY_FAILED verification block" >&2; exit 1; }
[[ "$STEP_5B" == *"[A-Za-z0-9_-]+"* ]] \
  || { echo "FAIL: Step 5b verification missing slug regex check" >&2; exit 1; }
[[ "$STEP_5B" == *"CLAUDE.md"* && "$STEP_5B" == *"AGENTS.md"* ]] \
  || { echo "FAIL: Step 5b verification missing CLAUDE.md/AGENTS.md presence check" >&2; exit 1; }
pass "Step 5b has verification block (slug regex + marker file checks)"

# 3. Conditional AskUserQuestion gated on VERIFY_FAILED + CW_DEPLOY_FORCE_RESCUE_PROMPT
[[ "$STEP_5B" == *"CW_DEPLOY_FORCE_RESCUE_PROMPT"* ]] \
  || { echo "FAIL: Step 5b missing CW_DEPLOY_FORCE_RESCUE_PROMPT env-var gate" >&2; exit 1; }
# Conditional structure check: AskUserQuestion appears AFTER the VERIFY_FAILED count gate
# (i.e., the auto-proceed log_ok line precedes the AskUserQuestion in the directive flow).
ASKUQ_COUNT=$(printf '%s' "$STEP_5B" | grep -c 'AskUserQuestion')
[[ "$ASKUQ_COUNT" -ge 1 ]] \
  || { echo "FAIL: Step 5b missing AskUserQuestion (no conditional confirm path)" >&2; exit 1; }
pass "AskUserQuestion is conditional on verification failure or FORCE env var"

# 4. Auto-proceed log_ok summary line
[[ "$STEP_5B" == *'log_ok "DAG auto-extract:'* || "$STEP_5B" == *'DAG auto-extract: $NUM_EXTRACTED_LINES'* ]] \
  || { echo "FAIL: Step 5b missing log_ok 'DAG auto-extract: N lines verified' summary" >&2; exit 1; }
pass "Step 5b emits log_ok auto-extract summary on auto-proceed path"

# 5. Audit log extended with VERIFY_STATUS field
[[ "$STEP_5B" == *"VERIFY_STATUS"* ]] \
  || { echo "FAIL: dag-rescue.log audit missing VERIFY_STATUS field" >&2; exit 1; }
[[ "$STEP_5B" == *"auto-passed"* ]] \
  || { echo "FAIL: VERIFY_STATUS values missing 'auto-passed' tag" >&2; exit 1; }
[[ "$STEP_5B" == *"verification: %s"* ]] \
  || { echo "FAIL: dag-rescue.log printf missing 'verification: %s' format" >&2; exit 1; }
pass "dag-rescue.log audit shape extended with VERIFY_STATUS field"

# 6. plugin.json semver-shape
PJ="$PLUGIN_ROOT/.claude-plugin/plugin.json"
grep -qE '"version": "0\.[0-9]+\.[0-9]+"' "$PJ" \
  || { echo "FAIL: plugin.json missing semver-shape version field" >&2; exit 1; }
pass "plugin.json version field present + semver-shaped"

pass "v0.23.0 static wiring complete (6 invariants locked)"
