#!/usr/bin/env bash
# tests/test_deep_research_abort.sh — v0.32.0 #16
# Locks: bin/deep-research-abort.sh writes halt.flag, runs finalize +
# teardown, exits 0. Bad topic → rc=2. Missing art-dir → rc=1.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
SANDBOX=$(mktemp -d)
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"
mkdir -p "$CLONE_WARS_HOME"
trap 'rm -rf "$SANDBOX"' EXIT

source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"

# Synthesize a minimal _deep-research/ state shape
TOPIC=deep-research-abort-test
REPO_HASH=$(cd "$SANDBOX" && cw_repo_hash)
TD="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC"
ART="$TD/_deep-research"
mkdir -p "$ART/troopers/rex"
printf '%s\n' rex > "$ART/troopers.txt"
printf '%s\n' "$TOPIC" > "$ART/topic.txt"
# Minimum file set for finalize.sh
cat > "$ART/troopers/rex/state.txt" <<EOF
exp_counter=0
phase=idle
current_exp_id=
last_event_ts=
last_event=spawn
probe_sent_ts=
EOF
printf 'fake-task-id-1\nfake-task-id-2\n' > "$ART/monitor-tasks.txt"
printf '%s\n' "$TOPIC" > "$ART/active.txt"

# Case 1: happy path
set +e
( cd "$SANDBOX" \
  && "$PLUGIN_ROOT/bin/deep-research-abort.sh" "$TOPIC" "test reason" ) \
  > "$SANDBOX/abort.out" 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || { echo "FAIL: abort happy path should rc=0, got $rc" >&2; cat "$SANDBOX/abort.out" >&2; exit 1; }

# State is now archived (not under state/, under archive/)
ARCHIVE_BASE="$CLONE_WARS_HOME/archive/$REPO_HASH"
archived_dir=$(ls -d "$ARCHIVE_BASE/${TOPIC}-"* 2>/dev/null | head -1)
[[ -n "$archived_dir" ]] || { echo "FAIL: archive dir not created under $ARCHIVE_BASE/" >&2; ls -laR "$ARCHIVE_BASE/" 2>/dev/null >&2; exit 1; }
assert_file_exists "$archived_dir/_deep-research/halt.flag" "halt.flag preserved in archive"
grep -q 'user-aborted via bin/deep-research-abort.sh' "$archived_dir/_deep-research/halt.flag" \
  || { echo "FAIL: halt.flag body missing expected marker:" >&2; cat "$archived_dir/_deep-research/halt.flag" >&2; exit 1; }
grep -q 'reason=test reason' "$archived_dir/_deep-research/halt.flag" \
  || { echo "FAIL: halt.flag body missing reason text:" >&2; cat "$archived_dir/_deep-research/halt.flag" >&2; exit 1; }
pass "1. happy path: halt.flag + archive + reason recorded"

# finalize.sh appends ## Halt to session-summary.md
assert_file_exists "$archived_dir/_deep-research/session-summary.md" "session-summary.md preserved"
grep -q '^## Halt' "$archived_dir/_deep-research/session-summary.md" \
  || { echo "FAIL: ## Halt section missing in session-summary.md" >&2; cat "$archived_dir/_deep-research/session-summary.md" >&2; exit 1; }
pass "2. finalize ran (## Halt section appended)"

# monitor-tasks.txt preserved in archive
assert_file_exists "$archived_dir/_deep-research/monitor-tasks.txt" "monitor-tasks.txt preserved in archive"
pass "3. monitor-tasks.txt preserved in archive"

# active.txt removed (finalize behavior)
[[ ! -f "$archived_dir/_deep-research/active.txt" ]] \
  || { echo "FAIL: active.txt should be removed by finalize, still present in archive" >&2; exit 1; }
pass "4. active.txt removed by finalize step"

# TaskStop hint printed with task IDs
grep -q 'fake-task-id-1' "$SANDBOX/abort.out" \
  || { echo "FAIL: abort output missing TaskStop hint for fake-task-id-1:" >&2; cat "$SANDBOX/abort.out" >&2; exit 1; }
pass "5. TaskStop deferral hint includes task IDs"

# Case 2: invalid topic (bad regex) → rc=2
set +e
( cd "$SANDBOX" \
  && "$PLUGIN_ROOT/bin/deep-research-abort.sh" 'has spaces' 2>"$SANDBOX/e.txt" )
rc=$?
set -e
[[ "$rc" == "2" ]] || { echo "FAIL: bad topic should rc=2, got $rc" >&2; cat "$SANDBOX/e.txt" >&2; exit 1; }
pass "6. invalid topic → rc=2"

# Case 3: missing art-dir → rc=1
set +e
( cd "$SANDBOX" \
  && "$PLUGIN_ROOT/bin/deep-research-abort.sh" deep-research-nonexistent 2>"$SANDBOX/e2.txt" )
rc=$?
set -e
[[ "$rc" == "1" ]] || { echo "FAIL: missing art-dir should rc=1, got $rc" >&2; cat "$SANDBOX/e2.txt" >&2; exit 1; }
pass "7. missing deep-research session → rc=1"

# Case 4: usage error (zero args) → rc=2
set +e
( cd "$SANDBOX" \
  && "$PLUGIN_ROOT/bin/deep-research-abort.sh" 2>"$SANDBOX/e3.txt" )
rc=$?
set -e
[[ "$rc" == "2" ]] || { echo "FAIL: missing topic arg should rc=2, got $rc" >&2; cat "$SANDBOX/e3.txt" >&2; exit 1; }
pass "8. missing topic arg → rc=2"

echo "test_deep_research_abort: 8 cases passed"
