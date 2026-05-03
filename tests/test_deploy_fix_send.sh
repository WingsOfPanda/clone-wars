#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

grep -q 'cw_deploy_build_fix_prompt' ../bin/deploy-fix-send.sh \
  || { echo "FAIL: missing fix-prompt builder" >&2; exit 1; }
grep -q 'fix-prompt-' ../bin/deploy-fix-send.sh \
  || { echo "FAIL: missing fix-prompt filename" >&2; exit 1; }
pass "fix-send static wiring"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=fix-send-fixture
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_deploy" "$TD/cody-codex"
touch "$TD/cody-codex/outbox.jsonl"
printf '{"pane_id":"%%66","spawned_at":"x"}\n' > "$TD/cody-codex/pane.json"

# Refuses if fix-prompt-N.md missing.
err=$(../bin/deploy-fix-send.sh "$TOPIC" 1 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$err" | grep -q 'fix-prompt' \
  || { echo "FAIL: missing fix-prompt should refuse: rc=$rc out=$err" >&2; exit 1; }
pass "fix-send refuses without fix-prompt-N.md"

# With variant: looks for fix-prompt-N-<variant>.md
echo "preamble" > "$TD/_deploy/fix-prompt-1-debug.md"
out=$(../bin/deploy-fix-send.sh "$TOPIC" 1 debug 2>&1) || rc=$?
# (send.sh will fail because pane is fake; we only care that the script
# accepted the variant + located the file before send.sh's failure.)
echo "$out" | grep -q 'fix-prompt-1-debug.md' \
  || { echo "FAIL: variant not used in prompt body: $out" >&2; exit 1; }
pass "fix-send accepts -<variant> suffix"
