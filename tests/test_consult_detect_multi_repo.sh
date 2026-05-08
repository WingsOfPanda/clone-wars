#!/usr/bin/env bash
# tests/test_consult_detect_multi_repo.sh
#
# cw_consult_detect_multi_repo <cwd> <topic-prose>
# Walks $cwd's first-level siblings for CLAUDE.md or AGENTS.md, intersects
# the directory basenames against words in $topic-prose. Emits TSV lines
# "<slug>\t<absolute-path-to-CLAUDE-or-AGENTS-file>" to stdout.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

source ../lib/consult-walk.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Build a fake hub layout:
#   $TMP/hub/api-server/CLAUDE.md       (mentioned in topic)
#   $TMP/hub/auth-service/AGENTS.md     (mentioned in topic)
#   $TMP/hub/billing-stub/CLAUDE.md     (NOT mentioned in topic)
#   $TMP/hub/.hidden/CLAUDE.md          (hidden, skipped)
#   $TMP/hub/no-marker/                  (no marker file, skipped)
mkdir -p "$TMP/hub/api-server" "$TMP/hub/auth-service" "$TMP/hub/billing-stub" \
         "$TMP/hub/.hidden" "$TMP/hub/no-marker"
touch "$TMP/hub/api-server/CLAUDE.md" "$TMP/hub/auth-service/AGENTS.md" \
      "$TMP/hub/billing-stub/CLAUDE.md" "$TMP/hub/.hidden/CLAUDE.md"

TOPIC="plan migration of session storage between api-server and auth-service repos"

got=$(cw_consult_detect_multi_repo "$TMP/hub" "$TOPIC")

# Two hits expected (api-server, auth-service); billing-stub filtered out.
echo "$got" | grep -qE "^api-server\b"    || { echo "FAIL: missing api-server in [$got]" >&2; exit 1; }
echo "$got" | grep -qE "^auth-service\b"  || { echo "FAIL: missing auth-service in [$got]" >&2; exit 1; }
echo "$got" | grep -qE "billing-stub" && { echo "FAIL: billing-stub should be filtered" >&2; exit 1; } || true
echo "$got" | grep -qE "\.hidden"     && { echo "FAIL: .hidden should be skipped" >&2; exit 1; } || true

# Each emitted line is TSV with absolute path.
echo "$got" | while IFS=$'\t' read -r slug path; do
  [[ -f "$path" ]] || { echo "FAIL: emitted path doesn't exist: $path" >&2; exit 1; }
  [[ "$path" = /* ]] || { echo "FAIL: path is not absolute: $path" >&2; exit 1; }
done

# Topic with NO matches → empty stdout, rc=0.
got=$(cw_consult_detect_multi_repo "$TMP/hub" "completely unrelated topic")
[[ -z "$got" ]] || { echo "FAIL: unrelated topic should produce no output, got=[$got]" >&2; exit 1; }

# CWD with no children → empty stdout, rc=0.
mkdir -p "$TMP/empty"
got=$(cw_consult_detect_multi_repo "$TMP/empty" "anything")
[[ -z "$got" ]] || { echo "FAIL: empty cwd should produce no output, got=[$got]" >&2; exit 1; }

# Missing args.
cw_consult_detect_multi_repo "" "topic" >/dev/null 2>&1 && { echo "FAIL: empty cwd should rc=2" >&2; exit 1; } || rc=$?
[[ "$rc" -eq 2 ]] || { echo "FAIL: empty cwd rc=$rc" >&2; exit 1; }
cw_consult_detect_multi_repo "$TMP/hub" "" >/dev/null 2>&1 && { echo "FAIL: empty topic should rc=2" >&2; exit 1; } || rc=$?
[[ "$rc" -eq 2 ]] || { echo "FAIL: empty topic rc=$rc" >&2; exit 1; }

# Non-existent cwd → rc=1.
cw_consult_detect_multi_repo "$TMP/nonexistent" "topic" >/dev/null 2>&1 && { echo "FAIL: missing cwd should rc=1" >&2; exit 1; } || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: missing cwd rc=$rc" >&2; exit 1; }

pass "cw_consult_detect_multi_repo: filters siblings by topic-prose mentions"
