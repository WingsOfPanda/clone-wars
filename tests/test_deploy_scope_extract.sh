#!/usr/bin/env bash
# tests/test_deploy_scope_extract.sh — v0.30.0 item 4
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deploy-scope.sh"

declare -F cw_deploy_extract_components_paths >/dev/null \
  || { echo "FAIL: cw_deploy_extract_components_paths not defined" >&2; exit 1; }
pass "helper defined"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# Case 1: simple single table
cat > "$SANDBOX/spec1.md" <<'EOF'
# Spec
## Components

| File | Edit |
|------|------|
| `lib/foo.sh` | new helper |
| `bin/bar.sh` | new wrapper |
| `commands/baz.md` | Step 0 |

## Testing
None.
EOF
out=$(cw_deploy_extract_components_paths "$SANDBOX/spec1.md")
expected=$'lib/foo.sh\nbin/bar.sh\ncommands/baz.md'
[[ "$out" == "$expected" ]] || { echo "FAIL: simple-table extraction mismatch" >&2; echo "  got:      $out"; echo "  expected: $expected"; exit 1; }
pass "1. simple table extraction (3 paths)"

# Case 2: nested under sub-heading
cat > "$SANDBOX/spec2.md" <<'EOF'
# Spec
## Components

### Files edited

| Path | Why |
|------|-----|
| `lib/a.sh` | x |
| `lib/b.sh` | y |

## Testing
EOF
out=$(cw_deploy_extract_components_paths "$SANDBOX/spec2.md")
expected=$'lib/a.sh\nlib/b.sh'
[[ "$out" == "$expected" ]] || { echo "FAIL: sub-heading-nested table extraction mismatch" >&2; echo "  got:      $out"; exit 1; }
pass "2. table under sub-heading extraction"

# Case 3: multiple tables in Components
cat > "$SANDBOX/spec3.md" <<'EOF'
# Spec
## Components

### Lib changes

| File | Edit |
|------|------|
| `lib/x.sh` | new |

### Bin changes

| File | Edit |
|------|------|
| `bin/y.sh` | new |
| `bin/z.sh` | new |

## Testing
EOF
out=$(cw_deploy_extract_components_paths "$SANDBOX/spec3.md")
expected=$'lib/x.sh\nbin/y.sh\nbin/z.sh'
[[ "$out" == "$expected" ]] || { echo "FAIL: multi-table extraction mismatch" >&2; echo "  got:      $out"; exit 1; }
pass "3. multiple tables in Components concatenated"

# Case 4: no Components section → empty output
cat > "$SANDBOX/spec4.md" <<'EOF'
# Spec
## Goal
Text.
## Testing
None.
EOF
out=$(cw_deploy_extract_components_paths "$SANDBOX/spec4.md")
[[ -z "$out" ]] || { echo "FAIL: no-Components should print nothing, got: $out" >&2; exit 1; }
pass "4. no Components section: empty output"

# Case 5: Components but no table (bullets) → empty (tables-only by design)
cat > "$SANDBOX/spec5.md" <<'EOF'
# Spec
## Components
- foo
- bar
## Testing
EOF
out=$(cw_deploy_extract_components_paths "$SANDBOX/spec5.md")
[[ -z "$out" ]] || { echo "FAIL: bullet-list Components should be ignored, got: $out" >&2; exit 1; }
pass "5. bullet-list Components ignored (table-only by design)"

# Case 6: cells with directories ending in / preserved
cat > "$SANDBOX/spec6.md" <<'EOF'
# Spec
## Components

| Path | Why |
|------|-----|
| `arsreportllm/skills/` | git mv target |
| `tests/lib/assert.sh` | no change |

## Testing
EOF
out=$(cw_deploy_extract_components_paths "$SANDBOX/spec6.md")
expected=$'arsreportllm/skills/\ntests/lib/assert.sh'
[[ "$out" == "$expected" ]] || { echo "FAIL: directory-suffix preservation failed" >&2; echo "  got: $out"; exit 1; }
pass "6. directory paths with trailing / preserved"

# Case 7: missing arg → rc=2
set +e
out=$(cw_deploy_extract_components_paths 2>&1); rc=$?
set -e
[[ "$rc" == "2" ]] || { echo "FAIL: missing arg: expected rc=2, got $rc" >&2; exit 1; }
pass "7. rc=2 on missing arg"

# Case 8: file doesn't exist → rc=1
set +e
out=$(cw_deploy_extract_components_paths "$SANDBOX/nope.md" 2>&1); rc=$?
set -e
[[ "$rc" == "1" ]] || { echo "FAIL: missing file: expected rc=1, got $rc" >&2; exit 1; }
pass "8. rc=1 on missing file"

echo "test_deploy_scope_extract: 8 cases passed"
