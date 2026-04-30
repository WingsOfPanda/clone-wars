#!/usr/bin/env bash
# tests/test_consult_load_prompt.sh — v0.5.0 prompt-template loader unit tests.
#
# Contract: cw_consult_load_prompt <relpath> [VAR=value ...]
#   - Reads $CLAUDE_PLUGIN_ROOT/config/prompt-templates/<relpath>
#   - Substitutes {{VAR}} tokens via single-pass sed
#   - rc=1 if template missing, rc=2 if any {{VAR}} survives substitution
#   - Refuses if CLAUDE_PLUGIN_ROOT unset (rc=2)
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

# Sandbox: stub plugin root with a fake template tree so the loader has
# something real to read without depending on the live config/.
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/config/prompt-templates/consult"
export CLAUDE_PLUGIN_ROOT="$SANDBOX"
PLUGIN_ROOT="$SANDBOX"
source ../lib/log.sh
source ../lib/consult.sh

# Case 1: simple substitution.
cat > "$SANDBOX/config/prompt-templates/consult/hello.md" <<'EOF'
hello {{NAME}}!
EOF
out=$(cw_consult_load_prompt consult/hello.md NAME=world)
[[ "$out" == "hello world!" ]] || { echo "FAIL c1 got '$out'"; exit 1; }
pass "simple {{NAME}} substitution"

# Case 2: multiple variables, single pass.
cat > "$SANDBOX/config/prompt-templates/consult/multi.md" <<'EOF'
{{A}}-{{B}}-{{A}}
EOF
out=$(cw_consult_load_prompt consult/multi.md A=foo B=bar)
[[ "$out" == "foo-bar-foo" ]] || { echo "FAIL c2 got '$out'"; exit 1; }
pass "multi-variable substitution"

# Case 3: missing template → rc=1.
if cw_consult_load_prompt consult/nope.md X=y 2>/dev/null; then
  echo "FAIL c3: expected rc=1 on missing template"; exit 1
fi
pass "missing template → rc=1"

# Case 4: surviving {{VAR}} → rc=2.
cat > "$SANDBOX/config/prompt-templates/consult/incomplete.md" <<'EOF'
hello {{NAME}}, today is {{DATE}}
EOF
if cw_consult_load_prompt consult/incomplete.md NAME=world 2>/dev/null; then
  echo "FAIL c4: expected rc=2 on surviving {{DATE}}"; exit 1
fi
pass "surviving {{VAR}} → rc=2"

# Case 5: special chars in value (sed delimiter pipe + ampersand).
cat > "$SANDBOX/config/prompt-templates/consult/special.md" <<'EOF'
path={{PATH}}
EOF
out=$(cw_consult_load_prompt consult/special.md "PATH=/a|b/c&d")
[[ "$out" == "path=/a|b/c&d" ]] || { echo "FAIL c5 got '$out'"; exit 1; }
pass "special chars (| &) in value"

# Case 6: newline in value.
cat > "$SANDBOX/config/prompt-templates/consult/nl.md" <<'EOF'
body={{BODY}}
EOF
out=$(cw_consult_load_prompt consult/nl.md "BODY=line1
line2")
expected="body=line1
line2"
[[ "$out" == "$expected" ]] || { echo "FAIL c6 got '$out'"; exit 1; }
pass "newline preserved in value"

# Case 7: missing CLAUDE_PLUGIN_ROOT → rc=2.
unset CLAUDE_PLUGIN_ROOT
unset PLUGIN_ROOT
if cw_consult_load_prompt consult/hello.md NAME=x 2>/dev/null; then
  echo "FAIL c7: expected rc=2 with no CLAUDE_PLUGIN_ROOT"; exit 1
fi
pass "missing CLAUDE_PLUGIN_ROOT → rc=2"

echo "ALL PASS"
