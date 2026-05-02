#!/usr/bin/env bash
# tests/test_consult_drilldown_args.sh — v0.5.3 arg-validation unit tests
# for bin/consult-drilldown.sh.
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

# Case 1: no args → rc=2 + usage to stderr.
err=$(bash "$DRILL" 2>&1 >/dev/null) && { echo "FAIL c1: expected rc!=0"; exit 1; }
[[ "$err" == *"Usage:"* ]] || { echo "FAIL c1 stderr: $err"; exit 1; }
pass "no args → rc=2 + usage"

# Case 2: 7 args (between single-trooper-6 and both-trooper-8) → rc=2.
if bash "$DRILL" t1 t2 t3 t4 t5 t6 t7 2>/dev/null; then
  echo "FAIL c2: expected rc=2 on 7 args"; exit 1
fi
pass "7 args (between valid 6 and 8) → rc=2"

# Case 3: invalid topic → rc=2 with topic-validation message.
mkdir -p "$SANDBOX/dd"
err=$(bash "$DRILL" "Bad Topic" "Title" "$SANDBOX/dd" "focus" rex codex 2>&1 >/dev/null) && {
  echo "FAIL c3: expected rc!=0"; exit 1
}
[[ "$err" == *"invalid topic"* ]] || { echo "FAIL c3 stderr: $err"; exit 1; }
pass "invalid topic → rc=2 + 'invalid topic' message"

# Case 4: missing dd_dir → rc=2.
err=$(bash "$DRILL" consult-foo "Title" "$SANDBOX/nonexistent-dd" "focus" rex codex 2>&1 >/dev/null) && {
  echo "FAIL c4: expected rc!=0"; exit 1
}
[[ "$err" == *"dd_dir not found"* ]] || { echo "FAIL c4 stderr: $err"; exit 1; }
pass "missing dd_dir → rc=2 + 'dd_dir not found' message"

# Case 5: missing synthesis.md → rc=2.
mkdir -p "$SANDBOX/dd"
TOPIC=consult-foo
mkdir -p "$SANDBOX/state/$(bash -c "source $CLAUDE_PLUGIN_ROOT/lib/state.sh; cw_repo_hash")/$TOPIC/_consult"
err=$(bash "$DRILL" "$TOPIC" "Title" "$SANDBOX/dd" "focus" rex codex 2>&1 >/dev/null) && {
  echo "FAIL c5: expected rc!=0"; exit 1
}
[[ "$err" == *"synthesis.md not found"* ]] || { echo "FAIL c5 stderr: $err"; exit 1; }
pass "missing synthesis.md → rc=2 + 'synthesis.md not found' message"

# Case 6: 6 args is accepted (single-trooper) — fails later because send.sh
# can't find a real trooper, but arg-count check passes.
RH=$(bash -c "source $CLAUDE_PLUGIN_ROOT/lib/state.sh; cw_repo_hash")
mkdir -p "$SANDBOX/state/$RH/$TOPIC/_consult"
echo "stub" > "$SANDBOX/state/$RH/$TOPIC/_consult/synthesis.md"
err=$(bash "$DRILL" "$TOPIC" "Title" "$SANDBOX/dd" "focus" rex codex 2>&1 >/dev/null) || true
# Should NOT contain the usage line (means we passed arg validation)
[[ "$err" != *"Usage:"* ]] || { echo "FAIL c6: arg validation rejected 6-arg call"; exit 1; }
pass "6 args (single trooper) passes arg validation"

# Case 7: 8 args is accepted (both troopers) — same fate as c6.
err=$(bash "$DRILL" "$TOPIC" "Title" "$SANDBOX/dd" "focus" rex codex cody claude 2>&1 >/dev/null) || true
[[ "$err" != *"Usage:"* ]] || { echo "FAIL c7: arg validation rejected 8-arg call"; exit 1; }
pass "8 args (both troopers) passes arg validation"

echo "ALL PASS"
