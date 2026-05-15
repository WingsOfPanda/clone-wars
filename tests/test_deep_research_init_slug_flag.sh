#!/usr/bin/env bash
# v0.34.0 — bin/deep-research-init.sh --slug <name>
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP"
mkdir -p "$TMP"
printf 'codex\n' > "$TMP/providers-available.txt"

# Case 1: --slug=foo → topic = deep-research-foo
TOPIC=$( "$PLUGIN_ROOT/bin/deep-research-init.sh" --slug=foo "raw topic text" 2>/dev/null )
[[ "$TOPIC" == "deep-research-foo" ]] \
  || { echo "FAIL: case 1 expected deep-research-foo, got '$TOPIC'"; exit 1; }
pass "1. --slug=foo → topic = deep-research-foo"

# Case 2: --slug=Foo (uppercase) → rc=2
rc=0
"$PLUGIN_ROOT/bin/deep-research-init.sh" --slug=Foo "another topic" 2>/dev/null || rc=$?
[[ "$rc" == 2 ]] \
  || { echo "FAIL: case 2 uppercase --slug should rc=2 (got $rc)"; exit 1; }
pass "2. --slug=Foo → rc=2"

# Case 3: --slug=foo_bar (underscore) → rc=2
rc=0
"$PLUGIN_ROOT/bin/deep-research-init.sh" --slug='foo_bar' "another topic" 2>/dev/null || rc=$?
[[ "$rc" == 2 ]] \
  || { echo "FAIL: case 3 invalid char in --slug should rc=2 (got $rc)"; exit 1; }
pass "3. --slug=foo_bar → rc=2 (underscore disallowed)"

# Case 4: --slug over 18 chars → rc=2
LONG=abcdefghijklmnopqrs   # 19 chars
rc=0
"$PLUGIN_ROOT/bin/deep-research-init.sh" --slug="$LONG" "topic" 2>/dev/null || rc=$?
[[ "$rc" == 2 ]] \
  || { echo "FAIL: case 4 long --slug should rc=2 (got $rc)"; exit 1; }
pass "4. --slug over 18 chars → rc=2"

# Case 5: --slug omitted → auto-derivation still works
TOPIC=$( "$PLUGIN_ROOT/bin/deep-research-init.sh" "optimize accuracy" 2>/dev/null )
[[ "$TOPIC" == deep-research-* ]] \
  || { echo "FAIL: case 5 expected deep-research-* prefix, got '$TOPIC'"; exit 1; }
pass "5. --slug omitted → auto-derivation preserved"

echo "test_deep_research_init_slug_flag: 5 cases passed"
