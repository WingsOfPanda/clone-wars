#!/usr/bin/env bash
# tests/test_consult_3trooper_verify_send.sh
#
# v0.15.0: with N=3 troopers (rex/cody/bly), each trooper's verify inbox =
# union of bucket files in _consult/ where this trooper is NOT a member.
#
# For trooper rex:
#   INCLUDE: cody_only_items.txt, bly_only_items.txt, cody+bly_only.txt
#   SKIP:    consensus.txt, rex_only_items.txt, rex+cody_only.txt, rex+bly_only.txt
#
# For trooper cody:
#   INCLUDE: rex_only_items.txt, bly_only_items.txt, rex+bly_only.txt
#
# For trooper bly:
#   INCLUDE: rex_only_items.txt, cody_only_items.txt, rex+cody_only.txt
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')

# Stage a 3-trooper consult artifact dir with all 7 bucket files populated.
stage_n3() {
  local topic="$1"
  local td="$CLONE_WARS_HOME/state/$RH/$topic"
  mkdir -p "$td/_consult" "$td/rex-codex" "$td/cody-claude" "$td/bly-opencode"
  touch "$td/rex-codex/outbox.jsonl"
  touch "$td/cody-claude/outbox.jsonl"
  touch "$td/bly-opencode/outbox.jsonl"
  printf 'codex\trex\nclaude\tcody\nopencode\tbly\n' > "$td/_consult/troopers.txt"

  cat > "$td/_consult/consensus.txt" <<'TXT'
[src/c.py:3] all-3 claim C
TXT
  cat > "$td/_consult/rex+cody_only.txt" <<'TXT'
[src/b.py:2] rex+cody claim B
TXT
  cat > "$td/_consult/rex+bly_only.txt" <<'TXT'
[src/k.py:7] rex+bly claim K
TXT
  cat > "$td/_consult/cody+bly_only.txt" <<'TXT'
[src/e.py:5] cody+bly claim E
TXT
  cat > "$td/_consult/rex_only_items.txt" <<'TXT'
[src/a.py:1] rex_only claim A
[src/d.py:4] rex_only claim D
TXT
  cat > "$td/_consult/cody_only_items.txt" <<'TXT'
[src/m.py:8] cody_only claim M
TXT
  cat > "$td/_consult/bly_only_items.txt" <<'TXT'
[src/f.py:6] bly_only claim F
TXT
  echo "$td"
}

# Helper: run verify-send for a commander on a topic; returns the path to the
# generated verify-claims file. send.sh will fail (no tmux pane) but the
# verify-claims file is written before that point.
run_verify_send() {
  local topic="$1" commander="$2" model="$3"
  ../bin/consult-verify-send.sh "$topic" "$commander" "$model" >/dev/null 2>&1 || true
  echo "$CLONE_WARS_HOME/state/$RH/$topic/_consult/verify-claims-${commander}.txt"
}

# === Test 1: rex's verify-claims = cody_only + bly_only + cody+bly_only ===
TOPIC=consult-fixture-3vs-rex
TD=$(stage_n3 "$TOPIC")

VC=$(run_verify_send "$TOPIC" rex codex)
[[ -f "$VC" ]] || { echo "FAIL: $VC missing" >&2; exit 1; }

expected=$(cat \
  "$TD/_consult/cody_only_items.txt" \
  "$TD/_consult/bly_only_items.txt" \
  "$TD/_consult/cody+bly_only.txt")
got=$(cat "$VC")
[[ "$got" == "$expected" ]] || {
  echo "FAIL: rex verify-claims content mismatch" >&2
  diff <(printf '%s\n' "$expected") <(printf '%s\n' "$got") >&2 || true
  exit 1
}
# Negative checks: rex's verify must NOT include consensus or any bucket containing rex.
grep -q 'all-3 claim C' "$VC" && { echo "FAIL: rex VC contains consensus" >&2; exit 1; }
grep -q 'rex+cody claim B' "$VC" && { echo "FAIL: rex VC contains rex+cody bucket" >&2; exit 1; }
grep -q 'rex+bly claim K' "$VC" && { echo "FAIL: rex VC contains rex+bly bucket" >&2; exit 1; }
grep -q 'rex_only claim' "$VC" && { echo "FAIL: rex VC contains rex_only bucket" >&2; exit 1; }
pass "N=3: rex verify-claims = cody_only + bly_only + cody+bly_only"

# === Test 2: cody's verify-claims = rex_only + bly_only + rex+bly_only ===
TOPIC=consult-fixture-3vs-cody
TD=$(stage_n3 "$TOPIC")

VC=$(run_verify_send "$TOPIC" cody claude)
[[ -f "$VC" ]] || { echo "FAIL: $VC missing" >&2; exit 1; }

expected=$(cat \
  "$TD/_consult/rex_only_items.txt" \
  "$TD/_consult/bly_only_items.txt" \
  "$TD/_consult/rex+bly_only.txt")
got=$(cat "$VC")
[[ "$got" == "$expected" ]] || {
  echo "FAIL: cody verify-claims content mismatch" >&2
  diff <(printf '%s\n' "$expected") <(printf '%s\n' "$got") >&2 || true
  exit 1
}
grep -q 'all-3 claim C' "$VC" && { echo "FAIL: cody VC contains consensus" >&2; exit 1; }
grep -q 'rex+cody claim B' "$VC" && { echo "FAIL: cody VC contains rex+cody bucket" >&2; exit 1; }
grep -q 'cody+bly claim E' "$VC" && { echo "FAIL: cody VC contains cody+bly bucket" >&2; exit 1; }
grep -q 'cody_only claim' "$VC" && { echo "FAIL: cody VC contains cody_only bucket" >&2; exit 1; }
pass "N=3: cody verify-claims = rex_only + bly_only + rex+bly_only"

# === Test 3: bly's verify-claims = rex_only + cody_only + rex+cody_only ===
TOPIC=consult-fixture-3vs-bly
TD=$(stage_n3 "$TOPIC")

VC=$(run_verify_send "$TOPIC" bly opencode)
[[ -f "$VC" ]] || { echo "FAIL: $VC missing" >&2; exit 1; }

expected=$(cat \
  "$TD/_consult/rex_only_items.txt" \
  "$TD/_consult/cody_only_items.txt" \
  "$TD/_consult/rex+cody_only.txt")
got=$(cat "$VC")
[[ "$got" == "$expected" ]] || {
  echo "FAIL: bly verify-claims content mismatch" >&2
  diff <(printf '%s\n' "$expected") <(printf '%s\n' "$got") >&2 || true
  exit 1
}
grep -q 'all-3 claim C' "$VC" && { echo "FAIL: bly VC contains consensus" >&2; exit 1; }
grep -q 'rex+bly claim K' "$VC" && { echo "FAIL: bly VC contains rex+bly bucket" >&2; exit 1; }
grep -q 'cody+bly claim E' "$VC" && { echo "FAIL: bly VC contains cody+bly bucket" >&2; exit 1; }
grep -q 'bly_only claim' "$VC" && { echo "FAIL: bly VC contains bly_only bucket" >&2; exit 1; }
pass "N=3: bly verify-claims = rex_only + cody_only + rex+cody_only"

# === Test 4: all-empty buckets → VS=skipped ===
TOPIC=consult-fixture-3vs-empty
TD=$(stage_n3 "$TOPIC")
# Wipe everything rex would verify (cody_only, bly_only, cody+bly).
: > "$TD/_consult/cody_only_items.txt"
: > "$TD/_consult/bly_only_items.txt"
: > "$TD/_consult/cody+bly_only.txt"

../bin/consult-verify-send.sh "$TOPIC" rex codex >/dev/null
SF="$TD/_consult/verify-rex.txt"
[[ -f "$SF" ]] || { echo "FAIL: verify-rex.txt missing" >&2; exit 1; }
grep -q '^VS=skipped' "$SF" || { echo "FAIL: VS not skipped" >&2; cat "$SF" >&2; exit 1; }
pass "N=3: all-empty include set → VS=skipped"

# === Test 5: trooper not in troopers.txt → fails loud ===
TOPIC=consult-fixture-3vs-bad
TD=$(stage_n3 "$TOPIC")
err=$(../bin/consult-verify-send.sh "$TOPIC" gree codex 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: unknown commander accepted" >&2; exit 1; }
# Note: 'gree' may fail on cw_consult_assert_commander first (commander pool),
# so we only assert the call returns non-zero. The "not in troopers.txt" path
# is exercised when the commander IS a known commander but not in this consult.
pass "N=3: unknown commander rejected"

# === Test 6: missing pair bucket file → fails loud ===
TOPIC=consult-fixture-3vs-broken
TD=$(stage_n3 "$TOPIC")
rm "$TD/_consult/cody+bly_only.txt"
err=$(../bin/consult-verify-send.sh "$TOPIC" rex codex 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: missing pair bucket should error" >&2; exit 1; }
echo "$err" | grep -q 'pair bucket missing' || {
  echo "FAIL: error message should mention pair bucket missing" >&2
  echo "  got: $err" >&2
  exit 1
}
pass "N=3: missing pair bucket file fails loud"
