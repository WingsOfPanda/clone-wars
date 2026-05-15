#!/usr/bin/env bash
# tests/test_deep_research_init_time_budget_flag.sh — v0.32.0 #23 (half)
# Locks: bin/deep-research-init.sh accepts --time-budget=<value>; writes
# time-budget.txt with the resolved seconds (or 'none'); accepts Nh, Ns,
# and raw integer forms; rejects garbage with rc=2; also writes
# session-start.txt when the flag is present.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
SANDBOX=$(mktemp -d)
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"
mkdir -p "$CLONE_WARS_HOME"
# init.sh refuses without codex provider — seed providers-available.txt
echo codex > "$CLONE_WARS_HOME/providers-available.txt"
trap 'rm -rf "$SANDBOX"' EXIT

source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"

assert_budget() {
  local val="$1" expected="$2" label="$3"
  local out
  out=$( cd "$SANDBOX" \
    && "$PLUGIN_ROOT/bin/deep-research-init.sh" --time-budget="$val" "tb $label test topic" )
  local topic="$out"
  local repo_hash; repo_hash=$(cd "$SANDBOX" && cw_repo_hash)
  local art="$CLONE_WARS_HOME/state/$repo_hash/$topic/_deep-research"
  assert_file_exists "$art/time-budget.txt" "time-budget.txt written for $label"
  local actual; actual=$(<"$art/time-budget.txt")
  actual="${actual//[[:space:]]/}"
  assert_eq "$actual" "$expected" "$label: time-budget.txt content"
  assert_file_exists "$art/session-start.txt" "session-start.txt written for $label"
}

assert_budget "none" "none" "none"
pass "1. --time-budget=none → 'none'"

assert_budget "4h"   "14400" "4h"
pass "2. --time-budget=4h → 14400"

assert_budget "12h"  "43200" "12h"
pass "3. --time-budget=12h → 43200"

assert_budget "14400" "14400" "raw-int"
pass "4. --time-budget=14400 → 14400"

# Invalid → rc=2
set +e
( cd "$SANDBOX" \
  && "$PLUGIN_ROOT/bin/deep-research-init.sh" --time-budget=bogus "invalid topic" 2>"$SANDBOX/err.txt" )
rc=$?
set -e
[[ "$rc" == "2" ]] || { echo "FAIL: invalid --time-budget should rc=2, got $rc; stderr:" >&2; cat "$SANDBOX/err.txt" >&2; exit 1; }
pass "5. --time-budget=bogus → rc=2"

echo "test_deep_research_init_time_budget_flag: 5 cases passed"
