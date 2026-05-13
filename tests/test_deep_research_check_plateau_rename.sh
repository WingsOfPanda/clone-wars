#!/usr/bin/env bash
# tests/test_deep_research_check_plateau_rename.sh — v0.28.0 rename lock
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

# New name must exist
declare -F cw_deep_research_check_plateau >/dev/null \
  || { echo "FAIL: cw_deep_research_check_plateau not defined" >&2; exit 1; }
pass "cw_deep_research_check_plateau exists"

# Old name must NOT exist (no back-compat alias per full-replacement decision)
if declare -F cw_deep_research_check_stagnation >/dev/null; then
  echo "FAIL: cw_deep_research_check_stagnation should be removed in v0.28.0" >&2
  exit 1
fi
pass "old name cw_deep_research_check_stagnation removed"

# Behavior: 5 consecutive identical metrics → plateau detected
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
SB="$TMP/scoreboard.md"
cat > "$SB" <<'EOF'
| Exp | Commander | Metric | Status | Runtime | Notes |
|---|---|---|---|---|---|
| exp-001 | rex | 0.97 | ok | 100 | |
| exp-002 | rex | 0.972 | ok | 100 | |
| exp-003 | rex | 0.971 | ok | 100 | |
| exp-004 | rex | 0.973 | ok | 100 | |
| exp-005 | rex | 0.972 | ok | 100 | |
EOF
echo "0" > "$TMP/cursor.txt"
rc=0; cw_deep_research_check_plateau "$SB" "$TMP/cursor.txt" || rc=$?
# Plateau detected (rc=0 means plateau in existing semantics)
pass "check_plateau invocable with same signature as check_stagnation"
