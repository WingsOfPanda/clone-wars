#!/usr/bin/env bash
# tests/test_skip_underscore_dirs.sh
# Regression: trooper-dir glob iterations must skip _-prefixed sibling dirs
# (e.g. _consult/ written by /clone-wars:consult). Without the skip, the
# fallback dir-name parser tries to split "_consult" on the last hyphen and
# fires the v0.0.4 deprecation warning every time list/teardown/commanders
# walk the topic.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/ipc.sh
source ../lib/commanders.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# Build a topic that has one real trooper + a _consult/ sibling dir.
RH=$(cw_repo_hash)
TOPIC=consult-fixture
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/rex-codex" "$TD/_consult"

# Real trooper has a v0.0.4-style pane.json so the dir-name fallback never
# fires for it. _consult/ has no pane.json — that's where the bug used to leak.
cat > "$TD/rex-codex/pane.json" <<'JSON'
{"pane_id":"%999","commander":"rex","model":"codex","spawned_at":"2026-04-29T00:00:00Z"}
JSON
echo 'topic placeholder' > "$TD/_consult/topic.txt"

# 1. cw_commanders_in_use_in_topic must return ONLY rex, no warnings on stderr.
out=$(cw_commanders_in_use_in_topic "$TOPIC" 2>"$TMP/err")
assert_eq "$out" "rex" "in_use_in_topic returns rex only"
[[ ! -s "$TMP/err" ]] || { echo "FAIL: stderr non-empty: $(cat "$TMP/err")" >&2; exit 1; }
pass "in_use_in_topic skips _consult/ silently"

# 2. cw_commanders_in_use_globally — same expectation across topics.
out=$(cw_commanders_in_use_globally 2>"$TMP/err2")
assert_eq "$out" "rex" "in_use_globally returns rex only"
[[ ! -s "$TMP/err2" ]] || { echo "FAIL: stderr non-empty: $(cat "$TMP/err2")" >&2; exit 1; }
pass "in_use_globally skips _consult/ silently"

# 3. bin/list.sh must not emit the deprecation warning.
out=$(../bin/list.sh "$TOPIC" 2>&1)
echo "$out" | grep -q 'pane.json predates' \
  && { echo "FAIL: list.sh leaked pane.json warning:" >&2; echo "$out" >&2; exit 1; }
echo "$out" | grep -q '^rex' || { echo "FAIL: list.sh did not list rex:" >&2; echo "$out" >&2; exit 1; }
pass "bin/list.sh skips _consult/ without warning"
