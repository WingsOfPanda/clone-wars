#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/consult.sh

TMPROOT=$(mktemp -d -t cw-detect-single.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

git init -q "$TMPROOT"
mkdir -p "$TMPROOT/src" "$TMPROOT/docs"   # plain children, no .git

out=$(cw_consult_detect_hub "$TMPROOT") && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: expected rc=1, got $rc"; exit 1; }
[[ -z "$out" ]] || { echo "FAIL: expected empty stdout, got: $out"; exit 1; }
pass "single-repo returns rc=1 + empty stdout (v0.10 backward-compat)"
