#!/usr/bin/env bash
# tests/test_consult_verify_send.sh
#
# v0.15.0: verify scope = union of bucket files NOT containing this trooper.
# For N=2 (rex+cody), this reduces to a single file: the OTHER commander's
# _only_items.txt — byte-equal to v0.14.0 behavior. This test covers N=2.
# (N=3 coverage lives in tests/test_consult_3trooper_verify_send.sh.)
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')

# Helper: stage a minimal _consult/ for a 2-trooper consult.
stage_n2() {
  local td="$1"
  mkdir -p "$td/_consult" "$td/rex-codex" "$td/cody-claude"
  touch "$td/rex-codex/outbox.jsonl"
  printf 'codex\trex\nclaude\tcody\n' > "$td/_consult/troopers.txt"
}

# 1. Empty peer file → VS=skipped, no OFFSET, no send.
TOPIC=consult-fixture-vs1
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
stage_n2 "$TD"
touch "$TD/_consult/cody_only_items.txt"  # EMPTY (cody-only — what rex verifies)
touch "$TD/_consult/rex_only_items.txt"   # required to exist so the script doesn't error

../bin/consult-verify-send.sh "$TOPIC" rex codex
[[ -f "$TD/_consult/verify-rex.txt" ]] || { echo "FAIL: verify-rex.txt missing" >&2; exit 1; }
grep -q '^VS=skipped' "$TD/_consult/verify-rex.txt" || { echo "FAIL: VS not skipped" >&2; cat "$TD/_consult/verify-rex.txt" >&2; exit 1; }
grep -q '^OFFSET='   "$TD/_consult/verify-rex.txt" && { echo "FAIL: OFFSET should not be present in skipped state" >&2; exit 1; }
pass "empty peer file → VS=skipped"

# 2. Idempotency: second call refuses.
err=$(../bin/consult-verify-send.sh "$TOPIC" rex codex 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: second call should refuse" >&2; exit 1; }
pass "verify-send fails loud on existing state"

# 3. Bad commander rejected.
TOPIC2=consult-fixture-vs2
TD2="$CLONE_WARS_HOME/state/$RH/$TOPIC2"
stage_n2 "$TD2"
touch "$TD2/_consult/cody_only_items.txt"
touch "$TD2/_consult/rex_only_items.txt"
err=$(../bin/consult-verify-send.sh "$TOPIC2" "bad/cmd" codex 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: bad commander accepted" >&2; exit 1; }
pass "bad commander rejected"

# 4. Static wiring: script names verify-claims output (file the prompt builder reads)
#    and reads bucket files via ${commander}_only_items.txt naming.
grep -q 'verify-claims-' ../bin/consult-verify-send.sh \
  || { echo "FAIL: script should write verify-claims-<COMMANDER>.txt" >&2; exit 1; }
grep -q '_only_items.txt' ../bin/consult-verify-send.sh \
  || { echo "FAIL: script should reference _only_items.txt buckets" >&2; exit 1; }
pass "verify-send wires verify-claims-<commander>.txt and _only_items.txt buckets"

# 5. N=2 happy path: verify-claims content is byte-equal to the peer's _only_items file.
TOPIC3=consult-fixture-vs3
TD3="$CLONE_WARS_HOME/state/$RH/$TOPIC3"
stage_n2 "$TD3"
# Stage outbox so OFFSET=0 succeeds; do NOT actually exercise send.sh — the
# script's send.sh call will fail (no tmux pane), but verify-claims gets
# written before that, which is what we assert here.
cat > "$TD3/_consult/cody_only_items.txt" <<'TXT'
[src/a.py:1] cody-only claim A
[src/b.py:2] cody-only claim B
TXT
cat > "$TD3/_consult/rex_only_items.txt" <<'TXT'
[src/x.py:9] rex-only claim X
TXT

# Run script; expect non-zero exit because send.sh has no pane to drive,
# but assert verify-claims-rex.txt was written with cody's items only.
../bin/consult-verify-send.sh "$TOPIC3" rex codex >/dev/null 2>&1 || true
VC="$TD3/_consult/verify-claims-rex.txt"
[[ -f "$VC" ]] || { echo "FAIL: $VC missing" >&2; exit 1; }
expected=$(cat "$TD3/_consult/cody_only_items.txt")
got=$(cat "$VC")
[[ "$got" == "$expected" ]] || {
  echo "FAIL: verify-claims-rex.txt content mismatch" >&2
  diff <(printf '%s\n' "$expected") <(printf '%s\n' "$got") >&2 || true
  exit 1
}
pass "N=2: verify-claims-rex.txt = cody_only_items.txt (byte-equal v0.14.0 scope)"
