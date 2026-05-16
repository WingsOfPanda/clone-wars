#!/usr/bin/env bash
# tests/test_spawn_collision_message.sh
# v0.40.0: cw_format_collision_error (new helper in lib/commanders.sh)
# must include the owning session id prefix when .session_id exists
# alongside the colliding trooper state dir.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib/assert.sh

# Sandbox: a fake CLONE_WARS_HOME with one occupied (topic, commander).
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

export CLONE_WARS_HOME="$SANDBOX/clone-wars-home"
mkdir -p "$CLONE_WARS_HOME"

# Source lib in dependency order: state → ipc → commanders.
source lib/state.sh
source lib/ipc.sh
source lib/commanders.sh

TOPIC=parallel-test
COMMANDER=rex
MODEL=codex

# Create the trooper state dir as if a prior session owned it.
TROOPER_DIR=$(cw_trooper_dir "$COMMANDER" "$MODEL" "$TOPIC")
mkdir -p "$TROOPER_DIR"
OWNER_SID=aaaaaaaa-1111-2222-3333-444444444444
echo "$OWNER_SID" > "$TROOPER_DIR/.session_id"

# Case 1: this session is different from the owner — owner prefix appears.
export CLAUDE_CODE_SESSION_ID=bbbbbbbb-5555-6666-7777-888888888888
out=$(cw_format_collision_error "$COMMANDER" "$MODEL" "$TOPIC")
[[ "$out" == *"is already deployed on $TOPIC"* ]] \
  || { echo "FAIL: case 1 — header line missing:" >&2; echo "$out" >&2; exit 1; }
[[ "$out" == *"owned by another Claude Code session"* ]] \
  || { echo "FAIL: case 1 — 'owned by another' marker missing:" >&2; echo "$out" >&2; exit 1; }
[[ "$out" == *"${OWNER_SID:0:8}"* ]] \
  || { echo "FAIL: case 1 — owner prefix (${OWNER_SID:0:8}) missing:" >&2; echo "$out" >&2; exit 1; }
[[ "$out" == *"/clone-wars:teardown $COMMANDER $TOPIC"* ]] \
  || { echo "FAIL: case 1 — teardown suggestion missing:" >&2; echo "$out" >&2; exit 1; }
pass "1. error message includes owner session prefix when foreign owner exists"

# Case 2: same session retries on its own collision — no 'owned by another' line.
export CLAUDE_CODE_SESSION_ID="$OWNER_SID"
out=$(cw_format_collision_error "$COMMANDER" "$MODEL" "$TOPIC")
[[ "$out" == *"is already deployed on $TOPIC"* ]] \
  || { echo "FAIL: case 2 — header line missing:" >&2; echo "$out" >&2; exit 1; }
[[ "$out" != *"owned by another"* ]] \
  || { echo "FAIL: case 2 — 'owned by another' should NOT appear for same session:" >&2; echo "$out" >&2; exit 1; }
pass "2. no 'owned by another' line when collision is same-session"

# Case 3: no .session_id sibling (pre-v0.40.0 state) — graceful degradation.
rm -f "$TROOPER_DIR/.session_id"
export CLAUDE_CODE_SESSION_ID=bbbbbbbb-5555-6666-7777-888888888888
out=$(cw_format_collision_error "$COMMANDER" "$MODEL" "$TOPIC")
[[ "$out" == *"is already deployed on $TOPIC"* ]] \
  || { echo "FAIL: case 3 — header missing on legacy state:" >&2; echo "$out" >&2; exit 1; }
[[ "$out" != *"owned by another"* ]] \
  || { echo "FAIL: case 3 — should not claim 'owned by another' without .session_id evidence:" >&2; echo "$out" >&2; exit 1; }
pass "3. graceful when .session_id absent (pre-v0.40.0 trooper state)"
