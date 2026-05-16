#!/usr/bin/env bash
# tests/test_no_hardcoded_paths.sh
# Permanent lint: runtime plugin code must NOT hardcode /home/<user>/ paths.
# Plugin gets installed at user-controlled paths via /plugin install;
# use ${CLAUDE_PLUGIN_ROOT}/<path> (Claude Code docs: plugin-install-path)
# OR, in bin/*.sh entry scripts, the resolution chain:
#   PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
#
# No version skip-guard — this lint runs every release, forever.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
PLUGIN_ROOT="$(cd .. && pwd)"

# Scan only runtime plugin code. tests/, docs/, CLAUDE.md, README excluded:
#   - tests/ can have legitimate fixture paths (test_deploy_v07_dogfood,
#     test_deploy_dag_capwords_path)
#   - docs/superpowers/{specs,plans}/ cite historical dogfood scenarios
#   - CLAUDE.md changelog references past dogfood paths
LINT_DIRS=(commands bin lib hooks config .claude-plugin)
FAILED=0
for d in "${LINT_DIRS[@]}"; do
  [[ -d "$PLUGIN_ROOT/$d" ]] || continue
  # Word-boundary regex: /home/<lowercase-username>/ — catches any
  # contributor's home dir, not just /home/liupan.
  hits=$(grep -rnE "/home/[a-z][a-zA-Z0-9_-]*/" "$PLUGIN_ROOT/$d" 2>/dev/null || true)
  if [[ -n "$hits" ]]; then
    echo "FAIL: hardcoded /home/<user>/ path(s) in $d/:" >&2
    echo "$hits" >&2
    FAILED=1
  fi
done

if (( FAILED != 0 )); then
  echo "" >&2
  echo "Fix: use \${CLAUDE_PLUGIN_ROOT}/<path> instead." >&2
  echo "For bin/*.sh entry scripts, use the standard resolution chain:" >&2
  echo "  PLUGIN_ROOT=\"\${CLAUDE_PLUGIN_ROOT:-\$(cd \"\$(dirname \"\${BASH_SOURCE[0]}\")/..\" && pwd)}\"" >&2
  exit 1
fi
pass "no hardcoded /home/<user>/ paths in: ${LINT_DIRS[*]}"
echo "test_no_hardcoded_paths: lint passed"
