#!/usr/bin/env bash
# tests/test_consult_wait_state_file.sh — v0.5.0 wait-script .done sentinel.
#
# Each terminal exit must:
#   1. Append `FS=<state>` (research-wait) or `VS=<state>` (verify-wait) as the
#      last line of $STATE_FILE.
#   2. Touch ${STATE_FILE%.txt}.done immediately after, before exit.
#
# We mock the outbox by feeding pre-canned JSONL into a fixture trooper dir
# and run the actual wait-script with a tiny timeout.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"
export CLONE_WARS_HOME="$SANDBOX"
export CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=2  # short for tests
PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"

# Helper: set up a trooper state dir + offset state file for research-wait.
# Echoes "<state_file>\n<outbox_path>".
setup() {
  local commander="$1" topic="$2" outbox_lines="$3"
  # shellcheck disable=SC1091
  source ../lib/log.sh
  # shellcheck disable=SC1091
  source ../lib/state.sh
  local repo_dir="$SANDBOX/state/$(cw_repo_hash)/$topic"
  mkdir -p "$repo_dir/_consult" "$repo_dir/${commander}-codex"
  local outbox="$repo_dir/${commander}-codex/outbox.jsonl"
  printf '%s' "$outbox_lines" > "$outbox"
  local state_file="$repo_dir/_consult/research-${commander}.txt"
  printf 'OFFSET=0\n' > "$state_file"
  printf '%s\n%s\n' "$state_file" "$outbox"
}

# assert_done_sentinel <state_file>
# Accepts FS= (research-wait) or VS= (verify-wait) as the terminal status line.
assert_done_sentinel() {
  local state_file="$1"
  local sentinel="${state_file%.txt}.done"
  [[ -f "$sentinel" ]] || { echo "FAIL: missing .done sentinel at $sentinel"; exit 1; }
  [[ "$(tail -1 "$state_file")" =~ ^(FS|VS)= ]] \
    || { echo "FAIL: state file last line is not FS=*/VS=*: $(tail -1 "$state_file")"; exit 1; }
}

# Case 1: done event → FS=missing (no findings.md), .done touched.
mapfile -t S < <(setup rex consult-topic-1 \
  '{"event":"ready","ts":"2026-04-30T00:00:00Z"}
{"event":"done","summary":"researched","ts":"2026-04-30T00:00:01Z"}
')
state_file="${S[0]}"
"$PLUGIN_ROOT/bin/consult-research-wait.sh" consult-topic-1 rex codex
assert_done_sentinel "$state_file"
grep -q '^FS=' "$state_file"
pass "done event → FS= written + .done sentinel touched"

# Case 2: error event → FS=failed, .done touched.
mapfile -t S < <(setup rex consult-topic-2 \
  '{"event":"ready","ts":"2026-04-30T00:00:00Z"}
{"event":"error","note":"boom","ts":"2026-04-30T00:00:01Z"}
')
state_file="${S[0]}"
"$PLUGIN_ROOT/bin/consult-research-wait.sh" consult-topic-2 rex codex
assert_done_sentinel "$state_file"
grep -q '^FS=failed$' "$state_file"
pass "error event → FS=failed + .done touched"

# Case 3: timeout (no terminal event) → FS=timeout, .done touched.
mapfile -t S < <(setup rex consult-topic-3 \
  '{"event":"ready","ts":"2026-04-30T00:00:00Z"}
')
state_file="${S[0]}"
"$PLUGIN_ROOT/bin/consult-research-wait.sh" consult-topic-3 rex codex
assert_done_sentinel "$state_file"
grep -q '^FS=timeout$' "$state_file"
pass "no terminal event → FS=timeout + .done touched"

# Case 4: question event → FS=question, .done touched, OFFSET advanced.
mapfile -t S < <(setup rex consult-topic-4 \
  '{"event":"ready","ts":"2026-04-30T00:00:00Z"}
{"event":"question","text":"async or sync?","options":["async","sync"]}
')
state_file="${S[0]}"
"$PLUGIN_ROOT/bin/consult-research-wait.sh" consult-topic-4 rex codex
assert_done_sentinel "$state_file"
grep -q '^FS=question$' "$state_file"
# Two OFFSET= lines: the original + the post-question advance.
[[ "$(grep -c '^OFFSET=' "$state_file")" -ge 2 ]] \
  || { echo "FAIL c4: expected >=2 OFFSET= lines; got $(grep -c '^OFFSET=' "$state_file")"; exit 1; }
pass "question event → FS=question + .done + OFFSET advanced"

# Case 5: malformed question payload → FS=failed (validator rejects), .done touched.
mapfile -t S < <(setup rex consult-topic-5 \
  '{"event":"ready","ts":"2026-04-30T00:00:00Z"}
{"event":"question","options":["a","b"]}
')
state_file="${S[0]}"
"$PLUGIN_ROOT/bin/consult-research-wait.sh" consult-topic-5 rex codex
assert_done_sentinel "$state_file"
grep -q '^FS=failed$' "$state_file"
pass "malformed question → FS=failed + .done touched"

# Case 6: same flow with bin/consult-verify-wait.sh (sanity).
# Set up a verify state file and outbox.
TOPIC=consult-topic-6 COMMANDER=rex MODEL=codex
# shellcheck disable=SC1091
source ../lib/state.sh
mkdir -p "$SANDBOX/state/$(cw_repo_hash)/$TOPIC/_consult"
mkdir -p "$SANDBOX/state/$(cw_repo_hash)/$TOPIC/${COMMANDER}-${MODEL}"
OUTBOX="$SANDBOX/state/$(cw_repo_hash)/$TOPIC/${COMMANDER}-${MODEL}/outbox.jsonl"
printf '%s\n' \
  '{"event":"ready","ts":"2026-04-30T00:00:00Z"}' \
  '{"event":"done","summary":"verified","ts":"2026-04-30T00:00:01Z"}' \
  > "$OUTBOX"
# Provide a non-empty verify.md so VS resolves to ok (rather than missing).
printf '# verify\nok\n' > "$SANDBOX/state/$(cw_repo_hash)/$TOPIC/${COMMANDER}-${MODEL}/verify.md"
VERIFY_STATE="$SANDBOX/state/$(cw_repo_hash)/$TOPIC/_consult/verify-${COMMANDER}.txt"
printf 'OFFSET=0\n' > "$VERIFY_STATE"
CW_CONSULT_VERIFY_TIMEOUT_OVERRIDE=2 \
  "$PLUGIN_ROOT/bin/consult-verify-wait.sh" "$TOPIC" "$COMMANDER" "$MODEL"
assert_done_sentinel "$VERIFY_STATE"
grep -q '^VS=' "$VERIFY_STATE"
pass "verify-wait done → VS= written + .done touched"

# Case 7: verify-wait skipped short-circuit → .done still touched.
TOPIC=consult-topic-7 COMMANDER=rex MODEL=codex
mkdir -p "$SANDBOX/state/$(cw_repo_hash)/$TOPIC/_consult"
mkdir -p "$SANDBOX/state/$(cw_repo_hash)/$TOPIC/${COMMANDER}-${MODEL}"
SKIP_STATE="$SANDBOX/state/$(cw_repo_hash)/$TOPIC/_consult/verify-${COMMANDER}.txt"
printf 'VS=skipped\n' > "$SKIP_STATE"
"$PLUGIN_ROOT/bin/consult-verify-wait.sh" "$TOPIC" "$COMMANDER" "$MODEL"
SKIP_DONE="${SKIP_STATE%.txt}.done"
[[ -f "$SKIP_DONE" ]] || { echo "FAIL c7: missing .done sentinel after VS=skipped short-circuit"; exit 1; }
[[ "$(tail -1 "$SKIP_STATE")" == "VS=skipped" ]] || { echo "FAIL c7: state file content drifted: $(tail -1 "$SKIP_STATE")"; exit 1; }
pass "verify-wait VS=skipped short-circuit → .done touched, state preserved"

echo "ALL PASS"
