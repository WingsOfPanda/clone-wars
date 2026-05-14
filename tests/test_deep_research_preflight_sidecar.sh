#!/usr/bin/env bash
# tests/test_deep_research_preflight_sidecar.sh — v0.28.3 lib helper contract.
# cw_deep_research_write_preflight_sidecar writes consult-shaped 2-col TSV
# (codex\t<commander>) to <art-dir>/troopers-preflight.txt for consumption by
# bin/preflight-layout.sh --troopers-from.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

declare -F cw_deep_research_write_preflight_sidecar >/dev/null \
  || { echo "FAIL: cw_deep_research_write_preflight_sidecar not defined" >&2; exit 1; }
pass "helper defined"

# Case 1: N=2 roster writes correct 2-col TSV
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/_deep-research"
cw_deep_research_write_preflight_sidecar "$SANDBOX/_deep-research" rex keeli
out="$SANDBOX/_deep-research/troopers-preflight.txt"
assert_file_exists "$out" "sidecar written"
got=$(cat "$out")
expected=$'codex\trex\ncodex\tkeeli'
[[ "$got" == "$expected" ]] || { echo "FAIL: N=2 content mismatch — got: $(printf %q "$got"); want: $(printf %q "$expected")" >&2; exit 1; }
pass "N=2 sidecar content correct (codex\\trex\\ncodex\\tkeeli)"

# Case 2: N=3 roster writes 3 rows in order
rm -f "$out"
cw_deep_research_write_preflight_sidecar "$SANDBOX/_deep-research" rex keeli cody
got=$(cat "$out")
expected=$'codex\trex\ncodex\tkeeli\ncodex\tcody'
[[ "$got" == "$expected" ]] || { echo "FAIL: N=3 content mismatch — got: $(printf %q "$got")" >&2; exit 1; }
pass "N=3 sidecar content correct"

# Case 3: idempotent — calling again with same args produces same content
cw_deep_research_write_preflight_sidecar "$SANDBOX/_deep-research" rex keeli cody
got2=$(cat "$out")
[[ "$got" == "$got2" ]] || { echo "FAIL: not idempotent" >&2; exit 1; }
pass "idempotent — second call produces same content"

# Case 4: idempotent overwrite — call with different roster, file is fully replaced
cw_deep_research_write_preflight_sidecar "$SANDBOX/_deep-research" rex
got=$(cat "$out")
[[ "$got" == $'codex\trex' ]] || { echo "FAIL: overwrite incomplete — got: $(printf %q "$got")" >&2; exit 1; }
pass "overwrite replaces content (no append)"

# Case 5: no .tmp leftover after success
[[ ! -f "$SANDBOX/_deep-research/troopers-preflight.txt.tmp" ]] \
  || { echo "FAIL: .tmp not cleaned up" >&2; exit 1; }
pass "no .tmp file left after success"

# Case 6: rc=1 on missing art-dir
set +e
cw_deep_research_write_preflight_sidecar "$SANDBOX/does-not-exist" rex 2>/dev/null
rc=$?
set -e
[[ "$rc" == "1" ]] || { echo "FAIL: expected rc=1 for missing art-dir, got $rc" >&2; exit 1; }
pass "rc=1 on missing art-dir"

# Case 7: rc=1 on zero commanders
set +e
cw_deep_research_write_preflight_sidecar "$SANDBOX/_deep-research" 2>/dev/null
rc=$?
set -e
[[ "$rc" == "1" ]] || { echo "FAIL: expected rc=1 for zero commanders, got $rc" >&2; exit 1; }
pass "rc=1 on zero commanders"

echo "test_deep_research_preflight_sidecar: 7 cases passed"
