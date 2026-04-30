#!/usr/bin/env bash
# tests/test_consult_design_doc_self_review.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/consult.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Clean doc — rc=0.
CLEAN="$TMP/clean.md"
cat > "$CLEAN" <<'MD'
# Foo Design

This is a complete spec with no placeholders.
MD
cw_consult_design_doc_self_review "$CLEAN" 2>"$TMP/err1" || { echo "FAIL: clean doc should pass"; exit 1; }
[[ ! -s "$TMP/err1" ]] || { echo "FAIL: clean doc produced stderr"; cat "$TMP/err1"; exit 1; }
pass "clean doc passes"

# Doc with TBD.
DIRTY1="$TMP/dirty1.md"
cat > "$DIRTY1" <<'MD'
# Foo Design

The retry logic is TBD.
MD
if cw_consult_design_doc_self_review "$DIRTY1" 2>"$TMP/err2"; then
  echo "FAIL: TBD should fail"; exit 1
fi
grep -q 'TBD' "$TMP/err2" || { echo "FAIL: stderr should mention TBD"; exit 1; }
pass "TBD detected"

# Doc with bare ellipsis.
DIRTY2="$TMP/dirty2.md"
cat > "$DIRTY2" <<'MD'
# Foo Design

The flow goes here ... and then onward.
MD
if cw_consult_design_doc_self_review "$DIRTY2" 2>/dev/null; then
  echo "FAIL: bare ellipsis should fail"; exit 1
fi
pass "bare ellipsis detected"

# TBD inside fenced code block — still flagged.
DIRTY3="$TMP/dirty3.md"
cat > "$DIRTY3" <<'MD'
# Foo Design

```bash
echo TBD
```
MD
if cw_consult_design_doc_self_review "$DIRTY3" 2>/dev/null; then
  echo "FAIL: TBD in code fence should still flag"; exit 1
fi
pass "TBD in code fence still flagged (no false-negative)"

# Missing file rejects.
if cw_consult_design_doc_self_review "$TMP/no-such-doc.md" 2>/dev/null; then
  echo "FAIL: missing file should reject"; exit 1
fi
pass "missing file rejects"
