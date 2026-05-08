#!/usr/bin/env bash
# tests/test_consult_synthesize_bin.sh
#
# v0.16.0 — synthesize writes the canonical design-doc at
#   _consult/design-doc/<YYYY-MM-DD>-<slug>-design.md
# with the rigid 6-section schema and the Source/Generated/Path trust-label
# header. The legacy _consult/synthesis.md write is REMOVED entirely.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=consult-fixture-syn
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_consult/design-doc" "$TD/rex-codex" "$TD/cody-claude"

# Pre-populate state.
echo "topic text" > "$TD/_consult/topic.txt"
cat > "$TD/_consult/research-rex.txt"  <<EOF
OFFSET=0
FS=ok
EOF
cat > "$TD/_consult/research-cody.txt" <<EOF
OFFSET=0
FS=ok
EOF
cat > "$TD/_consult/verify-rex.txt"  <<EOF
OFFSET=0
VS=ok
EOF
cat > "$TD/_consult/verify-cody.txt" <<EOF
OFFSET=0
VS=ok
EOF
cat > "$TD/_consult/diff.md" <<'MD'
## Agreed
- [src/x.py:5] both | Both confirm.
## Rex-only
## Cody-only
MD

# Compute the canonical design-doc path the same way the bin script does.
ART_DIR="$TD/_consult"
SLUG="${TOPIC#consult-}"
DESIGN_DOC=$(bash -c "source ../lib/consult.sh; cw_consult_design_doc_canonical_path '$ART_DIR' '$SLUG'")

# 1. adjudicated.md missing → rc=1.
err=$(../bin/consult-synthesize.sh "$TOPIC" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$err" | grep -q 'adjudicated.md' \
  || { echo "FAIL: missing adjudicated.md should reject" >&2; exit 1; }
pass "synthesize refuses without adjudicated.md"

# 2. adjudicated.md with PENDING → rc=1.
cat > "$TD/_consult/adjudicated.md" <<'MD'
## Cross-verified
## Adjudicated
- PENDING: [src/y.py:10] needs resolution
## Contested
## Not-verified
MD
err=$(../bin/consult-synthesize.sh "$TOPIC" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$err" | grep -q 'PENDING' \
  || { echo "FAIL: PENDING should block" >&2; exit 1; }
pass "synthesize refuses with PENDING items"

# 3. Resolved adjudicated.md → rc=0; design-doc created at canonical path,
#    legacy synthesis.md NOT written.
sed -i 's/^- PENDING:/- CONFIRMED:/' "$TD/_consult/adjudicated.md"
../bin/consult-synthesize.sh "$TOPIC" >/dev/null

[[ -f "$DESIGN_DOC" ]] \
  || { echo "FAIL: design-doc not at canonical path: $DESIGN_DOC" >&2; ls -la "$TD/_consult/design-doc/" >&2 || true; exit 1; }
pass "synthesize writes design-doc at canonical path"

[[ ! -f "$TD/_consult/synthesis.md" ]] \
  || { echo "FAIL: legacy synthesis.md still written" >&2; exit 1; }
pass "synthesize no longer writes legacy synthesis.md"

# 4. Rigid 6-section schema.
for section in "Summary" "Findings" "Tradeoffs" "Recommendation" "Open Questions" "Sources"; do
  grep -qE "^## ${section}\$" "$DESIGN_DOC" \
    || { echo "FAIL: section '## $section' missing from design-doc" >&2; cat "$DESIGN_DOC" >&2; exit 1; }
done
pass "design-doc has all 6 rigid sections"

# 5. Trust-label header (Source / Generated / Path).
grep -qE '^> \*\*Source:\*\*'    "$DESIGN_DOC" \
  || { echo "FAIL: Source: header missing" >&2; cat "$DESIGN_DOC" >&2; exit 1; }
grep -qE '^> \*\*Generated:\*\*' "$DESIGN_DOC" \
  || { echo "FAIL: Generated: header missing" >&2; cat "$DESIGN_DOC" >&2; exit 1; }
grep -qE '^> \*\*Path:\*\*'      "$DESIGN_DOC" \
  || { echo "FAIL: Path: header missing" >&2; cat "$DESIGN_DOC" >&2; exit 1; }
pass "design-doc has Source/Generated/Path trust-label headers"

# 6. Re-running on existing design-doc → rc=1.
err=$(../bin/consult-synthesize.sh "$TOPIC" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: re-run on existing design-doc should reject" >&2; exit 1; }
pass "synthesize fails loud on existing design-doc"
