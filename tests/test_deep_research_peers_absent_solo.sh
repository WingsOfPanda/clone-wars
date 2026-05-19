#!/usr/bin/env bash
# tests/test_deep_research_peers_absent_solo.sh — v0.45.0 Lane C regression lock
# Locks: when N=1 (solo session), the dispatched prompt.md does NOT
# contain a "## Peers" header.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
SANDBOX=$(mktemp -d)
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"
mkdir -p "$CLONE_WARS_HOME"
trap 'rm -rf "$SANDBOX"' EXIT

export CLAUDE_CODE_SESSION_ID=ssss0045-peers-absent-solo-1111-222222222222
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"

TOPIC=deep-research-peers-absent-solo
REPO_HASH=$(cd "$SANDBOX" && cw_repo_hash)
TD="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC"
ART="$TD/_deep-research"
COMMANDER=rex
mkdir -p "$ART/troopers/$COMMANDER/experiments" "$TD/$COMMANDER-codex"
touch "$TD/$COMMANDER-codex/outbox.jsonl"

printf '%s\n' "$COMMANDER" > "$ART/troopers.txt"
printf '%s\n' "$TOPIC" > "$ART/topic.txt"
printf '**Primary metric:** accuracy\n**Direction:** maximize\n' > "$ART/metric.md"
printf 'cpu cores=8\nram_gb=32\nno-gpu\n' > "$ART/hardware.txt"
cat > "$ART/troopers/$COMMANDER/state.txt" <<EOF
exp_counter=0
phase=idle
current_exp_id=
last_event_ts=
last_event=spawn
probe_sent_ts=
EOF

set +e
( cd "$SANDBOX" && "$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
    "$TOPIC" "$COMMANDER" "exp-001" "test-approach" "test brief" ) \
  > "$SANDBOX/dispatch.out" 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || { echo "FAIL: dispatch rc=$rc" >&2; cat "$SANDBOX/dispatch.out" >&2; exit 1; }

PROMPT="$ART/troopers/$COMMANDER/experiments/exp-001/prompt.md"
[[ -f "$PROMPT" ]] || { echo "FAIL: prompt.md not written" >&2; exit 1; }

if grep -qE '^## Peers$' "$PROMPT"; then
  echo "FAIL: prompt.md should not contain '## Peers' header when N=1" >&2
  cat "$PROMPT" >&2
  exit 1
fi
pass "1. prompt.md omits '## Peers' header when N=1 solo"

echo "test_deep_research_peers_absent_solo: 1 case passed"
