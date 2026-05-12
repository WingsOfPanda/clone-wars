#!/usr/bin/env bash
# tests/test_deep_research_lib_extensions.sh — locks lib seam for deep-research
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/contracts.sh"

# cw_consult_art_dir routes deep-research-* → _deep-research/
got=$(cw_consult_art_dir "deep-research-mnist-acc")
[[ "$got" == */_deep-research ]] \
  || { echo "FAIL: deep-research-* routes to $got" >&2; exit 1; }
pass "cw_consult_art_dir routes deep-research-* → _deep-research/"

# Regression: meditate-* still routes correctly
got=$(cw_consult_art_dir "meditate-foo")
[[ "$got" == */_meditate ]] || { echo "FAIL: meditate broken: $got" >&2; exit 1; }
pass "meditate-* still routes to _meditate/"

# Regression: consult-* still routes correctly
got=$(cw_consult_art_dir "consult-bar")
[[ "$got" == */_consult ]] || { echo "FAIL: consult broken: $got" >&2; exit 1; }
pass "consult-* still routes to _consult/"

# cw_consult_topic_validate accepts deep-research-*
cw_consult_topic_validate "deep-research-foo" \
  || { echo "FAIL: deep-research-foo rejected" >&2; exit 1; }
pass "topic_validate accepts deep-research-foo"

# Regression: meditate-* + consult-* validation
cw_consult_topic_validate "meditate-foo" \
  || { echo "FAIL: meditate-foo rejected" >&2; exit 1; }
pass "topic_validate accepts meditate-foo"
cw_consult_topic_validate "consult-foo" \
  || { echo "FAIL: consult-foo rejected" >&2; exit 1; }
pass "topic_validate accepts consult-foo"

# cw_consult_topic_validate rejects bad topics
if cw_consult_topic_validate "deep-research-../escape" 2>/dev/null; then
  echo "FAIL: dotdot accepted" >&2; exit 1
fi
pass "topic_validate rejects ../ traversal"

# cw_consult_timeout has experiment kind
got=$(cw_consult_timeout experiment)
[[ "$got" == "1800" ]] \
  || { echo "FAIL: experiment timeout expected 1800, got $got" >&2; exit 1; }
pass "cw_consult_timeout experiment = 1800"

# cw_consult_wait knows experiment kind — load + grep source
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/consult-wait.sh"
declare -f cw_consult_wait | grep -q "experiment)" \
  || { echo "FAIL: cw_consult_wait missing experiment case" >&2; exit 1; }
pass "cw_consult_wait recognizes experiment kind"

# Bad kind still rejected
if cw_consult_timeout fakekind 2>/dev/null; then
  echo "FAIL: fake kind accepted" >&2; exit 1
fi
pass "cw_consult_timeout rejects unknown kind"

echo "test_deep_research_lib_extensions: 10 assertions green"
