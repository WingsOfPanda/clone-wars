#!/usr/bin/env bash
# tests/test_consult_research_wait.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=consult-fixture-rw
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_consult" "$TD/rex-codex" "$TD/cody-claude"
touch "$TD/rex-codex/outbox.jsonl" "$TD/cody-claude/outbox.jsonl"

# 1. Pre-populate state files with offsets, then append done events past those offsets,
#    then create well-formed findings.md for both → wait should write FS=ok.
REX_OFF=$(wc -c < "$TD/rex-codex/outbox.jsonl" | tr -d ' ')
COD_OFF=$(wc -c < "$TD/cody-claude/outbox.jsonl" | tr -d ' ')
echo "OFFSET=$REX_OFF" > "$TD/_consult/research-rex.txt"
echo "OFFSET=$COD_OFF" > "$TD/_consult/research-cody.txt"

cat > "$TD/rex-codex/findings.md" <<'MD'
# Findings: x
## Summary
.
## Claims
1. [src/x.py:5] real claim.
## Notes
MD
cat > "$TD/cody-claude/findings.md" <<'MD'
# Findings: x
## Summary
.
## Claims
1. [src/y.py:5] real claim.
## Notes
MD

echo '{"event":"done","ts":"t1","summary":"rex"}' >> "$TD/rex-codex/outbox.jsonl"
echo '{"event":"done","ts":"t2","summary":"cody"}' >> "$TD/cody-claude/outbox.jsonl"

../bin/consult-research-wait.sh "$TOPIC" rex codex
../bin/consult-research-wait.sh "$TOPIC" cody claude

# Each state file should now have BOTH OFFSET= and FS= lines.
grep -q '^OFFSET=' "$TD/_consult/research-rex.txt"  || { echo "FAIL: rex OFFSET missing" >&2; exit 1; }
grep -q '^FS=ok'   "$TD/_consult/research-rex.txt"  || { echo "FAIL: rex FS not ok" >&2; cat "$TD/_consult/research-rex.txt" >&2; exit 1; }
grep -q '^OFFSET=' "$TD/_consult/research-cody.txt" || { echo "FAIL: cody OFFSET missing" >&2; exit 1; }
grep -q '^FS=ok'   "$TD/_consult/research-cody.txt" || { echo "FAIL: cody FS not ok" >&2; cat "$TD/_consult/research-cody.txt" >&2; exit 1; }
pass "per-commander wait writes FS=ok when findings well-formed"

# 2. Codex finding #2 fixture: rex times out, cody finishes. Cody's status must survive.
TOPIC2=consult-fixture-rw2
TD2="$CLONE_WARS_HOME/state/$RH/$TOPIC2"
mkdir -p "$TD2/_consult" "$TD2/rex-codex" "$TD2/cody-claude"
touch "$TD2/rex-codex/outbox.jsonl" "$TD2/cody-claude/outbox.jsonl"
REX_OFF2=$(wc -c < "$TD2/rex-codex/outbox.jsonl" | tr -d ' ')
COD_OFF2=$(wc -c < "$TD2/cody-claude/outbox.jsonl" | tr -d ' ')
echo "OFFSET=$REX_OFF2" > "$TD2/_consult/research-rex.txt"
echo "OFFSET=$COD_OFF2" > "$TD2/_consult/research-cody.txt"
# Only cody emits done; rex's outbox stays silent.
cat > "$TD2/cody-claude/findings.md" <<'MD'
# Findings: x
## Claims
1. [src/y.py:5] real claim.
## Notes
MD
echo '{"event":"done","ts":"t","summary":"cody"}' >> "$TD2/cody-claude/outbox.jsonl"

# Run cody-side wait FIRST (succeeds in <1s), then rex-side (times out via short timeout).
../bin/consult-research-wait.sh "$TOPIC2" cody claude
# Force a short timeout for rex via env override (script should pick up CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE if set).
CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=1 ../bin/consult-research-wait.sh "$TOPIC2" rex codex

grep -q '^FS=ok'      "$TD2/_consult/research-cody.txt" || { echo "FAIL: cody status was destroyed by rex timeout" >&2; cat "$TD2/_consult/research-cody.txt" >&2; exit 1; }
grep -q '^FS=missing' "$TD2/_consult/research-rex.txt"  || { echo "FAIL: rex status not 'missing' after timeout" >&2; cat "$TD2/_consult/research-rex.txt" >&2; exit 1; }
pass "rex timeout does not destroy cody's status (Codex #2 fixture)"

# 3. Refuses if state file missing.
err=$(../bin/consult-research-wait.sh "$TOPIC" missing-cmd codex 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: missing state file should reject" >&2; exit 1; }
pass "research-wait refuses with missing state file"
