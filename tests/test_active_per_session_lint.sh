#!/usr/bin/env bash
# tests/test_active_per_session_lint.sh
# Permanent lint (no skip-guard): bans bare `active.txt` references in
# bin/, lib/, hooks/. v0.40.0 migrates to `active-<session-id>.txt` so
# the hook can match only its own Claude Code session.
#
# Exclusions:
#   - providers-active.txt (medic config — different file entirely)
#   - active-*.txt (the new session-stamped form)
#   - any line containing "# legacy" or "# Legacy" (intentional bare
#     reference for backwards-compat cleanup of pre-v0.40.0 state)
#
# Word-boundary requirement: the match must be preceded by a
# non-word character (start-of-line, /, ', ", or hyphen) — so suffixes
# like "dev_active.txt" never trip it.
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -d bin && -d lib && -d hooks ]] \
  || { echo "FAIL: bin/, lib/, hooks/ not all found at $(pwd)" >&2; exit 1; }

set +e
# shellcheck disable=SC2016  # literal regex, no expansion intended
hits=$(grep -rn -E '(^|[^A-Za-z0-9_])active\.txt' bin/ lib/ hooks/ 2>/dev/null \
  | grep -vE 'providers-active\.txt' \
  | grep -vE '#[[:space:]]*[Ll]egacy' \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')
rc=$?
set -e
if [[ $rc -gt 1 ]]; then
  echo "FAIL: grep error (rc=$rc) scanning bin/, lib/, hooks/" >&2
  exit 1
fi
if [[ -n "$hits" ]]; then
  echo "FAIL: bare active.txt references in bin/, lib/, or hooks/ (must be active-*.txt):" >&2
  echo "$hits" >&2
  exit 1
fi
echo "PASS: no bare active.txt references in bin/, lib/, or hooks/"
