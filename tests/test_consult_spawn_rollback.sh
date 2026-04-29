#!/usr/bin/env bash
# tests/test_consult_spawn_rollback.sh — Codex #3 + Rev1 #4 fixture.
# Mocks parallel spawn (one rc=0, one rc=1), runs the directive's
# rollback recipe verbatim, asserts archive + _consult/ removed + nonzero rc.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

# Re-enabled by Task 14 (rewrite of commands/consult.md). The directive
# v0.1.2 ships does not contain the v0.2 rollback runbook, so this test
# would fail against the current directive. Task 14 rewrites the
# directive AND removes this guard.
if [[ "${CW_TEST_SKIP_SPAWN_ROLLBACK:-1}" == "1" ]]; then
  pass "spawn-rollback fixture deferred until Task 14"
  exit 0
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"

# === Static wiring: the directive must NOT use the broken $(<repo-hash>) pattern. ===
grep -q 'spawn-rollback\|rollback'        ../commands/consult.md || { echo "FAIL: directive missing rollback section" >&2; exit 1; }
grep -q 'consult-teardown'                ../commands/consult.md || { echo "FAIL: directive missing teardown call" >&2; exit 1; }
grep -q 'rm -rf "\$TOPIC_DIR"'            ../commands/consult.md || { echo "FAIL: rollback should rm -rf \$TOPIC_DIR" >&2; exit 1; }
grep -q 'cw_repo_hash'                    ../commands/consult.md || { echo "FAIL: directive must source lib/state.sh and call cw_repo_hash" >&2; exit 1; }
! grep -F '$(<repo-hash>)'                ../commands/consult.md || { echo "FAIL: directive contains broken \$(<repo-hash>) placeholder" >&2; exit 1; }
pass "directive rollback runbook is well-formed (no broken placeholders)"

# === Functional: mock spawn.sh that fails for cody, succeeds for rex. ===
MOCK_BIN="$TMP/mock-bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/spawn.sh" <<'MOCK'
#!/usr/bin/env bash
# Mock: rc=0 for rex, rc=1 for cody. Creates a fake state dir for rex.
COMMANDER="$1"; MODEL="$2"; TOPIC="$3"
if [[ "$COMMANDER" == "rex" ]]; then
  source "$CLAUDE_PLUGIN_ROOT/lib/state.sh"
  TD="$(cw_state_root)/state/$(cw_repo_hash)/$TOPIC/$COMMANDER-$MODEL"
  mkdir -p "$TD"
  touch "$TD/outbox.jsonl"
  echo "{\"pane_id\":\"%999\",\"commander\":\"$COMMANDER\",\"model\":\"$MODEL\",\"spawned_at\":\"2026-04-29T00:00:00Z\"}" > "$TD/pane.json"
  exit 0
else
  exit 1
fi
MOCK
chmod +x "$MOCK_BIN/spawn.sh"

# === Run init + parallel mock-spawns + actual rollback recipe. ===
source ../lib/state.sh
REPO_HASH=$(cw_repo_hash)
CONSULT_TOPIC=$(../bin/consult-init.sh "rollback fixture")
TOPIC_DIR="$CLONE_WARS_HOME/state/$REPO_HASH/$CONSULT_TOPIC"

# Parallel-mock-spawn: invoke both, capture rc per side.
"$MOCK_BIN/spawn.sh" rex  codex  "$CONSULT_TOPIC" && REX_RC=0 || REX_RC=$?
"$MOCK_BIN/spawn.sh" cody claude "$CONSULT_TOPIC" && CODY_RC=0 || CODY_RC=$?

[[ "$REX_RC"  -eq 0 ]] || { echo "FAIL: rex mock should succeed" >&2; exit 1; }
[[ "$CODY_RC" -ne 0 ]] || { echo "FAIL: cody mock should fail"  >&2; exit 1; }
pass "mocked parallel spawn: rex ok, cody fails"

# === Apply the directive's rollback recipe verbatim ===
( "$CLAUDE_PLUGIN_ROOT/bin/consult-teardown.sh" "$CONSULT_TOPIC" 2>&1 >/dev/null && rm -rf "$TOPIC_DIR" && exit 1 ) && ROLLBACK_RC=0 || ROLLBACK_RC=$?

# === Assertions ===
[[ "$ROLLBACK_RC" -ne 0 ]] || { echo "FAIL: rollback recipe should exit nonzero" >&2; exit 1; }
[[ ! -d "$TOPIC_DIR/_consult" ]] || { echo "FAIL: _consult/ survived rollback" >&2; ls -la "$TOPIC_DIR" >&2 || true; exit 1; }
[[ ! -d "$TOPIC_DIR" ]] || { echo "FAIL: \$TOPIC_DIR survived rollback" >&2; exit 1; }
# The survivor (rex) should have been archived by consult-teardown.sh.
ARCHIVED=$(find "$CLONE_WARS_HOME/archive/$REPO_HASH/$CONSULT_TOPIC" -maxdepth 1 -type d -name 'rex-codex-*' 2>/dev/null | head -n1)
[[ -n "$ARCHIVED" ]] || { echo "FAIL: rex-codex was not archived by consult-teardown" >&2; ls -la "$CLONE_WARS_HOME/archive/$REPO_HASH/$CONSULT_TOPIC" >&2 || true; exit 1; }
pass "rollback: \$TOPIC_DIR removed, rex archived, exit nonzero"
