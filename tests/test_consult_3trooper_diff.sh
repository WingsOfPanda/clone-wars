#!/usr/bin/env bash
# tests/test_consult_3trooper_diff.sh
#
# v0.15.0: cw_consult_diff is variadic. With N=3 troopers (rex/cody/wolffe) the
# 3-way Venn diagram has 7 non-empty cells. This test stages controlled
# overlaps and asserts each bucket file has the expected line count + key
# claim text, plus that diff.md has all the right section headers in the
# right order.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/ipc.sh
source ../lib/consult.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Findings fixtures with controlled overlaps:
#   Rex:  A, B, C, D
#   Cody: B, C, E
#   Wolffe:  C, E, F
#
# Expected Venn cells:
#   consensus  (all 3)        = [C]
#   rex+cody   (no wolffe)       = [B]
#   rex+wolffe    (no cody)      = (empty)
#   cody+wolffe   (no rex)       = [E]
#   rex_only                  = [A, D]
#   cody_only                 = (empty)
#   wolffe_only                  = [F]
REX="$TMP/rex.md" CODY="$TMP/cody.md" BLY="$TMP/wolffe.md"
cat > "$REX" <<'MD'
# Findings
## Claims
1. [src/a.py:1] claim A by rex
2. [src/b.py:2] claim B by rex
3. [src/c.py:3] claim C by rex
4. [src/d.py:4] claim D by rex
## Notes
MD
cat > "$CODY" <<'MD'
# Findings
## Claims
1. [src/b.py:2] claim B by cody
2. [src/c.py:3] claim C by cody
3. [src/e.py:5] claim E by cody
## Notes
MD
cat > "$BLY" <<'MD'
# Findings
## Claims
1. [src/c.py:3] claim C by wolffe
2. [src/e.py:5] claim E by wolffe
3. [src/f.py:6] claim F by wolffe
## Notes
MD

ART="$TMP/art"; mkdir -p "$ART"
cw_consult_diff "$ART" "rex:$REX" "cody:$CODY" "wolffe:$BLY"

# === diff.md section structure ===
DIFF="$ART/diff.md"
[[ -f "$DIFF" ]] || { echo "FAIL: diff.md not written" >&2; exit 1; }

# Section ordering: Consensus -> pair-only's (rex+cody, rex+wolffe, cody+wolffe) -> single-only's (rex, cody, wolffe).
order=$(grep -nE '^## ' "$DIFF" | awk -F: '{print $2}')
expected_order='## Consensus
## Rex+Cody only
## Rex+Wolffe only
## Cody+Wolffe only
## Rex-only
## Cody-only
## Wolffe-only'
assert_eq "$order" "$expected_order" "diff.md section ordering"
pass "diff.md emits 7 sections in canonical order"

# === per-bucket file presence ===
for f in consensus.txt rex+cody_only.txt rex+wolffe_only.txt cody+wolffe_only.txt \
         rex_only_items.txt cody_only_items.txt wolffe_only_items.txt; do
  [[ -f "$ART/$f" ]] || { echo "FAIL: bucket file $f missing" >&2; exit 1; }
done
pass "all 7 bucket files written (empty buckets get a 0-line file)"

# === bucket-content checks ===
# consensus.txt: exactly 1 line, contains 'src/c.py:3' AND text from all 3 troopers.
[[ "$(wc -l < "$ART/consensus.txt")" -eq 1 ]] || { echo "FAIL: consensus.txt should have 1 line" >&2; cat "$ART/consensus.txt" >&2; exit 1; }
grep -q 'src/c.py:3'      "$ART/consensus.txt" || { echo "FAIL: consensus missing C cite" >&2; exit 1; }
grep -q 'claim C by rex'  "$ART/consensus.txt" || { echo "FAIL: consensus missing rex text" >&2; exit 1; }
grep -q 'claim C by cody' "$ART/consensus.txt" || { echo "FAIL: consensus missing cody text" >&2; exit 1; }
grep -q 'claim C by wolffe'  "$ART/consensus.txt" || { echo "FAIL: consensus missing wolffe text" >&2; exit 1; }
pass "consensus.txt has all-3 intersection with merged texts"

# rex+cody_only.txt: 1 line for B; rex+wolffe_only.txt: empty (0 lines).
[[ "$(wc -l < "$ART/rex+cody_only.txt")" -eq 1 ]] || { echo "FAIL: rex+cody_only.txt should have 1 line" >&2; cat "$ART/rex+cody_only.txt" >&2; exit 1; }
grep -q 'src/b.py:2' "$ART/rex+cody_only.txt" || { echo "FAIL: rex+cody missing B cite" >&2; exit 1; }
[[ "$(wc -l < "$ART/rex+wolffe_only.txt")"  -eq 0 ]] || { echo "FAIL: rex+wolffe_only.txt should be empty" >&2; cat "$ART/rex+wolffe_only.txt" >&2; exit 1; }
[[ "$(wc -l < "$ART/cody+wolffe_only.txt")" -eq 1 ]] || { echo "FAIL: cody+wolffe_only.txt should have 1 line" >&2; cat "$ART/cody+wolffe_only.txt" >&2; exit 1; }
grep -q 'src/e.py:5' "$ART/cody+wolffe_only.txt" || { echo "FAIL: cody+wolffe missing E cite" >&2; exit 1; }
pass "pair-only buckets have correct cardinality and citations"

# Single-only: rex has 2 (A, D); cody has 0; wolffe has 1 (F).
[[ "$(wc -l < "$ART/rex_only_items.txt")"  -eq 2 ]] || { echo "FAIL: rex_only_items.txt should have 2 lines" >&2; cat "$ART/rex_only_items.txt" >&2; exit 1; }
grep -q 'src/a.py:1' "$ART/rex_only_items.txt" || { echo "FAIL: rex_only missing A" >&2; exit 1; }
grep -q 'src/d.py:4' "$ART/rex_only_items.txt" || { echo "FAIL: rex_only missing D" >&2; exit 1; }
[[ "$(wc -l < "$ART/cody_only_items.txt")" -eq 0 ]] || { echo "FAIL: cody_only_items.txt should be empty" >&2; cat "$ART/cody_only_items.txt" >&2; exit 1; }
[[ "$(wc -l < "$ART/wolffe_only_items.txt")"  -eq 1 ]] || { echo "FAIL: wolffe_only_items.txt should have 1 line" >&2; cat "$ART/wolffe_only_items.txt" >&2; exit 1; }
grep -q 'src/f.py:6' "$ART/wolffe_only_items.txt" || { echo "FAIL: wolffe_only missing F" >&2; exit 1; }
pass "single-only buckets have correct cardinality and citations"

# === diff.md body sanity: sections under each header reflect bucket contents. ===
# The "Consensus" section body must contain c.py:3 + all 3 texts pipe-joined.
consensus_body=$(awk '/^## Consensus/{f=1;next} /^## /{f=0} f' "$DIFF")
echo "$consensus_body" | grep -q 'src/c.py:3'              || { echo "FAIL: diff.md Consensus missing C cite" >&2; exit 1; }
echo "$consensus_body" | grep -q 'claim C by rex | claim C by cody | claim C by wolffe' \
  || { echo "FAIL: diff.md Consensus missing pipe-joined merged texts" >&2; echo "$consensus_body" >&2; exit 1; }
pass "diff.md Consensus section pipe-joins all 3 texts in input order"

# An empty bucket (rex+wolffe) must still have a header but no body lines.
rb_body=$(awk '/^## Rex\+Wolffe only/{f=1;next} /^## /{f=0} f && /^- /' "$DIFF")
[[ -z "$rb_body" ]] || { echo "FAIL: empty Rex+Wolffe bucket should have no body lines" >&2; echo "$rb_body" >&2; exit 1; }
pass "empty Rex+Wolffe bucket header present with no body items"

# === regression: existing N=2 ./ normalization + range-overlap still works ===
# (Re-tested in test_consult_diff.sh; here we just verify N=3 mixed input doesn't
#  break the underlying overlap matcher when path-only and ranged citations meet.)
cat > "$REX"  <<'MD'
# F
## Claims
1. [src/x.py:5-10] rex range
MD
cat > "$CODY" <<'MD'
# F
## Claims
1. [src/x.py:8] cody point
MD
cat > "$BLY"  <<'MD'
# F
## Claims
1. [src/x.py] wolffe path-only
MD
ART2="$TMP/art2"; mkdir -p "$ART2"
cw_consult_diff "$ART2" "rex:$REX" "cody:$CODY" "wolffe:$BLY"
[[ "$(wc -l < "$ART2/consensus.txt")" -eq 1 ]] || { echo "FAIL: range/point/path-only should fold into consensus" >&2; cat "$ART2/consensus.txt" >&2; exit 1; }
pass "N=3 path-only ⊇ range ⊇ specific-line all overlap into consensus"

# === N>=3: bucket files MUST be created even when bucket is empty ===
# Stages 3 disjoint findings; expect 0-line consensus + 0-line pair files.
cat > "$REX"  <<'MD'
# F
## Claims
1. [src/r.py:1] R-only
MD
cat > "$CODY" <<'MD'
# F
## Claims
1. [src/c.py:1] C-only
MD
cat > "$BLY"  <<'MD'
# F
## Claims
1. [src/b.py:1] B-only
MD
ART3="$TMP/art3"; mkdir -p "$ART3"
cw_consult_diff "$ART3" "rex:$REX" "cody:$CODY" "wolffe:$BLY"
for f in consensus.txt rex+cody_only.txt rex+wolffe_only.txt cody+wolffe_only.txt; do
  [[ -f "$ART3/$f" ]]                         || { echo "FAIL: $f not created (must exist even if empty)" >&2; exit 1; }
  [[ "$(wc -l < "$ART3/$f")" -eq 0 ]]         || { echo "FAIL: $f should be empty for fully disjoint inputs" >&2; cat "$ART3/$f" >&2; exit 1; }
done
[[ "$(wc -l < "$ART3/rex_only_items.txt")"  -eq 1 ]]
[[ "$(wc -l < "$ART3/cody_only_items.txt")" -eq 1 ]]
[[ "$(wc -l < "$ART3/wolffe_only_items.txt")"  -eq 1 ]]
pass "fully-disjoint N=3 inputs still produce all 7 bucket files (4 empty + 3 single-line)"
