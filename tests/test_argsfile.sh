#!/usr/bin/env bash
# tests/test_argsfile.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/argsfile.sh 2>/dev/null || true   # tolerate missing during pre-impl run

# 1. Empty file → no tokens.
TMP=$(mktemp); trap 'rm -f "$TMP" "$TMP".*' EXIT
mapfile -t TOKS < <(cw_args_file_load "$TMP")
assert_eq "${#TOKS[@]}" "0" "empty file → 0 tokens"
pass "empty file"

# 2. Simple whitespace-separated tokens.
echo 'rex codex demo' > "$TMP"
mapfile -t TOKS < <(cw_args_file_load "$TMP")
assert_eq "${#TOKS[@]}" "3" "3 tokens"
assert_eq "${TOKS[0]}" "rex"
assert_eq "${TOKS[1]}" "codex"
assert_eq "${TOKS[2]}" "demo"
pass "simple tokens"

# 3. Quoted multi-word arg stays one token.
echo 'rex codex demo "do the auth review please"' > "$TMP"
mapfile -t TOKS < <(cw_args_file_load "$TMP")
assert_eq "${#TOKS[@]}" "4" "4 tokens including the quoted phrase"
assert_eq "${TOKS[3]}" "do the auth review please" "quoted phrase preserved"
pass "quoted arg"

# 4. Adversarial: shell metacharacters in a quoted token are NOT executed.
echo 'rex codex demo "; rm -rf /"' > "$TMP"
mapfile -t TOKS < <(cw_args_file_load "$TMP")
assert_eq "${#TOKS[@]}" "4" "4 tokens"
assert_eq "${TOKS[3]}" "; rm -rf /" "metacharacters preserved as literal text"
pass "metacharacters quoted-safe"

# 5. Adversarial regression: simulate the exact payload that broke through the
#    naive printf-based fence (Codex review finding #1). The file content is
#    what /clone-wars:spawn would produce after the Write tool step. Verify
#    that loading the file does NOT execute the embedded command — we should
#    get back the literal payload as one token.
PAYLOAD_FILE=$(mktemp)
trap 'rm -f "$TMP" "$PAYLOAD_FILE" /tmp/cw-injection-canary' EXIT
rm -f /tmp/cw-injection-canary
# Note: the file content here is the LITERAL expansion of $ARGUMENTS as it
# would arrive via Claude's Write tool — no shell parsing involved during
# write. We only test the loader's parse semantics.
printf '%s\n' 'rex codex demo "; touch /tmp/cw-injection-canary; #"' > "$PAYLOAD_FILE"
mapfile -t TOKS < <(cw_args_file_load "$PAYLOAD_FILE")
[[ ! -e /tmp/cw-injection-canary ]] || {
  echo "FAIL: injection canary was created — payload executed during parse" >&2
  rm -f /tmp/cw-injection-canary
  exit 1
}
assert_eq "${TOKS[3]}" "; touch /tmp/cw-injection-canary; #" "payload returned as literal token"
pass "injection canary not triggered"

echo "  ALL: ok"
