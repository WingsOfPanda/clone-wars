#!/usr/bin/env bash
# tests/test_consult_design_doc_drilldown_prompt.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
# v0.5.0: drilldown prompt now loads from config/prompt-templates/ via
# cw_consult_load_prompt, which requires CLAUDE_PLUGIN_ROOT to resolve the
# template path. Point at the repo root so the loader finds drilldown.md.
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"
PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
source ../lib/consult.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
SYN="$TMP/synthesis.md"; touch "$SYN"
DD_DIR="$TMP/_consult/design-doc"; mkdir -p "$DD_DIR"

P=$(cw_consult_design_doc_drilldown_prompt "Architecture" "$SYN" "rex" "$DD_DIR" "the trade-offs feel hand-wavy")
echo "$P" | grep -q 'Architecture'                           || { echo "FAIL: section name"; exit 1; }
echo "$P" | grep -q 'END_OF_INSTRUCTION$'                    || { echo "FAIL: sentinel"; exit 1; }
echo "$P" | grep -q 'drilldown-architecture-rex.md'          || { echo "FAIL: output path"; exit 1; }
echo "$P" | grep -qF "$SYN"                                  || { echo "FAIL: synthesis path"; exit 1; }
echo "$P" | grep -q 'hand-wavy'                              || { echo "FAIL: focus text"; exit 1; }
pass "drilldown prompt has section, sentinel, output path, synthesis ref, focus text"

# Lowercase + space-stripped section in output filename.
P2=$(cw_consult_design_doc_drilldown_prompt "Data Flow" "$SYN" "cody" "$DD_DIR" "")
echo "$P2" | grep -q 'drilldown-data-flow-cody.md' || { echo "FAIL: multi-word slug"; exit 1; }
pass "multi-word section produces hyphen-slug filename"

# No-focus default text appears.
P3=$(cw_consult_design_doc_drilldown_prompt "Testing" "$SYN" "rex" "$DD_DIR" "")
echo "$P3" | grep -q 'Provide more depth' || { echo "FAIL: default focus text missing"; exit 1; }
pass "empty focus → default focus text"
