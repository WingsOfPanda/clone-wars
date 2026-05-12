#!/usr/bin/env bash
# tests/test_meditate_research_send_lit_guidance.sh — lit-track propagation
# from _meditate/lit-track.txt into the rendered trooper prompt's
# {{LIT_GUIDANCE}} placeholder.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

SANDBOX=$(mktemp -d -t cw-meditate-lit.XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT
export CLONE_WARS_HOME="$SANDBOX"

# Seed providers + contracts (mirrors test_meditate_init.sh)
printf 'codex\nclaude\n' > "$SANDBOX/providers-available.txt"
cat > "$SANDBOX/contracts.yaml" <<'EOF'
codex:
  binary: codex
  permission: allow
claude:
  binary: claude
  permission: allow
opencode:
  binary: opencode
  permission: allow
EOF

# Init the meditate topic
TOPIC=$("$PLUGIN_ROOT/bin/meditate-init.sh" "explore SOTA continuous batching" 2>/dev/null)
REPO_HASH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
ART_DIR="$SANDBOX/state/$REPO_HASH/$TOPIC/_meditate"

# Seed a fake trooper outbox so send-script's outbox-existence check passes
TROOPER_DIR="$SANDBOX/state/$REPO_HASH/$TOPIC/rex-codex"
mkdir -p "$TROOPER_DIR"
touch "$TROOPER_DIR/outbox.jsonl"

# --- ON case ---
printf 'ON\nreason: test\n' > "$ART_DIR/lit-track.txt"
CW_MEDITATE_DRY_RUN=1 "$PLUGIN_ROOT/bin/meditate-research-send.sh" "$TOPIC" rex codex 2>/dev/null
PROMPT_FILE="$ART_DIR/rex_research_prompt.md"
[[ -f "$PROMPT_FILE" ]] || { echo "FAIL: prompt file not written"; exit 1; }
grep -qiF 'prioritize peer-reviewed' "$PROMPT_FILE" \
  || { echo "FAIL: ON-case rendering missing 'prioritize peer-reviewed' in $PROMPT_FILE"; head -50 "$PROMPT_FILE"; exit 1; }
pass "ON case renders the academic-emphasis LIT_GUIDANCE block"

# Reset for OFF case
rm -f "$ART_DIR/research-rex.txt" "$PROMPT_FILE"

# --- OFF case ---
printf 'OFF\nreason: test\n' > "$ART_DIR/lit-track.txt"
CW_MEDITATE_DRY_RUN=1 "$PLUGIN_ROOT/bin/meditate-research-send.sh" "$TOPIC" rex codex 2>/dev/null
[[ -f "$PROMPT_FILE" ]] || { echo "FAIL: prompt file not written for OFF case"; exit 1; }
grep -qiF 'not academic-shaped' "$PROMPT_FILE" \
  || { echo "FAIL: OFF-case rendering missing 'not academic-shaped' in $PROMPT_FILE"; head -50 "$PROMPT_FILE"; exit 1; }
pass "OFF case renders the brief-SOTA LIT_GUIDANCE block"

# --- Missing lit-track.txt → defensive OFF fallback ---
rm -f "$ART_DIR/research-rex.txt" "$PROMPT_FILE" "$ART_DIR/lit-track.txt"
CW_MEDITATE_DRY_RUN=1 "$PLUGIN_ROOT/bin/meditate-research-send.sh" "$TOPIC" rex codex 2>/dev/null
[[ -f "$PROMPT_FILE" ]] || { echo "FAIL: prompt file not written for missing-lit-track case"; exit 1; }
grep -qiF 'not academic-shaped' "$PROMPT_FILE" \
  || { echo "FAIL: missing-lit-track defensive fallback didn't use OFF block"; head -50 "$PROMPT_FILE"; exit 1; }
pass "missing lit-track.txt falls back to OFF guidance (defensive)"

pass "lit-track propagation into trooper prompt works across 3 cases"
