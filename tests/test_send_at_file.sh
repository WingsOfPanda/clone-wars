#!/usr/bin/env bash
# tests/test_send_at_file.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

grep -q 'MSG_OR_FILE.*@\*'             ../bin/send.sh \
  || { echo "FAIL: @-prefix detection lost" >&2; exit 1; }
grep -q 'TASK="\$(cat "\$task_file")"' ../bin/send.sh \
  || { echo "FAIL: @file body load lost" >&2; exit 1; }
pass "send.sh keeps @file branch wired"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ARGS="$TMP/args.txt"
# argsfile.sh reads a single line and tokenizes via xargs, so quoted @paths
# survive as one token. (3-line heredocs would only see the first line.)
printf '%s\n' 'rex demo "@/tmp/some prompt with spaces.md"' > "$ARGS"
mapfile -t TOK < <(bash -c '
  source ../lib/argsfile.sh
  cw_args_file_load "$1"
' _ "$ARGS")
[[ "${#TOK[@]}" -eq 3 ]] || { echo "FAIL: 3 tokens (got ${#TOK[@]})" >&2; exit 1; }
assert_eq "${TOK[2]}" "@/tmp/some prompt with spaces.md" "@-path token preserved"
pass "args-file preserves @path-with-spaces as a single token"
