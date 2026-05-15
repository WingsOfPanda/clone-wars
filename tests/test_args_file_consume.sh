#!/usr/bin/env bash
# tests/test_args_file_consume.sh — v0.31.0 item 3
# Locks: cw_args_file_consume deletes the args file after read.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/argsfile.sh"

declare -F cw_args_file_consume >/dev/null \
  || { echo "FAIL: cw_args_file_consume not defined" >&2; exit 1; }
pass "helper defined"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# Case 1: deletes existing file
F1=$(mktemp -p "$SANDBOX" -t consult.XXXXXX)
echo "some args" > "$F1"
[[ -f "$F1" ]] || { echo "FAIL: setup — file not created" >&2; exit 1; }
cw_args_file_consume "$F1"
[[ ! -f "$F1" ]] || { echo "FAIL: cw_args_file_consume did not delete the file" >&2; exit 1; }
pass "1. existing file deleted"

# Case 2: silent on missing file (rc=0, no error)
F_MISSING="$SANDBOX/nope.txt"
set +e
out=$(cw_args_file_consume "$F_MISSING" 2>&1); rc=$?
set -e
[[ "$rc" == "0" ]] || { echo "FAIL: missing file should rc=0, got $rc" >&2; exit 1; }
[[ -z "$out" ]] || { echo "FAIL: missing file should be silent, got: $out" >&2; exit 1; }
pass "2. silent rc=0 on missing file"

# Case 3: silent on empty arg (rc=0, no error)
set +e
out=$(cw_args_file_consume "" 2>&1); rc=$?
set -e
[[ "$rc" == "0" ]] || { echo "FAIL: empty arg should rc=0, got $rc" >&2; exit 1; }
[[ -z "$out" ]] || { echo "FAIL: empty arg should be silent, got: $out" >&2; exit 1; }
pass "3. silent rc=0 on empty arg"

# Case 4: doesn't touch other files
F2=$(mktemp -p "$SANDBOX" -t consult.XXXXXX)
F3=$(mktemp -p "$SANDBOX" -t consult.XXXXXX)
echo "other" > "$F2"
echo "another" > "$F3"
cw_args_file_consume "$F2"
[[ ! -f "$F2" ]] || { echo "FAIL: target not deleted" >&2; exit 1; }
[[ -f "$F3" ]] || { echo "FAIL: untouched file deleted" >&2; exit 1; }
pass "4. only the targeted file deleted"

echo "test_args_file_consume: 4 cases passed"
