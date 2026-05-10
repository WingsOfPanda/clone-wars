#!/usr/bin/env bash
# tests/test_v0_20_3_static_wiring.sh
# v0.20.3 spawn-cwd-fix — static wiring assertions across all 4 layers.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib/assert.sh

# Layer 3 — cw_pane_respawn uses respawn-pane -c, no cd-then-exec
tmux_src=$(cat lib/tmux.sh)
[[ "$tmux_src" != *"cd '\$cwd' && exec"* ]] \
  || { echo "FAIL: lib/tmux.sh still has cd-then-exec hack"; exit 1; }
[[ "$tmux_src" == *"respawn-pane -k -c"* ]] \
  || { echo "FAIL: lib/tmux.sh missing 'respawn-pane -k -c' pattern"; exit 1; }
pass "Layer 3: cw_pane_respawn uses respawn-pane -c"

# Layer 1 — deploy-multi-init.sh writes cmdr-cwd-map.txt
multi_src=$(cat bin/deploy-multi-init.sh)
[[ "$multi_src" == *"cmdr-cwd-map.txt"* ]] \
  || { echo "FAIL: bin/deploy-multi-init.sh doesn't reference cmdr-cwd-map.txt"; exit 1; }
pass "Layer 1: deploy-multi-init writes cmdr-cwd-map.txt"

# Layer 2 — preflight-layout.sh accepts --cwd-from + builds CMDR_TO_CWD map + threads SPLIT_C_FLAG
pf_src=$(cat bin/preflight-layout.sh)
[[ "$pf_src" == *"--cwd-from"* ]] \
  || { echo "FAIL: bin/preflight-layout.sh missing --cwd-from"; exit 1; }
[[ "$pf_src" == *"CMDR_TO_CWD"* ]] \
  || { echo "FAIL: bin/preflight-layout.sh missing CMDR_TO_CWD map"; exit 1; }
[[ "$pf_src" == *"SPLIT_C_FLAG"* ]] \
  || { echo "FAIL: bin/preflight-layout.sh missing SPLIT_C_FLAG threading"; exit 1; }
pass "Layer 2: preflight-layout has --cwd-from + per-pane -c"

# Layer 4 — directive Step 3a passes --cwd-from
dep_src=$(cat commands/deploy.md)
[[ "$dep_src" == *"--cwd-from"* ]] \
  || { echo "FAIL: commands/deploy.md missing --cwd-from in preflight invocation"; exit 1; }
pass "Layer 4: directive Step 3a threads --cwd-from"

# v0.20.4: loosened to semver-shape regex per the v0.20.2 lesson —
# survives subsequent version bumps. The exact-version lock for v0.20.3
# was load-bearing only for v0.20.3's own release commit; this test now
# guards "version field present + semver-shaped" across both manifests,
# and tests/test_v0_20_4_static_wiring.sh holds the exact 0.20.4 lock.
grep -qE '"version": "0\.[0-9]+\.[0-9]+"' .claude-plugin/plugin.json \
  || { echo "FAIL: plugin.json missing semver-shape version field"; exit 1; }
grep -qE '"version": "0\.[0-9]+\.[0-9]+"' .claude-plugin/marketplace.json \
  || { echo "FAIL: marketplace.json missing semver-shape version field"; exit 1; }
pass "version field present + semver-shaped (loosened from exact-0.20.3 lock)"

echo "ALL PASS — v0.20.3 spawn-cwd-fix wiring locked"
