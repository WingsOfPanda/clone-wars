#!/usr/bin/env bash
# tests/test_deep_research_extract_approaches.sh — parse meditate landscape's ## Approaches
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Fixture: realistic meditate landscape shape
cat >"$TMPDIR/landscape.md" <<'EOF'
# Landscape: SOTA autoresearch

## Summary
Some prose.

## Approaches

1. **AIDE tree search** — depth-first iteration with UCB1 selection over solution variants.
2. **Sequential MCTS** — Monte Carlo tree search with rollouts and value estimation.
3. **Greedy hill climb** — local search with no backtracking.

## Tradeoffs
Other content.
EOF

result=$(cw_deep_research_extract_approaches "$TMPDIR/landscape.md")
got_lines=$(echo "$result" | wc -l | tr -d ' ')
[[ "$got_lines" == "3" ]] || { echo "FAIL: expected 3 lines, got $got_lines" >&2; echo "DEBUG: $result" >&2; exit 1; }
pass "3 approaches extracted"

first=$(echo "$result" | head -1)
[[ "$first" == "AIDE tree search"$'\t'* ]] \
  || { echo "FAIL: first label wrong: '$first'" >&2; exit 1; }
pass "first approach has correct label"

[[ "$first" == *"depth-first iteration"* ]] \
  || { echo "FAIL: first brief missing" >&2; exit 1; }
pass "first approach has brief"

# No ## Approaches section → empty
cat >"$TMPDIR/no-approaches.md" <<'EOF'
# Landscape

## Summary
Just summary.

## Tradeoffs
Some tradeoffs but no approaches.
EOF
result=$(cw_deep_research_extract_approaches "$TMPDIR/no-approaches.md")
[[ -z "$result" ]] || { echo "FAIL: expected empty, got '$result'" >&2; exit 1; }
pass "no Approaches section → empty"

# Missing file → error
if cw_deep_research_extract_approaches "$TMPDIR/missing.md" 2>/dev/null; then
  echo "FAIL: missing file should error" >&2; exit 1
fi
pass "missing file errors"

# Section boundary: doesn't bleed into next section
cat >"$TMPDIR/bounded.md" <<'EOF'
## Approaches

1. **First** — only this one.

## Other Section

2. **Should not be captured** — different section.
EOF
result=$(cw_deep_research_extract_approaches "$TMPDIR/bounded.md")
got_lines=$(echo "$result" | wc -l | tr -d ' ')
[[ "$got_lines" == "1" ]] || { echo "FAIL: section bleeding; got $got_lines lines" >&2; exit 1; }
pass "section boundary respected"

echo "test_deep_research_extract_approaches: 6 assertions green"
