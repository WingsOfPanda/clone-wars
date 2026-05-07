#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/cw" "$TMP/bin" "$TMP/repo"
cp "$PLUGIN_ROOT/config/contracts.yaml" "$TMP/cw/contracts.yaml"
cat > "$TMP/bin/codex" <<'BIN'
#!/usr/bin/env bash
echo "codex 1.0.0"; exit 0
BIN
chmod +x "$TMP/bin/codex"

# Invoke medic — should write providers-available.txt
CLONE_WARS_HOME="$TMP/cw" PATH="$TMP/bin:$PATH" HOME="$TMP/nohome" \
  bash -c "cd '$TMP/repo' && '$PLUGIN_ROOT/bin/medic.sh'" >/dev/null 2>&1 || true

REMARK="$TMP/cw/providers-available.txt"
[[ -f "$REMARK" ]] || { echo "FAIL: providers-available.txt missing"; exit 1; }
pass "providers-available.txt exists after medic run"

# Header line is a timestamped comment.
head -1 "$REMARK" | grep -qE '^# generated [0-9]{4}-[0-9]{2}-[0-9]{2}' \
  || { echo "FAIL: header line missing timestamp"; cat "$REMARK"; exit 1; }
pass "remark header has ISO-8601 timestamp"

# codex was on PATH, should appear in remark.
grep -qE '^codex$' "$REMARK" \
  || { echo "FAIL: codex not in remark"; cat "$REMARK"; exit 1; }
pass "codex listed (binary on PATH)"

# Idempotence: second medic run overwrites cleanly.
CLONE_WARS_HOME="$TMP/cw" PATH="$TMP/bin:$PATH" HOME="$TMP/nohome" \
  bash -c "cd '$TMP/repo' && '$PLUGIN_ROOT/bin/medic.sh'" >/dev/null 2>&1 || true
[[ $(grep -cE '^codex$' "$REMARK") -eq 1 ]] \
  || { echo "FAIL: codex duplicated after second medic run"; cat "$REMARK"; exit 1; }
pass "second medic run overwrites cleanly (no duplicates)"
