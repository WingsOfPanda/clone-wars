#!/usr/bin/env bash
# tests/test_consult_init.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# v0.2.1: consult-init.sh prints CONSULT_TOPIC on line 1 and a randomly-picked
# Jedi general slug on line 2. Tests extract just line 1 for topic checks.
init_topic() { ../bin/consult-init.sh "$@" | sed -n '1p'; }

# 1. Long topic-text → slug capped at 20 chars; full topic ≤32.
topic=$(init_topic "review the authentication middleware for token-refresh edge cases")
[[ "$topic" == consult-* ]] || { echo "FAIL: prefix missing: $topic" >&2; exit 1; }
[[ ${#topic} -le 32 ]]      || { echo "FAIL: topic ${#topic} chars > 32: $topic" >&2; exit 1; }
RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
[[ -d "$CLONE_WARS_HOME/state/$RH/$topic/_consult" ]] || { echo "FAIL: _consult dir not created" >&2; exit 1; }
[[ -f "$CLONE_WARS_HOME/state/$RH/$topic/_consult/topic.txt" ]] || { echo "FAIL: topic.txt missing" >&2; exit 1; }
[[ -f "$CLONE_WARS_HOME/state/$RH/$topic/_consult/general.txt" ]] || { echo "FAIL: general.txt missing" >&2; exit 1; }
pass "init creates capped slug + _consult/ + topic.txt + general.txt"

# 2. topic.txt preserves the raw topic-text.
saved=$(cat "$CLONE_WARS_HOME/state/$RH/$topic/_consult/topic.txt")
assert_eq "$saved" "review the authentication middleware for token-refresh edge cases" "topic.txt round-trips"
pass "topic.txt preserves raw topic-text"

# 2b. general.txt holds a slug from the Jedi pool.
general=$(cat "$CLONE_WARS_HOME/state/$RH/$topic/_consult/general.txt")
[[ "$general" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "FAIL: bad general slug: $general" >&2; exit 1; }
grep -qx -- "  - $general" ../config/generals.yaml || { echo "FAIL: $general not in generals.yaml" >&2; exit 1; }
pass "general.txt holds a slug from generals.yaml"

# 3. All-uppercase + punctuation normalized.
topic=$(init_topic "REVIEW @ AUTH: TOKEN!?")
[[ "$topic" =~ ^consult-[a-z0-9-]+$ ]] || { echo "FAIL: bad chars: $topic" >&2; exit 1; }
pass "uppercase + punctuation normalized"

# 4. Conflict resolver bumps to -3 on third invocation of same slug.
t1=$(init_topic "foo")
t2=$(init_topic "foo")
t3=$(init_topic "foo")
assert_eq "$t1" "consult-foo"   "1st"
assert_eq "$t2" "consult-foo-2" "2nd"
assert_eq "$t3" "consult-foo-3" "3rd"
pass "conflict resolver"

# 5. Empty slug rejected.
err=$(../bin/consult-init.sh "@@@@@" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$err" | grep -q 'empty slug' \
  || { echo "FAIL: empty slug should reject" >&2; exit 1; }
pass "empty slug rejected"
