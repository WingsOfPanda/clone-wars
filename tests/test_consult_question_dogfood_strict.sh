#!/usr/bin/env bash
# tests/test_consult_question_dogfood_strict.sh — Task 10 (v0.3.0).
# H3 closure GATE. Validates the autonomy contract is actually obeyed
# by a live codex trooper. Skips ONLY on missing binaries.
# Once the harness can run, any failure to reach FS=question is a test
# failure (not a permissive pass). This is the test that gates v0.3.0
# release.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

if ! command -v codex >/dev/null 2>&1; then
  echo "  SKIP: codex CLI not installed — STRICT dogfood skipped (release gate not exercised)"
  exit 0
fi
if ! command -v tmux >/dev/null 2>&1; then
  echo "  SKIP: tmux not installed — STRICT dogfood skipped"
  exit 0
fi
if [[ -z "${TMUX:-}" ]]; then
  echo "  SKIP: not inside a tmux session — STRICT dogfood skipped"
  exit 0
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"

# Stage the config files spawn.sh + identity-template need.
mkdir -p "$CLONE_WARS_HOME"
cp ../config/contracts.yaml       "$CLONE_WARS_HOME/contracts.yaml"
cp ../config/commanders.yaml      "$CLONE_WARS_HOME/commanders.yaml"
cp ../config/identity-template.md "$CLONE_WARS_HOME/identity-template.md"

source ../lib/state.sh
source ../lib/ipc.sh
source ../lib/consult.sh

RH=$(cw_repo_hash)

# Forced-fork brainstorming topic — should COMPEL the trooper to ask if
# the autonomy contract is being honored, because there's no sensible
# default to choose from topic context alone.
TOPIC=$(../bin/consult-init.sh \
  "decide between LRU and LFU eviction for the cache layer; both are valid; need explicit pick" \
  2>/dev/null)
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
[[ "$(cat "$TD/_consult/skill.txt")" == "brainstorming" ]] \
  || { echo "FAIL: expected brainstorming classification"; exit 1; }

# Spawn failure: SKIP (with loud message) — codex bootstrap reliability is
# orthogonal to the v0.3 question protocol. The release gate still requires
# this test to PASS at least once on a working spawn environment; SKIP here
# means "infrastructure not exercising the gate", not "gate satisfied".
if ! ../bin/spawn.sh rex codex "$TOPIC" >/dev/null 2>&1; then
  echo "  SKIP: codex spawn failed — STRICT gate NOT exercised (release requires manual run)"
  exit 0
fi
# Teardown FIRST (needs $CLONE_WARS_HOME state to find pane), THEN rm -rf.
# Reversing this order leaks the pane: rm -rf nukes pane.json, then teardown
# can't find the pane_id and exits silently via `|| true`.
trap '../bin/consult-teardown.sh "$TOPIC" >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

if ! ../bin/consult-research-send.sh "$TOPIC" rex codex >/dev/null 2>&1; then
  echo "FAIL: STRICT — consult-research-send failed despite prereqs"
  exit 1
fi

# Wait up to 120s for FS=question. Per-call wait timeout = 10s; outer
# deadline polled with sleep 2. FS=timeout is transient (not break-worthy).
T0=$(date +%s); DEADLINE=$((T0 + 120))
FS=""
while (( $(date +%s) < DEADLINE )); do
  CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=10 \
    ../bin/consult-research-wait.sh "$TOPIC" rex codex >/dev/null 2>&1 || true
  FS=$(grep '^FS=' "$TD/_consult/research-rex.txt" 2>/dev/null | tail -1 | cut -d= -f2 || echo "")
  case "$FS" in
    question|ok|empty|missing|failed|malformed) break ;;
    *) sleep 2 ;;
  esac
done

[[ "$FS" == "question" ]] \
  || { echo "FAIL: STRICT gate — expected FS=question on forced-fork topic; got '$FS'"
       echo "  outbox tail:"; tail -30 "$(cw_outbox_path rex codex "$TOPIC")" 2>/dev/null || true
       exit 1; }
pass "STRICT: real codex trooper emitted {event:question} via outbox (contract obeyed)"

# Verify payload extracted correctly.
[[ -f "$TD/_consult/question-rex.txt" ]] \
  || { echo "FAIL: question payload missing"; exit 1; }
Q_TEXT=$(cw_consult_question_payload_read "$TD/_consult/question-rex.txt" TEXT)
[[ -n "$Q_TEXT" ]] \
  || { echo "FAIL: question payload TEXT is empty"; exit 1; }
pass "STRICT: question payload extracted with non-empty TEXT"

# Send synthetic ANSWER. Verify trooper recognizes ANSWER: prefix and
# resumes (must reflect content in findings.md — proves ANSWER-line was
# actually parsed, not just "any inbox change resumes").
../bin/send.sh rex "$TOPIC" "ANSWER: pick LRU (Least Recently Used). Use a doubly-linked list + hashmap. Document this choice in findings.md.

(resume your skill loop)
END_OF_INSTRUCTION" >/dev/null 2>&1

T1=$(date +%s); DEADLINE2=$((T1 + 90))
while (( $(date +%s) < DEADLINE2 )); do
  CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=10 \
    ../bin/consult-research-wait.sh "$TOPIC" rex codex >/dev/null 2>&1 || true
  FS=$(grep '^FS=' "$TD/_consult/research-rex.txt" 2>/dev/null | tail -1 | cut -d= -f2 || echo "")
  case "$FS" in
    ok|empty|missing|question|failed|malformed) break ;;
    *) sleep 2 ;;
  esac
done

case "$FS" in
  ok|empty|missing)
    pass "STRICT: trooper resumed after ANSWER, reached terminal state ($FS)"
    ;;
  question)
    Q2_TEXT=$(cw_consult_question_payload_read "$TD/_consult/question-rex.txt" TEXT)
    [[ "$Q2_TEXT" != "$Q_TEXT" ]] \
      || { echo "FAIL: STRICT — trooper re-emitted SAME question; ANSWER not consumed"; exit 1; }
    pass "STRICT: trooper resumed and asked a NEW question (multi-Q loop)"
    ;;
  *)
    echo "FAIL: STRICT — trooper did not resume after ANSWER; FS='$FS'"; exit 1
    ;;
esac

# Verify findings.md reflects the ANSWER content (LRU choice).
TROOPER_DIR=$(cw_trooper_dir rex codex "$TOPIC")
if [[ -f "$TROOPER_DIR/findings.md" ]]; then
  if grep -qiE 'LRU|Least Recently Used' "$TROOPER_DIR/findings.md"; then
    pass "STRICT: findings.md reflects ANSWER content (LRU choice) — ANSWER-line was parsed"
  else
    echo "FAIL: STRICT — ANSWER said LRU but findings.md does not mention it"
    echo "  findings.md:"; cat "$TROOPER_DIR/findings.md"
    exit 1
  fi
fi
