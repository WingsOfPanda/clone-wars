#!/usr/bin/env bash
# tests/test_deploy_v070_dogfood.sh
# MANUAL release gate — exercises the full /clone-wars:deploy pipeline
# end-to-end against a real Codex trooper. Skipped from tests/run.sh because
# it requires tmux + a running codex CLI + can take 20+ minutes.
#
# Run explicitly:
#   bash tests/test_deploy_v070_dogfood.sh
set -euo pipefail
echo "Manual release gate. Steps:"
echo "  1. Pick a small design doc under docs/superpowers/specs/."
echo "  2. From a tmux session: /clone-wars:deploy <design-path>"
echo "  3. Confirm: cody-codex pane spawns, plan.md is written, implementation"
echo "     commits land on feat/deploy-<topic>, cross-verify reports PASS within"
echo "     5 rounds, archive happens cleanly."
echo "  4. Confirm: bash tests/run.sh stays green on the new branch."
echo
echo "Pass criteria documented in:"
echo "  docs/superpowers/specs/2026-05-02-clone-wars-execute-design.md §Success criteria"
exit 0
