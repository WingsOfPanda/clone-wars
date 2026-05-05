#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/consult-hub.sh"

TMP=$(mktemp -d -t cw-findings.XXXXXX); trap 'rm -rf "$TMP"' EXIT

# (a) Latest ### returned (parses correctly through nested headings)
cat > "$TMP/findings1.md" <<'F'
## Findings

### ars_fleet/ARS-TaskServe
1. [src/registry.py:42] foo

### ars_fleet/ARS-LVMGateway
1. [src/dispatcher.py:1] bar

### ars_lab/ARS-Foo
1. [src/foo.py:7] baz
F
out=$(cw_consult_findings_active_subproject "$TMP/findings1.md")
[[ "$out" == "ars_lab/ARS-Foo" ]] || { echo "FAIL (a): expected ars_lab/ARS-Foo, got $out"; exit 1; }
pass "(a) latest ### heading returned (nested under ## Findings)"

# (b) Two headings — last wins
cat > "$TMP/findings2.md" <<'F'
### A
1. [x] one

### B
1. [y] two
F
out=$(cw_consult_findings_active_subproject "$TMP/findings2.md")
[[ "$out" == "B" ]] || { echo "FAIL (b): $out"; exit 1; }
pass "(b) two headings → last wins"

# (c) Flat findings (no ###) → rc=1
cat > "$TMP/findings3.md" <<'F'
## Findings

1. [src/x.py:1] thing
2. [src/y.py:2] other
F
if cw_consult_findings_active_subproject "$TMP/findings3.md" 2>/dev/null; then
  echo "FAIL (c): expected rc=1"; exit 1
fi
pass "(c) flat findings (no ###) → rc=1"

# (d) Missing file → rc=1
if cw_consult_findings_active_subproject "$TMP/no-such-file.md" 2>/dev/null; then
  echo "FAIL (d): expected rc=1"; exit 1
fi
pass "(d) missing file → rc=1"
