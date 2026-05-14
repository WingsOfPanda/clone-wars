#!/usr/bin/env bash
# tests/test_deploy_scope_match.sh — v0.30.0 item 4
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deploy-scope.sh"

declare -F cw_deploy_match_diff_against_components >/dev/null \
  || { echo "FAIL: cw_deploy_match_diff_against_components not defined" >&2; exit 1; }
pass "helper defined"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# Case 1: exact match → in-scope (empty output)
printf 'lib/foo.sh\n' > "$SANDBOX/diff1.txt"
printf 'lib/foo.sh\n' > "$SANDBOX/comp1.txt"
out=$(cw_deploy_match_diff_against_components "$SANDBOX/diff1.txt" "$SANDBOX/comp1.txt")
[[ -z "$out" ]] || { echo "FAIL: exact match should produce empty output, got: $out" >&2; exit 1; }
pass "1. exact match: in-scope (no output)"

# Case 2: explicit-dir prefix (listed with /)
printf 'arsreportllm/skills/radiology/brain_mri/SKILL.md\narsreportllm/skills/admission/admission_record/SKILL.md\n' > "$SANDBOX/diff2.txt"
printf 'arsreportllm/skills/\n' > "$SANDBOX/comp2.txt"
out=$(cw_deploy_match_diff_against_components "$SANDBOX/diff2.txt" "$SANDBOX/comp2.txt")
[[ -z "$out" ]] || { echo "FAIL: explicit-dir prefix match failed, got: $out" >&2; exit 1; }
pass "2. explicit dir (with /) covers all files under it"

# Case 3: implicit-dir prefix (listed without /)
printf 'arsreportllm/skills/radiology/brain_mri/SKILL.md\n' > "$SANDBOX/diff3.txt"
printf 'arsreportllm/skills\n' > "$SANDBOX/comp3.txt"
out=$(cw_deploy_match_diff_against_components "$SANDBOX/diff3.txt" "$SANDBOX/comp3.txt")
[[ -z "$out" ]] || { echo "FAIL: implicit-dir prefix match failed, got: $out" >&2; exit 1; }
pass "3. implicit dir (no /) also covers files under it"

# Case 4: out-of-scope reported, in-scope suppressed
printf 'tests/run.sh\nlib/foo.sh\n' > "$SANDBOX/diff4.txt"
printf 'lib/foo.sh\n' > "$SANDBOX/comp4.txt"
out=$(cw_deploy_match_diff_against_components "$SANDBOX/diff4.txt" "$SANDBOX/comp4.txt")
[[ "$out" == "tests/run.sh" ]] || { echo "FAIL: out-of-scope detection wrong (got: $out)" >&2; exit 1; }
pass "4. out-of-scope path reported, in-scope suppressed"

# Case 5: similar-prefix non-match (lib/foo vs lib/foobar)
printf 'lib/foobar.sh\n' > "$SANDBOX/diff5.txt"
printf 'lib/foo\n' > "$SANDBOX/comp5.txt"
out=$(cw_deploy_match_diff_against_components "$SANDBOX/diff5.txt" "$SANDBOX/comp5.txt")
[[ "$out" == "lib/foobar.sh" ]] || { echo "FAIL: similar-prefix should NOT match (got: $out)" >&2; exit 1; }
pass "5. similar prefix (lib/foo vs lib/foobar) correctly NOT matched"

# Case 6: empty diff → empty output
: > "$SANDBOX/diff6.txt"
printf 'lib/foo.sh\n' > "$SANDBOX/comp6.txt"
out=$(cw_deploy_match_diff_against_components "$SANDBOX/diff6.txt" "$SANDBOX/comp6.txt")
[[ -z "$out" ]] || { echo "FAIL: empty diff should produce empty output, got: $out" >&2; exit 1; }
pass "6. empty diff file: empty output"

# Case 7: empty components → every diff path is out-of-scope
printf 'lib/a.sh\nlib/b.sh\n' > "$SANDBOX/diff7.txt"
: > "$SANDBOX/comp7.txt"
out=$(cw_deploy_match_diff_against_components "$SANDBOX/diff7.txt" "$SANDBOX/comp7.txt")
expected=$'lib/a.sh\nlib/b.sh'
[[ "$out" == "$expected" ]] || { echo "FAIL: empty components should print every diff path, got: $out" >&2; exit 1; }
pass "7. empty components: every diff path is out-of-scope"

# Case 8: missing args → rc=2
set +e
out=$(cw_deploy_match_diff_against_components 2>&1); rc=$?
set -e
[[ "$rc" == "2" ]] || { echo "FAIL: missing args: expected rc=2, got $rc" >&2; exit 1; }
pass "8. rc=2 on missing args"

echo "test_deploy_scope_match: 8 cases passed"
