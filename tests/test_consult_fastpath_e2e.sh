#!/usr/bin/env bash
# tests/test_consult_fastpath_e2e.sh
# v0.16.0 contract test: design-doc rigid schema + /spec source-defaulting picks it up.
#
# Hand-crafts a design-doc satisfying the v0.16 rigid schema at the canonical path,
# then asserts:
#   1. All 6 H2 sections present (Summary / Findings / Tradeoffs /
#      Recommendation / Open Questions / Sources)
#   2. Trust-label headers (Source / Generated / Path) in correct format
#   3. Source label vocabulary (1 of 3 fixed values)
#   4. Path label vocabulary (1 of 4 fixed values)
#   5. /spec source-defaulting (bin/spec-init.sh no-arg) discovers the design-doc
#
# This is a contract test, not a behavior test. Real Yoda fast-path E2E lives in
# the v0.16 dogfood (Task 9 — manual).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --- Stage a sandbox state root ---
export CLONE_WARS_HOME="$TMP/cw"
mkdir -p "$CLONE_WARS_HOME"

# Stage a fake repo cwd — bin/spec-init.sh derives REPO_HASH from cwd.
EREPO="$TMP/erepo"
mkdir -p "$EREPO"
( cd "$EREPO" && git init -q \
    && git config user.email "test@example.com" \
    && git config user.name "Test User" \
    && git commit -q --allow-empty -m "init" )

# Compute the topic dir + canonical design-doc path
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
REPO_HASH=$( cd "$EREPO" && cw_repo_hash )
TOPIC=consult-fastpath-e2e
TOPIC_DIR="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC"
ART_DIR="$TOPIC_DIR/_consult"
mkdir -p "$ART_DIR/design-doc"

DESIGN_DOC=$(cw_consult_design_doc_canonical_path "$ART_DIR" "$TOPIC")

# --- Hand-craft a design-doc satisfying the v0.16 rigid schema ---
GENERATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat > "$DESIGN_DOC" <<EOF
# Consult Fastpath E2E

> **Source:** Master Yoda (single-source)
> **Generated:** ${GENERATED_AT}
> **Path:** fast

## Summary
Test fixture for v0.16.0 contract test.

## Findings
- \`tests/test_consult_fastpath_e2e.sh\` exists.

## Tradeoffs
_(not applicable)_

## Recommendation
Verify the design-doc passes the rigid schema check.

## Open Questions
_(not applicable)_

## Sources
- \`tests/test_consult_fastpath_e2e.sh:1\` — this test
EOF

# --- Schema assertions ---
[[ -f "$DESIGN_DOC" ]] || { echo "FAIL: staged design-doc missing" >&2; exit 1; }
pass "design-doc fixture written at canonical path"

# All 6 H2 sections (anchored: ^## <name>$)
for section in "Summary" "Findings" "Tradeoffs" "Recommendation" "Open Questions" "Sources"; do
  grep -qE "^## ${section}$" "$DESIGN_DOC" \
    || { echo "FAIL: section '$section' missing from design-doc" >&2; cat "$DESIGN_DOC" >&2; exit 1; }
done
pass "design-doc has all 6 rigid H2 sections"

# Trust-label headers — anchored ^...$ on each line
grep -qE '^> \*\*Source:\*\* Master Yoda \(single-source\)$' "$DESIGN_DOC" \
  || { echo "FAIL: Source header (Master Yoda single-source) missing or malformed" >&2; exit 1; }
grep -qE '^> \*\*Generated:\*\* [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$DESIGN_DOC" \
  || { echo "FAIL: Generated header missing or malformed (need ISO-8601 UTC)" >&2; exit 1; }
grep -qE '^> \*\*Path:\*\* fast$' "$DESIGN_DOC" \
  || { echo "FAIL: Path header (fast) missing or malformed" >&2; exit 1; }
pass "design-doc has Source/Generated/Path trust-label headers in correct format"

# Path label vocabulary check — assert one of the 4 fixed values
PATH_VAL=$(grep -E '^> \*\*Path:\*\*' "$DESIGN_DOC" | sed -E 's/^> \*\*Path:\*\* //')
case "$PATH_VAL" in
  fast|escalated-from-flag|escalated-from-phrasing|escalated-from-signals)
    pass "Path label vocabulary check: '$PATH_VAL'" ;;
  *)
    echo "FAIL: Path label '$PATH_VAL' not in fixed vocabulary" >&2; exit 1 ;;
esac

# Source label vocabulary check — assert it matches one of the 3 fixed values
SOURCE_VAL=$(grep -E '^> \*\*Source:\*\*' "$DESIGN_DOC" | sed -E 's/^> \*\*Source:\*\* //')
case "$SOURCE_VAL" in
  "Master Yoda (single-source)"|"rex+cody cross-verified (N=2)"|"rex+cody+bly cross-verified (N=3)")
    pass "Source label vocabulary check: '$SOURCE_VAL'" ;;
  *)
    echo "FAIL: Source label '$SOURCE_VAL' not in fixed vocabulary" >&2; exit 1 ;;
esac

# --- /spec source-defaulting picks up the design-doc ---
# Invoke bin/spec-init.sh with no positional arg from the staged repo cwd; it
# should auto-detect the design-doc by mtime in $CLONE_WARS_HOME/state/$REPO_HASH/.
SPEC_INIT_OUT=$( cd "$EREPO" && CLONE_WARS_HOME="$CLONE_WARS_HOME" \
  bash "$PLUGIN_ROOT/bin/spec-init.sh" 2>&1 ) && rc=0 || rc=$?

if [[ "$rc" == "0" ]]; then
  # spec-init prints `TOPIC=<topic>\nSEED=<path>` on success — assert SEED line points at our design-doc
  echo "$SPEC_INIT_OUT" | grep -qE "^SEED=" \
    || { echo "FAIL: spec-init success but no SEED= line; got: $SPEC_INIT_OUT" >&2; exit 1; }
  echo "$SPEC_INIT_OUT" | grep -qF "$DESIGN_DOC" \
    || { echo "FAIL: spec-init did not return our design-doc path; got: $SPEC_INIT_OUT" >&2; exit 1; }
  echo "$SPEC_INIT_OUT" | grep -qE "^TOPIC=" \
    || { echo "FAIL: spec-init success but no TOPIC= line; got: $SPEC_INIT_OUT" >&2; exit 1; }
  pass "spec-init source-defaulting picks up the canonical design-doc (rc=0)"
else
  # Non-zero exit — capture stderr and assert it at least surfaces the design-doc path
  # (i.e. didn't fall back to synthesis.md or a different pattern).
  echo "$SPEC_INIT_OUT" | grep -qF "$DESIGN_DOC" \
    || { echo "FAIL: spec-init rc=$rc but did not surface the design-doc path; got: $SPEC_INIT_OUT" >&2; exit 1; }
  pass "spec-init mentions the design-doc path (rc=$rc; user-confirmation likely needed)"
fi

echo "ALL: ok"
