#!/usr/bin/env bash
# tests/test_consult_prompts.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/ipc.sh
source ../lib/consult.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

ITEMS="$TMP/items.txt"
cat > "$ITEMS" <<'EOF'
[src/auth/refresh.py:15-30] No retry logic.
[src/oauth/callback.py:88] State unvalidated.
EOF

PROMPT=$(cw_consult_build_verify_prompt "$ITEMS" "/state/verify.md")
echo "$PROMPT" | grep -q 'END_OF_INSTRUCTION$'      || { echo "FAIL: sentinel"; exit 1; }
echo "$PROMPT" | grep -q 'AGREE / DISPUTE / UNCERTAIN' || { echo "FAIL: tags"; exit 1; }
echo "$PROMPT" | grep -q '/state/verify.md'         || { echo "FAIL: path"; exit 1; }
pass "verify prompt has sentinel, tags, output path"

VERIFY="$TMP/v.md"
cat > "$VERIFY" <<'MD'
# Verify
## Verdicts
1. AGREE [src/auth/refresh.py:15-30] No retry logic.
   src/auth/refresh.py:25 — no except RetryError block
2. DISPUTE [src/oauth/callback.py:88] State unvalidated.
   actually reads from session at line 88
3. UNCERTAIN [src/util/x.py:10] Some claim.
   no test reproduces this
MD

mapfile -t V < <(cw_consult_parse_verdicts "$VERIFY")
[[ "${#V[@]}" -eq 3 ]] || { echo "FAIL: 3 verdicts" >&2; exit 1; }
IFS=$'\t' read -r tag cite text <<< "${V[0]}"; assert_eq "$tag" "AGREE" "v1 tag"
IFS=$'\t' read -r tag cite text <<< "${V[1]}"; assert_eq "$tag" "DISPUTE" "v2 tag"
IFS=$'\t' read -r tag cite text <<< "${V[2]}"; assert_eq "$tag" "UNCERTAIN" "v3 tag"
pass "all three tags recognized"

cat > "$VERIFY" <<'MD'
# Verify
## Verdicts
1. UNKNOWN [src/x.py:1] Garbled.
2. AGREE [src/y.py:5] Real.
MD
mapfile -t V < <(cw_consult_parse_verdicts "$VERIFY")
[[ "${#V[@]}" -eq 1 ]] || { echo "FAIL: unknown tag should be filtered"; exit 1; }
pass "unknown tags filtered"

PROMPT=$(cw_consult_build_research_prompt "review src/auth for token edge cases" "/state/findings.md")
echo "$PROMPT" | grep -q 'review src/auth for token edge cases' || { echo "FAIL: topic"; exit 1; }
echo "$PROMPT" | grep -q '/state/findings.md'  || { echo "FAIL: path"; exit 1; }
echo "$PROMPT" | grep -q '## Claims'            || { echo "FAIL: format anchor"; exit 1; }
echo "$PROMPT" | grep -q 'END_OF_INSTRUCTION$' || { echo "FAIL: sentinel"; exit 1; }
pass "research prompt complete"
