#!/usr/bin/env bash
# tests/test_consult_diff.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/ipc.sh
source ../lib/consult.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# === citation overlap: pairwise unit tests ===
cw_consult_citation_overlaps "src/x.py:5"     "src/x.py:5"      || { echo "FAIL: same line"        >&2; exit 1; }
cw_consult_citation_overlaps "src/x.py:5-10"  "src/x.py:7"      || { echo "FAIL: line in range"   >&2; exit 1; }
cw_consult_citation_overlaps "src/x.py:5-10"  "src/x.py:8-15"   || { echo "FAIL: ranges overlap"  >&2; exit 1; }
cw_consult_citation_overlaps "./src/x.py:5"   "src/x.py:5"      || { echo "FAIL: ./ normalize"    >&2; exit 1; }
cw_consult_citation_overlaps "src/x.py"       "src/x.py:5"      || { echo "FAIL: path-only ⊇ line">&2; exit 1; }
cw_consult_citation_overlaps "src/x.py:5"     "src/y.py:5"      && { echo "FAIL: paths differ"    >&2; exit 1; }
cw_consult_citation_overlaps "src/x.py:5-10"  "src/x.py:11-20"  && { echo "FAIL: disjoint ranges" >&2; exit 1; }
cw_consult_citation_overlaps "https://a/b"    "https://a/b"     || { echo "FAIL: same URL"        >&2; exit 1; }
cw_consult_citation_overlaps "https://a/b"    "https://a/c"     && { echo "FAIL: diff URLs"       >&2; exit 1; }
cw_consult_citation_overlaps "src/x.py:5"     "https://a/x"     && { echo "FAIL: file vs URL"     >&2; exit 1; }
cw_consult_citation_overlaps "runtime: pytest" "runtime: pytest" || { echo "FAIL: same runtime"   >&2; exit 1; }
cw_consult_citation_overlaps "runtime: pytest" "runtime: tox"    && { echo "FAIL: diff runtime"   >&2; exit 1; }
pass "cw_consult_citation_overlaps unit cases"

# === diff bucketing ===
REX="$TMP/rex.md"; CODY="$TMP/cody.md"
cat > "$REX" <<'MD'
# Findings
## Summary
.
## Claims
1. [src/auth/store.py:42] Plaintext storage.
2. [src/auth/refresh.py:15-30] No retry logic.
3. [src/util/log.py:7] Logger leaks tokens.
## Notes
MD
cat > "$CODY" <<'MD'
# Findings
## Summary
.
## Claims
1. [./src/auth/store.py:42] Tokens not encrypted.
2. [src/auth/refresh.py:20] No retry block.
3. [src/oauth/callback.py:88] State unvalidated.
## Notes
MD

OUT="$TMP/diff.md"
cw_consult_diff "$REX" "$CODY" "$OUT"

grep -q '^## Agreed'    "$OUT" || { echo "FAIL: missing Agreed"    >&2; exit 1; }
grep -q '^## Rex-only'  "$OUT" || { echo "FAIL: missing Rex-only"  >&2; exit 1; }
grep -q '^## Cody-only' "$OUT" || { echo "FAIL: missing Cody-only" >&2; exit 1; }

# Both store.py:42 (./ normalized) AND refresh.py:15-30 vs :20 (range-overlap)
# bucket as Agreed. That's 2 agreed pairs.
agreed_n=$(awk '/^## Agreed/{f=1;next} /^## /{f=0} f && /^- /{n++} END{print n+0}' "$OUT")
[[ "$agreed_n" -eq 2 ]] || { echo "FAIL: expected 2 agreed, got $agreed_n" >&2; cat "$OUT" >&2; exit 1; }
pass "Agreed bucket includes ./ normalization + range overlap"

# Rex-only: log.py only.
rex_n=$(awk '/^## Rex-only/{f=1;next} /^## /{f=0} f && /^- /{n++} END{print n+0}' "$OUT")
[[ "$rex_n" -eq 1 ]] || { echo "FAIL: expected 1 rex-only, got $rex_n" >&2; cat "$OUT" >&2; exit 1; }
grep -q 'src/util/log.py:7' "$OUT" || { echo "FAIL: log.py not in Rex-only" >&2; exit 1; }
pass "Rex-only correctly identifies disjoint claim"

# Cody-only: callback.py.
cody_n=$(awk '/^## Cody-only/{f=1;next} /^## /{f=0} f && /^- /{n++} END{print n+0}' "$OUT")
[[ "$cody_n" -eq 1 ]] || { echo "FAIL: expected 1 cody-only, got $cody_n" >&2; cat "$OUT" >&2; exit 1; }
pass "Cody-only correctly identifies disjoint claim"

# Empty inputs still emit all three sections.
echo '# x' > "$TMP/e1.md"; echo '# x' > "$TMP/e2.md"
cw_consult_diff "$TMP/e1.md" "$TMP/e2.md" "$TMP/d2.md"
grep -q '^## Agreed' "$TMP/d2.md"
grep -q '^## Rex-only' "$TMP/d2.md"
grep -q '^## Cody-only' "$TMP/d2.md"
pass "empty inputs still emit all three section headers"
