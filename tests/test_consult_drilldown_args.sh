#!/usr/bin/env bash
# tests/test_consult_drilldown_args.sh — v0.20.2 arg-validation unit tests
# for bin/consult-drilldown.sh after the design-doc-path positional arg
# was inserted at position 5 (was: synthesis.md auto-derived from topic).
#
# Live drill-down (which sends to a real trooper pane and waits for a done
# event) is exercised in the end-to-end consult dogfood; this test covers
# only the early arg-validation paths so we catch regressions in the
# CLI contract without spinning up tmux.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"
export CLONE_WARS_HOME="$SANDBOX"

DRILL="$CLAUDE_PLUGIN_ROOT/bin/consult-drilldown.sh"
[[ -x "$DRILL" ]] || { echo "FAIL: $DRILL not executable"; exit 1; }

# Stub design-doc file so cases past arg validation don't fail on
# "design-doc not found".
DD_FILE="$SANDBOX/dd.md"
echo "stub design doc" > "$DD_FILE"

# Case 1: no args → rc=2 + usage to stderr.
err=$(bash "$DRILL" 2>&1 >/dev/null) && { echo "FAIL c1: expected rc!=0"; exit 1; }
[[ "$err" == *"Usage:"* ]] || { echo "FAIL c1 stderr: $err"; exit 1; }
pass "no args → rc=2 + usage"

# Case 2: invalid arg counts.
# Valid shapes (v0.20.2): 7 (single, no subproject), 8 (single + subproject),
# 9 (both, no subproject), 10 (both + subproject). Anything else → rc=2.
for n in 6 11; do
  args=()
  for ((i=1;i<=n;i++)); do args+=("t$i"); done
  if bash "$DRILL" "${args[@]}" 2>/dev/null; then
    echo "FAIL c2: expected rc=2 on $n args"; exit 1
  fi
done
pass "invalid arg counts (6, 11) → rc=2"

# Case 3: invalid topic → rc=2 with topic-validation message.
mkdir -p "$SANDBOX/dd"
err=$(bash "$DRILL" "Bad Topic" "Title" "$SANDBOX/dd" "focus" "$DD_FILE" rex codex 2>&1 >/dev/null) && {
  echo "FAIL c3: expected rc!=0"; exit 1
}
[[ "$err" == *"invalid topic"* ]] || { echo "FAIL c3 stderr: $err"; exit 1; }
pass "invalid topic → rc=2 + 'invalid topic' message"

# Case 4: missing dd_dir → rc=2.
err=$(bash "$DRILL" consult-foo "Title" "$SANDBOX/nonexistent-dd" "focus" "$DD_FILE" rex codex 2>&1 >/dev/null) && {
  echo "FAIL c4: expected rc!=0"; exit 1
}
[[ "$err" == *"dd_dir not found"* ]] || { echo "FAIL c4 stderr: $err"; exit 1; }
pass "missing dd_dir → rc=2 + 'dd_dir not found' message"

# Case 5: missing design-doc → rc=2 (replaces v0.5.3's synthesis.md check).
err=$(bash "$DRILL" consult-foo "Title" "$SANDBOX/dd" "focus" "$SANDBOX/no-such-dd.md" rex codex 2>&1 >/dev/null) && {
  echo "FAIL c5: expected rc!=0"; exit 1
}
[[ "$err" == *"design-doc not found"* ]] || { echo "FAIL c5 stderr: $err"; exit 1; }
pass "missing design-doc → rc=2 + 'design-doc not found' message"

# Case 6: 7 args is accepted (single-trooper) — fails later because send.sh
# can't find a real trooper, but arg-count check passes.
err=$(bash "$DRILL" consult-foo "Title" "$SANDBOX/dd" "focus" "$DD_FILE" rex codex 2>&1 >/dev/null) || true
# Should NOT contain the usage line (means we passed arg validation)
[[ "$err" != *"Usage:"* ]] || { echo "FAIL c6: arg validation rejected 7-arg call"; exit 1; }
pass "7 args (single trooper) passes arg validation"

# Case 7: 9 args is accepted (both troopers) — same fate as c6.
err=$(bash "$DRILL" consult-foo "Title" "$SANDBOX/dd" "focus" "$DD_FILE" rex codex cody claude 2>&1 >/dev/null) || true
[[ "$err" != *"Usage:"* ]] || { echo "FAIL c7: arg validation rejected 9-arg call"; exit 1; }
pass "9 args (both troopers) passes arg validation"

# Case 8: 8 args (single trooper + sub-project) passes arg validation.
# Use invalid topic to fail fast before send.sh is reached, so we observe
# arg-count acceptance via "no Usage: line" + "invalid topic" message.
err=$(bash "$DRILL" "Bad Topic" "Title" "$SANDBOX/dd" "focus" "$DD_FILE" rex codex backend 2>&1 >/dev/null) || true
[[ "$err" != *"Usage:"* ]] || { echo "FAIL c8: arg validation rejected 8-arg call"; exit 1; }
[[ "$err" == *"invalid topic"* ]] || { echo "FAIL c8 stderr: $err"; exit 1; }
pass "8 args (single trooper + sub-project) passes arg validation"

# Case 9: 10 args (both troopers + sub-project) passes arg validation. Same
# fast-fail trick via invalid topic.
err=$(bash "$DRILL" "Bad Topic" "Title" "$SANDBOX/dd" "focus" "$DD_FILE" rex codex cody claude backend 2>&1 >/dev/null) || true
[[ "$err" != *"Usage:"* ]] || { echo "FAIL c9: arg validation rejected 10-arg call"; exit 1; }
[[ "$err" == *"invalid topic"* ]] || { echo "FAIL c9 stderr: $err"; exit 1; }
pass "10 args (both troopers + sub-project) passes arg validation"

echo "ALL PASS"
