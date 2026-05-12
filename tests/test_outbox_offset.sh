#!/usr/bin/env bash
# tests/test_outbox_offset.sh — v0.27.3 cw_outbox_offset helper lock.
# Folds the "wc -c < outbox | tr -d <ws>" + drilldown's missing-file
# `|| echo 0` fallback into one helper.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/ipc.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Case A: file with content → returns its byte length, whitespace-stripped.
echo -n "hello world" > "$TMP/full.jsonl"   # 11 bytes, no newline
OFF=$(cw_outbox_offset "$TMP/full.jsonl")
[[ "$OFF" == "11" ]] \
  || { echo "FAIL: full file: expected 11, got '$OFF'" >&2; exit 1; }
pass "cw_outbox_offset returns byte length for non-empty file"

# Case B: empty file → returns 0 (no leading whitespace).
:> "$TMP/empty.jsonl"
OFF=$(cw_outbox_offset "$TMP/empty.jsonl")
[[ "$OFF" == "0" ]] \
  || { echo "FAIL: empty file: expected 0, got '$OFF'" >&2; exit 1; }
pass "cw_outbox_offset returns 0 for empty file (whitespace stripped)"

# Case C: missing file → returns 0 (folds drilldown's `|| echo 0` fallback).
OFF=$(cw_outbox_offset "$TMP/does-not-exist.jsonl")
[[ "$OFF" == "0" ]] \
  || { echo "FAIL: missing file: expected 0, got '$OFF'" >&2; exit 1; }
pass "cw_outbox_offset returns 0 for missing file"

# Case D: no arg → rc=2 + stderr message.
rc=0; ERR=$(cw_outbox_offset 2>&1) || rc=$?
[[ "$rc" == "2" ]] \
  || { echo "FAIL: missing-arg should exit rc=2, got '$rc'" >&2; exit 1; }
[[ "$ERR" == *"outbox path required"* ]] \
  || { echo "FAIL: stderr should mention 'outbox path required'; got: $ERR" >&2; exit 1; }
pass "cw_outbox_offset rejects missing arg with rc=2"

# Case E: value is safe for numeric comparison (no leading spaces).
echo -n "abc" > "$TMP/small.jsonl"
OFF=$(cw_outbox_offset "$TMP/small.jsonl")
(( OFF == 3 )) \
  || { echo "FAIL: arithmetic compare failed for '$OFF'" >&2; exit 1; }
pass "cw_outbox_offset output is numeric-compare safe"
