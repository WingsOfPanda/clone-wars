#!/usr/bin/env bash
# tests/test_consult_verify_wait.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')

# 1. VS=skipped state → wait short-circuits, no FS append, rc=0.
TOPIC=consult-fixture-vw1
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_consult" "$TD/rex-codex"
touch "$TD/rex-codex/outbox.jsonl"
echo "VS=skipped" > "$TD/_consult/verify-rex.txt"

../bin/consult-verify-wait.sh "$TOPIC" rex codex
content=$(cat "$TD/_consult/verify-rex.txt")
assert_eq "$content" "VS=skipped" "skipped state untouched"
pass "verify-wait short-circuits on VS=skipped"

# 2. OFFSET state with done event → VS=ok appended.
TOPIC2=consult-fixture-vw2
TD2="$CLONE_WARS_HOME/state/$RH/$TOPIC2"
mkdir -p "$TD2/_consult" "$TD2/rex-codex"
touch "$TD2/rex-codex/outbox.jsonl"
OFF=$(wc -c < "$TD2/rex-codex/outbox.jsonl" | tr -d ' ')
echo "OFFSET=$OFF" > "$TD2/_consult/verify-rex.txt"
cat > "$TD2/rex-codex/verify.md" <<'MD'
# Verify
## Verdicts
1. AGREE [src/x.py:5] real claim.
   evidence here
MD
echo '{"event":"done","ts":"t","summary":"verified"}' >> "$TD2/rex-codex/outbox.jsonl"

../bin/consult-verify-wait.sh "$TOPIC2" rex codex
grep -q '^VS=ok' "$TD2/_consult/verify-rex.txt" || { echo "FAIL: VS not ok" >&2; cat "$TD2/_consult/verify-rex.txt" >&2; exit 1; }
pass "verify-wait writes VS=ok when verify.md present"

# 3. Refuses if state file missing.
err=$(../bin/consult-verify-wait.sh "$TOPIC" missing-cmd codex 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: missing state file should reject" >&2; exit 1; }
pass "verify-wait refuses with missing state file"
