#!/usr/bin/env bash
# tests/test_consult_skill_hint.sh — Task 3 (v0.3.0).
# Verifies skill-hint files exist + are well-formed.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

HINTS=../config/skill-hints

[[ -f "$HINTS/brainstorming.md"        ]] || { echo "FAIL: brainstorming.md missing"        >&2; exit 1; }
[[ -f "$HINTS/systematic-debugging.md" ]] || { echo "FAIL: systematic-debugging.md missing" >&2; exit 1; }
[[ -f "$HINTS/none.md"                 ]] || { echo "FAIL: none.md missing"                 >&2; exit 1; }
pass "all three skill-hint files exist"

# none.md must be empty (or whitespace only).
if [[ -s "$HINTS/none.md" ]]; then
  body_only=$(tr -d '[:space:]' < "$HINTS/none.md")
  [[ -z "$body_only" ]] || { echo "FAIL: none.md must be empty for no-op append" >&2; exit 1; }
fi
pass "none.md is empty"

# brainstorming + systematic-debugging must mention the autonomy contract.
grep -q 'AUTONOMY CONTRACT' "$HINTS/brainstorming.md"        || { echo "FAIL: brainstorming.md missing autonomy contract"        >&2; exit 1; }
grep -q 'AUTONOMY CONTRACT' "$HINTS/systematic-debugging.md" || { echo "FAIL: systematic-debugging.md missing autonomy contract" >&2; exit 1; }
pass "both hints contain AUTONOMY CONTRACT"

# Both must mention the question event format.
grep -q '"event":"question"' "$HINTS/brainstorming.md"        || { echo "FAIL: brainstorming.md missing question event format"        >&2; exit 1; }
grep -q '"event":"question"' "$HINTS/systematic-debugging.md" || { echo "FAIL: systematic-debugging.md missing question event format" >&2; exit 1; }
pass "question event format documented in both hints"

# Both must mention the ANSWER: parse contract.
grep -q 'ANSWER:' "$HINTS/brainstorming.md"        || { echo "FAIL: brainstorming.md missing ANSWER: contract"        >&2; exit 1; }
grep -q 'ANSWER:' "$HINTS/systematic-debugging.md" || { echo "FAIL: systematic-debugging.md missing ANSWER: contract" >&2; exit 1; }
pass "ANSWER: response contract documented in both hints"

# Skill names referenced in hints must resolve to installed SKILL.md files
# (M4 closure). Skip when superpowers not installed in this env.
SKILL_ROOTS=(
  "$HOME/.claude/plugins/cache"
  "$HOME/.codex/superpowers/skills"
)
resolve_skill() {
  local name="$1"
  local root path
  for root in "${SKILL_ROOTS[@]}"; do
    [[ -d "$root" ]] || continue
    path=$(find "$root" -maxdepth 6 -type d -name "$name" 2>/dev/null | head -n1)
    if [[ -n "$path" && -f "$path/SKILL.md" ]]; then return 0; fi
  done
  return 1
}
if resolve_skill brainstorming; then
  pass "superpowers:brainstorming resolves to an installed SKILL.md"
else
  echo "  SKIP: superpowers:brainstorming not installed in this env"
fi
if resolve_skill systematic-debugging; then
  pass "superpowers:systematic-debugging resolves to an installed SKILL.md"
else
  echo "  SKIP: superpowers:systematic-debugging not installed in this env"
fi
