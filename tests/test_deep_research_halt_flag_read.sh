#!/usr/bin/env bash
# tests/test_deep_research_halt_flag_read.sh — v0.48 finding #1+#2
# Locks the contract of cw_deep_research_halt_flag_read in lib/deep-research.sh.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/lib/state.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/lib/consult.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/lib/deep-research.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# Case 1: structured halt.flag — newlines preserved, format=structured emitted first
cat >"$SANDBOX/halt-structured.flag" <<'EOF'
halted_by=yoda
halted_at=2026-05-20T06:24:10Z
reason=cross-family convergence at no-search ceiling
target_met=no
plateau=yes
plateau_observed_n=3
EOF
out=$(cw_deep_research_halt_flag_read "$SANDBOX/halt-structured.flag")
assert_contains "$out" "format=structured" "structured: format key"
assert_contains "$out" "halted_by=yoda" "structured: halted_by preserved"
assert_contains "$out" "reason=cross-family convergence at no-search ceiling" "structured: reason preserved verbatim"
assert_contains "$out" "plateau_observed_n=3" "structured: optional key preserved"
# Newlines preserved: count lines (format= + 6 fields = 7)
line_count=$(printf '%s\n' "$out" | wc -l)
assert_eq "$line_count" "7" "structured: 7 lines emitted (format + 6 fields)"
pass "1. structured halt.flag parsed with newlines preserved"

# Case 2: prose halt.flag (legacy pre-v0.43) — wrapped as format=prose + reason=<text>
cat >"$SANDBOX/halt-prose.flag" <<'EOF'
yoda-halted at 16:15:34Z: target met across 3 independent Q-network runs at 0.967+ WDL.
EOF
out=$(cw_deep_research_halt_flag_read "$SANDBOX/halt-prose.flag")
assert_contains "$out" "format=prose" "prose: format key"
assert_contains "$out" "reason=yoda-halted at 16:15:34Z: target met" "prose: reason carries body"
pass "2. legacy prose halt.flag wrapped as format=prose + reason"

# Case 3: missing halt.flag
out=$(cw_deep_research_halt_flag_read "$SANDBOX/halt-missing.flag")
assert_eq "$out" "format=missing" "missing: format=missing only"
pass "3. missing halt.flag emits format=missing"

# Case 4: empty halt.flag
: >"$SANDBOX/halt-empty.flag"
out=$(cw_deep_research_halt_flag_read "$SANDBOX/halt-empty.flag")
assert_eq "$out" "format=missing" "empty: treated as missing"
pass "4. empty halt.flag emits format=missing"

# Case 5: structured halt with multi-line reason (literal \n in value)
cat >"$SANDBOX/halt-multiline.flag" <<'EOF'
halted_by=user
halted_at=2026-05-20T08:00:00Z
reason=user pressed ctrl-c
final_leader=rex/exp-005
EOF
out=$(cw_deep_research_halt_flag_read "$SANDBOX/halt-multiline.flag")
assert_contains "$out" "format=structured" "multiline: format key"
assert_contains "$out" "reason=user pressed ctrl-c" "multiline: reason line intact"
assert_contains "$out" "final_leader=rex/exp-005" "multiline: trailing field preserved"
pass "5. structured halt with all required + optional keys"

echo "test_deep_research_halt_flag_read: 5 cases passed"
