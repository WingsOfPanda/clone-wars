#!/usr/bin/env bash
# tests/test_send_from_flag.sh — v0.5.0 cw_send --from sender attribution.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"
export CLONE_WARS_HOME="$SANDBOX"
PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
source ../lib/log.sh
source ../lib/state.sh
source ../lib/ipc.sh

mkdir -p "$SANDBOX/state/$(cw_repo_hash)/topic-x/rex-codex"
INBOX="$SANDBOX/state/$(cw_repo_hash)/topic-x/rex-codex/inbox.md"

# Case 1: default sender → "From: master-yoda".
cw_inbox_write rex codex topic-x "hello rex"
head -1 "$INBOX" | grep -q '^From: master-yoda$' \
  || { echo "FAIL c1"; cat "$INBOX"; exit 1; }
pass "default sender → From: master-yoda"

# Case 2: explicit --from cody → "From: cody".
cw_inbox_write --from cody rex codex topic-x "hi from cody"
head -1 "$INBOX" | grep -q '^From: cody$' \
  || { echo "FAIL c2"; cat "$INBOX"; exit 1; }
pass "explicit --from cody → From: cody"

# Case 3: --from with no value → rc=2.
if cw_inbox_write --from 2>/dev/null; then
  echo "FAIL c3: expected rc=2"; exit 1
fi
pass "--from with no value → rc=2"

# Case 4: invalid sender chars → rc=2.
if cw_inbox_write --from "evil$(date)" rex codex topic-x "x" 2>/dev/null; then
  echo "FAIL c4: expected rc=2"; exit 1
fi
pass "invalid sender chars → rc=2"

# Case 5: body unchanged after header (smoke check on END_OF_INSTRUCTION).
cw_inbox_write --from rex rex codex topic-x "task body content"
grep -q '^task body content$' "$INBOX" \
  || { echo "FAIL c5: body missing"; cat "$INBOX"; exit 1; }
grep -q '^END_OF_INSTRUCTION$' "$INBOX" \
  || { echo "FAIL c5: sentinel missing"; cat "$INBOX"; exit 1; }
pass "body and END_OF_INSTRUCTION sentinel preserved"

echo "ALL PASS"
