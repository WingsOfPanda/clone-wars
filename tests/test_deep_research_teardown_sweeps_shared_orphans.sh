#!/usr/bin/env bash
# tests/test_deep_research_teardown_sweeps_shared_orphans.sh
# v0.43.0 Lane B: teardown sweeps *.tmp + *.lock from shared/ before archive mv.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
cd "$SANDBOX"
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"

TOPIC=deep-research-sweep-test
TD="$(cw_topic_state_dir "$TOPIC")"
ART="$TD/_deep-research"
mkdir -p "$ART/shared"

echo orphan-tmp > "$ART/shared/foo.tmp"
: > "$ART/shared/bar.bin.lock"
echo "real content" > "$ART/shared/keep.py"
echo "rex" > "$ART/troopers.txt"

ARCHIVE=$("$PLUGIN_ROOT/bin/deep-research-teardown.sh" "$TOPIC")

[[ -d "$ARCHIVE" ]] || { echo "FAIL: archive dir not created: $ARCHIVE" >&2; exit 1; }
[[ ! -f "$ARCHIVE/_deep-research/shared/foo.tmp" ]] \
  || { echo "FAIL: *.tmp orphan survived sweep" >&2; exit 1; }
[[ ! -f "$ARCHIVE/_deep-research/shared/bar.bin.lock" ]] \
  || { echo "FAIL: *.lock orphan survived sweep" >&2; exit 1; }
[[ -f "$ARCHIVE/_deep-research/shared/keep.py" ]] \
  || { echo "FAIL: legitimate file deleted: keep.py missing in archive" >&2; exit 1; }
pass "1. teardown sweeps shared/*.tmp + shared/*.lock; preserves real files"

echo "test_deep_research_teardown_sweeps_shared_orphans: 1 case passed"
