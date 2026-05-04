#!/usr/bin/env bash
# tests/test_consult_v011_dogfood.sh — manual release gate, NOT run by tests/run.sh
#
# Scenarios:
#   CW-DF-CONS-1: from /home/liupan/ARS/, super-hub detection + two-step
#                 AskUserQuestion + hub-mode design doc with header pair +
#                 DAG + Cross-Repo Deps + tagged tests.
#   CW-DF-CONS-2: from /home/liupan/ARS/ars_fleet/, hub-subrepo +
#                 single-step multi-select + hub-mode shape.
#   CW-DF-CONS-3: from /home/liupan/CC/clone-wars/, single-repo unchanged
#                 (no DAG / Cross-Repo / tagged-tests blocks).
#   CW-DF-CONS-4: hub-mode validator failure path — author cyclic DAG,
#                 verify validator catches + re-enters walk + accepts fix.
#
# Each scenario runs /clone-wars:consult interactively. Mark PASS/FAIL by
# inspecting the committed design doc against the success criteria in
# docs/superpowers/specs/2026-05-04-consult-hub-mode-design.md "Release
# gate" section.
set -euo pipefail
echo "This test is interactive. Run /clone-wars:consult manually per the"
echo "scenarios above and confirm the success criteria in the spec."
exit 0
