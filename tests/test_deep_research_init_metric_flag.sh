#!/usr/bin/env bash
# tests/test_deep_research_init_metric_flag.sh — v0.32.0 #23 (half)
# Locks: bin/deep-research-init.sh accepts --metric=<kv,kv,...>; writes
# metric.md via cw_deep_research_format_metric_block; rejects missing
# required keys (primary_metric, direction) with rc=2.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
SANDBOX=$(mktemp -d)
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"
mkdir -p "$CLONE_WARS_HOME"
echo codex > "$CLONE_WARS_HOME/providers-available.txt"
trap 'rm -rf "$SANDBOX"' EXIT

source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"

# Case 1: minimal required pair
out=$( cd "$SANDBOX" \
  && "$PLUGIN_ROOT/bin/deep-research-init.sh" \
       --metric='primary_metric=accuracy,direction=maximize' \
       "metric minimal test topic" )
topic="$out"
repo_hash=$(cd "$SANDBOX" && cw_repo_hash)
art="$CLONE_WARS_HOME/state/$repo_hash/$topic/_deep-research"
assert_file_exists "$art/metric.md" "metric.md from minimal --metric"
grep -q '^\*\*Primary metric:\*\* accuracy' "$art/metric.md" \
  || { echo "FAIL: metric.md missing 'Primary metric: accuracy'" >&2; cat "$art/metric.md" >&2; exit 1; }
grep -q '^\*\*Direction:\*\* maximize' "$art/metric.md" \
  || { echo "FAIL: metric.md missing 'Direction: maximize'" >&2; cat "$art/metric.md" >&2; exit 1; }
pass "1. --metric=minimal → valid metric.md with primary_metric + direction"

# Case 2: full key set
out=$( cd "$SANDBOX" \
  && "$PLUGIN_ROOT/bin/deep-research-init.sh" \
       --metric='primary_metric=loss,direction=minimize,min_acceptable=<= 0.05,target=<= 0.01,K_corroboration=2,hard_constraints=batch<=128,notes=test set' \
       "metric full test topic" )
topic="$out"
art="$CLONE_WARS_HOME/state/$repo_hash/$topic/_deep-research"
assert_file_exists "$art/metric.md" "metric.md from full --metric"
grep -q 'min_acceptable' "$art/metric.md" \
  || { echo "FAIL: full --metric metric.md missing min_acceptable" >&2; cat "$art/metric.md" >&2; exit 1; }
grep -q 'K_corroboration:\*\* 2' "$art/metric.md" \
  || { echo "FAIL: full --metric metric.md missing K_corroboration=2" >&2; cat "$art/metric.md" >&2; exit 1; }
pass "2. --metric=full → metric.md includes all optional fields"

# Case 3: missing primary_metric → rc=2
set +e
( cd "$SANDBOX" \
  && "$PLUGIN_ROOT/bin/deep-research-init.sh" \
       --metric='direction=maximize' \
       "metric missing pm topic" 2>"$SANDBOX/err.txt" )
rc=$?
set -e
[[ "$rc" == "2" ]] || { echo "FAIL: missing primary_metric should rc=2, got $rc:" >&2; cat "$SANDBOX/err.txt" >&2; exit 1; }
pass "3. --metric without primary_metric → rc=2"

# Case 4: missing direction → rc=2
set +e
( cd "$SANDBOX" \
  && "$PLUGIN_ROOT/bin/deep-research-init.sh" \
       --metric='primary_metric=accuracy' \
       "metric missing dir topic" 2>"$SANDBOX/err.txt" )
rc=$?
set -e
[[ "$rc" == "2" ]] || { echo "FAIL: missing direction should rc=2, got $rc:" >&2; cat "$SANDBOX/err.txt" >&2; exit 1; }
pass "4. --metric without direction → rc=2"

echo "test_deep_research_init_metric_flag: 4 cases passed"
