#!/usr/bin/env bash
# tests/test_consult_v050_dogfood.sh — MANUAL v0.5.0 release-gate dogfood.
#
# Skipped by tests/run.sh (manual gate). Run by hand:
#   bash tests/test_consult_v050_dogfood.sh
#
# Required state: tmux session active; codex+claude on PATH.
#
# Procedure:
#   1. Run: /clone-wars:consult decide between mutex vs spin-lock for foo cache
#   2. During Step 3 (research wait), type a chat message to Yoda's pane.
#      Verify the pane responds (prompt is interactive — not "busy").
#   3. From a second terminal: bash bin/list.sh
#      Verify both troopers show `working`. Wait > $CW_STALE_THRESHOLD_S
#      seconds (default 180) and re-run; verify `stale` appears.
#      (Tip: if the trooper finishes before 180s, re-run with a slower
#       task or temporarily set CW_STALE_THRESHOLD_S=30 in the env.)
#   4. Answer any FS=question prompts.
#   5. Wait for synthesis; verify final shape.
#
# Pass criteria:
#   - Yoda's pane was demonstrably interactive during steps 2-3.
#   - /clone-wars:list showed `stale` after the wait elapsed.
#   - Synthesis shipped with no errors.
echo "This is a manual dogfood checklist. Read the script header and run the steps yourself."
exit 0
