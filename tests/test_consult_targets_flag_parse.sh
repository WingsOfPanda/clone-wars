#!/usr/bin/env bash
# tests/test_consult_targets_flag_parse.sh
#
# bin/consult-init.sh --targets a,b,c <topic>
# Parses comma-separated slugs, validates each against CW_SLUG_REGEX_BASE,
# checks directory presence + CLAUDE.md/AGENTS.md, writes
# _consult/targets.txt (TSV slug\tabsolute-marker-path) and
# _consult/multi-repo.txt (single line: "multi"). Without --targets,
# behavior is unchanged.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# Stage providers-available.txt (init.sh requires this v0.15.0 gate).
mkdir -p "$CLONE_WARS_HOME"
cat > "$CLONE_WARS_HOME/providers-available.txt" <<EOF
codex
claude
EOF

# Build a fake hub layout to consult against.
mkdir -p "$TMP/hub/api-server" "$TMP/hub/auth-service"
touch "$TMP/hub/api-server/CLAUDE.md" "$TMP/hub/auth-service/CLAUDE.md"

INIT="$(cd .. && pwd)/bin/consult-init.sh"
LIB="$(cd .. && pwd)/lib/state.sh"

# --- Happy path: two valid slugs ---
cd "$TMP/hub"
RH=$(bash -c "source '$LIB'; cw_repo_hash")
TOPIC_OUT=$("$INIT" --targets api-server,auth-service "session storage migration")
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC_OUT"
assert_file_exists "$TD/_consult/targets.txt"     "targets.txt written"
assert_file_exists "$TD/_consult/multi-repo.txt"  "multi-repo.txt written"
mode=$(cat "$TD/_consult/multi-repo.txt")
[[ "$mode" == "multi" ]] || { echo "FAIL: multi-repo.txt = [$mode] (expected multi)" >&2; exit 1; }
TAB=$(printf '\t')
grep -qE "^api-server${TAB}.*api-server/CLAUDE\.md$"    "$TD/_consult/targets.txt" || { echo "FAIL: api-server row missing or wrong path; targets.txt:" >&2; cat "$TD/_consult/targets.txt" >&2; exit 1; }
grep -qE "^auth-service${TAB}.*auth-service/CLAUDE\.md$" "$TD/_consult/targets.txt" || { echo "FAIL: auth-service row missing" >&2; exit 1; }

# --- Invalid slug (uppercase) → rc=1 ---
"$INIT" --targets API-SERVER,auth-service "topic-2" 2>/dev/null && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: uppercase slug should rc=1, got $rc" >&2; exit 1; }

# --- Slug pointing at non-existent dir → rc=1 with named slug in error ---
err=$("$INIT" --targets api-server,nonexistent "topic-3" 2>&1 1>/dev/null) && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: missing-dir rc=$rc (expected 1)" >&2; exit 1; }
echo "$err" | grep -qE "nonexistent" || { echo "FAIL: error didn't name missing slug; got: $err" >&2; exit 1; }

# --- Empty targets list → rc=1 ---
"$INIT" --targets "" "topic-4" 2>/dev/null && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: empty --targets should rc=1, got $rc" >&2; exit 1; }

# --- Duplicate slugs → rc=1 ---
"$INIT" --targets api-server,api-server "topic-5" 2>/dev/null && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: duplicate slug should rc=1, got $rc" >&2; exit 1; }

# --- Without --targets, behavior unchanged: no targets.txt, no multi-repo.txt ---
TOPIC_OUT=$("$INIT" "single-repo topic")
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC_OUT"
[[ ! -f "$TD/_consult/targets.txt" ]]    || { echo "FAIL: targets.txt should NOT exist without --targets" >&2; exit 1; }
[[ ! -f "$TD/_consult/multi-repo.txt" ]] || { echo "FAIL: multi-repo.txt should NOT exist without --targets" >&2; exit 1; }

pass "bin/consult-init.sh --targets parsing + validation works"
