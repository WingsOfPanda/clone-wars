#!/usr/bin/env bash
# tests/test_jsonl_string_field.sh — v0.46.0 finding #1
# Locks: cw_jsonl_string_field(line, key) extracts the value of `"key":"..."`
# from a JSONL line. Generalization of cw_event_name_extract (which stays as
# named alias for the canonical "event" key).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"

# Case 1: present key
line='{"event":"done","summary":"all good","ts":"2026-05-20T01:00:00Z"}'
assert_eq "$(cw_jsonl_string_field "$line" event)"   "done"      "extract event"
assert_eq "$(cw_jsonl_string_field "$line" summary)" "all good"  "extract summary"
assert_eq "$(cw_jsonl_string_field "$line" ts)"      "2026-05-20T01:00:00Z" "extract ts"
pass "1. present key extracted (event, summary, ts)"

# Case 2: absent key → empty output, rc=0
out=$(cw_jsonl_string_field "$line" missing)
assert_eq "$out" "" "absent key → empty"
pass "2. absent key → empty output"

# Case 3: multi-field line, first match wins per key
line='{"a":"first","b":"x","a":"second"}'
out=$(cw_jsonl_string_field "$line" a)
assert_eq "$out" "first" "first match for duplicate key"
pass "3. multi-field line: first match wins"

# Case 4: empty line → empty output
out=$(cw_jsonl_string_field "" event)
assert_eq "$out" "" "empty input → empty output"
pass "4. empty input → empty output"

# Bonus: cw_event_name_extract still works as named alias (back-compat)
line='{"event":"ready","ts":"2026-05-20T02:00:00Z"}'
assert_eq "$(cw_event_name_extract "$line")" "ready" "named alias still works"
pass "5. cw_event_name_extract stays as named alias"

echo "test_jsonl_string_field: 4 cases passed (+1 back-compat)"
