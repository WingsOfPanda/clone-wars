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
# v0.2.1 regressions:
# Boundary-touching ranges share line 10 → overlap (inclusive).
cw_consult_citation_overlaps "src/x.py:5-10"  "src/x.py:10-20" || { echo "FAIL: boundary-touching ranges should overlap"   >&2; exit 1; }
# Leading-zero line numerals must compare base-10, not octal (was: arithmetic error on :008).
cw_consult_citation_overlaps "src/x.py:008"   "src/x.py:8"     || { echo "FAIL: leading-zero must compare as decimal"      >&2; exit 1; }
cw_consult_citation_overlaps "src/x.py:5-009" "src/x.py:7"     || { echo "FAIL: leading-zero in range endpoint"            >&2; exit 1; }
# Empty/dash endpoints must NOT overlap — guard rejects each endpoint individually.
cw_consult_citation_overlaps "src/x.py:-5"    "src/x.py:2"     && { echo "FAIL: leading-dash range should not match"        >&2; exit 1; }
cw_consult_citation_overlaps "src/x.py:5-"    "src/x.py:3"     && { echo "FAIL: trailing-dash range should not match"       >&2; exit 1; }
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

# v0.15.0 signature: cw_consult_diff <art-dir> <name1>:<findings1> <name2>:<findings2> ...
# For N=2 the art-dir output (diff.md + <name>_only_items.txt) is byte-equal
# to v0.14.0; no consensus.txt is written.
ART="$TMP/art1"; mkdir -p "$ART"
OUT="$ART/diff.md"
cw_consult_diff "$ART" "rex:$REX" "cody:$CODY"

grep -q '^## Agreed'    "$OUT" || { echo "FAIL: missing Agreed"    >&2; exit 1; }
grep -q '^## Rex-only'  "$OUT" || { echo "FAIL: missing Rex-only"  >&2; exit 1; }
grep -q '^## Cody-only' "$OUT" || { echo "FAIL: missing Cody-only" >&2; exit 1; }
# N=2 must NOT write consensus.txt.
[[ ! -e "$ART/consensus.txt" ]] || { echo "FAIL: consensus.txt should not exist for N=2" >&2; exit 1; }

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

# Per-bucket files for N=2: rex_only_items.txt and cody_only_items.txt.
[[ -f "$ART/rex_only_items.txt"  ]] || { echo "FAIL: rex_only_items.txt missing"  >&2; exit 1; }
[[ -f "$ART/cody_only_items.txt" ]] || { echo "FAIL: cody_only_items.txt missing" >&2; exit 1; }
grep -q 'src/util/log.py:7'         "$ART/rex_only_items.txt"  || { echo "FAIL: log.py not in rex_only_items.txt" >&2; exit 1; }
grep -q 'src/oauth/callback.py:88'  "$ART/cody_only_items.txt" || { echo "FAIL: callback.py not in cody_only_items.txt" >&2; exit 1; }
pass "N=2 emits rex_only_items.txt and cody_only_items.txt"

# === regression: path-only cody must not steal pairing from specific-line cody ===
cat > "$REX" <<'MD'
# Findings
## Claims
1. [src/x.py:5] R-five.
2. [src/x.py:50] R-fifty.
## Notes
MD
cat > "$CODY" <<'MD'
# Findings
## Claims
1. [src/x.py] C-pathonly.
2. [src/x.py:50] C-fifty.
## Notes
MD

ART2="$TMP/art2"; mkdir -p "$ART2"
OUT="$ART2/diff.md"
cw_consult_diff "$ART2" "rex:$REX" "cody:$CODY"
# Both rex claims paired (path-only catches the rex[0] specific-line; rex[1]
# pairs with cody[1] specific-line — pairing is order-of-bucketing).
agreed_lines=$(awk '/^## Agreed/{f=1;next} /^## /{f=0} f && /^- /{print}' "$OUT")
n=$(echo "$agreed_lines" | grep -c '^- ')
[[ "$n" -eq 2 ]] || { echo "FAIL: expected 2 agreed pairs, got $n" >&2; cat "$OUT" >&2; exit 1; }
# C-fifty MUST appear in the Agreed section — the bug dropped it before.
echo "$agreed_lines" | grep -q 'C-fifty' || { echo "FAIL: C-fifty missing from Agreed" >&2; cat "$OUT" >&2; exit 1; }
# C-pathonly should appear EXACTLY ONCE (was duplicated by the bug).
pathonly_count=$(echo "$agreed_lines" | grep -c 'C-pathonly')
[[ "$pathonly_count" -eq 1 ]] || { echo "FAIL: C-pathonly appears $pathonly_count times, expected 1" >&2; cat "$OUT" >&2; exit 1; }
# Cody-only should be empty (both cody claims used).
cody_only_n=$(awk '/^## Cody-only/{f=1;next} /^## /{f=0} f && /^- /{n++} END{print n+0}' "$OUT")
[[ "$cody_only_n" -eq 0 ]] || { echo "FAIL: expected 0 cody-only, got $cody_only_n" >&2; exit 1; }
pass "path-only cody does not steal pairing from specific-line cody"

# Empty inputs still emit all three sections.
ART3="$TMP/art3"; mkdir -p "$ART3"
echo '# x' > "$TMP/e1.md"; echo '# x' > "$TMP/e2.md"
cw_consult_diff "$ART3" "rex:$TMP/e1.md" "cody:$TMP/e2.md"
grep -q '^## Agreed'    "$ART3/diff.md"
grep -q '^## Rex-only'  "$ART3/diff.md"
grep -q '^## Cody-only' "$ART3/diff.md"
pass "empty inputs still emit all three section headers"
