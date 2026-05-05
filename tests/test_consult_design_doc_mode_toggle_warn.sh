#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
DD_BIN="$PLUGIN_ROOT/bin/consult-design-doc.sh"

# Static-wiring: assert the warn block exists in source.
grep -qE 'testing\.md.*acceptance-tests\.md' "$DD_BIN" \
  || { echo "FAIL: mode-toggle warn not wired"; exit 1; }
grep -qE 'log_warn.*both' "$DD_BIN" \
  || { echo "FAIL: log_warn for mode-toggle missing"; exit 1; }
pass "mode-toggle warn wired in bin/consult-design-doc.sh"
