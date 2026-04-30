#!/usr/bin/env bash
# tests/test_consult_design_doc_walkthrough.sh — MANUAL DOGFOOD ONLY.
#
# This test is skipped by tests/run.sh because it requires a live tmux
# session, real codex+claude binaries, and an interactive operator to walk
# through 5 sections of AskUserQuestion prompts. Run it as a slash command
# when dogfooding v0.4.0 design-doc mode:
#
#   /clone-wars:consult --design-doc decide between LRU and LFU cache eviction
#
# Verifies:
#   1. Step 8.5 enters automatically when --design-doc flag is present.
#   2. Per-section AskUserQuestion fires for all 5 sections.
#   3. Drill-deeper path on at least one section produces drilldown-*.md
#      and folds it into the section draft.
#   4. Final docs/clone-wars/specs/YYYY-MM-DD-<slug>-design.md lands and
#      is committed.
#   5. Re-running on the same topic same day triggers the overwrite-refuse
#      path.
#   6. Aborting mid-walkthrough leaves _consult/design-doc/ intact for
#      resume on the next run.
echo "MANUAL — see header for steps"
exit 0
