#!/usr/bin/env bash
# tests/test_consult_question_loop.sh — Task 9 (v0.3.0).
# End-to-end mock round-trip: question caught → simulated cw_send →
# wait-script re-runs (no offset-reset, no send-script) → FS=ok.
# Also covers multi-question loop.
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
TOPIC=$(../bin/consult-init.sh "design pattern for cache eviction" 2>/dev/null)
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"

# init wrote skill=brainstorming?
assert_eq "$(cat "$TD/_consult/skill.txt")" "brainstorming" "init wrote brainstorming skill"

# Stage trooper dir + outbox.
mkdir -p "$TD/rex-codex"
OUTBOX="$TD/rex-codex/outbox.jsonl"
: > "$OUTBOX"

# Phase 1: trooper emits ready then question.
echo '{"event":"ready"}' >> "$OUTBOX"
OFFSET_AT_QUESTION=$(wc -c < "$OUTBOX" | tr -d ' ')
echo '{"event":"question","text":"LRU or LFU?","options":["LRU","LFU"]}' >> "$OUTBOX"
OUTBOX_SIZE_AFTER_Q=$(wc -c < "$OUTBOX" | tr -d ' ')

# Stage state file post research-send.
printf 'OFFSET=%s\n' "$OFFSET_AT_QUESTION" > "$TD/_consult/research-rex.txt"

# wait-script catches the question.
CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=5 \
  ../bin/consult-research-wait.sh "$TOPIC" rex codex >/dev/null 2>&1
grep -q '^FS=question$' "$TD/_consult/research-rex.txt" \
  || { echo "FAIL: FS=question not set" >&2; cat "$TD/_consult/research-rex.txt"; exit 1; }
[[ -f "$TD/_consult/question-rex.txt" ]] \
  || { echo "FAIL: question payload missing" >&2; exit 1; }
pass "phase 1: wait-script caught question and wrote payload"

# H1 closure: state file should have 2 OFFSET= lines (initial + post-q).
OFFSET_LINES=$(grep -c '^OFFSET=' "$TD/_consult/research-rex.txt")
[[ "$OFFSET_LINES" -ge 2 ]] \
  || { echo "FAIL: state file should have ≥2 OFFSET lines; got $OFFSET_LINES"; cat "$TD/_consult/research-rex.txt"; exit 1; }
SECOND_OFFSET=$(grep '^OFFSET=' "$TD/_consult/research-rex.txt" | tail -1 | cut -d= -f2)
[[ "$SECOND_OFFSET" == "$OUTBOX_SIZE_AFTER_Q" ]] \
  || { echo "FAIL: 2nd OFFSET=$SECOND_OFFSET should equal outbox-size-after-q=$OUTBOX_SIZE_AFTER_Q"; exit 1; }
pass "wait-script auto-bumped OFFSET past question (no offset-reset call)"

# Phase 2: simulated cw_send (writes inbox.md only — does not touch state file).
[[ -f "$TD/_consult/research-rex.txt" ]] || { echo "FAIL: state file should survive simulated answer"; exit 1; }
[[ -f "$TD/_consult/question-rex.txt" ]] || { echo "FAIL: payload should still exist before re-arm"; exit 1; }
pass "phase 2: simulated cw_send leaves state file + payload intact"

# Phase 3: trooper resumes. Append done event + findings; re-run wait-script.
echo '{"event":"done"}' >> "$OUTBOX"
cat > "$TD/rex-codex/findings.md" <<'F'
## Claims
1. [src/x.py:1] sample claim
F

CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=5 \
  ../bin/consult-research-wait.sh "$TOPIC" rex codex >/dev/null 2>&1

FS_FINAL=$(grep '^FS=' "$TD/_consult/research-rex.txt" | tail -1 | cut -d= -f2)
[[ "$FS_FINAL" == "ok" ]] \
  || { echo "FAIL: expected FS=ok after resume; got '$FS_FINAL'"; cat "$TD/_consult/research-rex.txt"; exit 1; }
pass "phase 3: trooper resumes via re-run wait-script (no offset-reset, no send-script)"

# === Multi-question loop: Q1 → Q2 → done ===
TD2_TOPIC=$(../bin/consult-init.sh "design pattern multi-q test" 2>/dev/null)
TD2="$CLONE_WARS_HOME/state/$RH/$TD2_TOPIC"
mkdir -p "$TD2/rex-codex"
OUTBOX2="$TD2/rex-codex/outbox.jsonl"
echo '{"event":"ready"}' >> "$OUTBOX2"
OFFSET_INIT=$(wc -c < "$OUTBOX2" | tr -d ' ')
echo '{"event":"question","text":"Q1?","options":[]}' >> "$OUTBOX2"
printf 'OFFSET=%s\n' "$OFFSET_INIT" > "$TD2/_consult/research-rex.txt"

# First question caught.
CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=5 \
  ../bin/consult-research-wait.sh "$TD2_TOPIC" rex codex >/dev/null 2>&1
FS=$(grep '^FS=' "$TD2/_consult/research-rex.txt" | tail -1 | cut -d= -f2)
[[ "$FS" == "question" ]] || { echo "FAIL multi-q phase 1: FS=$FS"; exit 1; }

# Simulate answer + second question appears.
echo '{"event":"question","text":"Q2?","options":["A","B"]}' >> "$OUTBOX2"
CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=5 \
  ../bin/consult-research-wait.sh "$TD2_TOPIC" rex codex >/dev/null 2>&1
FS=$(grep '^FS=' "$TD2/_consult/research-rex.txt" | tail -1 | cut -d= -f2)
[[ "$FS" == "question" ]] || { echo "FAIL multi-q phase 2: FS=$FS"; exit 1; }
Q2_TEXT=$(cw_consult_question_payload_read "$TD2/_consult/question-rex.txt" TEXT)
[[ "$Q2_TEXT" == "Q2?" ]] || { echo "FAIL multi-q: payload should be Q2 got '$Q2_TEXT'"; exit 1; }

# Final: trooper finishes.
echo '{"event":"done"}' >> "$OUTBOX2"
cat > "$TD2/rex-codex/findings.md" <<'F'
## Claims
1. [src/y.py:1] x
F
CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=5 \
  ../bin/consult-research-wait.sh "$TD2_TOPIC" rex codex >/dev/null 2>&1
FS=$(grep '^FS=' "$TD2/_consult/research-rex.txt" | tail -1 | cut -d= -f2)
[[ "$FS" == "ok" ]] || { echo "FAIL multi-q done: FS=$FS"; exit 1; }
pass "multi-question loop: Q1 → Q2 → done; OFFSET advances each time, no send-script call"
