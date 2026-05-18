#!/usr/bin/env bash
# tests/test_deep_research_sota_in_prompt.sh — v0.44.0 Lane C
# Locks: when $ART_DIR/sota.md exists, the dispatched prompt.md
# contains a "## Reference: SOTA" section with sota.md content
# inlined verbatim, plus a "Web search affordance" two-liner.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
SANDBOX=$(mktemp -d)
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"
mkdir -p "$CLONE_WARS_HOME"
trap 'rm -rf "$SANDBOX"' EXIT

export CLAUDE_CODE_SESSION_ID=ssss0044-sota-in-prompt-1111-222222222222
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"

TOPIC=deep-research-sota-in-prompt
REPO_HASH=$(cd "$SANDBOX" && cw_repo_hash)
TD="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC"
ART="$TD/_deep-research"
COMMANDER=rex
mkdir -p "$ART/troopers/$COMMANDER/experiments"
mkdir -p "$TD/$COMMANDER-codex"
touch "$TD/$COMMANDER-codex/outbox.jsonl"

# Seed minimum state files dispatch needs
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

# Seed sota.md with a distinctive marker string
cat > "$ART/sota.md" <<'EOF'
# SOTA reference — sota-in-prompt-test

> **Sweep date:** 2026-05-18T10:00:00Z
> **Optimizing for:** accuracy
> **Queries fired:** test query

| Approach family | Best known | Constraint compliance | Source | Notes |
|---|---|---|---|---|
| MARKER-FAMILY | MARKER-99.99% | fits | https://marker.example | MARKER-row |
EOF

# Dispatch one experiment
set +e
( cd "$SANDBOX" && "$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
    "$TOPIC" "$COMMANDER" "exp-001" "test-approach" "test brief" ) \
  > "$SANDBOX/dispatch.out" 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || { echo "FAIL: dispatch rc=$rc" >&2; cat "$SANDBOX/dispatch.out" >&2; exit 1; }

PROMPT="$ART/troopers/$COMMANDER/experiments/exp-001/prompt.md"
[[ -f "$PROMPT" ]] || { echo "FAIL: prompt.md not written at $PROMPT" >&2; ls -laR "$ART/troopers/$COMMANDER/" >&2; exit 1; }

# Assert "## Reference: SOTA" header present
grep -qE '^## Reference: SOTA$' "$PROMPT" \
  || { echo "FAIL: prompt.md missing '## Reference: SOTA' header" >&2; cat "$PROMPT" >&2; exit 1; }
pass "1. prompt.md contains '## Reference: SOTA' header"

# Assert sota.md content inlined verbatim
grep -q 'MARKER-FAMILY' "$PROMPT" \
  || { echo "FAIL: prompt.md missing MARKER-FAMILY row from sota.md" >&2; cat "$PROMPT" >&2; exit 1; }
grep -q 'MARKER-99.99%' "$PROMPT" \
  || { echo "FAIL: prompt.md missing MARKER-99.99% column from sota.md" >&2; cat "$PROMPT" >&2; exit 1; }
grep -q 'https://marker.example' "$PROMPT" \
  || { echo "FAIL: prompt.md missing marker.example URL from sota.md" >&2; cat "$PROMPT" >&2; exit 1; }
pass "2. sota.md row content inlined verbatim in prompt.md"

# Assert web-search affordance two-liner present (case-insensitive
# because the rendered prose uses "Web search" with capital W)
grep -qiE 'web search.{0,40}(allowed|permitted)' "$PROMPT" \
  || { echo "FAIL: prompt.md missing web-search affordance clause" >&2; cat "$PROMPT" >&2; exit 1; }
grep -qE 'notes\.md' "$PROMPT" \
  || { echo "FAIL: prompt.md missing notes.md sources-consulted reference" >&2; cat "$PROMPT" >&2; exit 1; }
pass "3. prompt.md carries web-search affordance + notes.md sources-consulted clause"

echo "test_deep_research_sota_in_prompt: 3 cases passed"
