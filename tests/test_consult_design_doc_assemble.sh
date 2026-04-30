#!/usr/bin/env bash
# tests/test_consult_design_doc_assemble.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/consult.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
SECTIONS="$TMP/sections"; mkdir -p "$SECTIONS"
OUT="$TMP/design.md"

# Fixture: 4 sections present, error-handling missing.
cat > "$SECTIONS/architecture.md" <<'MD'
The system uses pane-based file IPC.

Two troopers run in tmux panes; conductor coordinates via inbox/outbox files.
The design-doc phase consumes their cross-verified output.

## Tech Stack
- bash 4.2+
- tmux 3.0+
MD

cat > "$SECTIONS/components.md" <<'MD'
- consult-design-doc.sh: orchestrator
- lib/consult.sh: helpers
MD

cat > "$SECTIONS/data-flow.md" <<'MD'
Inputs read from $TOPIC_DIR/_consult/.
MD

cat > "$SECTIONS/testing.md" <<'MD'
Five unit-style tests + one manual dogfood.
MD

# error-handling.md intentionally missing.

cw_consult_design_doc_assemble "$SECTIONS" "$OUT" "Test Topic"

[[ -s "$OUT" ]] || { echo "FAIL: output empty"; exit 1; }
grep -q '^# Test Topic Design$'                    "$OUT" || { echo "FAIL: title"; exit 1; }
grep -q '^\*\*Goal:\*\*'                           "$OUT" || { echo "FAIL: goal line"; exit 1; }
grep -q '^\*\*Architecture:\*\*'                   "$OUT" || { echo "FAIL: arch line"; exit 1; }
grep -q '^\*\*Tech Stack:\*\*'                     "$OUT" || { echo "FAIL: tech stack line"; exit 1; }
grep -q '^---$'                                    "$OUT" || { echo "FAIL: separator"; exit 1; }
grep -q '^## Architecture$'                        "$OUT" || { echo "FAIL: arch heading"; exit 1; }
grep -q '^## Components$'                          "$OUT" || { echo "FAIL: components heading"; exit 1; }
grep -q '^## Data Flow$'                           "$OUT" || { echo "FAIL: data flow heading"; exit 1; }
grep -q '^## Error Handling$'                      "$OUT" || { echo "FAIL: error handling heading"; exit 1; }
grep -q '^## Testing$'                             "$OUT" || { echo "FAIL: testing heading"; exit 1; }
grep -q '_(skipped)_'                              "$OUT" || { echo "FAIL: missing-section placeholder"; exit 1; }
pass "assemble produces full doc with skipped-section placeholder"

# Empty title rejects.
if cw_consult_design_doc_assemble "$SECTIONS" "$TMP/x.md" "" 2>/dev/null; then
  echo "FAIL: empty title should reject"; exit 1
fi
pass "empty title rejects"

# Missing section dir rejects.
if cw_consult_design_doc_assemble "$TMP/no-such-dir" "$TMP/y.md" "T" 2>/dev/null; then
  echo "FAIL: missing dir should reject"; exit 1
fi
pass "missing dir rejects"

# v0.4.1 — Case A: 4th arg overrides title with topic-text source.
OUT_A="$TMP/case_a.md"
cw_consult_design_doc_assemble "$SECTIONS" "$OUT_A" "Decide Between Lru A" "decide between LRU and LFU cache eviction"
grep -q '^# Decide Between Lru And Lfu Cache Eviction Design$' "$OUT_A" \
  || { echo "FAIL: title should be Title-Cased from topic-text 4th arg"; head -1 "$OUT_A" >&2; exit 1; }
pass "v0.4.1: title from topic-text override"

# v0.4.1 — Case A.2: empty 4th arg falls back to slug-derived title.
OUT_A2="$TMP/case_a2.md"
cw_consult_design_doc_assemble "$SECTIONS" "$OUT_A2" "Test Topic" ""
grep -q '^# Test Topic Design$' "$OUT_A2" \
  || { echo "FAIL: empty topic-text should fall back to title arg"; exit 1; }
pass "v0.4.1: empty topic-text falls back to title arg"
