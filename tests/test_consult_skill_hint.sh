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

# === T4 helper integration ===
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"

# v0.15.0: pre-write providers-available.txt fixture (N=2: claude+codex).
mkdir -p "$CLONE_WARS_HOME"
cat > "$CLONE_WARS_HOME/providers-available.txt" <<'EOF'
# fixture
codex
claude
EOF

source ../lib/state.sh
RH=$(cw_repo_hash)
TOPIC=$(../bin/consult-init.sh "design pattern for the cache" 2>/dev/null)
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC/_consult"
assert_eq "$(cat "$TD/skill.txt")" "brainstorming" "init wrote brainstorming skill"

source ../lib/consult.sh
PROMPT=$(cw_consult_skill_hint_append "$TD/skill.txt" "BASE PROMPT")

echo "$PROMPT" | grep -q "^BASE PROMPT$" || { echo "FAIL: base prompt preserved"     >&2; exit 1; }
echo "$PROMPT" | grep -q "AUTONOMY CONTRACT" || { echo "FAIL: hint appended"          >&2; exit 1; }
pass "skill-hint append wires brainstorming hint after base prompt"

# none case: no append.
echo none > "$TD/skill.txt"
PROMPT_NONE=$(cw_consult_skill_hint_append "$TD/skill.txt" "BASE PROMPT")
[[ "$PROMPT_NONE" == "BASE PROMPT" ]] \
  || { echo "FAIL: none should not append; got: $PROMPT_NONE" >&2; exit 1; }
pass "skill=none produces no append"

# missing skill.txt case: defaults to none (no append).
rm -f "$TD/skill.txt"
PROMPT_MISSING=$(cw_consult_skill_hint_append "$TD/skill.txt" "BASE PROMPT")
[[ "$PROMPT_MISSING" == "BASE PROMPT" ]] \
  || { echo "FAIL: missing skill.txt should default to none" >&2; exit 1; }
pass "missing skill.txt defaults to no append"

# CW_CONSULT_SKILL_OVERRIDE=none forces no append.
echo brainstorming > "$TD/skill.txt"
PROMPT_OVR=$(CW_CONSULT_SKILL_OVERRIDE=none cw_consult_skill_hint_append "$TD/skill.txt" "BASE PROMPT")
[[ "$PROMPT_OVR" == "BASE PROMPT" ]] \
  || { echo "FAIL: CW_CONSULT_SKILL_OVERRIDE=none kill-switch broken; got: $PROMPT_OVR" >&2; exit 1; }
pass "CW_CONSULT_SKILL_OVERRIDE=none kill-switch works"

# PLUGIN_ROOT unset → loud failure (rc=2), not silent no-append.
unset PLUGIN_ROOT
unset CLAUDE_PLUGIN_ROOT
echo brainstorming > "$TD/skill.txt"
err=$(cw_consult_skill_hint_append "$TD/skill.txt" "BASE PROMPT" 2>&1) && rc=0 || rc=$?
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"
[[ "$rc" -eq 2 ]] && echo "$err" | grep -q "PLUGIN_ROOT" \
  || { echo "FAIL: missing PLUGIN_ROOT should rc=2 + error msg; got rc=$rc, err='$err'" >&2; exit 1; }
pass "missing PLUGIN_ROOT/CLAUDE_PLUGIN_ROOT fails loud"
