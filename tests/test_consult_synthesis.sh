#!/usr/bin/env bash
# tests/test_consult_synthesis.sh
#
# v0.16.0 — cw_consult_synthesize emits the rigid 6-section design-doc with
# trust-label header (Source/Generated/Path). Banner emission for
# malformed/empty/timeout statuses is preserved.
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
- CONFIRMED: [src/oauth/callback.py:88] State unvalidated. — REX disputed; Master Yoda verdict: callback.py:88 reads from request

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

# H1 + 6 rigid sections.
grep -qE '^# Review Auth$'      "$OUT" || { echo "FAIL: H1 title-cased"; cat "$OUT"; exit 1; }
for section in "Summary" "Findings" "Tradeoffs" "Recommendation" "Open Questions" "Sources"; do
  grep -qE "^## ${section}\$" "$OUT" \
    || { echo "FAIL: section '## $section' missing"; cat "$OUT"; exit 1; }
done
pass "design-doc has H1 + 6 rigid sections"

# Trust-label header.
grep -qE '^> \*\*Source:\*\*'    "$OUT" || { echo "FAIL: Source: header missing"; cat "$OUT"; exit 1; }
grep -qE '^> \*\*Generated:\*\*' "$OUT" || { echo "FAIL: Generated: header missing"; cat "$OUT"; exit 1; }
grep -qE '^> \*\*Path:\*\*'      "$OUT" || { echo "FAIL: Path: header missing"; cat "$OUT"; exit 1; }
pass "design-doc has Source/Generated/Path trust-label headers"

# Banner appears: cody verify timed out.
grep -q '^> NOTE:.*verify.*partial' "$OUT" \
  || { echo "FAIL: missing partial-verify banner" >&2; cat "$OUT" >&2; exit 1; }
pass "partial-verify banner present"

# Cross-verified content from adjudicated.md flows through into Findings.
grep -q 'No retry.' "$OUT"          || { echo "FAIL: cross-verified content missing"; exit 1; }
grep -q 'State unvalidated.' "$OUT" || { echo "FAIL: adjudicated content missing"; exit 1; }
pass "Findings inherits cross-verified + adjudicated content"

# Not-verified content surfaces as Open Questions.
grep -q 'Logger leaks tokens' "$OUT" \
  || { echo "FAIL: Not-verified content missing in Open Questions"; cat "$OUT"; exit 1; }
pass "Open Questions inherits Not-verified content"

# Source-label defaults to N=2 cross-verified text when CW_SOURCE_LABEL unset.
grep -qE '^> \*\*Source:\*\*[[:space:]]+rex\+cody' "$OUT" \
  || { echo "FAIL: default Source label not 'rex+cody cross-verified'"; cat "$OUT"; exit 1; }
pass "default Source label is rex+cody cross-verified"

# Path-label defaults to escalated-from-signals when CW_PATH_LABEL unset.
grep -qE '^> \*\*Path:\*\*[[:space:]]+escalated-from-signals' "$OUT" \
  || { echo "FAIL: default Path label not escalated-from-signals"; cat "$OUT"; exit 1; }
pass "default Path label is escalated-from-signals"

# All-good case: no banners.
cw_consult_synthesize "review auth" "$DIFF" "$ADJ" \
  "/state/rex" "/state/cody" "ok" "ok" "ok" "ok" "$TMP/syn2.md"
grep -q '^> NOTE:' "$TMP/syn2.md" \
  && { echo "FAIL: unexpected banner in clean run"; cat "$TMP/syn2.md"; exit 1; } \
  || true
pass "clean run has no NOTE banner"

# Findings malformed for one side → degraded banner.
cw_consult_synthesize "review auth" "$DIFF" "$ADJ" \
  "/state/rex" "/state/cody" "malformed" "ok" "ok" "ok" "$TMP/syn3.md"
grep -q '^> NOTE:.*REX.*malformed' "$TMP/syn3.md" \
  || { echo "FAIL: missing degraded findings banner"; exit 1; }
pass "degraded findings banner emitted"

# vs=empty must trigger a partial-verify banner.
cw_consult_synthesize "review auth" "$DIFF" "$ADJ" \
  "/state/rex" "/state/cody" "ok" "ok" "empty" "ok" "$TMP/syn4.md"
grep -q '^> NOTE:.*REX.*verify.*partial' "$TMP/syn4.md" \
  || { echo "FAIL: empty verify did not produce banner"; cat "$TMP/syn4.md"; exit 1; }
pass "empty verify status triggers partial-verify banner"

# Custom CW_SOURCE_LABEL / CW_PATH_LABEL flow through.
CW_SOURCE_LABEL='rex+cody+bly cross-verified' \
CW_PATH_LABEL='escalated-from-flag' \
  cw_consult_synthesize "review auth" "$DIFF" "$ADJ" \
    "/state/rex" "/state/cody" "ok" "ok" "ok" "ok" "$TMP/syn5.md"
grep -qE '^> \*\*Source:\*\*[[:space:]]+rex\+cody\+bly cross-verified' "$TMP/syn5.md" \
  || { echo "FAIL: CW_SOURCE_LABEL override ignored"; cat "$TMP/syn5.md"; exit 1; }
grep -qE '^> \*\*Path:\*\*[[:space:]]+escalated-from-flag' "$TMP/syn5.md" \
  || { echo "FAIL: CW_PATH_LABEL override ignored"; cat "$TMP/syn5.md"; exit 1; }
pass "CW_SOURCE_LABEL / CW_PATH_LABEL env overrides honored"
