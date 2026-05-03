#!/usr/bin/env bash
# tests/test_deploy_wait_scripts.sh
# Parameterized integration test for the three deploy wait scripts:
#   bin/deploy-plan-wait.sh
#   bin/deploy-implement-wait.sh
#   bin/deploy-verify-wait.sh
#
# Each wait script reads OFFSET= from a per-phase state file, blocks via
# cw_outbox_wait_since, then writes a status field (PS=/IS=/VS=) based on the
# matched event. This test stages a fixture outbox.jsonl with a synthetic done
# event PAST the recorded OFFSET, runs the wait script with a tight timeout,
# and asserts the status line is appended correctly + the .done sentinel fires.

set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

REPO_ROOT="$(cd .. && pwd)"
BIN="$REPO_ROOT/bin"

RH=$(bash -c "source $REPO_ROOT/lib/state.sh; cw_repo_hash")
TOPIC=wait-fixture
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_deploy" "$TD/cody-codex"

# ---- run_wait_case <name> <wait-script> <state-file> <status-prefix>
#                   <pre-outbox-bytes> [<artifact-path>]
# Stages: an outbox with PRE bytes, records OFFSET=PRE in the state file, then
# appends a {"event":"done"} line to the outbox AFTER OFFSET. Optionally
# pre-creates an artifact (verify-report-N.md / plan.md) so the wait script's
# artifact-existence check passes.
run_wait_case() {
  local name="$1" script="$2" state_file="$3" prefix="$4" pre_bytes="$5" \
        artifact="${6:-}"

  : > "$TD/cody-codex/outbox.jsonl"
  # Pad outbox to PRE bytes so OFFSET=PRE points past anything pre-existing.
  if (( pre_bytes > 0 )); then
    head -c "$pre_bytes" /dev/zero > "$TD/cody-codex/outbox.jsonl"
  fi
  printf '{"event":"done"}\n' >> "$TD/cody-codex/outbox.jsonl"

  echo "OFFSET=$pre_bytes" > "$state_file"
  [[ -n "$artifact" ]] && echo "artifact" > "$artifact"

  # Tight timeout — done event is already present, wait should return immediately.
  bash "$script" "$@" >/dev/null 2>&1 \
    || { echo "FAIL [$name]: wait script returned non-zero" >&2; exit 1; }

  grep -q "^${prefix}=ok$" "$state_file" \
    || { echo "FAIL [$name]: missing ${prefix}=ok line in $state_file" >&2; cat "$state_file" >&2; exit 1; }

  [[ -f "${state_file%.txt}.done" ]] \
    || { echo "FAIL [$name]: sentinel ${state_file%.txt}.done not touched" >&2; exit 1; }

  pass "$name → ${prefix}=ok + sentinel"
}

# Reset between cases (state files + outbox + artifacts).
reset_state() {
  rm -f "$TD/_deploy"/*.txt "$TD/_deploy"/*.done "$TD/_deploy"/*.md "$TD/_deploy"/*.log
  rm -f "$TD/cody-codex/outbox.jsonl"
  touch "$TD/cody-codex/outbox.jsonl"
}

# 1. plan-wait — needs plan.md non-empty for PS=ok.
reset_state
PLAN_SCRIPT_ARGS=("$TOPIC")
CW_DEPLOY_PLAN_TIMEOUT=5 bash "$BIN/deploy-plan-wait.sh" "${PLAN_SCRIPT_ARGS[@]}" >/dev/null 2>&1 \
  && { echo "FAIL: plan-wait should refuse without state file" >&2; exit 1; } || true
pass "plan-wait refuses missing state file"

# Stage and run plan-wait happy path.
PRE=10
head -c "$PRE" /dev/zero > "$TD/cody-codex/outbox.jsonl"
printf '{"event":"done"}\n' >> "$TD/cody-codex/outbox.jsonl"
echo "OFFSET=$PRE" > "$TD/_deploy/plan-cody.txt"
echo "plan body" > "$TD/_deploy/plan.md"
CW_DEPLOY_PLAN_TIMEOUT=5 bash "$BIN/deploy-plan-wait.sh" "$TOPIC" >/dev/null 2>&1
grep -q '^PS=ok$' "$TD/_deploy/plan-cody.txt" \
  || { echo "FAIL: plan-wait missing PS=ok"; exit 1; }
[[ -f "$TD/_deploy/plan-cody.done" ]] \
  || { echo "FAIL: plan-wait sentinel missing"; exit 1; }
pass "plan-wait → PS=ok + sentinel"

# 2. plan-wait — done event but plan.md missing → PS=failed.
reset_state
PRE=5
head -c "$PRE" /dev/zero > "$TD/cody-codex/outbox.jsonl"
printf '{"event":"done"}\n' >> "$TD/cody-codex/outbox.jsonl"
echo "OFFSET=$PRE" > "$TD/_deploy/plan-cody.txt"
# NO plan.md
CW_DEPLOY_PLAN_TIMEOUT=5 bash "$BIN/deploy-plan-wait.sh" "$TOPIC" >/dev/null 2>&1
grep -q '^PS=failed$' "$TD/_deploy/plan-cody.txt" \
  || { echo "FAIL: plan-wait should report PS=failed when plan.md missing"; exit 1; }
pass "plan-wait → PS=failed when plan.md missing (artifact gate)"

# 3. implement-wait — done event → IS=ok (no artifact gate).
reset_state
PRE=20
head -c "$PRE" /dev/zero > "$TD/cody-codex/outbox.jsonl"
printf '{"event":"done"}\n' >> "$TD/cody-codex/outbox.jsonl"
echo "OFFSET=$PRE" > "$TD/_deploy/implement-cody.txt"
CW_DEPLOY_IMPLEMENT_TIMEOUT=5 bash "$BIN/deploy-implement-wait.sh" "$TOPIC" >/dev/null 2>&1
grep -q '^IS=ok$' "$TD/_deploy/implement-cody.txt" \
  || { echo "FAIL: implement-wait missing IS=ok"; exit 1; }
[[ -f "$TD/_deploy/implement-cody.done" ]] \
  || { echo "FAIL: implement-wait sentinel missing"; exit 1; }
pass "implement-wait → IS=ok + sentinel"

# 4. verify-wait round 1 — done event + verify-report-1.md → VS=ok.
reset_state
PRE=15
head -c "$PRE" /dev/zero > "$TD/cody-codex/outbox.jsonl"
printf '{"event":"done"}\n' >> "$TD/cody-codex/outbox.jsonl"
echo "OFFSET=$PRE" > "$TD/_deploy/verify-cody-1.txt"
echo "VERDICT=PASS" > "$TD/_deploy/verify-report-1.md"
CW_DEPLOY_VERIFY_TIMEOUT=5 bash "$BIN/deploy-verify-wait.sh" "$TOPIC" 1 >/dev/null 2>&1
grep -q '^VS=ok$' "$TD/_deploy/verify-cody-1.txt" \
  || { echo "FAIL: verify-wait missing VS=ok"; exit 1; }
[[ -f "$TD/_deploy/verify-cody-1.done" ]] \
  || { echo "FAIL: verify-wait round-1 sentinel missing"; exit 1; }
pass "verify-wait round=1 → VS=ok + sentinel"

# 5. verify-wait round 2 — separate state from round 1.
reset_state
PRE=8
head -c "$PRE" /dev/zero > "$TD/cody-codex/outbox.jsonl"
printf '{"event":"done"}\n' >> "$TD/cody-codex/outbox.jsonl"
echo "OFFSET=$PRE" > "$TD/_deploy/verify-cody-2.txt"
echo "VERDICT=PASS" > "$TD/_deploy/verify-report-2.md"
CW_DEPLOY_VERIFY_TIMEOUT=5 bash "$BIN/deploy-verify-wait.sh" "$TOPIC" 2 >/dev/null 2>&1
grep -q '^VS=ok$' "$TD/_deploy/verify-cody-2.txt" \
  || { echo "FAIL: verify-wait round=2 missing VS=ok"; exit 1; }
[[ -f "$TD/_deploy/verify-cody-2.done" ]] \
  || { echo "FAIL: verify-wait round-2 sentinel missing"; exit 1; }
pass "verify-wait round=2 → VS=ok + sentinel (per-round isolation)"

# 6. verify-wait — error event → VS=failed.
reset_state
PRE=5
head -c "$PRE" /dev/zero > "$TD/cody-codex/outbox.jsonl"
printf '{"event":"error"}\n' >> "$TD/cody-codex/outbox.jsonl"
echo "OFFSET=$PRE" > "$TD/_deploy/verify-cody-3.txt"
echo "VERDICT=FAIL" > "$TD/_deploy/verify-report-3.md"
CW_DEPLOY_VERIFY_TIMEOUT=5 bash "$BIN/deploy-verify-wait.sh" "$TOPIC" 3 >/dev/null 2>&1
grep -q '^VS=failed$' "$TD/_deploy/verify-cody-3.txt" \
  || { echo "FAIL: verify-wait missing VS=failed on error"; exit 1; }
pass "verify-wait → VS=failed on error event"

# 7. plan-wait — invalid bad topic → exit 2.
reset_state
out=$(bash "$BIN/deploy-plan-wait.sh" "../bad" 2>&1) && rc=0 || rc=$?
[[ "$rc" -eq 2 ]] || { echo "FAIL: bad topic exit code $rc, want 2"; exit 1; }
pass "plan-wait rejects bad topic"
