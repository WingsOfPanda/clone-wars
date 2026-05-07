#!/usr/bin/env bash
# tests/test_consult_question_event_priority.sh — Task 6 (v0.3.0).
# H2 closure: wait-script must branch on the actual matched event, with
# terminal-event precedence (done/error WIN over question) and head -n1
# semantics for question (serialization across re-arms).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"

# v0.15.0: pre-write providers-available.txt fixture (N=2: claude+codex).
mkdir -p "$CLONE_WARS_HOME"
cat > "$CLONE_WARS_HOME/providers-available.txt" <<'EOF'
# fixture
codex
claude
EOF

source ../lib/state.sh
source ../lib/consult.sh
RH=$(cw_repo_hash)

stage_topic() {
  local topic; topic=$(../bin/consult-init.sh "$1" 2>/dev/null)
  local td="$CLONE_WARS_HOME/state/$RH/$topic"
  mkdir -p "$td/rex-codex"
  printf '%s' "$td"
}

# Case 1: question THEN error → terminal precedence; FS=failed, no payload.
TD=$(stage_topic "case1 q-then-error")
OUTBOX="$TD/rex-codex/outbox.jsonl"
echo '{"event":"ack"}'                                            >> "$OUTBOX"
OFFSET=$(wc -c < "$OUTBOX" | tr -d ' ')
echo '{"event":"question","text":"x","options":[]}'                >> "$OUTBOX"
echo '{"event":"error","text":"trooper died"}'                    >> "$OUTBOX"
TOPIC=$(basename "$TD")
printf 'OFFSET=%s\n' "$OFFSET" > "$TD/_consult/research-rex.txt"
CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=5 \
  ../bin/consult-research-wait.sh "$TOPIC" rex codex >/dev/null 2>&1
FS=$(grep '^FS=' "$TD/_consult/research-rex.txt" | tail -1 | cut -d= -f2)
[[ "$FS" == "failed" ]] \
  || { echo "FAIL case1: expected FS=failed when error follows question; got '$FS'"; exit 1; }
[[ ! -f "$TD/_consult/question-rex.txt" ]] \
  || { echo "FAIL case1: payload should NOT be written when terminal event is error"; exit 1; }
pass "case 1 (question→error): FS=failed, no payload"

# Case 2: question THEN done → terminal precedence; FS depends on findings.md.
TD=$(stage_topic "case2 q-then-done")
OUTBOX="$TD/rex-codex/outbox.jsonl"
echo '{"event":"ack"}'                              >> "$OUTBOX"
OFFSET=$(wc -c < "$OUTBOX" | tr -d ' ')
echo '{"event":"question","text":"x","options":[]}' >> "$OUTBOX"
echo '{"event":"done"}'                             >> "$OUTBOX"
cat > "$TD/rex-codex/findings.md" <<'F'
## Claims
1. [src/x.py:1] sample claim
F
TOPIC=$(basename "$TD")
printf 'OFFSET=%s\n' "$OFFSET" > "$TD/_consult/research-rex.txt"
CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=5 \
  ../bin/consult-research-wait.sh "$TOPIC" rex codex >/dev/null 2>&1
FS=$(grep '^FS=' "$TD/_consult/research-rex.txt" | tail -1 | cut -d= -f2)
[[ "$FS" == "ok" ]] \
  || { echo "FAIL case2: expected FS=ok when done follows question; got '$FS'"; exit 1; }
pass "case 2 (question→done): FS=ok (terminal done wins over earlier question)"

# Case 3: only question → FS=question, OFFSET advances past it.
TD=$(stage_topic "case3 question-only")
OUTBOX="$TD/rex-codex/outbox.jsonl"
echo '{"event":"ack"}'                              >> "$OUTBOX"
OFFSET=$(wc -c < "$OUTBOX" | tr -d ' ')
echo '{"event":"question","text":"sync or async?","options":["sync","async"]}' >> "$OUTBOX"
EXPECTED_END=$(wc -c < "$OUTBOX" | tr -d ' ')
TOPIC=$(basename "$TD")
printf 'OFFSET=%s\n' "$OFFSET" > "$TD/_consult/research-rex.txt"
CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=5 \
  ../bin/consult-research-wait.sh "$TOPIC" rex codex >/dev/null 2>&1
FS=$(grep '^FS=' "$TD/_consult/research-rex.txt" | tail -1 | cut -d= -f2)
[[ "$FS" == "question" ]] || { echo "FAIL case3: expected FS=question; got '$FS'"; exit 1; }
NEW_OFF=$(grep '^OFFSET=' "$TD/_consult/research-rex.txt" | tail -1 | cut -d= -f2)
[[ "$NEW_OFF" == "$EXPECTED_END" ]] \
  || { echo "FAIL case3: OFFSET=$NEW_OFF should equal end-of-question=$EXPECTED_END"; exit 1; }
pass "case 3 (question only): FS=question + OFFSET advances past question"

# Case 4: malformed question (missing text) → FS=failed, no payload.
TD=$(stage_topic "case4 malformed-q")
OUTBOX="$TD/rex-codex/outbox.jsonl"
echo '{"event":"ack"}'                                  >> "$OUTBOX"
OFFSET=$(wc -c < "$OUTBOX" | tr -d ' ')
echo '{"event":"question","options":["x"]}'              >> "$OUTBOX"
TOPIC=$(basename "$TD")
printf 'OFFSET=%s\n' "$OFFSET" > "$TD/_consult/research-rex.txt"
CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=5 \
  ../bin/consult-research-wait.sh "$TOPIC" rex codex >/dev/null 2>&1
FS=$(grep '^FS=' "$TD/_consult/research-rex.txt" | tail -1 | cut -d= -f2)
[[ "$FS" == "failed" ]] \
  || { echo "FAIL case4: malformed question should FS=failed; got '$FS'"; exit 1; }
[[ ! -f "$TD/_consult/question-rex.txt" ]] \
  || { echo "FAIL case4: malformed question should not write payload"; exit 1; }
pass "case 4 (malformed question): FS=failed, no payload"

# Case 5: q1+q2 only — first wins, OFFSET points BEFORE q2.
TD=$(stage_topic "case5 q-q-no-done")
OUTBOX="$TD/rex-codex/outbox.jsonl"
echo '{"event":"ack"}'                                            >> "$OUTBOX"
OFFSET=$(wc -c < "$OUTBOX" | tr -d ' ')
echo '{"event":"question","text":"Q1?","options":[]}'              >> "$OUTBOX"
END_OF_Q1=$(wc -c < "$OUTBOX" | tr -d ' ')
echo '{"event":"question","text":"Q2?","options":[]}'              >> "$OUTBOX"
TOPIC=$(basename "$TD")
printf 'OFFSET=%s\n' "$OFFSET" > "$TD/_consult/research-rex.txt"
CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=5 \
  ../bin/consult-research-wait.sh "$TOPIC" rex codex >/dev/null 2>&1
FS=$(grep '^FS=' "$TD/_consult/research-rex.txt" | tail -1 | cut -d= -f2)
[[ "$FS" == "question" ]] \
  || { echo "FAIL case5: expected FS=question on multi-question; got $FS"; exit 1; }
NEW_OFF=$(grep '^OFFSET=' "$TD/_consult/research-rex.txt" | tail -1 | cut -d= -f2)
[[ "$NEW_OFF" == "$END_OF_Q1" ]] \
  || { echo "FAIL case5: NEW_OFFSET=$NEW_OFF should equal end-of-Q1=$END_OF_Q1 (NOT past Q2)"; exit 1; }
Q_TEXT=$(cw_consult_question_payload_read "$TD/_consult/question-rex.txt" TEXT)
[[ "$Q_TEXT" == "Q1?" ]] \
  || { echo "FAIL case5: should have Q1 payload (FIRST question); got '$Q_TEXT'"; exit 1; }
pass "case 5 (serialization+race): caught Q1, OFFSET points BEFORE Q2"

# Case 5b: re-run wait-script — should now catch Q2.
CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=5 \
  ../bin/consult-research-wait.sh "$TOPIC" rex codex >/dev/null 2>&1
Q_TEXT2=$(cw_consult_question_payload_read "$TD/_consult/question-rex.txt" TEXT)
[[ "$Q_TEXT2" == "Q2?" ]] \
  || { echo "FAIL case5b: re-run should catch Q2; got '$Q_TEXT2'"; exit 1; }
pass "case 5b: re-run wait catches Q2 — questions truly serialized"

# Case 6: question + done — terminal wins, no payload.
TD=$(stage_topic "case6 q-done-priority")
OUTBOX="$TD/rex-codex/outbox.jsonl"
echo '{"event":"ack"}'                                            >> "$OUTBOX"
OFFSET=$(wc -c < "$OUTBOX" | tr -d ' ')
echo '{"event":"question","text":"abandoned Q","options":[]}'      >> "$OUTBOX"
echo '{"event":"done"}'                                            >> "$OUTBOX"
cat > "$TD/rex-codex/findings.md" <<'F'
## Claims
1. [src/x.py:1] x
F
TOPIC=$(basename "$TD")
printf 'OFFSET=%s\n' "$OFFSET" > "$TD/_consult/research-rex.txt"
CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=5 \
  ../bin/consult-research-wait.sh "$TOPIC" rex codex >/dev/null 2>&1
FS=$(grep '^FS=' "$TD/_consult/research-rex.txt" | tail -1 | cut -d= -f2)
[[ "$FS" == "ok" ]] \
  || { echo "FAIL case6: terminal done should win over abandoned question; got FS=$FS"; exit 1; }
[[ ! -f "$TD/_consult/question-rex.txt" ]] \
  || { echo "FAIL case6: abandoned question payload should not be written"; exit 1; }
pass "case 6 (priority): terminal done wins over in-flight question"
