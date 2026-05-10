#!/usr/bin/env bash
# tests/test_deploy_dag_capwords_path.sh
# Locks v0.21.0 cw_deploy_dag_parse_line regex extension:
# - CapWords/underscore slugs accepted (was: lowercase only [a-z0-9-]+)
# - Optional `(<absolute-path>)` group between slug and em-dash
# - 5-field TSV emitted: <step>\t<repo>\t<path|none>\t<desc>\t<deps|none>
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deploy-dag.sh"

# 1. Backward-compat: flat lowercase slug, no path, no deps.
out=$(cw_deploy_dag_parse_line "1. taskserve — Edit deploy.py")
assert_eq "$out" $'1\ttaskserve\tnone\tEdit deploy.py\tnone' "flat slug, no path, no deps"

# 2. CapWords slug accepted (was rejected in v0.20.5).
out=$(cw_deploy_dag_parse_line "1. ARS-TaskServe — Edit deploy.py")
assert_eq "$out" $'1\tARS-TaskServe\tnone\tEdit deploy.py\tnone' "CapWords slug accepted"

# 3. Underscore in slug accepted.
out=$(cw_deploy_dag_parse_line "2. ars_fleet — multi-token slug")
assert_eq "$out" $'2\tars_fleet\tnone\tmulti-token slug\tnone' "underscore slug accepted"

# 4. Optional absolute path captured.
out=$(cw_deploy_dag_parse_line "1. ARS-TaskServe (/home/liupan/ARS/ars_fleet/ARS-TaskServe) — Edit deploy.py")
assert_eq "$out" $'1\tARS-TaskServe\t/home/liupan/ARS/ars_fleet/ARS-TaskServe\tEdit deploy.py\tnone' "absolute path captured"

# 5. Path + single dep.
out=$(cw_deploy_dag_parse_line "2. foo (/p) — desc (depends on 1)")
assert_eq "$out" $'2\tfoo\t/p\tdesc\t1' "path + single dep"

# 6. Path + multi-deps.
out=$(cw_deploy_dag_parse_line "3. bar (/q/r) — desc (depends on 1, 2)")
assert_eq "$out" $'3\tbar\t/q/r\tdesc\t1,2' "path + multi-dep"

# 7. Malformed slug (special char) rejected.
if cw_deploy_dag_parse_line "1. bad slug! — desc" 2>/dev/null; then
  echo "FAIL: malformed slug should be rejected" >&2
  exit 1
fi
pass "malformed slug rejected"

# 8. Relative path in parens not honored as path (only absolute /paths).
# The regex requires `/<abspath>` so non-absolute parens fall through and
# the line as a whole fails to parse (parens become unparseable structure).
if cw_deploy_dag_parse_line "1. foo (relative/path) — desc" 2>/dev/null; then
  echo "FAIL: relative path in parens should be rejected (only absolute /paths honored)" >&2
  exit 1
fi
pass "relative path in parens rejected"

pass "v0.21.0 cw_deploy_dag_parse_line: regex extension + 5-field TSV (8 cases)"
