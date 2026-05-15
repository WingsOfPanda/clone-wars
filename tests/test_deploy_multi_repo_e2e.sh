#!/usr/bin/env bash
# tests/test_deploy_multi_repo_e2e.sh
# v0.22.0 — end-to-end seal for the multi-repo deploy preflight + dispatch seam.
#
# Skips when $TMUX is unset (mirrors other tmux-dependent tests in this suite).
# When $TMUX IS set, runs all preflight + spawn + dispatch ops inside a DETACHED
# test tmux session ("cw-e2e-$$") so the user's interactive session is never
# disturbed (no layout reflows, no orphan panes). Cleanup is a single
# `tmux kill-session` call.
#
# Asserts the full chain:
#   deploy-init → deploy-dag-parse → deploy-multi-init → preflight-layout
#   → spawn (--target-pane validation) → bin/send.sh dispatch → tmux nudge.
#
# This single test would have caught all 5 v0.21.0 dogfood bugs in one run.
set -uo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

if [[ -z "${TMUX:-}" ]]; then
  echo "  SKIP: not in tmux session"
  exit 0
fi

PLUGIN_ROOT="$(cd .. && pwd)"
SANDBOX=$(mktemp -d)
TEST_SESSION="cw-e2e-$$"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"
mkdir -p "$CLONE_WARS_HOME"

cleanup() {
  tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

# 1. Synthesize a hub with 3 sub-repos: one flat sibling, two nested CapWords
HUB="$SANDBOX/hub"
mkdir -p "$HUB/flat-sib" "$HUB/inner/CapWordsA" "$HUB/inner/CapWordsB"
for d in "$HUB/flat-sib" "$HUB/inner/CapWordsA" "$HUB/inner/CapWordsB"; do
  echo "# $(basename "$d")" > "$d/CLAUDE.md"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init )
done
# Hub itself needs a git repo for cw_repo_root resolution
( cd "$HUB" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init )

# 2. Hand-craft a multi-repo design doc with parser-conforming DAG lines.
# Use absolute paths in DAG lines (v0.21.0 feature) so deploy-dag-parse
# populates the path field correctly for the nested CapWords sub-repos.
DESIGN="$HUB/design.md"
cat > "$DESIGN" <<EOF
# E2E test design

**Target Sub-Project(s):** flat-sib, CapWordsA, CapWordsB

## Problem
Test the deploy seam.

## Goal
Trooper dispatch works end-to-end in nested heterogeneous fleet.

## Architecture
Three sub-repos, three troopers, single wave.

## Components
- flat-sib: synthetic
- CapWordsA: synthetic (nested)
- CapWordsB: synthetic (nested)

## Execution DAG

1. flat-sib — flat sibling case
2. CapWordsA ($HUB/inner/CapWordsA) — nested CapWords case A
3. CapWordsB ($HUB/inner/CapWordsB) — nested CapWords case B

## Testing
This file.

## Success Criteria
- [ ] Each pane gets a tmux nudge after dispatch.
EOF

# 3. Run deploy-init from $HUB (the conductor's cwd in real flow). v0.31.0:
# CW_TOPIC_REPO_CWD env var is dead; cw_topic_repo_hash uses $PWD verbatim,
# so the cd into $HUB is sufficient.
TOPIC="e2e$$"
( cd "$HUB" \
  && "$PLUGIN_ROOT/bin/deploy-init.sh" --no-branch --topic "$TOPIC" "$DESIGN" >/dev/null )

REPO_HASH=$(cd "$HUB" && cw_repo_hash)
ART_DIR="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC/_deploy"

# 4. Verify all 4 expected sidecar files (closes Bug 0 — would have shown
# missing troopers-preflight.txt before this PR landed).
assert_file_exists "$ART_DIR/troopers.txt"           "troopers.txt written"
assert_file_exists "$ART_DIR/troopers-preflight.txt" "troopers-preflight.txt written (sidecar)"
assert_file_exists "$ART_DIR/cmdr-cwd-map.txt"       "cmdr-cwd-map.txt written"
assert_file_exists "$ART_DIR/dag-waves.txt"          "dag-waves.txt written"
pass "deploy-init produces all 4 sidecar files (incl. v0.22.0 troopers-preflight.txt)"

# 5. Create a DETACHED test tmux session — preflight will split panes off its
# initial pane, isolated from the user's interactive session.
tmux new-session -d -s "$TEST_SESSION" -x 240 -y 60 "sleep infinity" \
  || { echo "FAIL: could not create detached tmux session" >&2; exit 1; }
# Get initial pane id of the test session
TEST_INITIAL_PANE=$(tmux list-panes -t "$TEST_SESSION" -F '#{pane_id}' | head -1)
[[ -n "$TEST_INITIAL_PANE" ]] \
  || { echo "FAIL: could not discover test session's initial pane" >&2; exit 1; }

# 6. Run preflight-layout with the v0.22.0 flag triple, targeting the test session
N=$(grep -cvE '^[[:space:]]*(#|$)' "$ART_DIR/troopers-preflight.txt")
TMUX_PANE="$TEST_INITIAL_PANE" \
  "$PLUGIN_ROOT/bin/preflight-layout.sh" \
    --art-dir "$ART_DIR" \
    --cwd-from "$ART_DIR/cmdr-cwd-map.txt" \
    --troopers-from "$ART_DIR/troopers-preflight.txt" \
    "$TOPIC" "$N" >/dev/null 2>&1 \
  || { echo "FAIL: preflight-layout failed" >&2; tmux capture-pane -p -t "$TEST_INITIAL_PANE" >&2; exit 1; }

assert_file_exists "$ART_DIR/preflight-panes.txt" "preflight-panes.txt written"

# 7. Verify preflight-panes.txt has commander names (NOT paths) in column 1 —
# closes Bugs 2/3.
while IFS=$'\t' read -r cmdr pane; do
  [[ -n "$cmdr" && -n "$pane" ]] || continue
  [[ "$cmdr" =~ ^[a-z0-9-]+$ ]] \
    || { echo "FAIL: preflight-panes.txt col 1 has non-commander value: '$cmdr' (BUG 2/3 not closed)" >&2; exit 1; }
  [[ "$pane" =~ ^%[0-9]+$ ]] \
    || { echo "FAIL: preflight-panes.txt col 2 not a pane id: '$pane'" >&2; exit 1; }
done < "$ART_DIR/preflight-panes.txt"
pass "preflight-panes.txt has commander-keyed rows (BUGS 2/3 closed)"

# 8. Verify each pane's cwd matches its sub-repo — closes Bug 4.
declare -A CWD_MAP
while IFS=$'\t' read -r cmdr cwd; do
  CWD_MAP["$cmdr"]="$cwd"
done < "$ART_DIR/cmdr-cwd-map.txt"

while IFS=$'\t' read -r cmdr pane; do
  [[ -n "$cmdr" && -n "$pane" ]] || continue
  expected_cwd="${CWD_MAP[$cmdr]:-}"
  [[ -n "$expected_cwd" ]] \
    || { echo "FAIL: no cmdr-cwd-map entry for commander '$cmdr'" >&2; exit 1; }
  actual_cwd=$(tmux display-message -p -t "$pane" '#{pane_current_path}' 2>/dev/null || echo "")
  [[ "$actual_cwd" == "$expected_cwd" ]] \
    || { echo "FAIL: pane $pane (cmdr=$cmdr) cwd is '$actual_cwd', expected '$expected_cwd' (BUG 4 not closed)" >&2; exit 1; }
done < "$ART_DIR/preflight-panes.txt"
pass "each preflight pane allocated in its sub-repo cwd (BUG 4 closed; v0.20.3 behavior restored)"

# 9. Test spawn --target-pane validation with --preflight-art-dir (closes Bug 1).
# Bogus pane id should be rejected — proves spawn is reading the OVERRIDE path.
FIRST_LINE=$(grep -vE '^[[:space:]]*(#|$)' "$ART_DIR/preflight-panes.txt" | head -1)
IFS=$'\t' read -r FIRST_CMDR FIRST_PANE <<<"$FIRST_LINE"

err=$( "$PLUGIN_ROOT/bin/spawn.sh" "$FIRST_CMDR" codex "$TOPIC" \
  --target-pane "%99999" \
  --preflight-art-dir "$ART_DIR" 2>&1 ) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: bogus pane id should rc!=0" >&2; exit 1; }
echo "$err" | grep -qE "not in preflight-panes\.txt" \
  || { echo "FAIL: error should mention pane not in preflight-panes.txt: $err" >&2; exit 1; }
pass "spawn --preflight-art-dir validates against override path (BUG 1 closed)"

# 10. Confirm valid pane id passes spawn's --target-pane validation.
err2=$( "$PLUGIN_ROOT/bin/spawn.sh" "$FIRST_CMDR" codex "$TOPIC" \
  --target-pane "$FIRST_PANE" \
  --preflight-art-dir "$ART_DIR" 2>&1 ) && rc2=0 || rc2=$?
echo "$err2" | grep -q "not in preflight-panes.txt" \
  && { echo "FAIL: validation rejected a valid pane id: $err2" >&2; exit 1; }
pass "spawn --preflight-art-dir validation accepts pane that's in override file"

# 11. Smoke-test bin/send.sh dispatch nudges the pane via tmux send-keys —
# closes Bug 5. Manually craft minimal trooper state so send.sh can find
# pane.json + state dir (real flow: spawn writes these).
TROOPER_STATE_DIR="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC/$FIRST_CMDR-codex"
mkdir -p "$TROOPER_STATE_DIR"
printf '{"pane_id":"%s","pid":0,"spawned_at":"%s"}\n' \
  "$FIRST_PANE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TROOPER_STATE_DIR/pane.json"
: > "$TROOPER_STATE_DIR/outbox.jsonl"

PROMPT_FILE="$ART_DIR/${FIRST_CMDR}_dag_unit_prompt.md"
echo "TEST PROMPT v0.22.0 e2e: please read inbox and start working" > "$PROMPT_FILE"

# Replace the preflight sentinel (which runs `sleep infinity` and does NOT
# echo stdin) with `cat` so tmux send-keys input becomes visible in
# capture-pane. In real flow this is what spawn does via cw_pane_respawn —
# replaces the sentinel with a real TUI like codex/claude/opencode that
# reads stdin via PTY. We use `cat` here as the smallest interactive
# stdin-echo stand-in.
tmux respawn-pane -k -t "$FIRST_PANE" "cat" \
  || { echo "FAIL: could not respawn preflight pane with cat" >&2; exit 1; }
sleep 0.5

# Sanity-check: confirm respawn worked and the pane is alive + running cat
PANE_CMD=$(tmux display-message -p -t "$FIRST_PANE" '#{pane_current_command}' 2>/dev/null || echo "")
PANE_DEAD=$(tmux display-message -p -t "$FIRST_PANE" '#{pane_dead}' 2>/dev/null || echo "1")
[[ "$PANE_DEAD" == "0" ]] || { echo "FAIL: pane $FIRST_PANE is dead after respawn" >&2; exit 1; }
[[ "$PANE_CMD" == "cat" ]] || echo "  NOTE: pane command is '$PANE_CMD' (expected 'cat'); proceeding"

# Direct sanity: send a plain string and verify capture-pane sees it.
# This isolates "send-keys → capture-pane" from "send.sh → send-keys".
tmux send-keys -t "$FIRST_PANE" -l "DIRECT-PROBE-MARKER"
tmux send-keys -t "$FIRST_PANE" Enter
sleep 0.5
DIRECT_PROBE=$(tmux capture-pane -p -t "$FIRST_PANE" 2>/dev/null | grep -c "DIRECT-PROBE-MARKER" || echo "0")
[[ "$DIRECT_PROBE" -gt 0 ]] \
  || { echo "FAIL: direct send-keys probe didn't appear in capture-pane (cat respawn issue?)" >&2; tmux capture-pane -p -t "$FIRST_PANE" >&2; exit 1; }
pass "direct send-keys → capture-pane works (PTY echo confirmed)"

# Dispatch — Step 3b's v0.22.0 shape. v0.31.0: cd into $HUB so send.sh's
# cw_topic_state_dir resolves against $HUB's repo-hash via $PWD (matches
# what deploy-init.sh wrote). The v0.30.0 CW_TOPIC_REPO_CWD env var is
# dead; subshell cd is the v0.31.0 contract. Capture stderr so failures
# surface.
SEND_ERR=$( cd "$HUB" \
  && "$PLUGIN_ROOT/bin/send.sh" "$FIRST_CMDR" "$TOPIC" "@$PROMPT_FILE" 2>&1 >/dev/null ) \
  || { echo "FAIL: bin/send.sh failed (BUG 5 fix not landed? stderr below)" >&2; echo "--- stderr ---" >&2; echo "$SEND_ERR" >&2; echo "--- TROOPER_STATE_DIR ($TROOPER_STATE_DIR) ---" >&2; ls -la "$TROOPER_STATE_DIR" >&2; exit 1; }

# Give tmux a moment to deliver the send-keys + propagate display state.
# Two sleeps + display-message bracketing was found to be necessary for
# capture-pane to consistently observe the nudge text (without the
# bracketing, capture-pane occasionally returned an empty buffer even
# though direct send-keys probes worked).
sleep 0.5
tmux display-message -p -t "$FIRST_PANE" '#{pane_dead}' >/dev/null 2>&1 || true
sleep 0.2

# Capture pane content AFTER dispatch — the nudge sends "Read <inbox-path> and execute the task. Reply when done."
AFTER=$(tmux capture-pane -p -t "$FIRST_PANE" 2>&1)
echo "$AFTER" | grep -qE 'Read .*inbox\.md and execute' \
  || { echo "FAIL: pane did NOT receive nudge (BUG 5 not closed)." >&2; echo "--- pane content ---" >&2; echo "$AFTER" >&2; echo "--- inbox.md ---" >&2; cat "$INBOX" 2>&1 >&2; exit 1; }
pass "bin/send.sh dispatch delivers tmux nudge to pane (BUG 5 closed)"

# 12. Verify inbox.md was written too.
INBOX="$TROOPER_STATE_DIR/inbox.md"
assert_file_exists "$INBOX" "inbox.md written by bin/send.sh"
grep -q "TEST PROMPT v0.22.0 e2e" "$INBOX" \
  || { echo "FAIL: inbox.md does not contain prompt content" >&2; exit 1; }
pass "inbox.md content matches dispatched prompt"

pass "v0.22.0 multi-repo deploy seam: 5 bugs sealed end-to-end (Bug 0 closed by this test)"
