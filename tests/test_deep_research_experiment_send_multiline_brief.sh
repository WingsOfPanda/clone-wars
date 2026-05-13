#!/usr/bin/env bash
# tests/test_deep_research_experiment_send_multiline_brief.sh — v0.27.2 BUG #4 lock
# experiment-send.sh must render multi-line APPROACH_BRIEF with regex
# metachars correctly into a non-empty prompt.md with no remaining placeholders.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

mkdir -p "$CLONE_WARS_HOME"
echo "codex" > "$CLONE_WARS_HOME/providers-available.txt"

# Init the topic via deep-research-init.sh
TOPIC=$("$PLUGIN_ROOT/bin/deep-research-init.sh" "BUG #4 multiline brief test")
echo "TOPIC=$TOPIC"

source "$PLUGIN_ROOT/lib/state.sh"
REPO_HASH=$(cw_repo_hash)
TD="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC"
ART="$TD/_deep-research"
mkdir -p "$ART"

# Hand-write metric.md (Phase 1 stand-in)
cat > "$ART/metric.md" <<'EOF'
# Research goal

**Primary metric:** accuracy
**Direction:** maximize
EOF

# Hand-write hardware.txt (Phase 2 init-time probe stand-in)
{
  printf 'detected_at\t2026-05-12T12:00:00Z\n'
  printf 'gpu\tNVIDIA L20\t49140\t30000\t580.126.09\n'
} > "$ART/hardware.txt"

# Stage a fake-spawned trooper (pane.json + outbox.jsonl + status.json) so
# experiment-send.sh's send.sh nudge has a pane to look up. Use DRY_RUN to
# skip the actual tmux send-keys call.
mkdir -p "$TD/rex-codex"
echo '{"pane_id":"%9999","pid":99999,"spawned_at":"2026-05-12T00:00:00Z"}' > "$TD/rex-codex/pane.json"
echo '' > "$TD/rex-codex/outbox.jsonl"
echo '{"state":"working","updated":"2026-05-12T12:00:00Z","last_event":"ready"}' > "$TD/rex-codex/status.json"

# v0.28.0: seed per-trooper state.txt (normally done by directive Phase 4.a)
source "$PLUGIN_ROOT/lib/deep-research.sh"
mkdir -p "$ART/troopers/rex/experiments"
cw_deep_research_trooper_state_write "$ART" rex \
  exp_counter=0 phase=idle current_exp_id= \
  last_event_ts=2026-05-13T08:00:00Z last_event=spawn probe_sent_ts=

# Build a deliberately nasty multi-line APPROACH_BRIEF that would break sed:
#   - newlines
#   - regex metachars: + * ( ) | & / \ ^ $ ?
#   - unicode arrow
#   - JSON-looking content
read -r -d '' NASTY <<'BRIEF' || true
Build on your exp-002 winner (Depthwise-separable CNN, 0.9977 acc, 89,666 params).

Add three upgrades:
  (1) MixUp regularization with alpha=0.2.
  (2) Test-Time Augmentation with 5-crop (4 corners + center).
  (3) Bump epochs 60 -> 100; keep AdamW lr=1e-3 wd=1e-2.

Regex metachars test: a+b*c?d (e|f) [g] {h} & / \ ^ $
Unicode arrow → here
JSON-like: {"key": "value"}
BRIEF

export CW_DEEP_RESEARCH_DRY_RUN=1
"$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
  "$TOPIC" rex exp-001 "Multiline brief test" "$NASTY"

# Assert prompt.md is non-empty
PROMPT="$ART/troopers/rex/experiments/exp-001/prompt.md"
assert_file_exists "$PROMPT" "prompt.md exists"
size=$(wc -c < "$PROMPT")
(( size > 500 )) \
  || { echo "FAIL: prompt.md too small ($size bytes); expected >500 bytes:" >&2; head -20 "$PROMPT" >&2; exit 1; }
pass "prompt.md non-empty ($size bytes)"

# Assert no unrendered placeholders
if grep -qE '\{\{[A-Z_]+\}\}' "$PROMPT"; then
  echo "FAIL: unrendered placeholders remain:" >&2
  grep -E '\{\{[A-Z_]+\}\}' "$PROMPT" >&2
  exit 1
fi
pass "prompt.md has no remaining {{...}} placeholders"

# Assert the multi-line brief content landed verbatim
grep -q 'Build on your exp-002 winner' "$PROMPT" \
  || { echo "FAIL: brief first line missing" >&2; exit 1; }
grep -q 'Regex metachars test: a+b\*c?d (e|f)' "$PROMPT" \
  || { echo "FAIL: regex-metachar line missing" >&2; exit 1; }
grep -q 'Unicode arrow → here' "$PROMPT" \
  || { echo "FAIL: unicode arrow line missing" >&2; exit 1; }
grep -qF 'JSON-like: {"key": "value"}' "$PROMPT" \
  || { echo "FAIL: JSON-like line missing" >&2; exit 1; }
pass "brief content (regex metachars + unicode + JSON) landed verbatim"

# Assert inbox.md was written
INBOX="$TD/rex-codex/inbox.md"
assert_file_exists "$INBOX" "inbox.md exists"
grep -q 'Build on your exp-002 winner' "$INBOX" \
  || { echo "FAIL: inbox.md missing the brief content" >&2; exit 1; }
pass "inbox.md contains the rendered prompt"
