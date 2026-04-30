#!/usr/bin/env bash
# tests/test_consult_prompts.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/ipc.sh
# v0.5.0: research prompt now loads from config/prompt-templates/ via
# cw_consult_load_prompt, which requires CLAUDE_PLUGIN_ROOT to resolve the
# template path. Point at the repo root so the loader finds research.md.
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"
PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
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

# v0.3.2: verify prompt authorizes WebSearch/WebFetch.
echo "$PROMPT" | grep -q 'Verification methods' || { echo "FAIL: verify prompt missing v0.3.2 methods clause"; exit 1; }
echo "$PROMPT" | grep -q 'WebSearch / WebFetch' || { echo "FAIL: verify prompt missing WebSearch/WebFetch authorization"; exit 1; }
pass "verify prompt authorizes WebSearch/WebFetch (v0.3.2)"

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

# Evidence line round-trip — verify.md has indented continuation lines below
# each verdict; parser must preserve them as a 4th TSV column so synthesis
# can show the trooper's actual reasoning, not just echo the original claim.
cat > "$VERIFY" <<'MD'
# Verify
## Verdicts
1. AGREE [src/auth/refresh.py:15-30] No retry logic.
   src/auth/refresh.py:25 — try block has no except RetryError handler
2. DISPUTE [src/oauth/callback.py:88] State unvalidated.
   actually validated against session at line 91 — original claim is wrong
MD
mapfile -t V < <(cw_consult_parse_verdicts "$VERIFY")
[[ "${#V[@]}" -eq 2 ]] || { echo "FAIL: 2 verdicts, got ${#V[@]}" >&2; exit 1; }
IFS=$'\t' read -r tag cite text evidence <<< "${V[0]}"
[[ "$evidence" == *"except RetryError"* ]] \
  || { echo "FAIL: evidence not captured: '$evidence'" >&2; exit 1; }
IFS=$'\t' read -r tag cite text evidence <<< "${V[1]}"
[[ "$evidence" == *"validated against session"* ]] \
  || { echo "FAIL: dispute evidence not captured: '$evidence'" >&2; exit 1; }
pass "verdict parser captures evidence continuation line as 4th TSV column"

PROMPT=$(cw_consult_build_research_prompt "review src/auth for token edge cases" "/state/findings.md")
echo "$PROMPT" | grep -q 'review src/auth for token edge cases' || { echo "FAIL: topic"; exit 1; }
echo "$PROMPT" | grep -q '/state/findings.md'  || { echo "FAIL: path"; exit 1; }
echo "$PROMPT" | grep -q '## Claims'            || { echo "FAIL: format anchor"; exit 1; }
echo "$PROMPT" | grep -q 'END_OF_INSTRUCTION$' || { echo "FAIL: sentinel"; exit 1; }
pass "research prompt complete"

# v0.3.2: research prompt authorizes WebSearch/WebFetch.
echo "$PROMPT" | grep -q 'Research methods'    || { echo "FAIL: research prompt missing v0.3.2 methods clause"; exit 1; }
echo "$PROMPT" | grep -q 'WebSearch / WebFetch' || { echo "FAIL: research prompt missing WebSearch/WebFetch authorization"; exit 1; }
pass "research prompt authorizes WebSearch/WebFetch (v0.3.2)"
