#!/usr/bin/env bash
# tests/test_consult_3trooper_synthesize.sh
#
# v0.16.0 contract: bin/consult-synthesize.sh + cw_consult_synthesize must
# propagate 3-trooper source tags from adjudicated.md into the design-doc
# byte-for-byte. The expanded tag set is 7 tags (singletons rex/cody/wolffe,
# pairs rex+cody/rex+wolffe/cody+wolffe, all-three rex+cody+wolffe) plus per-claim
# verifier annotations like "verified by wolffe: AGREE".
#
# Strategy: stage adjudicated.md whose ## Cross-verified and ## Contested
# sections contain claims tagged with the v0.15.0 tag vocabulary. v0.16
# changes the OUTPUT location/structure (design-doc with rigid 6 sections),
# but tag propagation through the awk pipeline is unchanged — verify both.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=consult-fixture-3t-syn
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_consult/design-doc" "$TD/rex-codex" "$TD/cody-claude" "$TD/wolffe-opencode"

# Stage minimum prerequisites for synthesize: topic + non-PENDING stage status
# files for both legacy (rex-only/cody-only) inputs the existing API expects.
echo "v0.15 3-trooper tag propagation" > "$TD/_consult/topic.txt"
for stage in research verify; do
  for cmdr in rex cody wolffe; do
    cat > "$TD/_consult/$stage-$cmdr.txt" <<EOF
OFFSET=0
$( [[ "$stage" == research ]] && echo FS=ok || echo VS=ok )
EOF
  done
done

# Stage diff.md with a v0.14-style ## Agreed section (synthesize copies this
# section through verbatim into the Findings section). Tag propagation here
# is incidental — the load-bearing assertion below targets adjudicated.md →
# design-doc.
cat > "$TD/_consult/diff.md" <<'MD'
## Agreed
- [src/a.py:1] consensus body | rex+cody+wolffe all raised
## Rex-only
## Cody-only
MD

# Stage adjudicated.md with 7-tag source set + verifier annotations.
# Place all 7 source-set forms in ## Cross-verified or ## Contested so that
# synthesize's awk pattern (Cross-verified|Adjudicated|Contested|Not-verified)
# captures every line. This isolates the test to tag-string propagation.
cat > "$TD/_consult/adjudicated.md" <<'MD'
## Cross-verified
- [src/a.py:1] all-three claim [rex+cody+wolffe]
- [src/a.py:2] rex+cody pair [rex+cody, verified by wolffe: AGREE]
- [src/a.py:3] rex+wolffe pair [rex+wolffe, verified by cody: AGREE]
- [src/a.py:4] cody+wolffe pair [cody+wolffe, verified by rex: AGREE]
- [src/a.py:5] rex singleton [rex, verified by cody: AGREE, wolffe: AGREE]
- [src/a.py:6] cody singleton [cody, verified by rex: AGREE, wolffe: AGREE]
- [src/a.py:7] wolffe singleton [wolffe, verified by rex: AGREE, cody: AGREE]

## Contested
- [src/c.py:1] rex+cody disputed [rex+cody, verified by wolffe: DISPUTE]

## Not-verified
MD

# Run synthesize.
../bin/consult-synthesize.sh "$TOPIC" >/dev/null

# v0.17.0: synthesize emits per-section seed drafts, NOT a final design-doc.
DRAFT_DIR="$TD/_consult/design-doc/.draft"
[[ -d "$DRAFT_DIR" ]] || { echo "FAIL: $DRAFT_DIR missing" >&2; exit 1; }

# v0.17.0 negative: legacy synthesis.md and final *-design.md should NOT exist.
[[ ! -f "$TD/_consult/synthesis.md" ]] || { echo "FAIL: legacy synthesis.md still written" >&2; exit 1; }
DD=$(find "$TD/_consult/design-doc" -maxdepth 1 -name '*-design.md' 2>/dev/null | head -1)
[[ -z "$DD" ]] || { echo "FAIL: synthesize emitted final $DD (should be walk-assemble's job)" >&2; exit 1; }

# Concatenate all seed drafts; assert every v0.15 source-set tag appears.
ALL_SEEDS=$(cat "$DRAFT_DIR"/*.md)

assert_contains "$ALL_SEEDS" '[rex+cody+wolffe]'                                 "all-three tag in seeds"
assert_contains "$ALL_SEEDS" '[rex+cody, verified by wolffe: AGREE]'             "rex+cody pair tag in seeds"
assert_contains "$ALL_SEEDS" '[rex+wolffe, verified by cody: AGREE]'             "rex+wolffe pair tag in seeds"
assert_contains "$ALL_SEEDS" '[cody+wolffe, verified by rex: AGREE]'             "cody+wolffe pair tag in seeds"
assert_contains "$ALL_SEEDS" '[rex, verified by cody: AGREE, wolffe: AGREE]'     "rex singleton tag in seeds"
assert_contains "$ALL_SEEDS" '[cody, verified by rex: AGREE, wolffe: AGREE]'     "cody singleton tag in seeds"
assert_contains "$ALL_SEEDS" '[wolffe, verified by rex: AGREE, cody: AGREE]'     "wolffe singleton tag in seeds"
assert_contains "$ALL_SEEDS" '[rex+cody, verified by wolffe: DISPUTE]'           "DISPUTE annotation in seeds"
pass "v0.17 seed drafts preserve all 7 v0.15.0 source-set tag forms + verifier annotations"
