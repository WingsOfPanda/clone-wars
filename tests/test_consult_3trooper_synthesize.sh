#!/usr/bin/env bash
# tests/test_consult_3trooper_synthesize.sh
#
# v0.16.0 contract: bin/consult-synthesize.sh + cw_consult_synthesize must
# propagate 3-trooper source tags from adjudicated.md into the design-doc
# byte-for-byte. The expanded tag set is 7 tags (singletons rex/cody/bly,
# pairs rex+cody/rex+bly/cody+bly, all-three rex+cody+bly) plus per-claim
# verifier annotations like "verified by bly: AGREE".
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
mkdir -p "$TD/_consult/design-doc" "$TD/rex-codex" "$TD/cody-claude" "$TD/bly-opencode"

# Stage minimum prerequisites for synthesize: topic + non-PENDING stage status
# files for both legacy (rex-only/cody-only) inputs the existing API expects.
echo "v0.15 3-trooper tag propagation" > "$TD/_consult/topic.txt"
for stage in research verify; do
  for cmdr in rex cody bly; do
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
- [src/a.py:1] consensus body | rex+cody+bly all raised
## Rex-only
## Cody-only
MD

# Stage adjudicated.md with 7-tag source set + verifier annotations.
# Place all 7 source-set forms in ## Cross-verified or ## Contested so that
# synthesize's awk pattern (Cross-verified|Adjudicated|Contested|Not-verified)
# captures every line. This isolates the test to tag-string propagation.
cat > "$TD/_consult/adjudicated.md" <<'MD'
## Cross-verified
- [src/a.py:1] all-three claim [rex+cody+bly]
- [src/a.py:2] rex+cody pair [rex+cody, verified by bly: AGREE]
- [src/a.py:3] rex+bly pair [rex+bly, verified by cody: AGREE]
- [src/a.py:4] cody+bly pair [cody+bly, verified by rex: AGREE]
- [src/a.py:5] rex singleton [rex, verified by cody: AGREE, bly: AGREE]
- [src/a.py:6] cody singleton [cody, verified by rex: AGREE, bly: AGREE]
- [src/a.py:7] bly singleton [bly, verified by rex: AGREE, cody: AGREE]

## Contested
- [src/c.py:1] rex+cody disputed [rex+cody, verified by bly: DISPUTE]

## Not-verified
MD

# Run synthesize.
../bin/consult-synthesize.sh "$TOPIC" >/dev/null

# v0.16: design-doc replaces synthesis.md.
SLUG="${TOPIC#consult-}"
DESIGN_DOC=$(bash -c "source ../lib/consult.sh; cw_consult_design_doc_canonical_path '$TD/_consult' '$SLUG'")
assert_file_exists "$DESIGN_DOC" "design-doc should be written at canonical path"
[[ ! -f "$TD/_consult/synthesis.md" ]] || { echo "FAIL: legacy synthesis.md still written" >&2; exit 1; }

DD_CONTENT=$(cat "$DESIGN_DOC")

# Singletons (3 tags).
assert_contains "$DD_CONTENT" '[rex+cody+bly]'                                 "all-three tag preserved"
assert_contains "$DD_CONTENT" '[rex+cody, verified by bly: AGREE]'             "rex+cody pair tag preserved"
assert_contains "$DD_CONTENT" '[rex+bly, verified by cody: AGREE]'             "rex+bly pair tag preserved"
assert_contains "$DD_CONTENT" '[cody+bly, verified by rex: AGREE]'             "cody+bly pair tag preserved"
assert_contains "$DD_CONTENT" '[rex, verified by cody: AGREE, bly: AGREE]'     "rex singleton tag preserved"
assert_contains "$DD_CONTENT" '[cody, verified by rex: AGREE, bly: AGREE]'     "cody singleton tag preserved"
assert_contains "$DD_CONTENT" '[bly, verified by rex: AGREE, cody: AGREE]'     "bly singleton tag preserved"
assert_contains "$DD_CONTENT" '[rex+cody, verified by bly: DISPUTE]'           "DISPUTE annotation preserved"
pass "design-doc preserves all 7 v0.15.0 source-set tag forms + verifier annotations"
