#!/usr/bin/env bash
# tests/test_consult_init.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# v0.15.0: pre-write providers-available.txt fixture (claude+codex == N=2,
# matches v0.14.0 trooper roster rex+cody so existing assertions don't change).
mkdir -p "$CLONE_WARS_HOME"
cat > "$CLONE_WARS_HOME/providers-available.txt" <<'EOF'
# fixture
codex
claude
EOF

# 1. Long topic-text → slug capped at 20 chars; full topic ≤32.
out=$(../bin/consult-init.sh "review the authentication middleware for token-refresh edge cases")
[[ "$out" == consult-* ]] || { echo "FAIL: prefix missing: $out" >&2; exit 1; }
[[ ${#out} -le 32 ]]      || { echo "FAIL: topic ${#out} chars > 32: $out" >&2; exit 1; }
RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
[[ -d "$CLONE_WARS_HOME/state/$RH/$out/_consult" ]] || { echo "FAIL: _consult dir not created" >&2; exit 1; }
[[ -f "$CLONE_WARS_HOME/state/$RH/$out/_consult/topic.txt" ]] || { echo "FAIL: topic.txt missing" >&2; exit 1; }
pass "init creates capped slug + _consult/ + topic.txt"

# 1a. v0.16.0: _consult/design-doc/ pre-created so fast-path + trooper-path
# writers don't need their own mkdir logic.
[[ -d "$CLONE_WARS_HOME/state/$RH/$out/_consult/design-doc" ]] \
  || { echo "FAIL: _consult/design-doc/ not created" >&2; exit 1; }
pass "consult-init creates _consult/design-doc/ subdir"

# 2. topic.txt preserves the raw topic-text.
saved=$(cat "$CLONE_WARS_HOME/state/$RH/$out/_consult/topic.txt")
assert_eq "$saved" "review the authentication middleware for token-refresh edge cases" "topic.txt round-trips"
pass "topic.txt preserves raw topic-text"

# 2a. v0.3: skill.txt holds one of brainstorming|systematic-debugging|none.
[[ -f "$CLONE_WARS_HOME/state/$RH/$out/_consult/skill.txt" ]] \
  || { echo "FAIL: skill.txt missing" >&2; exit 1; }
skill=$(cat "$CLONE_WARS_HOME/state/$RH/$out/_consult/skill.txt")
[[ "$skill" =~ ^(brainstorming|systematic-debugging|none)$ ]] \
  || { echo "FAIL: skill='$skill' not in pool" >&2; exit 1; }
pass "skill.txt holds a valid classifier value"

# 2b. brainstorming-shaped topic produces skill=brainstorming.
out_brain=$(../bin/consult-init.sh "how should we approach the cache layer")
skill_brain=$(cat "$CLONE_WARS_HOME/state/$RH/$out_brain/_consult/skill.txt")
assert_eq "$skill_brain" "brainstorming" "brainstorming topic classified"
pass "brainstorming-shaped topic auto-selects brainstorming skill"

# 2c. debugging-shaped topic produces skill=systematic-debugging.
out_dbg=$(../bin/consult-init.sh "why is the test suite failing on macOS")
skill_dbg=$(cat "$CLONE_WARS_HOME/state/$RH/$out_dbg/_consult/skill.txt")
assert_eq "$skill_dbg" "systematic-debugging" "debugging topic classified"
pass "debugging-shaped topic auto-selects systematic-debugging skill"

# 3. All-uppercase + punctuation normalized.
out=$(../bin/consult-init.sh "REVIEW @ AUTH: TOKEN!?")
[[ "$out" =~ ^consult-[a-z0-9-]+$ ]] || { echo "FAIL: bad chars: $out" >&2; exit 1; }
pass "uppercase + punctuation normalized"

# 4. Conflict resolver bumps to -3 on third invocation of same slug.
out1=$(../bin/consult-init.sh "foo")
out2=$(../bin/consult-init.sh "foo")
out3=$(../bin/consult-init.sh "foo")
assert_eq "$out1" "consult-foo"   "1st"
assert_eq "$out2" "consult-foo-2" "2nd"
assert_eq "$out3" "consult-foo-3" "3rd"
pass "conflict resolver"

# 5. Empty slug rejected.
err=$(../bin/consult-init.sh "@@@@@" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$err" | grep -q 'empty slug' \
  || { echo "FAIL: empty slug should reject" >&2; exit 1; }
pass "empty slug rejected"
