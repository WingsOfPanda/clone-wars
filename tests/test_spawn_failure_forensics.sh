#!/usr/bin/env bash
# tests/test_spawn_failure_forensics.sh — 3 cases for
# cw_spawn_capture_failure_forensics.
set -uo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Use a temporary CLONE_WARS_HOME so cw_trooper_dir resolves under $TMP.
export CLONE_WARS_HOME="$TMP/.clone-wars"
mkdir -p "$CLONE_WARS_HOME/state"

cd "$PLUGIN_ROOT"
TOPIC="test-spawn-forensics-topic"
CMDR="rex"
MODEL="codex"

# shellcheck disable=SC1091
source "$PLUGIN_ROOT/lib/log.sh"
# shellcheck disable=SC1091
source "$PLUGIN_ROOT/lib/state.sh"
# shellcheck disable=SC1091
source "$PLUGIN_ROOT/lib/ipc.sh"

# Pre-create the trooper dir so the forensics file can be written.
TROOPER_DIR=$(cw_trooper_dir "$CMDR" "$MODEL" "$TOPIC")
mkdir -p "$TROOPER_DIR"

FAILURE_FILE="$TROOPER_DIR/failure-reason.txt"

# --- Case 1: reason=timeout (no event_line) → file has all 7 header fields + "no error event before timeout"
# pane_id %999 is invalid (no real tmux session) but cw_spawn_capture_failure_forensics
# tolerates it — tmux capture-pane will fail silently, scrollback section is empty.
rm -f "$FAILURE_FILE"
cw_spawn_capture_failure_forensics "$CMDR" "$MODEL" "$TOPIC" "%999" timeout
assert_eq "$?" "0" "case1a: forensics exit 0"
assert_file_exists "$FAILURE_FILE" "case1b: failure-reason.txt created"
content=$(cat "$FAILURE_FILE")
assert_contains "$content" "# Spawn bootstrap failure" "case1c: header banner"
assert_contains "$content" "commander:     $CMDR"      "case1d: commander field"
assert_contains "$content" "model:         $MODEL"     "case1e: model field"
assert_contains "$content" "topic:         $TOPIC"     "case1f: topic field"
assert_contains "$content" "pane_id:       %999"       "case1g: pane_id field"
assert_contains "$content" "fail_reason:   timeout"    "case1h: fail_reason field"
assert_contains "$content" "## Pane scrollback"        "case1i: scrollback section header"
assert_contains "$content" "## Event context"          "case1j: event context section header"
assert_contains "$content" "no error event before timeout" "case1k: timeout sentinel"

# --- Case 2: reason=error_event with event_line arg → file contains the JSONL under ## Event context
rm -f "$FAILURE_FILE"
event_line='{"event":"error","reason":"codex_bootstrap_failed","ts":"2026-05-21T10:00:00Z"}'
cw_spawn_capture_failure_forensics "$CMDR" "$MODEL" "$TOPIC" "%999" error_event "$event_line"
assert_eq "$?" "0" "case2a: forensics exit 0"
content=$(cat "$FAILURE_FILE")
assert_contains "$content" "fail_reason:   error_event"           "case2b: fail_reason=error_event"
assert_contains "$content" '"event":"error"'                       "case2c: event_line embedded"
assert_contains "$content" '"reason":"codex_bootstrap_failed"'     "case2d: event_line reason field"

# --- Case 3: missing trooper dir → rc=1, no file written
rmdir "$TROOPER_DIR" 2>/dev/null || rm -rf "$TROOPER_DIR"
rm -f "$FAILURE_FILE"
cw_spawn_capture_failure_forensics "$CMDR" "$MODEL" "$TOPIC" "%999" timeout 2>/dev/null
assert_eq "$?" "1" "case3a: missing trooper dir → rc=1"
[[ ! -e "$FAILURE_FILE" ]] || { echo "FAIL case3b: failure-reason.txt written despite missing dir" >&2; exit 1; }
pass "case3b: no file written when dir missing"

echo "test_spawn_failure_forensics: 3 cases passed"
