#!/usr/bin/env bash
# tests/test_deploy_directive_v020_static_wiring.sh
# Static-wiring asserts on commands/deploy.md for v0.20.0:
# - Frontmatter: allowed-tools listed
# - Routing branch present (reads routing.txt)
# - NEW Steps 3a/3b/3c/3d multi-repo headings
# - MAX_FIX_ROUNDS=3 + AskUserQuestion at-cap wording
# - PREFLIGHT_PANES array used (mirrors v0.19.0 consult)
# - Trigger phrases at top
# - NEGATIVE: no ACTIVE --design-doc / synthesis.md USAGE (deprecation
#   prose mentions are allowed, but no `find` patterns or flag usage)
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

DIR=../commands/deploy.md
BODY=$(cat "$DIR")

# Frontmatter
grep -qE '^allowed-tools:' "$DIR" \
  || { echo "FAIL: frontmatter missing allowed-tools" >&2; exit 1; }
grep -qE '^allowed-tools:.*AskUserQuestion' "$DIR" \
  || { echo "FAIL: allowed-tools missing AskUserQuestion" >&2; exit 1; }

# Trigger phrases
assert_contains "$BODY" "When to use this command" "directive has When-to-use block"
assert_contains "$BODY" "deploy this design"        "directive lists 'deploy this design' trigger"

# Routing branch (reads routing.txt written by deploy-init.sh)
assert_contains "$BODY" 'routing.txt'                  "directive reads routing.txt"
assert_contains "$BODY" 'ROUTING == "single-repo"'     "directive branches on single-repo"
assert_contains "$BODY" 'ROUTING == "multi-repo"'      "directive branches on multi-repo"

# NEW v0.20.0 Steps for multi-repo (3a/3b/3c/3d)
grep -qE '^### Step 3a ' "$DIR" || { echo "FAIL: missing '### Step 3a' heading" >&2; exit 1; }
grep -qE '^### Step 3b ' "$DIR" || { echo "FAIL: missing '### Step 3b' heading" >&2; exit 1; }
grep -qE '^### Step 3c ' "$DIR" || { echo "FAIL: missing '### Step 3c' heading" >&2; exit 1; }
grep -qE '^### Step 3d ' "$DIR" || { echo "FAIL: missing '### Step 3d' heading" >&2; exit 1; }

# Multi-repo final-verification prose (Step 3c)
assert_contains "$BODY" "feels unsafe"               "directive uses 'feels unsafe' wording"
assert_contains "$BODY" "cross-repo invariants"      "directive describes cross-repo invariants check"
assert_contains "$BODY" "WAVE_COUNT"                 "directive computes WAVE_COUNT for unsafe heuristic"
assert_contains "$BODY" "FAN_IN_REPOS"               "directive computes FAN_IN_REPOS for unsafe heuristic"

# Multi-repo fix-loop prose (Step 3d)
assert_contains "$BODY" "MAX_FIX_ROUNDS=3"          "directive uses MAX_FIX_ROUNDS=3 cap"
assert_contains "$BODY" "Give up on this sub-repo"  "directive offers 'give up' option at cap"
assert_contains "$BODY" "Escalate to different commander" "directive offers escalate-commander option at cap"

# Preflight + DAG infrastructure
assert_contains "$BODY" "bin/preflight-layout.sh"   "directive references preflight-layout.sh"
assert_contains "$BODY" "--target-pane"             "directive uses --target-pane in spawn calls"
assert_contains "$BODY" "--art-dir"                 "directive uses --art-dir in preflight call"
assert_contains "$BODY" "PREFLIGHT_PANES"           "directive declares PREFLIGHT_PANES array"
assert_contains "$BODY" "dag-waves.txt"             "directive walks dag-waves.txt"
assert_contains "$BODY" "Stage 1 retry-once"        "directive describes Stage 1 retry-once"
assert_contains "$BODY" "Stage 2 partial-success"   "directive describes Stage 2 partial-success"

# Superpowers ceremony in DAG-unit prompt
assert_contains "$BODY" "superpowers:writing-plans"             "DAG-unit prompt invokes superpowers:writing-plans"
assert_contains "$BODY" "superpowers:subagent-driven-development" "DAG-unit prompt invokes subagent-driven-development"
assert_contains "$BODY" "superpowers:verification-before-completion" "DAG-unit prompt invokes verification-before-completion"

# NEGATIVE: no ACTIVE --design-doc usage. The deprecation prose mentions
# `--design-doc` and `synthesis.md` to explain WHAT WAS REMOVED — those
# are fine. But there must be no `find ... -path ...synthesis.md...`
# pattern (the old fallback find) and no command-line FLAG usage.
! grep -qE "find.*synthesis\.md|-o[[:space:]]+-path.*synthesis\.md" "$DIR" \
  || { echo "FAIL: directive has ACTIVE 'find ... synthesis.md' pattern (should only be in deprecation prose)" >&2; exit 1; }
# `--design-doc` should not appear as a command-line flag (e.g. in a bash
# code block invoking consult or deploy with --design-doc).
! grep -qE 'consult.*--design-doc|deploy.*--design-doc[^a-zA-Z-]' "$DIR" \
  || { echo "FAIL: directive has ACTIVE --design-doc flag usage (should be gone since v0.12)" >&2; exit 1; }

# NEGATIVE: line-257 single-quote bug — no `description='...$ROUND...` patterns
! grep -qE "description='.*\\\$ROUND" "$DIR" \
  || { echo "FAIL: line-257 single-quote bug still present (description='...\$ROUND')" >&2; exit 1; }

pass "commands/deploy.md v0.20.0 static wiring complete"
