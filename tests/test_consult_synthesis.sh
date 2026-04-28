#!/usr/bin/env bash
# tests/test_consult_synthesis.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/ipc.sh
source ../lib/consult.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

DIFF="$TMP/diff.md"
cat > "$DIFF" <<'MD'
## Agreed
- [src/auth/store.py:42] Plaintext. | Not encrypted.

## Rex-only
- [src/auth/refresh.py:15-30] No retry.

## Cody-only
- [src/oauth/callback.py:88] State unvalidated.
MD

ADJ="$TMP/adj.md"
cat > "$ADJ" <<'MD'
## Cross-verified
- [src/auth/refresh.py:15-30] No retry. — CODY confirmed (refresh.py:25)

## Adjudicated
- CONFIRMED: [src/oauth/callback.py:88] State unvalidated. — REX disputed; conductor verdict: callback.py:88 reads from request

## Contested

## Not-verified
- [src/util/log.py:7] Logger leaks tokens. — CODY did not respond
MD

OUT="$TMP/syn.md"
cw_consult_synthesize "review auth" "$DIFF" "$ADJ" \
  "/state/rex" "/state/cody" \
  "ok" "ok" \
  "ok" "timeout" \
  "$OUT"

# Title + 6 sections (added Not-verified).
grep -q '^# Consultation: review auth'    "$OUT" || { echo "FAIL: title";        exit 1; }
grep -q '^## Agreed findings'             "$OUT" || { echo "FAIL: agreed";       exit 1; }
grep -q '^## Cross-verified'              "$OUT" || { echo "FAIL: cross";        exit 1; }
grep -q '^## Adjudicated'                 "$OUT" || { echo "FAIL: adjudicated";  exit 1; }
grep -q '^## Contested'                   "$OUT" || { echo "FAIL: contested";    exit 1; }
grep -q '^## Not-verified'                "$OUT" || { echo "FAIL: not-verified"; exit 1; }
grep -q '^## Trooper artifacts'           "$OUT" || { echo "FAIL: artifacts";    exit 1; }
pass "synthesis has all 6 sections"

# Banner appears: cody verify timed out.
grep -q '^> .*verify.*partial' "$OUT" || { echo "FAIL: missing partial-verify banner" >&2; cat "$OUT" >&2; exit 1; }
pass "partial-verify banner present"

# All-good case: no banners.
cw_consult_synthesize "review auth" "$DIFF" "$ADJ" \
  "/state/rex" "/state/cody" "ok" "ok" "ok" "ok" "$TMP/syn2.md"
grep -q '^> ' "$TMP/syn2.md" && { echo "FAIL: unexpected banner in clean run" >&2; exit 1; }
pass "clean run has no banner"

# Findings malformed for one side → degraded banner.
cw_consult_synthesize "review auth" "$DIFF" "$ADJ" \
  "/state/rex" "/state/cody" "malformed" "ok" "ok" "ok" "$TMP/syn3.md"
grep -q '^> .*REX.*malformed' "$TMP/syn3.md" || { echo "FAIL: missing degraded findings banner" >&2; exit 1; }
pass "degraded findings banner emitted"

# vs=empty must trigger a partial-verify banner.
cw_consult_synthesize "review auth" "$DIFF" "$ADJ" \
  "/state/rex" "/state/cody" "ok" "ok" "empty" "ok" "$TMP/syn4.md"
grep -q '^> .*REX.*verify.*partial' "$TMP/syn4.md" \
  || { echo "FAIL: empty verify did not produce banner" >&2; cat "$TMP/syn4.md" >&2; exit 1; }
pass "empty verify status triggers partial-verify banner"
