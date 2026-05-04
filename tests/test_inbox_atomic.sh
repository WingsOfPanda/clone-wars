#!/usr/bin/env bash
# tests/test_inbox_atomic.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/ipc.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
mkdir -p "$(cw_trooper_dir rex codex demo)"

# 1. cw_inbox_write produces a complete inbox.md ending with END_OF_INSTRUCTION.
cw_inbox_write rex codex demo "test task body"
INBOX=$(cw_inbox_path rex codex demo)
assert_file_exists "$INBOX" "inbox.md created"
tail -n1 "$INBOX" | grep -q '^END_OF_INSTRUCTION$' || {
  echo "FAIL: inbox.md doesn't end with END_OF_INSTRUCTION sentinel" >&2; exit 1; }
pass "inbox.md ends with sentinel"

# 2. After the write, no .tmp* files are left in the trooper dir.
DIR=$(cw_trooper_dir rex codex demo)
shopt -s nullglob
LEAKS=("$DIR"/inbox.md.tmp*)
(( ${#LEAKS[@]} == 0 )) || { echo "FAIL: tmp leaks: ${LEAKS[*]}" >&2; exit 1; }
shopt -u nullglob
pass "no tmp file leaks after single write"

# 3. Static wiring check: cw_inbox_write delegates to cw_atomic_write
#    (lib/state.sh), which itself uses mktemp on a tmp beside the dest AND
#    mv -f into the final path. Without per-call tmp the concurrent test
#    below would fail intermittently — the static check is a quick
#    regression guard against accidental reverts to a deterministic tmp path.
grep -qE 'cw_atomic_write[[:space:]]+"\$inbox"' ../lib/ipc.sh \
  || { echo "FAIL: cw_inbox_write doesn't pipe heredoc through cw_atomic_write \"\$inbox\"" >&2; exit 1; }
grep -qE 'mktemp[[:space:]].*"\$\{?dest\}?\.tmp\.XXXXXX"' ../lib/state.sh \
  || { echo "FAIL: cw_atomic_write doesn't use mktemp \"\${dest}.tmp.XXXXXX\"" >&2; exit 1; }
grep -qE 'mv[[:space:]]-f[[:space:]]"\$tmp"[[:space:]]"\$dest"' ../lib/state.sh \
  || { echo "FAIL: cw_atomic_write doesn't mv -f \"\$tmp\" \"\$dest\"" >&2; exit 1; }
pass "atomic-write wired (mktemp per call + mv -f via cw_atomic_write)"

# 4. Sequential overwrites land cleanly (no race, just regression check).
cw_inbox_write rex codex demo "first task"
cw_inbox_write rex codex demo "second task"
shopt -s nullglob
LEAKS2=("$DIR"/inbox.md.tmp*)
(( ${#LEAKS2[@]} == 0 )) || { echo "FAIL: tmp leaks after sequential writes: ${LEAKS2[*]}" >&2; exit 1; }
shopt -u nullglob
# Body now starts at line 3 (line 1 is `From: <sender>`, line 2 blank); use a
# position-agnostic grep so the assertion tolerates the v0.5.0 inbox header.
grep -q '^second task$' "$INBOX" || {
  echo "FAIL: second write didn't replace inbox content" >&2; exit 1; }
pass "sequential overwrites land cleanly"

# 5. CONCURRENT-WRITER regression test (the failure mode #8 actually closes).
#    Spawn N writers in parallel; each writes a uniquely-tagged task body.
#    Afterwards: inbox.md must be exactly one of the N versions (atomic
#    final state); NO inbox.md.tmp* file may linger; the visible content
#    must end with END_OF_INSTRUCTION on its own line (no truncation).
N=20
PIDS=()
for ((i = 0; i < N; i++)); do
  ( cw_inbox_write rex codex demo "writer-$i: this is a concurrent test message body" ) &
  PIDS+=("$!")
done
for p in "${PIDS[@]}"; do wait "$p"; done
# (a) No tmp leaks after all writers exit.
shopt -s nullglob
LEAKS3=("$DIR"/inbox.md.tmp*)
(( ${#LEAKS3[@]} == 0 )) || { echo "FAIL: concurrent tmp leaks: ${LEAKS3[*]}" >&2; exit 1; }
shopt -u nullglob
pass "no tmp leaks after $N concurrent writers"
# (b) Final inbox.md ends with END_OF_INSTRUCTION (not truncated).
tail -n1 "$INBOX" | grep -q '^END_OF_INSTRUCTION$' || {
  echo "FAIL: concurrent-write final state truncated; tail was:" >&2
  tail -n3 "$INBOX" >&2
  exit 1; }
pass "final inbox.md ends with sentinel after $N concurrent writers"
# (c) Final content is one of the N writers' messages exactly (no interleaving).
# v0.5.0: body now starts at line 3 (line 1 is `From: <sender>`, line 2 blank).
BODY_LINE=$(sed -n '3p' "$INBOX")
[[ "$BODY_LINE" =~ ^writer-[0-9]+: ]] || {
  echo "FAIL: concurrent-write body looks interleaved/corrupted: '$BODY_LINE'" >&2; exit 1; }
pass "final content is one writer's message verbatim (no interleaving)"

echo "  ALL: ok"
