#!/usr/bin/env bash
# tests/test_consult_wait_question_rearm.sh — v0.5.0 question→re-arm loop.
#
# Asserts:
#   1. After call 1 (question): state file ends with FS=question, has >=2
#      OFFSET= lines (original + post-question), .done sentinel exists.
#   2. Caller deletes .done sentinel (simulating background re-spawn).
#   3. New outbox content (ANSWER acknowledgement + done event) is appended.
#   4. Call 2 (re-arm): state file ends with FS=ok (or empty/missing depending
#      on findings.md), .done sentinel re-touched.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"
export CLONE_WARS_HOME="$SANDBOX"
export CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=2
PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
source ../lib/log.sh; source ../lib/state.sh

TOPIC=consult-topic-rearm
COMMANDER=rex
MODEL=codex
TROOPER_DIR="$SANDBOX/state/$(cw_repo_hash)/$TOPIC/${COMMANDER}-${MODEL}"
ART_DIR="$SANDBOX/state/$(cw_repo_hash)/$TOPIC/_consult"
mkdir -p "$TROOPER_DIR" "$ART_DIR"

OUTBOX="$TROOPER_DIR/outbox.jsonl"
STATE_FILE="$ART_DIR/research-$COMMANDER.txt"
DONE_SENTINEL="${STATE_FILE%.txt}.done"

# Phase 1: initial outbox with a question event after ready.
printf '%s\n' \
  '{"event":"ready","ts":"2026-04-30T00:00:00Z"}' \
  '{"event":"question","text":"async or sync?","options":["async","sync"]}' \
  > "$OUTBOX"
printf 'OFFSET=0\n' > "$STATE_FILE"

"$PLUGIN_ROOT/bin/consult-research-wait.sh" "$TOPIC" "$COMMANDER" "$MODEL"

# Case 1: post-call-1 invariants.
[[ "$(tail -1 "$STATE_FILE")" == "FS=question" ]] \
  || { echo "FAIL c1: tail=$(tail -1 "$STATE_FILE")"; exit 1; }
[[ "$(grep -c '^OFFSET=' "$STATE_FILE")" -eq 2 ]] \
  || { echo "FAIL c1: expected 2 OFFSET= lines; got $(grep -c '^OFFSET=' "$STATE_FILE")"; exit 1; }
[[ -f "$DONE_SENTINEL" ]] \
  || { echo "FAIL c1: missing .done"; exit 1; }
pass "call 1: FS=question, 2 OFFSET= lines, .done sentinel"

# Phase 2: simulate the directive's background re-spawn — remove .done and
# append a done event to the outbox (simulating the ANSWER nudge + trooper
# completion).
rm -f "$DONE_SENTINEL"
printf '%s\n' \
  '{"event":"progress","note":"got ANSWER","ts":"2026-04-30T00:00:02Z"}' \
  '{"event":"done","summary":"researched after answer","ts":"2026-04-30T00:00:03Z"}' \
  >> "$OUTBOX"

"$PLUGIN_ROOT/bin/consult-research-wait.sh" "$TOPIC" "$COMMANDER" "$MODEL"

# Case 2: post-call-2 invariants.
[[ "$(tail -1 "$STATE_FILE")" =~ ^FS=(ok|empty|missing)$ ]] \
  || { echo "FAIL c2: expected FS=ok|empty|missing; got $(tail -1 "$STATE_FILE")"; exit 1; }
[[ -f "$DONE_SENTINEL" ]] \
  || { echo "FAIL c2: missing .done after re-arm"; exit 1; }
pass "call 2: FS=ok-class terminal, .done re-touched"

# Case 3: state file is well-formed (no garbage, last line is FS=, all OFFSET=
# lines are numeric).
last=$(tail -1 "$STATE_FILE")
[[ "$last" =~ ^FS= ]] \
  || { echo "FAIL c3: last line not FS=: $last"; exit 1; }
while IFS= read -r line; do
  case "$line" in
    OFFSET=*[!0-9]*) echo "FAIL c3: bad OFFSET= line: $line"; exit 1 ;;
  esac
done < <(grep '^OFFSET=' "$STATE_FILE")
pass "state file well-formed after re-arm"

echo "ALL PASS"
