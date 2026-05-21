#!/usr/bin/env bash
# tests/test_v0_49_0_static_wiring.sh — v0.49 static-wiring lock.
# Skip-guarded: passes via SKIP until plugin.json version reaches 0.49.0,
# then activates and enforces all 5 invariants.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"
MARKETPLACE_JSON="$PLUGIN_ROOT/.claude-plugin/marketplace.json"

CUR_VER=$(awk -F'"' '/"version":/ { print $4; exit }' "$PLUGIN_JSON")
if [[ "$CUR_VER" != "0.49.0" ]]; then
  pass "SKIP — plugin.json version is $CUR_VER (lock active only at 0.49.0)"
  echo "test_v0_49_0_static_wiring: skip-pass"
  exit 0
fi

# Invariant 1: plugin.json AND marketplace.json both at 0.49.0
mp_count=$(grep -c '"version": *"0\.49\.0"' "$MARKETPLACE_JSON")
assert_eq "$mp_count" "2" "INV1: marketplace.json has both version lines at 0.49.0"
pass "INV1. plugin.json + marketplace.json at 0.49.0"

# Invariants 2+3: writer escapes embedded newlines, reader unescapes them.
# Both substitutions carry a "v0.49 #9" comment marker for grep stability;
# the substitution syntax itself is also grep'd for to catch a future edit
# that strips the marker but keeps the behavior — or vice versa.
v049_9_count=$(grep -c "v0.49 #9" "$PLUGIN_ROOT/lib/deep-research.sh")
assert_eq "$v049_9_count" "2" "INV2/3: v0.49 #9 marker appears in both writer and reader comments"

# Writer substitution: literal '${kv[$k]//$' uniquely identifies the escape
# substring in the printf loop. Single-quoted so no shell expansion happens.
# shellcheck disable=SC2016
grep -qF '${kv[$k]//$' "$PLUGIN_ROOT/lib/deep-research.sh" \
  || { printf 'FAIL INV2: writer escape substitution not found\n' >&2; exit 1; }
pass "INV2. writer escapes embedded newlines"

# Reader substitution: literal '${raw//' uniquely identifies the unescape.
# shellcheck disable=SC2016
grep -qF '${raw//' "$PLUGIN_ROOT/lib/deep-research.sh" \
  || { printf 'FAIL INV3: reader unescape substitution not found\n' >&2; exit 1; }
pass "INV3. reader unescapes literal backslash-n back to newline"

# Invariant 4: resume.md Step 3.a contains the v0.49 #10 callout marker on
# both the done|error and heartbeat bullets — that's the load-bearing signal
# that the clear-probe-on-recovery instruction is in place.
v049_count=$(grep -c "v0.49 #10" "$PLUGIN_ROOT/commands/deep-research-resume.md")
assert_eq "$v049_count" "2" "INV4: v0.49 #10 marker appears in both done|error and heartbeat bullets"
pass "INV4. resume.md clears probe_sent_ts on done/error and heartbeat"

# Invariant 5: deep-research.md halt.flag example block contains
# plateau_observed_n=<N> (positive) and does NOT contain plateau_window=<N>
# (negative — literal <N> token form, not the L225 config reference).
grep -q "plateau_observed_n=<N>" "$PLUGIN_ROOT/commands/deep-research.md" \
  || { echo "FAIL INV5a: plateau_observed_n=<N> not present in halt.flag example" >&2; exit 1; }
if grep -q "plateau_window=<N>" "$PLUGIN_ROOT/commands/deep-research.md"; then
  echo "FAIL INV5b: plateau_window=<N> still present (should be renamed to plateau_observed_n=<N>)" >&2
  exit 1
fi
pass "INV5. halt.flag example uses plateau_observed_n=<N>"

echo "test_v0_49_0_static_wiring: 5 invariants passed"
