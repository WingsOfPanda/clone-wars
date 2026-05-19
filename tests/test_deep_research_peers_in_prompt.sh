#!/usr/bin/env bash
# tests/test_deep_research_peers_in_prompt.sh — v0.45.0 Lane C
# Locks: when N≥2, the dispatched prompt.md contains a "## Peers"
# section with rows for OTHER troopers; the dispatching trooper
# does NOT appear in their own peers table.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
SANDBOX=$(mktemp -d)
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"
mkdir -p "$CLONE_WARS_HOME"
trap 'rm -rf "$SANDBOX"' EXIT

export CLAUDE_CODE_SESSION_ID=ssss0045-peers-in-prompt-1111-222222222222
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"

TOPIC=deep-research-peers-in-prompt
REPO_HASH=$(cd "$SANDBOX" && cw_repo_hash)
TD="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC"
ART="$TD/_deep-research"
COMMANDER=rex
PEER=keeli
mkdir -p "$ART/troopers/$COMMANDER/experiments" \
         "$ART/troopers/$PEER/experiments" \
         "$TD/$COMMANDER-codex"
touch "$TD/$COMMANDER-codex/outbox.jsonl"

printf '%s\n%s\n' "$COMMANDER" "$PEER" > "$ART/troopers.txt"
printf '%s\n' "$TOPIC" > "$ART/topic.txt"
printf '**Primary metric:** accuracy\n**Direction:** maximize\n' > "$ART/metric.md"
printf 'cpu cores=8\nram_gb=32\nno-gpu\n' > "$ART/hardware.txt"

for c in "$COMMANDER" "$PEER"; do
  cat > "$ART/troopers/$c/state.txt" <<EOF
exp_counter=0
phase=idle
current_exp_id=
last_event_ts=
last_event=spawn
probe_sent_ts=
EOF
done

mkdir -p "$ART/troopers/$PEER/experiments/exp-001"
cat > "$ART/troopers/$PEER/experiments/exp-001/result.json" <<'EOF'
{
  "branch_id": "exp-001",
  "approach_label": "MARKER-PEER-APPROACH",
  "metric_name": "accuracy",
  "metric_value": 0.9871,
  "status": "ok",
  "runtime_s": 12,
  "log_paths": ["./stdout.log"],
  "notes": "MARKER-PEER-NOTES"
}
EOF

set +e
( cd "$SANDBOX" && "$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
    "$TOPIC" "$COMMANDER" "exp-001" "test-approach" "test brief" ) \
  > "$SANDBOX/dispatch.out" 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || { echo "FAIL: dispatch rc=$rc" >&2; cat "$SANDBOX/dispatch.out" >&2; exit 1; }

PROMPT="$ART/troopers/$COMMANDER/experiments/exp-001/prompt.md"
[[ -f "$PROMPT" ]] || { echo "FAIL: prompt.md not written at $PROMPT" >&2; exit 1; }

grep -qE '^## Peers$' "$PROMPT" \
  || { echo "FAIL: prompt.md missing '## Peers' header" >&2; cat "$PROMPT" >&2; exit 1; }
pass "1. prompt.md contains '## Peers' header"

grep -q 'MARKER-PEER-APPROACH' "$PROMPT" \
  || { echo "FAIL: prompt.md missing peer approach marker" >&2; cat "$PROMPT" >&2; exit 1; }
grep -q 'MARKER-PEER-NOTES' "$PROMPT" \
  || { echo "FAIL: prompt.md missing peer notes marker" >&2; cat "$PROMPT" >&2; exit 1; }
pass "2. peer's result.json content appears in prompt.md peers table"

peers_section=$(awk '/^## Peers/{flag=1;next} /^## |^Branch sandbox:/{flag=0} flag' "$PROMPT")
if echo "$peers_section" | grep -qE "\| $COMMANDER "; then
  echo "FAIL: '$COMMANDER' (current commander) appears in own peers table" >&2
  echo "$peers_section" >&2
  exit 1
fi
pass "3. current commander does NOT appear in own peers table"

grep -qiE 'diverge|different corner|justify' "$PROMPT" \
  || { echo "FAIL: prompt.md missing divergence guidance" >&2; cat "$PROMPT" >&2; exit 1; }
pass "4. prompt.md carries divergence guidance"

echo "test_deep_research_peers_in_prompt: 4 cases passed"
