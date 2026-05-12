#!/usr/bin/env bash
# tests/test_deep_research_init_v027.sh — v0.27.0 init contract
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

TMPHOME=$(mktemp -d); trap 'rm -rf "$TMPHOME"' EXIT
export CLONE_WARS_HOME="$TMPHOME"
echo "codex" > "$TMPHOME/providers-available.txt"

# Case 1: topic-only invocation works; emits slug ≤ 18 chars
slug=$("$PLUGIN_ROOT/bin/deep-research-init.sh" "MNIST accuracy under 100k params")
[[ -n "$slug" ]] || { echo "FAIL: empty slug" >&2; exit 1; }
[[ "$slug" == deep-research-* ]] \
  || { echo "FAIL: slug missing prefix: $slug" >&2; exit 1; }
slug_body="${slug#deep-research-}"
[[ ${#slug_body} -le 18 ]] \
  || { echo "FAIL: slug body > 18 chars: '${slug_body}' (${#slug_body} chars)" >&2; exit 1; }
[[ ${#slug} -le 32 ]] \
  || { echo "FAIL: full slug > 32 chars: '$slug' (${#slug} chars)" >&2; exit 1; }
pass "slug body ≤ 18 chars (full slug fits 32-char spawn cap)"

# Case 2: state files written (topic.txt + metric.txt only)
source "$PLUGIN_ROOT/lib/state.sh"
REPO_HASH=$(cw_repo_hash)
state_dir="$TMPHOME/state/$REPO_HASH/$slug/_deep-research"
assert_file_exists "$state_dir/topic.txt"
assert_file_exists "$state_dir/metric.txt"
[[ ! -f "$state_dir/budget.txt" ]] \
  || { echo "FAIL: v0.27.0 must not create budget.txt" >&2; exit 1; }
pass "topic.txt and metric.txt written; budget.txt absent"

# Case 3: --max-rounds rejected
if "$PLUGIN_ROOT/bin/deep-research-init.sh" --max-rounds 3 "another topic" 2>/dev/null; then
  echo "FAIL: --max-rounds should be rejected" >&2; exit 1
fi
pass "--max-rounds rejected"

# Case 4: --branches-per-round rejected
if "$PLUGIN_ROOT/bin/deep-research-init.sh" --branches-per-round 2 "another topic" 2>/dev/null; then
  echo "FAIL: --branches-per-round should be rejected" >&2; exit 1
fi
pass "--branches-per-round rejected"

# Case 5: --time-budget rejected
if "$PLUGIN_ROOT/bin/deep-research-init.sh" --time-budget 1h "another topic" 2>/dev/null; then
  echo "FAIL: --time-budget should be rejected" >&2; exit 1
fi
pass "--time-budget rejected"

# Case 6: --cost-warning rejected
if "$PLUGIN_ROOT/bin/deep-research-init.sh" --cost-warning 10 "another topic" 2>/dev/null; then
  echo "FAIL: --cost-warning should be rejected" >&2; exit 1
fi
pass "--cost-warning rejected"

# Case 7: --allow-net rejected
if "$PLUGIN_ROOT/bin/deep-research-init.sh" --allow-net "another topic" 2>/dev/null; then
  echo "FAIL: --allow-net should be rejected" >&2; exit 1
fi
pass "--allow-net rejected"

# Case 8: --seed-from still accepted
seed_doc="$TMPHOME/fake-landscape.md"
echo "# fake" > "$seed_doc"
slug2=$("$PLUGIN_ROOT/bin/deep-research-init.sh" --seed-from "$seed_doc" "topic with seed")
assert_file_exists "$TMPHOME/state/$REPO_HASH/$slug2/_deep-research/seed-from.txt"
pass "--seed-from still accepted; writes seed-from.txt"

# Case 9: codex missing → init refuses
rm "$TMPHOME/providers-available.txt"
echo "claude" > "$TMPHOME/providers-available.txt"
if "$PLUGIN_ROOT/bin/deep-research-init.sh" "no codex" 2>/dev/null; then
  echo "FAIL: should refuse without codex" >&2; exit 1
fi
pass "init refuses without codex"

# Case 10: BLOCKER #1 reproduction — the v0.26.0 case
echo "codex" > "$TMPHOME/providers-available.txt"
slug3=$("$PLUGIN_ROOT/bin/deep-research-init.sh" "optimize MNIST classifier accuracy under 100k params")
[[ ${#slug3} -le 32 ]] \
  || { echo "FAIL: BLOCKER #1 not fixed; slug '$slug3' is ${#slug3} chars" >&2; exit 1; }
pass "BLOCKER #1 reproduction: long topic produces ≤32-char slug"

echo "test_deep_research_init_v027: 10 assertions green"
