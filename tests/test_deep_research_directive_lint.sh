#!/usr/bin/env bash
# tests/test_deep_research_directive_lint.sh — v0.43.0 PERMANENT LINT
# Asserts:
#   - halt.flag format spec section exists in commands/deep-research.md
#   - Item 9 context-file guidance note exists in commands/deep-research.md Phase 4.a
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib/assert.sh

DIRECTIVE="commands/deep-research.md"
[[ -f "$DIRECTIVE" ]] || { echo "FAIL: $DIRECTIVE missing" >&2; exit 1; }

# Invariant 1: halt.flag format spec section present
grep -qE '^###?#?[[:space:]]*halt\.flag format|^###?#?[[:space:]]*Halt-flag format' "$DIRECTIVE" \
  || { echo "FAIL: directive missing 'halt.flag format' spec section" >&2; exit 1; }
grep -qE 'halted_by=user\|yoda' "$DIRECTIVE" \
  || { echo "FAIL: directive halt.flag spec missing 'halted_by=user|yoda'" >&2; exit 1; }
grep -qE 'halted_at=<ISO' "$DIRECTIVE" \
  || { echo "FAIL: directive halt.flag spec missing 'halted_at=<ISO'" >&2; exit 1; }
pass "1. directive carries halt.flag format spec section with required keys"

# Invariant 2: context-file guidance in Phase 4.a (don't write per-trooper context.md)
PHASE4A=$(awk '/^### Phase 4 — Per-trooper turn loop|^#### 4\.a/,/^### Phase 5/' "$DIRECTIVE")
[[ -n "$PHASE4A" ]] || { echo "FAIL: Phase 4 / 4.a section not found" >&2; exit 1; }
echo "$PHASE4A" | grep -qiE 'context.*belongs in prompt\.md|--context-file' \
  || { echo "FAIL: Phase 4.a missing context-file guidance" >&2; exit 1; }
echo "$PHASE4A" | grep -qiE 'do.{0,5}not.*write.{0,30}context\.md|NOT.{0,30}context\.md' \
  || { echo "FAIL: Phase 4.a missing the explicit 'do not write context.md' clause" >&2; exit 1; }
pass "2. Phase 4.a carries context-file guidance note"

# Invariant 3 (v0.44.0): Phase 1.5 SOTA sweep section present
grep -qE '^### Phase 1\.5 — SOTA sweep$' "$DIRECTIVE" \
  || { echo "FAIL: directive missing '### Phase 1.5 — SOTA sweep' heading" >&2; exit 1; }
grep -qE 'cw_deep_research_format_sota_block' "$DIRECTIVE" \
  || { echo "FAIL: Phase 1.5 missing cw_deep_research_format_sota_block call" >&2; exit 1; }
pass "3. directive carries Phase 1.5 SOTA sweep section invoking the helper"

# Invariant 4 (v0.44.0): dispatch documentation references '## Reference: SOTA'
grep -qE '## Reference: SOTA' "$DIRECTIVE" \
  || { echo "FAIL: directive missing '## Reference: SOTA' documentation in dispatch flow" >&2; exit 1; }
pass "4. directive documents '## Reference: SOTA' section in dispatch flow"

# Invariant 5 (v0.45.0): Phase 4.a documents '## Peers' callout
echo "$PHASE4A" | grep -qE '## Peers' \
  || { echo "FAIL: Phase 4.a missing '## Peers' callout" >&2; exit 1; }
pass "5. Phase 4.a carries '## Peers' visibility callout"

echo "test_deep_research_directive_lint: 5 invariants locked"
