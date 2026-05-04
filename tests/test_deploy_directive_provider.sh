#!/usr/bin/env bash
# tests/test_deploy_directive_provider.sh — static-wiring assertions
# for the v0.9 auto-provider directive flow. The directive's
# AskUserQuestion can't be exercised from a shell test; this catches
# the mechanical wiring (file refs, spawn variable usage).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

D=../commands/deploy.md

# Auto file is read.
grep -q 'auto_provider.txt' "$D" \
  || { echo "FAIL: directive must reference auto_provider.txt" >&2; exit 1; }
pass "directive reads auto_provider.txt"

# Final-choice file is written + read.
grep -q 'provider.txt' "$D" \
  || { echo "FAIL: directive must reference provider.txt (final choice)" >&2; exit 1; }
pass "directive writes/reads provider.txt"

# AskUserQuestion appears near the provider block (within ~40 lines of auto_provider.txt).
auto_line=$(grep -n 'auto_provider.txt' "$D" | head -1 | cut -d: -f1)
ask_after=$(awk -v start="$auto_line" -v end="$((auto_line + 40))" \
  'NR>=start && NR<=end && /AskUserQuestion/ {print NR; exit}' "$D")
[[ -n "$ask_after" ]] \
  || { echo "FAIL: AskUserQuestion not found within 40 lines of auto_provider.txt read" >&2; exit 1; }
pass "directive asks user when claude is auto-detected"

# Spawn uses $PROVIDER, not hardcoded codex.
grep -qE 'spawn\.sh.*cody.*"?\$PROVIDER"?\b|spawn\.sh.*cody.*"\$\{PROVIDER\}"' "$D" \
  || { echo "FAIL: Step 1.1 spawn line must use \$PROVIDER variable" >&2; exit 1; }
pass "directive's spawn line uses \$PROVIDER variable"

# No leftover hard-coded codex in the spawn line (matches the literal command form,
# allowing matches inside the new provider-resolve block's prose).
if grep -qE '^\s*"\$CLAUDE_PLUGIN_ROOT/bin/spawn\.sh" cody codex ' "$D"; then
  echo "FAIL: leftover hard-coded 'spawn.sh cody codex' line in directive" >&2; exit 1
fi
pass "no leftover hard-coded 'cody codex' spawn line"

echo "ALL: ok"
