#!/usr/bin/env bash
# tests/test_consult_3trooper_teardown.sh
#
# v0.15.0: bin/consult-teardown.sh iterates _consult/troopers.txt so it scales
# to N=2/3 troopers. This covers the N=3 case (rex/codex + cody/claude +
# bly/opencode) — asserts all three trooper subdirs are archived and the
# topic dir is cleaned up. The N=2 case is covered in
# tests/test_consult_teardown_bin.sh.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')

# === Test 1: N=3 — all three troopers archived ===
TOPIC=consult-3trooper-td
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_consult" "$TD/rex-codex" "$TD/cody-claude" "$TD/bly-opencode"

# troopers.txt drives iteration order.
printf 'codex\trex\nclaude\tcody\nopencode\tbly\n' > "$TD/_consult/troopers.txt"

# Stage minimal trooper state (no pane.json — teardown.sh's 2-arg branch will
# fall back to dir-name parsing and archive the dirs since no panes are alive).
for d in rex-codex cody-claude bly-opencode; do
  touch "$TD/$d/outbox.jsonl"
done

../bin/consult-teardown.sh "$TOPIC" >/dev/null 2>&1 || true

# All three trooper dirs should be archived (i.e. no longer under topic).
[[ ! -d "$TD/rex-codex"    ]] || { echo "FAIL: rex-codex still in topic dir"    >&2; exit 1; }
[[ ! -d "$TD/cody-claude"  ]] || { echo "FAIL: cody-claude still in topic dir"  >&2; exit 1; }
[[ ! -d "$TD/bly-opencode" ]] || { echo "FAIL: bly-opencode still in topic dir" >&2; exit 1; }

# Verify they landed in archive/ for forensics.
ARCH="$CLONE_WARS_HOME/archive/$RH/$TOPIC"
ls -1 "$ARCH" 2>/dev/null | grep -q '^rex-codex-'    || { echo "FAIL: rex-codex not archived"    >&2; ls -la "$ARCH" >&2 || true; exit 1; }
ls -1 "$ARCH" 2>/dev/null | grep -q '^cody-claude-'  || { echo "FAIL: cody-claude not archived"  >&2; ls -la "$ARCH" >&2 || true; exit 1; }
ls -1 "$ARCH" 2>/dev/null | grep -q '^bly-opencode-' || { echo "FAIL: bly-opencode not archived" >&2; ls -la "$ARCH" >&2 || true; exit 1; }
pass "N=3 teardown archives all three troopers"

# === Test 2: troopers.txt drives iteration; rogue dir not in troopers.txt is left alone ===
# (Defensive — we only tear down what consult registered, not arbitrary state.)
TOPIC2=consult-3trooper-td-rogue
TD2="$CLONE_WARS_HOME/state/$RH/$TOPIC2"
mkdir -p "$TD2/_consult" "$TD2/rex-codex" "$TD2/cody-claude" "$TD2/rogue-claude"
printf 'codex\trex\nclaude\tcody\n' > "$TD2/_consult/troopers.txt"
for d in rex-codex cody-claude rogue-claude; do
  touch "$TD2/$d/outbox.jsonl"
done

../bin/consult-teardown.sh "$TOPIC2" >/dev/null 2>&1 || true

[[ ! -d "$TD2/rex-codex"   ]] || { echo "FAIL: rex-codex still in topic dir (test 2)"   >&2; exit 1; }
[[ ! -d "$TD2/cody-claude" ]] || { echo "FAIL: cody-claude still in topic dir (test 2)" >&2; exit 1; }
[[   -d "$TD2/rogue-claude" ]] || { echo "FAIL: rogue-claude was archived but isn't in troopers.txt" >&2; exit 1; }
pass "teardown follows troopers.txt; rogue dirs untouched"

# === Test 3: missing troopers.txt → fallback to topic-scan ===
TOPIC3=consult-3trooper-td-fallback
TD3="$CLONE_WARS_HOME/state/$RH/$TOPIC3"
mkdir -p "$TD3/_consult" "$TD3/rex-codex" "$TD3/cody-claude"
# NO troopers.txt — defensive fallback path.
for d in rex-codex cody-claude; do
  touch "$TD3/$d/outbox.jsonl"
done

out=$(../bin/consult-teardown.sh "$TOPIC3" 2>&1) || true
echo "$out" | grep -q 'troopers.txt missing' || { echo "FAIL: fallback warning not emitted" >&2; echo "$out" >&2; exit 1; }
[[ ! -d "$TD3/rex-codex"   ]] || { echo "FAIL: rex-codex still in topic dir (fallback)"   >&2; exit 1; }
[[ ! -d "$TD3/cody-claude" ]] || { echo "FAIL: cody-claude still in topic dir (fallback)" >&2; exit 1; }
pass "missing troopers.txt → falls back to topic-scan teardown"

# === Test 4: static wiring — script reads troopers.txt via cw_consult_load_troopers ===
grep -q 'cw_consult_load_troopers' ../bin/consult-teardown.sh \
  || { echo "FAIL: consult-teardown.sh should use cw_consult_load_troopers" >&2; exit 1; }
grep -q 'troopers.txt' ../bin/consult-teardown.sh \
  || { echo "FAIL: consult-teardown.sh should reference troopers.txt" >&2; exit 1; }
pass "consult-teardown.sh wires cw_consult_load_troopers + troopers.txt"
