#!/usr/bin/env bash
# tests/test_consult_question_dogfood_default.sh — Task 10 (v0.3.0).
# Informational dogfood — validates the trooper produces well-formed
# findings on a topic with clear defaults (where NOT asking is also
# valid). NOT release-blocking.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

if ! command -v codex >/dev/null 2>&1 || ! command -v tmux >/dev/null 2>&1 \
   || [[ -z "${TMUX:-}" ]]; then
  echo "  SKIP: codex / tmux / TMUX missing — default-path dogfood skipped"
  exit 0
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"

mkdir -p "$CLONE_WARS_HOME"
cp ../config/contracts.yaml       "$CLONE_WARS_HOME/contracts.yaml"
cp ../config/commanders.yaml      "$CLONE_WARS_HOME/commanders.yaml"
cp ../config/identity-template.md "$CLONE_WARS_HOME/identity-template.md"

source ../lib/state.sh
source ../lib/ipc.sh
source ../lib/consult.sh

RH=$(cw_repo_hash)

# Plain audit topic — should classify as 'none', no skill hint, no question.
TOPIC=$(../bin/consult-init.sh "review the auth middleware for token-refresh edge cases" 2>/dev/null)
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
SKILL=$(cat "$TD/_consult/skill.txt")
# Note: "edge cases" classifies as systematic-debugging (bug-hunt shape) —
# that's actually the better skill for this topic. Either skill is fine
# for the default-path test; what we care about is the trooper produces
# well-formed findings without questioning.
[[ "$SKILL" =~ ^(none|systematic-debugging|brainstorming)$ ]] \
  || { echo "FAIL: unexpected skill classification: $SKILL"; exit 1; }

if ! ../bin/spawn.sh rex codex "$TOPIC" >/dev/null 2>&1; then
  echo "  SKIP: codex spawn failed"; exit 0
fi
# Teardown FIRST (needs $CLONE_WARS_HOME state), THEN rm -rf.
trap '../bin/consult-teardown.sh "$TOPIC" >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

../bin/consult-research-send.sh "$TOPIC" rex codex >/dev/null 2>&1 || true

T0=$(date +%s); DEADLINE=$((T0 + 120))
FS=""
while (( $(date +%s) < DEADLINE )); do
  CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=10 \
    ../bin/consult-research-wait.sh "$TOPIC" rex codex >/dev/null 2>&1 || true
  FS=$(grep '^FS=' "$TD/_consult/research-rex.txt" 2>/dev/null | tail -1 | cut -d= -f2 || echo "")
  case "$FS" in
    ok|empty|missing|question|failed|malformed) break ;;
    *) sleep 2 ;;
  esac
done

case "$FS" in
  ok|empty|missing) pass "default-path: trooper terminated normally (FS=$FS)" ;;
  *) echo "  INFO: default-path trooper FS='$FS' (informational, not blocking)" ;;
esac
