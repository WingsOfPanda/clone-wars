#!/usr/bin/env bash
# tests/test_meditate_init.sh — meditate-init writes expected state files
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# Sandbox state in a temp dir
SANDBOX=$(mktemp -d -t cw-meditate-init.XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT
export CLONE_WARS_HOME="$SANDBOX"

# Seed providers-available.txt with two providers (codex + claude)
mkdir -p "$SANDBOX"
printf 'codex\nclaude\n' > "$SANDBOX/providers-available.txt"

# Seed a stub contracts.yaml so eligibility check doesn't trip
cat > "$SANDBOX/contracts.yaml" <<'EOF'
codex:
  binary: codex
  permission: allow
claude:
  binary: claude
  permission: allow
opencode:
  binary: opencode
  permission: allow
EOF

# Run init
output=$("$PLUGIN_ROOT/bin/meditate-init.sh" "explore SOTA continuous batching" 2>/tmp/cw-meditate-init.err)
[[ -n "$output" ]] || { echo "FAIL: init produced no stdout (topic)"; cat /tmp/cw-meditate-init.err; exit 1; }

# Topic should be meditate-<slug>
[[ "$output" =~ ^meditate-explore-sota ]] \
  || { echo "FAIL: topic '$output' does not start with meditate-explore-sota"; exit 1; }
pass "init prints meditate-<slug> topic to stdout"

# State dir should exist (REPO_HASH is for the test's cwd — tests/ — since
# init inherits that cwd from this script)
REPO_HASH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC_DIR="$SANDBOX/state/$REPO_HASH/$output"
[[ -d "$TOPIC_DIR/_meditate" ]] \
  || { echo "FAIL: _meditate/ dir not created at $TOPIC_DIR"; exit 1; }
pass "init creates _meditate/ directory"

# topic.txt should contain the topic text
[[ -f "$TOPIC_DIR/_meditate/topic.txt" ]] || { echo "FAIL: topic.txt not written"; exit 1; }
content=$(cat "$TOPIC_DIR/_meditate/topic.txt")
[[ "$content" == "explore SOTA continuous batching" ]] \
  || { echo "FAIL: topic.txt content wrong: '$content'"; exit 1; }
pass "topic.txt has verbatim topic text"

# troopers.txt should have 2 rows (codex + claude)
[[ -f "$TOPIC_DIR/_meditate/troopers.txt" ]] || { echo "FAIL: troopers.txt not written"; exit 1; }
rows=$(grep -cE '^[a-z]+	[a-z]+$' "$TOPIC_DIR/_meditate/troopers.txt" || true)
[[ "$rows" -eq 2 ]] \
  || { echo "FAIL: troopers.txt has $rows data rows (expected 2)"; cat "$TOPIC_DIR/_meditate/troopers.txt"; exit 1; }
pass "troopers.txt has 2 provider-commander rows"

pass "meditate-init.sh writes expected state files for 2-trooper roster"
