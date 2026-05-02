#!/usr/bin/env bash
# tests/test_pane_meta.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/state.sh
source ../lib/ipc.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# 1. cw_pane_meta_write embeds commander + model fields.
mkdir -p "$(cw_trooper_dir rex codex demo)"
cw_pane_meta_write rex codex demo '%42'
META=$(cw_pane_meta_path rex codex demo)
assert_file_exists "$META" "pane.json created"
grep -q '"pane_id":"%42"' "$META" || { echo "FAIL: pane_id missing" >&2; exit 1; }
grep -q '"commander":"rex"' "$META" || { echo "FAIL: commander field missing" >&2; exit 1; }
grep -q '"model":"codex"' "$META" || { echo "FAIL: model field missing" >&2; exit 1; }
pass "pane_meta_write embeds commander+model"

# 2. cw_pane_meta_model returns the model field when present.
got=$(cw_pane_meta_model rex codex demo)
assert_eq "$got" "codex" "reader returns embedded model"
pass "pane_meta_model returns embedded value"

# 3. cw_pane_meta_commander returns the commander field when present.
got=$(cw_pane_meta_commander rex codex demo)
assert_eq "$got" "rex" "reader returns embedded commander"
pass "pane_meta_commander returns embedded value"

# 4. Hyphenated model keys round-trip cleanly (the whole point of #3).
mkdir -p "$(cw_trooper_dir rex claude-haiku demo)"
cw_pane_meta_write rex claude-haiku demo '%99'
got_m=$(cw_pane_meta_model rex claude-haiku demo)
got_c=$(cw_pane_meta_commander rex claude-haiku demo)
assert_eq "$got_m" "claude-haiku" "hyphenated model round-trips"
assert_eq "$got_c" "rex" "commander correct alongside hyphenated model"
pass "hyphenated model + commander"

# 5. cw_pane_meta_read_for_dir returns commander, model, pane_id from a dir
#    path WITHOUT relying on dir-name parsing for hyphenated models.
DIR=$(cw_trooper_dir rex claude-haiku demo)
mapfile -t META_OUT < <(cw_pane_meta_read_for_dir "$DIR")
assert_eq "${META_OUT[0]}" "rex" "read_for_dir commander"
assert_eq "${META_OUT[1]}" "claude-haiku" "read_for_dir model (hyphenated)"
assert_eq "${META_OUT[2]}" "%99" "read_for_dir pane_id"
pass "read_for_dir authoritative for hyphenated models"

# 6. Backward compat: pane.json without commander/model fields falls back to
#    dir-name parse (with the known caveat that hyphenated models lose data,
#    but at least non-hyphenated v0.0.3 troopers keep working).
mkdir -p "$(cw_trooper_dir cody codex demo)"
META_OLD=$(cw_pane_meta_path cody codex demo)
printf '{"pane_id":"%%55","spawned_at":"2026-04-26T00:00:00Z"}\n' > "$META_OLD"
unset _CW_PANE_META_FALLBACK_WARNED
out=$(cw_pane_meta_model cody codex demo 2>&1 1>/tmp/cw-meta-out)
val=$(cat /tmp/cw-meta-out); rm -f /tmp/cw-meta-out
assert_eq "$val" "codex" "fallback returns dir-parsed model"
assert_contains "$out" "missing 'commander'/'model' fields" "fallback emits deprecation warning"
pass "backward-compat fallback (model)"

# 7. Warning fires only ONCE per shell invocation across both readers.
out2=$(cw_pane_meta_commander cody codex demo 2>&1 1>/dev/null)
[[ -z "$out2" ]] || { echo "FAIL: warning fired twice; out2='$out2'" >&2; exit 1; }
pass "fallback warning is one-shot across readers"

echo "  ALL: ok"
