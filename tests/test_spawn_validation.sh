#!/usr/bin/env bash
# tests/test_spawn_validation.sh
# Validates that bin/spawn.sh rejects malformed commander/topic args
# BEFORE attempting any tmux or provider operation. Runs outside a tmux
# session intentionally so any tmux call would error out differently.
set -uo pipefail   # NOT -e: we expect non-zero exits
cd "$(dirname "$0")"
source lib/assert.sh

SPAWN=../bin/spawn.sh
unset TMUX   # ensure NOT inside a tmux session — validation must precede this check

# 1. Bad commander chars are rejected with exit 2 (usage error).
out=$(bash "$SPAWN" 'evil|payload' codex demo 2>&1); code=$?
assert_eq "$code" "2" "bad commander exits 2"
assert_contains "$out" "commander" "error mentions commander"
pass "bad commander chars"

# 2. Empty commander rejected.
out=$(bash "$SPAWN" '' codex demo 2>&1); code=$?
[[ "$code" -ne 0 ]] || { echo "FAIL: empty commander accepted" >&2; exit 1; }
pass "empty commander rejected"

# 3. Over-length commander rejected.
LONG=$(printf 'a%.0s' {1..40})   # 40 chars > 32 limit
out=$(bash "$SPAWN" "$LONG" codex demo 2>&1); code=$?
assert_eq "$code" "2" "over-length commander exits 2"
pass "over-length commander rejected"

# 4. Bad topic still rejected (existing behavior preserved).
out=$(bash "$SPAWN" rex codex 'BAD TOPIC' 2>&1); code=$?
assert_eq "$code" "2" "bad topic exits 2"
assert_contains "$out" "topic" "error mentions topic"
pass "bad topic rejected"

# 5. Valid commander+topic but no tmux → fails AFTER input validation, with the
#    tmux-specific error message (proves validation didn't accidentally pass through).
out=$(bash "$SPAWN" rex codex demo 2>&1); code=$?
[[ "$code" -ne 0 ]] || { echo "FAIL: spawn unexpectedly succeeded outside tmux" >&2; exit 1; }
assert_contains "$out" "tmux" "tmux-not-running error reaches stderr"
pass "valid args reach tmux check"

echo "  ALL: ok"
