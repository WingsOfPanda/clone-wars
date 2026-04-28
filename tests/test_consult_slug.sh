#!/usr/bin/env bash
# tests/test_consult_slug.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

# bin/consult.sh prints the resolved consult topic before spawning, so we can
# capture and validate it without running tmux. Use a sentinel env var to make
# consult.sh print-then-exit before the spawn step.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
export CW_CONSULT_DRY_RUN=1   # consult.sh: print topic and exit 0

# Long topic — base slug must be cropped to 20 chars.
out=$(../bin/consult.sh "review the authentication middleware for token-refresh edge cases and rate-limiting issues")
slug=$(echo "$out" | awk -F': ' '/consultation topic:/{print $NF}')
[[ ${#slug} -le 32 ]] || { echo "FAIL: slug $slug = ${#slug} chars > 32" >&2; exit 1; }
[[ "$slug" == consult-* ]] || { echo "FAIL: slug missing prefix: $slug" >&2; exit 1; }
pass "long topic produces <=32-char consult-<slug>"

# All-uppercase, mixed punctuation.
out=$(../bin/consult.sh "REVIEW @ AUTH: TOKEN!?")
slug=$(echo "$out" | awk -F': ' '/consultation topic:/{print $NF}')
[[ "$slug" =~ ^consult-[a-z0-9-]+$ ]] || { echo "FAIL: bad chars in slug: $slug" >&2; exit 1; }
pass "uppercase + punctuation normalized"

# Conflict resolver bumps n. Pre-create a few directories.
RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
DIR_BASE="$CLONE_WARS_HOME/state/$RH"
mkdir -p "$DIR_BASE/consult-foo"
mkdir -p "$DIR_BASE/consult-foo-2"
out=$(../bin/consult.sh "foo")
slug=$(echo "$out" | awk -F': ' '/consultation topic:/{print $NF}')
assert_eq "$slug" "consult-foo-3" "third consult on same slug bumps to -3"
pass "conflict resolver"

# Conflict resolver gives up at 999.
for n in {3..999}; do mkdir -p "$DIR_BASE/consult-foo-$n"; done
out=$(../bin/consult.sh "foo" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: 999 conflicts should fail" >&2; exit 1; }
pass "conflict resolver bounded at 999"

# Empty slug rejected.
out=$(../bin/consult.sh "@@@@@" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'empty slug' \
  || { echo "FAIL: empty slug should be rejected" >&2; exit 1; }
pass "empty slug rejected"
