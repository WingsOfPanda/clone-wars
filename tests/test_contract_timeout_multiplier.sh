#!/usr/bin/env bash
# v0.35.0 Layer A — cw_contract_timeout_multiplier returns per-provider value
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP"

source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/contracts.sh"

# Synthesize a contracts.yaml with mixed providers
cat > "$TMP/contracts.yaml" <<'EOF'
codex:
  binary: codex
  default_mode: full
  ready_timeout_s: 90
  bootstrap_sleep_s: 20

opencode:
  binary: opencode
  default_mode: full
  ready_timeout_s: 60
  bootstrap_sleep_s: 15
  timeout_multiplier: 2.5

claude:
  binary: claude
  default_mode: full
  ready_timeout_s: 60
  bootstrap_sleep_s: 12

bogus:
  binary: bogus
  timeout_multiplier: not-a-number

zero:
  binary: zero
  timeout_multiplier: 0

decimal:
  binary: decimal
  timeout_multiplier: 1.5
EOF

# Case 1: codex (no field) → 1.0
out=$(cw_contract_timeout_multiplier codex)
assert_eq "$out" "1.0" "case 1: codex default 1.0 when field absent"
pass "1. codex defaults to 1.0"

# Case 2: opencode → 2.5
out=$(cw_contract_timeout_multiplier opencode)
assert_eq "$out" "2.5" "case 2: opencode reads 2.5"
pass "2. opencode reads 2.5"

# Case 3: claude (no field) → 1.0
out=$(cw_contract_timeout_multiplier claude)
assert_eq "$out" "1.0" "case 3: claude default 1.0"
pass "3. claude defaults to 1.0"

# Case 4: malformed value → 1.0
out=$(cw_contract_timeout_multiplier bogus)
assert_eq "$out" "1.0" "case 4a: malformed string falls back to 1.0"
out=$(cw_contract_timeout_multiplier zero)
assert_eq "$out" "1.0" "case 4b: zero falls back to 1.0"
pass "4. malformed/zero falls back to 1.0"

# Case 5: decimal accepted
out=$(cw_contract_timeout_multiplier decimal)
assert_eq "$out" "1.5" "case 5: 1.5 accepted as decimal"
pass "5. decimal multiplier accepted"

echo "test_contract_timeout_multiplier: 5 cases passed"
