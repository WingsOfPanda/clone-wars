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
echo ""
echo "v0.9 auto-provider scenarios:"
echo "  4. cd into a non-plugin repo (no .claude-plugin/plugin.json)."
echo "     Run /clone-wars:deploy <design>. Confirm Step 0 picks codex"
echo "     WITHOUT prompting (auto-go). Inspect"
echo "     <topic-state>/_deploy/auto_provider.txt -> 'codex'."
echo "     Inspect <topic-state>/_deploy/provider.txt -> 'codex'."
echo "  5. cd into the clone-wars repo (has .claude-plugin/plugin.json)."
echo "     Run /clone-wars:deploy <design>. Confirm Step 0 raises an"
echo "     AskUserQuestion. Pick 'Use claude'. Confirm cody-claude pane"
echo "     spawns. auto_provider.txt='claude'; provider.txt='claude'."
echo "  6. Re-run scenario 5 with a fresh topic. Pick 'Fall back to codex'"
echo "     in the AskUserQuestion. Confirm cody-codex pane spawns."
echo "     auto_provider.txt='claude'; provider.txt='codex' (the override)."
echo ""
echo "If scenarios 4-6 pass, this gate is GREEN (also) for v0.9 — flip"
echo "the v0.9 release checkbox in CLAUDE.md."
echo ""
echo "v0.10 sub-repo redirect scenarios:"
echo "  7. cd /home/liupan/ARS/ars_fleet (a hub repo). Author a fixture spec"
echo "     containing **Target Sub-Project:** ARS-Perfusion and the standard"
echo "     Goal/Architecture/Testing/Success sections. Run /clone-wars:deploy."
echo "     Confirm: trooper pane spawns with pwd=ars_fleet/ARS-Perfusion;"
echo "     branch feat/deploy-<topic> is created in the sub-repo (not the hub);"
echo "     state lives at <state-root>/state/<sub-repo-hash>/<topic>/_deploy/;"
echo "     target_cwd.txt content matches the sub-repo absolute path."
echo "  8. Re-run with **Target Sub-Project:** ARS-NonExistent. Confirm clean"
echo "     rc!=0 with 'not found' error and _deploy/ auto-rollback."
echo "  9. cd /home/liupan/ARS/ars_fleet. Run /clone-wars:consult --design-doc"
echo "     for any topic. Confirm Step 8.5 raises an AskUserQuestion listing"
echo "     the 8 ARS-* sub-repos. Pick one. Confirm assembled spec at"
echo "     docs/clone-wars/specs/...md has the **Target Sub-Project:** header"
echo "     as the second non-blank line."
echo ""
echo "If scenarios 7-9 pass, this gate is GREEN (also) for v0.10."
exit 0
