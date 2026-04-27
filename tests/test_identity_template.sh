#!/usr/bin/env bash
# tests/test_identity_template.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/ipc.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
export PLUGIN_ROOT="$(cd .. && pwd)"

DIR=$(cw_trooper_dir rex codex demo)
mkdir -p "$DIR"

# 1. cw_identity_write produces identity.md with the trooper's name + topic.
cw_identity_write rex codex demo
IDENTITY="$DIR/identity.md"
assert_file_exists "$IDENTITY" "identity.md created"
grep -q 'rex' "$IDENTITY" || { echo "FAIL: identity.md missing commander 'rex'" >&2; exit 1; }
grep -q 'demo' "$IDENTITY" || { echo "FAIL: identity.md missing topic 'demo'" >&2; exit 1; }
pass "identity.md substitutes commander+topic"

# 2. The "First action" block exists with the ready-event echo command.
grep -q 'First action' "$IDENTITY" || { echo "FAIL: First action block missing" >&2; exit 1; }
grep -q '"event":"ready"' "$IDENTITY" || { echo "FAIL: ready event template missing" >&2; exit 1; }
pass "First action block present"

# 3. The commander/model substitutions WORK at write time (those should be
#    baked — they don't change between write and emit). The "commander":"rex"
#    and "model":"codex" fields must be literally present somewhere in
#    identity.md (either in the display JSON line or the shell command line).
grep -q '"commander":"rex"' "$IDENTITY" || { echo "FAIL: commander field not baked" >&2; exit 1; }
grep -q '"model":"codex"' "$IDENTITY" || { echo "FAIL: model field not baked" >&2; exit 1; }
pass "commander+model baked correctly (these don't drift)"

# 4. Defense against pre-baked timestamps inside the SHELL command line:
#    extract the line that begins with `echo "{...` (the verbatim shell
#    command the trooper is told to run) and ensure the ts field is a
#    runtime command substitution, not a literal value.
SHELL_LINE=$(grep -E '^\\?`echo "?\{|^echo "\{' "$IDENTITY" | head -n1)
[[ -z "$SHELL_LINE" ]] && SHELL_LINE=$(grep -F '$(date' "$IDENTITY" | head -n1)
[[ -n "$SHELL_LINE" ]] || {
  echo "FAIL: couldn't locate the shell-command line in identity.md" >&2
  echo "  identity.md tail:" >&2; tail -20 "$IDENTITY" >&2
  exit 1; }
[[ "$SHELL_LINE" == *'$(date'* ]] || {
  echo "FAIL: shell-command line lacks runtime \$(date ...) substitution" >&2
  echo "  line was: $SHELL_LINE" >&2
  exit 1; }
[[ "$SHELL_LINE" =~ \"ts\":\"[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] && {
  echo "FAIL: shell-command line has a literal pre-baked timestamp inside ts" >&2
  echo "  line was: $SHELL_LINE" >&2
  exit 1; } || true
pass "shell command line uses runtime \$(date ...) and has no baked ts"

# 5. EXECUTABLE VERIFICATION (the load-bearing test, per Codex review):
#    extract the verbatim shell command from identity.md, run it against
#    a temp outbox file, and assert exactly one well-formed JSONL line
#    with commander/model baked AND a runtime-fresh ts inside the
#    [before, after] execution window. This proves the heredoc's escape
#    sequences actually produce a parseable, working shell command —
#    not just a substring that LOOKS right but mis-parses when run.
EXEC_OUTBOX="$TMP/exec-outbox.jsonl"
:> "$EXEC_OUTBOX"
# Extract the line that contains both 'echo' and '$(date' and looks like
# the verbatim command (sits inside markdown backticks).
CMD=$(grep -E 'echo .*\$\(date' "$IDENTITY" | head -n1 \
  | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        -e 's/^`//' -e 's/`$//')
[[ -n "$CMD" ]] || {
  echo "FAIL: couldn't extract verbatim shell command" >&2
  exit 1; }
# Replace the rendered $outbox path (which points at $DIR/outbox.jsonl)
# with our test outbox so we don't pollute the sandbox. We rendered with
# rex/codex/demo so the path in $CMD is $DIR/outbox.jsonl.
RENDERED_OUTBOX="$DIR/outbox.jsonl"
CMD_TEST=${CMD//$RENDERED_OUTBOX/$EXEC_OUTBOX}
BEFORE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
sleep 1
bash -c "$CMD_TEST"
sleep 1
AFTER=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Outbox should have exactly one line.
LINE_COUNT=$(wc -l < "$EXEC_OUTBOX")
assert_eq "$LINE_COUNT" "1" "exactly one JSONL line written"
LINE=$(cat "$EXEC_OUTBOX")
# Must be valid-shape JSON with the four expected fields.
[[ "$LINE" =~ ^\{\"event\":\"ready\",\"ts\":\"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\",\"commander\":\"rex\",\"model\":\"codex\"\}$ ]] || {
  echo "FAIL: emitted line doesn't match expected JSON shape" >&2
  echo "  line: $LINE" >&2
  exit 1; }
# Extract the ts and check it's strictly within [BEFORE, AFTER].
EMITTED_TS=$(printf '%s\n' "$LINE" | grep -oE '"ts":"[0-9TZ:-]+"' | head -n1 | sed -e 's/"ts":"//' -e 's/"$//')
[[ "$EMITTED_TS" > "$BEFORE" || "$EMITTED_TS" == "$BEFORE" ]] || {
  echo "FAIL: emitted ts $EMITTED_TS is older than BEFORE $BEFORE" >&2; exit 1; }
[[ "$EMITTED_TS" < "$AFTER" || "$EMITTED_TS" == "$AFTER" ]] || {
  echo "FAIL: emitted ts $EMITTED_TS is newer than AFTER $AFTER" >&2; exit 1; }
pass "executable rendering produces well-formed JSON with runtime ts"

echo "  ALL: ok"
