#!/usr/bin/env bash
# tests/test_inbox_ack_round_trip.sh — 3 cases for bin/inbox-ack.sh.
set -uo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export CLONE_WARS_HOME="$TMP/.clone-wars"
mkdir -p "$CLONE_WARS_HOME/state"

cd "$PLUGIN_ROOT"
TOPIC="test-inbox-ack-topic"
CMDR="cody"

source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
OUTBOX=$(cw_outbox_path "$CMDR" codex "$TOPIC")
mkdir -p "$(dirname "$OUTBOX")"
: > "$OUTBOX"

INBOX="$TMP/inbox.md"

# --- Case 1: well-formed inbox → ack has sha + tail
cat > "$INBOX" <<'EOF'
From: master-yoda

Verdict: FOUND
Resume implementation.
EOF
bash "$PLUGIN_ROOT/bin/inbox-ack.sh" "$TOPIC" "$CMDR" "$INBOX"
assert_eq "$?" "0" "case1a: inbox-ack exit 0"
line=$(tail -n1 "$OUTBOX")
expected_sha=$(sha256sum < "$INBOX" | cut -d' ' -f1)
assert_contains "$line" '"event":"ack"' "case1b: event=ack"
assert_contains "$line" "\"inbox_sha256\":\"$expected_sha\"" "case1c: sha matches"
assert_contains "$line" '"inbox_tail":"Resume implementation."' "case1d: tail is last non-blank line"

# --- Case 2: inbox with trailing blank lines → tail is the last *non-blank* line
cat > "$INBOX" <<'EOF'
some content

last meaningful line


EOF
bash "$PLUGIN_ROOT/bin/inbox-ack.sh" "$TOPIC" "$CMDR" "$INBOX"
line=$(tail -n1 "$OUTBOX")
assert_contains "$line" '"inbox_tail":"last meaningful line"' "case2: blank lines skipped"

# --- Case 3: missing inbox → rc=1, no append
before=$(wc -l < "$OUTBOX")
bash "$PLUGIN_ROOT/bin/inbox-ack.sh" "$TOPIC" "$CMDR" "$TMP/no-such-inbox.md" 2>/dev/null
assert_eq "$?" "1" "case3a: missing inbox → rc=1"
after=$(wc -l < "$OUTBOX")
assert_eq "$before" "$after" "case3b: outbox unchanged"

echo "test_inbox_ack_round_trip: 3 cases passed"
