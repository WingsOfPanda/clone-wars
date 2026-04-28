#!/usr/bin/env bash
# tests/test_consult_findings_parse.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/ipc.sh
source ../lib/consult.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# Path helpers
cw_state_init alpha codex demo
DIR=$(cw_trooper_dir alpha codex demo)
assert_eq "$(cw_consult_findings_path alpha codex demo)" "$DIR/findings.md" "findings path"
assert_eq "$(cw_consult_verify_path   alpha codex demo)" "$DIR/verify.md"   "verify path"
pass "path helpers"

# Well-formed claims.
cat > "$DIR/findings.md" <<'MD'
# Findings: x
## Summary
.
## Claims
1. [src/auth/store.py:42] Tokens stored in plaintext.
2. [src/auth/refresh.py:15-30] No retry logic on refresh.
3. [https://example.com/x] External source.
## Notes
MD
mapfile -t CLAIMS < <(cw_consult_parse_claims "$DIR/findings.md")
[[ "${#CLAIMS[@]}" -eq 3 ]] || { echo "FAIL: 3 claims, got ${#CLAIMS[@]}" >&2; exit 1; }
assert_eq "${CLAIMS[0]%%$'\t'*}" "src/auth/store.py:42" "claim 1 cite"
assert_eq "${CLAIMS[2]%%$'\t'*}" "https://example.com/x" "URL cite"
pass "well-formed parsed into 3 claims"

# Status = ok
status=$(cw_consult_findings_status "$DIR/findings.md")
assert_eq "$status" "ok" "well-formed → ok"

# Empty Claims block (no items, but block present).
cat > "$DIR/findings.md" <<'MD'
# Findings: x
## Summary
nothing
## Claims
## Notes
MD
mapfile -t CLAIMS < <(cw_consult_parse_claims "$DIR/findings.md")
[[ "${#CLAIMS[@]}" -eq 0 ]] || { echo "FAIL: empty block expected 0" >&2; exit 1; }
status=$(cw_consult_findings_status "$DIR/findings.md")
assert_eq "$status" "empty" "block empty → empty"
pass "empty Claims block"

# Malformed: file has content but parser extracts 0 (no [citation] anywhere).
cat > "$DIR/findings.md" <<'MD'
# Findings: x
## Summary
A long discussion of token storage and refresh behavior, written in prose.
The trooper did real work but didn't follow the format. Need to surface this.
## Claims
1. The store has plaintext tokens.
2. Refresh has no retry logic.
## Notes
MD
mapfile -t CLAIMS < <(cw_consult_parse_claims "$DIR/findings.md")
[[ "${#CLAIMS[@]}" -eq 0 ]] || { echo "FAIL: malformed expected 0" >&2; exit 1; }
status=$(cw_consult_findings_status "$DIR/findings.md")
assert_eq "$status" "malformed" "no [cite] under non-empty Claims → malformed"
pass "malformed (zero parseable claims) detected"

# Missing
status=$(cw_consult_findings_status "$DIR/missing.md")
assert_eq "$status" "missing" "absent file → missing"
pass "missing detected"
