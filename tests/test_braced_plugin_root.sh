#!/usr/bin/env bash
# Permanent invariant: every $CLAUDE_PLUGIN_ROOT in commands/*.md must be
# braced form (${CLAUDE_PLUGIN_ROOT}). The Claude Code slash-command renderer
# substitutes only the braced form into absolute install paths at
# directive-render time. Unbraced references survive literal into bash
# subshells where $CLAUDE_PLUGIN_ROOT is unset and expand to empty.
# See docs/superpowers/specs/2026-05-16-v0.39.0-braced-plugin-root-design.md
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -d commands ]] || { echo "FAIL: commands/ not found at $(pwd)/commands" >&2; exit 1; }

set +e
# shellcheck disable=SC2016  # literal '\$CLAUDE_PLUGIN_ROOT' is the regex we want
hits=$(grep -rn '\$CLAUDE_PLUGIN_ROOT' commands/ 2>/dev/null)
rc=$?
set -e

# grep exit codes: 0=match found, 1=no match, 2+=error
if [[ $rc -gt 1 ]]; then
  echo "FAIL: grep error (rc=$rc) scanning commands/" >&2
  exit 1
fi
if [[ -n "$hits" ]]; then
  echo "FAIL: unbraced \$CLAUDE_PLUGIN_ROOT in commands/ (must be \${CLAUDE_PLUGIN_ROOT}):" >&2
  echo "$hits" >&2
  exit 1
fi
echo "PASS: all CLAUDE_PLUGIN_ROOT refs in commands/ are braced"
