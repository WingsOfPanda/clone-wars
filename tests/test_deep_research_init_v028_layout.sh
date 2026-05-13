#!/usr/bin/env bash
# tests/test_deep_research_init_v028_layout.sh — v0.28.0 init layout
# init.sh's v0.28.0 responsibility: touch active.txt with topic slug.
# Per-trooper dirs are created by the directive in Phase 4.a after the
# roster is picked (init doesn't know N or ROSTER).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
mkdir -p "$CLONE_WARS_HOME"
echo "codex" > "$CLONE_WARS_HOME/providers-available.txt"

SLUG=$("$PLUGIN_ROOT/bin/deep-research-init.sh" "optimize MNIST classifier accuracy under 100k params")

source "$PLUGIN_ROOT/lib/state.sh"
REPO_HASH=$(cw_repo_hash)
ART="$CLONE_WARS_HOME/state/$REPO_HASH/$SLUG/_deep-research"

# active.txt touched, contains the slug
[[ -f "$ART/active.txt" ]] \
  || { echo "FAIL: active.txt not touched by init" >&2; exit 1; }
got_slug=$(cat "$ART/active.txt" | tr -d '\n')
[[ "$got_slug" == "$SLUG" ]] \
  || { echo "FAIL: active.txt content mismatch (got '$got_slug', expected '$SLUG')" >&2; exit 1; }
pass "init touches active.txt with topic slug"
