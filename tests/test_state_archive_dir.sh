#!/usr/bin/env bash
# tests/test_state_archive_dir.sh — shared archive helper contract.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"

declare -F cw_state_archive_dir >/dev/null \
  || { echo "FAIL: cw_state_archive_dir not defined" >&2; exit 1; }
pass "helper defined"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"
mkdir -p "$CLONE_WARS_HOME"

# Case 1: archive a consult-style dir
TOPIC_DIR="$CLONE_WARS_HOME/state/abc/foo-topic"
ART_DIR="$TOPIC_DIR/_consult"
mkdir -p "$ART_DIR"
echo "hello" > "$ART_DIR/file.txt"

DEST=$(cw_state_archive_dir "$ART_DIR" "$CLONE_WARS_HOME/archive/abc/foo-topic" "_consult")
[[ -n "$DEST" ]] || { echo "FAIL: helper returned empty path" >&2; exit 1; }
[[ -d "$DEST" ]] || { echo "FAIL: archive dir not created at $DEST" >&2; exit 1; }
[[ -f "$DEST/file.txt" ]] || { echo "FAIL: contents not preserved at $DEST" >&2; exit 1; }
[[ ! -d "$ART_DIR" ]] || { echo "FAIL: source ART_DIR still exists after archive" >&2; exit 1; }
pass "consult-style archive: source moved, contents preserved"

# Case 2: same-second collision suffixes correctly
mkdir -p "$ART_DIR"
echo "second" > "$ART_DIR/file.txt"
DEST2=$(cw_state_archive_dir "$ART_DIR" "$CLONE_WARS_HOME/archive/abc/foo-topic" "_consult")
[[ "$DEST2" != "$DEST" ]] || { echo "FAIL: same-second collision: got $DEST2 == $DEST" >&2; exit 1; }
[[ -d "$DEST2" ]] || { echo "FAIL: collision-suffix path not created: $DEST2" >&2; exit 1; }
pass "same-second collision: distinct paths"

# Case 3: missing source returns rc != 0
rm -rf "$ART_DIR"
set +e
DEST3=$(cw_state_archive_dir "$ART_DIR" "$CLONE_WARS_HOME/archive/abc/foo-topic" "_consult" 2>/dev/null)
rc=$?
set -e
[[ "$rc" != "0" ]] || { echo "FAIL: missing source should fail, got rc=0" >&2; exit 1; }
pass "missing source returns non-zero"

# Case 4: works with _deploy slug too
TOPIC_DIR2="$CLONE_WARS_HOME/state/abc/bar-topic"
ART_DIR2="$TOPIC_DIR2/_deploy"
mkdir -p "$ART_DIR2"
echo "deploy" > "$ART_DIR2/file.txt"
DEST4=$(cw_state_archive_dir "$ART_DIR2" "$CLONE_WARS_HOME/archive/abc/bar-topic" "_deploy")
[[ -d "$DEST4" ]] || { echo "FAIL: _deploy archive dir not created" >&2; exit 1; }
[[ "$DEST4" == *"/_deploy-"* ]] || { echo "FAIL: dest path doesn't contain '_deploy-': $DEST4" >&2; exit 1; }
pass "_deploy slug also works"

echo "test_state_archive_dir: 4 cases passed"
