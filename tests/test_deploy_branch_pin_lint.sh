#!/usr/bin/env bash
# tests/test_deploy_branch_pin_lint.sh — v0.42.0 PERMANENT LINT
# Asserts the BRANCH DISCIPLINE stanza appears in all three deploy
# prompt builders so the stanza can't silently drift away.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib/assert.sh

LIB="lib/deploy.sh"
[[ -f "$LIB" ]] || { echo "FAIL: $LIB missing" >&2; exit 1; }

# Extract each builder body (function start → next function start or EOF).
for fn in cw_deploy_build_turn_prompt_round1 cw_deploy_build_turn_prompt_fix cw_deploy_build_dag_unit_prompt; do
  body=$(awk -v fn="$fn" '
    $0 ~ "^"fn"\\(\\) \\{" { p=1 }
    p && /^# cw_deploy_/ && !/^# cw_deploy_build/ { exit }
    p && /^cw_deploy_/ && $0 !~ "^"fn"\\(\\) \\{" { exit }
    p
  ' "$LIB")
  echo "$body" | grep -qE 'BRANCH DISCIPLINE' \
    || { echo "FAIL: $fn missing BRANCH DISCIPLINE stanza" >&2; exit 1; }
  echo "$body" | grep -qE 'Do NOT run .git checkout' \
    || { echo "FAIL: $fn missing 'Do NOT run \`git checkout\`' clause" >&2; exit 1; }
  pass "$fn carries BRANCH DISCIPLINE stanza"
done

echo "test_deploy_branch_pin_lint: 3 builders carry the stanza"
