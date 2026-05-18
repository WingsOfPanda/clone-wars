#!/usr/bin/env bash
# tests/test_deep_research_halt_flag_format_resume.sh
# v0.43.0 Lane E: directive-shape assertion — Step 6 user-halt block in
# commands/deep-research-resume.md writes structured key=value lines.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib/assert.sh

DIRECTIVE="commands/deep-research-resume.md"
[[ -f "$DIRECTIVE" ]] || { echo "FAIL: $DIRECTIVE missing" >&2; exit 1; }

# Locate the user-halt block (was line 116-118; should now span the new multi-line write)
BLOCK=$(awk '/Halt intent/,/Jump to Step 2/' "$DIRECTIVE")
[[ -n "$BLOCK" ]] || { echo "FAIL: Halt intent block not found" >&2; exit 1; }

echo "$BLOCK" | grep -qE 'halted_by=user'   || { echo "FAIL: directive missing halted_by=user write" >&2; echo "$BLOCK" >&2; exit 1; }
echo "$BLOCK" | grep -qE 'halted_at='        || { echo "FAIL: directive missing halted_at= write" >&2; echo "$BLOCK" >&2; exit 1; }
echo "$BLOCK" | grep -qE 'reason='           || { echo "FAIL: directive missing reason= write" >&2; echo "$BLOCK" >&2; exit 1; }
pass "1. directive Step 6 user-halt block uses key=value halt.flag format"

echo "test_deep_research_halt_flag_format_resume: 1 case passed"
