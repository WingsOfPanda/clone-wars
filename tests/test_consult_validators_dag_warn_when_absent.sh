#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/consult-hub.sh"
source "$PLUGIN_ROOT/lib/consult-validators.sh"

TMP=$(mktemp -d -t cw-acc-warn.XXXXXX); trap 'rm -rf "$TMP"' EXIT
ART="$TMP/_consult"; mkdir -p "$ART/design-doc"
printf '%s\n' "hub/A" "hub/B" | cw_consult_targets_persist "$ART"
# Intentionally NO dag.md present.

cat > "$TMP/tests.md" <<'T'
- **Step 1** [A] base
  - Run: pytest
  - Pass: exit 0

- **Step 2** [B] consume
  - Run: pytest
  - Pass: exit 0
T

# Should pass (dag absent → step-id check skipped) AND emit log_warn.
err=$(cw_consult_acceptance_tests_validate "$ART" < "$TMP/tests.md" 2>&1) && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] || { echo "FAIL: expected rc=0 (pass with warn), got $rc"; exit 1; }
grep -qi 'dag.md absent' <<< "$err" \
  || { echo "FAIL: expected log_warn 'dag.md absent', got: $err"; exit 1; }
pass "acceptance-tests validator log_warns when dag.md absent"
