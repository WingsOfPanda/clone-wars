#!/usr/bin/env bash
# tests/test_deploy_v07_dogfood.sh
# MANUAL release gate — exercises the single-turn /clone-wars:deploy refactor
# end-to-end against a real Codex trooper. Skipped from tests/run.sh because
# it requires tmux + a running codex CLI + can take 20+ minutes.
#
# Run explicitly:
#   bash tests/test_deploy_v07_dogfood.sh
set -euo pipefail
echo "Manual release gate for the /clone-wars:deploy single-turn refactor."
echo
echo "Three scenarios to validate end-to-end (from inside a tmux session,"
echo "with the codex CLI on PATH):"
echo
echo "  1. Round-1 happy path."
echo "     /clone-wars:deploy <small-design-path>"
echo "     Confirm cody-codex spawns, the round-1 turn dispatches, and"
echo "     plan.md + implementation commits + verify-report-1.md all land"
echo "     BEFORE the {event:done} record is appended to outbox.jsonl."
echo
echo "  2. Auto-retry resume after a timeout."
echo "     Mid-implementation, force a TS=timeout by killing the codex pane"
echo "     manually. Confirm Yoda's auto-retry fires once, the new prompt"
echo "     re-dispatches, and the trooper resumes from git log + plan.md"
echo "     state rather than re-planning from scratch."
echo
echo "  3. Fix-round resume after a cross-verify FAIL."
echo "     Force a verify FAIL on round 1. Confirm fix-prompt-2.md is"
echo "     authored by Yoda, the second turn dispatches as a single fix-round"
echo "     prompt (no -debug/-gap split), and the trooper skips already-"
echo "     committed fixes via the resume contract."
echo
echo "If all three scenarios pass, this gate is GREEN — flip the v0.7"
echo "release checkbox in CLAUDE.md."
echo
echo "Pass criteria documented in:"
echo "  docs/superpowers/specs/2026-05-02-clone-wars-execute-design.md §Success criteria"
echo "  docs/superpowers/specs/ — single-turn refactor spec (v0.7)"
exit 0
