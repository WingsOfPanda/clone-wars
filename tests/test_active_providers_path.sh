#!/usr/bin/env bash
# tests/test_active_providers_path.sh
#
# v0.18.0: cw_active_providers_path returns providers-active.txt when it
# exists (user-selected roster); falls back to providers-available.txt
# (medic-detected) otherwise. Pure path resolution; does not validate
# contents.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

source ../lib/log.sh
source ../lib/state.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
mkdir -p "$CLONE_WARS_HOME"

# Scenario 1: only providers-available.txt exists → returns that path.
echo codex > "$CLONE_WARS_HOME/providers-available.txt"
got=$(cw_active_providers_path)
assert_eq "$got" "$CLONE_WARS_HOME/providers-available.txt" \
  "fallback to providers-available.txt"

# Scenario 2: both files exist → returns providers-active.txt (preference wins).
echo claude > "$CLONE_WARS_HOME/providers-active.txt"
got=$(cw_active_providers_path)
assert_eq "$got" "$CLONE_WARS_HOME/providers-active.txt" \
  "providers-active.txt preferred when both exist"

# Scenario 3: only providers-active.txt exists (defensive — medic never ran)
# → returns providers-active.txt anyway.
rm "$CLONE_WARS_HOME/providers-available.txt"
got=$(cw_active_providers_path)
assert_eq "$got" "$CLONE_WARS_HOME/providers-active.txt" \
  "providers-active.txt returned when alone"

pass "cw_active_providers_path: precedence resolution works"
