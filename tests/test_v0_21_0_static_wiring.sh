#!/usr/bin/env bash
# tests/test_v0_21_0_static_wiring.sh
# Locks v0.21.0 invariants:
#   1. cw_deploy_dag_parse_line regex accepts CapWords/underscore slugs
#   2. cw_deploy_dag_parse_line regex has optional /abspath capture group
#   3. bin/deploy-multi-init.sh reads 5-field dag-waves.txt
#   4. commands/deploy.md Step 0 contains DAG rescue intercept block
#   5. Rescue block uses AskUserQuestion
#   6. plugin.json semver-shape (loosened per v0.20.2 lesson)
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"

# 1. lib/deploy-dag.sh regex contains CapWords class (not the v0.20 [a-z0-9-]+).
DAG="$PLUGIN_ROOT/lib/deploy-dag.sh"
grep -qE '\[A-Za-z0-9_-\]\+' "$DAG" \
  || { echo "FAIL: cw_deploy_dag_parse_line regex missing [A-Za-z0-9_-]+ class" >&2; exit 1; }
# Negative-assert: the v0.20 lowercase-only class is gone from the parse_line body.
awk '/^cw_deploy_dag_parse_line\(\)/,/^}/' "$DAG" | grep -qE '\[a-z0-9-\]\+' \
  && { echo "FAIL: cw_deploy_dag_parse_line still uses lowercase-only [a-z0-9-]+ class" >&2; exit 1; }
pass "cw_deploy_dag_parse_line regex accepts CapWords/underscore"

# 2. Regex contains optional path-in-parens group: \((/[^\)]+)\)
grep -qE '\\\(\(/\[\^\\\)\]\+\)\\\)' "$DAG" \
  || { echo "FAIL: cw_deploy_dag_parse_line regex missing optional (/abspath) group" >&2; exit 1; }
pass "cw_deploy_dag_parse_line regex has optional path group"

# 3. bin/deploy-multi-init.sh reads 5-field TSV with `path` field between repo and desc.
MULTI_INIT="$PLUGIN_ROOT/bin/deploy-multi-init.sh"
grep -qE 'while IFS=\$'"'"'\\t'"'"' read -r wave step repo path desc' "$MULTI_INIT" \
  || { echo "FAIL: deploy-multi-init.sh does not read 5-field dag-waves.txt (wave step repo path desc)" >&2; exit 1; }
pass "deploy-multi-init.sh reads 5-field dag-waves.txt"

# 4. commands/deploy.md Step 0 contains DAG rescue intercept block (unique phrase).
DEPLOY_MD="$PLUGIN_ROOT/commands/deploy.md"
grep -qE 'DAG rescue intercept' "$DEPLOY_MD" \
  || { echo "FAIL: commands/deploy.md missing 'DAG rescue intercept' block" >&2; exit 1; }
pass "commands/deploy.md Step 0 has DAG rescue intercept"

# 5. Rescue block uses AskUserQuestion. Scan only the rescue intercept body
# (between '5b. **DAG rescue intercept' and '5c.') to avoid false-positive on
# the audit-FAIL AskUserQuestion in sub-step 7 (which is unrelated to v0.21).
# Capture into variable to avoid SIGPIPE under `set -euo pipefail`.
RESCUE_BODY=$(awk '/5b\. \*\*DAG rescue intercept/,/^5c\./' "$DEPLOY_MD")
[[ "$RESCUE_BODY" == *"AskUserQuestion"* ]] \
  || { echo "FAIL: rescue intercept block (5b) missing AskUserQuestion" >&2; exit 1; }
pass "rescue intercept block uses AskUserQuestion"

# 6. plugin.json version semver-shape (loosened per v0.20.2 lesson;
# survives subsequent bumps).
PJ="$PLUGIN_ROOT/.claude-plugin/plugin.json"
grep -qE '"version": "0\.[0-9]+\.[0-9]+"' "$PJ" \
  || { echo "FAIL: plugin.json missing semver-shape version field" >&2; exit 1; }
pass "plugin.json version field present + semver-shaped"

pass "v0.21.0 static wiring complete (6 invariants locked)"
