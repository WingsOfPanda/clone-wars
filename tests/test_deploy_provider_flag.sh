#!/usr/bin/env bash
# tests/test_deploy_provider_flag.sh — v0.13.0 regression for the new
# --provider override on /clone-wars:deploy. Asserts:
#   1. cw_deploy_detect_provider's 2nd-arg override beats auto-detect
#   2. empty-string override is treated as no override (auto-detect runs)
#   3. bin/deploy-init.sh recognizes --provider <name> and writes the
#      overridden value to ART_DIR/auto_provider.txt
set -euo pipefail
cd "$(dirname "$0")"
PLUGIN_ROOT=$(cd .. && pwd)
source lib/assert.sh

source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# === Case 1: no override, no plugin marker -> codex (default) ===
mkdir -p "$TMP/plain"
detected=$(cw_deploy_detect_provider "$TMP/plain")
assert_eq "$detected" "codex" "default detection for plain repo"
pass "detect: plain repo -> codex"

# === Case 2: no override, plugin marker -> claude ===
mkdir -p "$TMP/plug/.claude-plugin"
echo '{}' > "$TMP/plug/.claude-plugin/plugin.json"
detected=$(cw_deploy_detect_provider "$TMP/plug")
assert_eq "$detected" "claude" "plugin repo -> claude"
pass "detect: plugin repo -> claude"

# === Case 3: override beats default ===
# v0.20.0 dropped opencode from deploy support (codex + claude only).
# Test "override beats default" by overriding plain repo (auto=codex) → claude.
detected=$(cw_deploy_detect_provider "$TMP/plain" "claude")
assert_eq "$detected" "claude" "override beats default (codex → claude)"
pass "detect: override beats default"

# === Case 4: override beats plugin-marker too ===
# Override plugin repo (auto=claude) → codex.
detected=$(cw_deploy_detect_provider "$TMP/plug" "codex")
assert_eq "$detected" "codex" "override beats plugin-marker (claude → codex)"
pass "detect: override beats plugin-marker"

# === Case 5: empty-string override is no-op (auto-detect runs) ===
detected=$(cw_deploy_detect_provider "$TMP/plug" "")
assert_eq "$detected" "claude" "empty override = no override"
pass "detect: empty-string override is treated as no override"

# === Case 6: end-to-end via bin/deploy-init.sh --provider claude ===
# v0.20.0: opencode rejected, codex/claude only. Drive end-to-end through
# deploy-init with --provider claude on a PLAIN repo (auto-detect would
# pick codex). Assert auto_provider.txt records the override.
EREPO="$TMP/erepo"
mkdir -p "$EREPO"
( cd "$EREPO" && git init -q \
    && git config user.email "test@example.com" \
    && git config user.name "Test User" \
    && git commit -q --allow-empty -m "init" )

DESIGN="$TMP/design.md"
cat > "$DESIGN" <<'EOF'
# Provider Flag Test Design

## Goal
Drive deploy-init's --provider flag end-to-end.

## Architecture
N/A.

## Testing
This file is the fixture.

## Success
auto_provider.txt contains "claude".
EOF

export CLONE_WARS_HOME="$TMP/cw"
mkdir -p "$CLONE_WARS_HOME"

# Run deploy-init from inside the ephemeral repo (plain repo → auto=codex).
( cd "$EREPO" && \
  "$PLUGIN_ROOT/bin/deploy-init.sh" \
    --no-branch \
    --topic "providertest" \
    --provider "claude" \
    "$DESIGN" \
) >/dev/null 2>&1 || { echo "FAIL: deploy-init.sh exited non-zero" >&2; exit 1; }

# Topic dir was created under state/<repo-hash>/providertest.
REPO_HASH=$(cd "$EREPO" && cw_repo_hash)
AUTO_FILE="$CLONE_WARS_HOME/state/$REPO_HASH/providertest/_deploy/auto_provider.txt"
assert_file_exists "$AUTO_FILE" "auto_provider.txt under $REPO_HASH/providertest"
got=$(cat "$AUTO_FILE")
assert_eq "$got" "claude" "auto_provider.txt content matches override (claude over plain-repo default codex)"
pass "deploy-init: --provider claude lands in auto_provider.txt"
