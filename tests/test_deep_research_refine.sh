#!/usr/bin/env bash
# v0.34.0 D2 — bin/deep-research-refine.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP"

source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"

# Case 1: script exists + executable
assert_file_exists "$PLUGIN_ROOT/bin/deep-research-refine.sh" \
  "case 1: bin/deep-research-refine.sh missing"
[[ -x "$PLUGIN_ROOT/bin/deep-research-refine.sh" ]] \
  || { echo "FAIL: case 1 script not executable"; exit 1; }
pass "1. script exists + executable"

# Case 2: bad topic → rc=2
rc=0
"$PLUGIN_ROOT/bin/deep-research-refine.sh" 'BAD TOPIC!' rex exp-001 'refine text' 2>/dev/null || rc=$?
[[ "$rc" == 2 ]] \
  || { echo "FAIL: case 2 bad topic should rc=2 (got $rc)"; exit 1; }
pass "2. invalid topic → rc=2"

# Case 3: bad exp-id → rc=2
TOPIC=deep-research-v034ref
rc=0
"$PLUGIN_ROOT/bin/deep-research-refine.sh" "$TOPIC" rex 'not-an-exp' 'refine text' 2>/dev/null || rc=$?
[[ "$rc" == 2 ]] \
  || { echo "FAIL: case 3 bad exp-id should rc=2 (got $rc)"; exit 1; }
pass "3. invalid exp-id → rc=2"

# Case 4: missing branch dir → rc=1
TOPIC_DIR="$(cw_topic_state_dir "$TOPIC")"
mkdir -p "$TOPIC_DIR/_deep-research/troopers/rex"
rc=0
"$PLUGIN_ROOT/bin/deep-research-refine.sh" "$TOPIC" rex exp-001 'refine text' 2>/dev/null || rc=$?
[[ "$rc" == 1 ]] \
  || { echo "FAIL: case 4 missing branch dir should rc=1 (got $rc)"; exit 1; }
pass "4. missing branch dir → rc=1"

# Case 5: happy path — refine-1.md written
mkdir -p "$TOPIC_DIR/_deep-research/troopers/rex/experiments/exp-001"
CW_DEEP_RESEARCH_DRY_RUN=1 "$PLUGIN_ROOT/bin/deep-research-refine.sh" \
  "$TOPIC" rex exp-001 'narrow scope to header extraction only' 2>/dev/null
assert_file_exists "$TOPIC_DIR/_deep-research/troopers/rex/experiments/exp-001/refine-1.md" \
  "case 5: refine-1.md should exist"
grep -q 'narrow scope to header extraction only' \
  "$TOPIC_DIR/_deep-research/troopers/rex/experiments/exp-001/refine-1.md" \
  || { echo "FAIL: case 5 refine content not preserved"; exit 1; }
pass "5. happy path: refine-1.md written with content"

# Case 6: second refine becomes refine-2.md
CW_DEEP_RESEARCH_DRY_RUN=1 "$PLUGIN_ROOT/bin/deep-research-refine.sh" \
  "$TOPIC" rex exp-001 'also: emit JSON' 2>/dev/null
assert_file_exists "$TOPIC_DIR/_deep-research/troopers/rex/experiments/exp-001/refine-2.md" \
  "case 6: refine-2.md should exist on second call"
pass "6. second refine becomes refine-2.md (numbered)"

# Case 7: third refine becomes refine-3.md
CW_DEEP_RESEARCH_DRY_RUN=1 "$PLUGIN_ROOT/bin/deep-research-refine.sh" \
  "$TOPIC" rex exp-001 'final tweak' 2>/dev/null
assert_file_exists "$TOPIC_DIR/_deep-research/troopers/rex/experiments/exp-001/refine-3.md" \
  "case 7: refine-3.md should exist on third call"
pass "7. third refine becomes refine-3.md"

echo "test_deep_research_refine: 7 cases passed"
