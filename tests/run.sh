#!/usr/bin/env bash
# tests/run.sh — discover and run every tests/test_*.sh; non-zero on any failure.
#
# Skips test_consult_question_dogfood_*.sh — those are manual release gates
# that exercise live codex and are inherently variance-prone (LLM response
# time, network). Run them explicitly:
#   bash tests/test_consult_question_dogfood_strict.sh
#   bash tests/test_consult_question_dogfood_default.sh
set -euo pipefail
cd "$(dirname "$0")"

fail=0
for t in test_*.sh; do
  case "$t" in
    test_consult_question_dogfood_*.sh)
      echo "=== $t === (SKIP — manual release gate, run explicitly)"
      continue ;;
    test_consult_design_doc_walkthrough.sh)
      echo "=== $t === (SKIP — manual interactive dogfood, run via slash command)"
      continue ;;
    test_consult_v050_dogfood.sh)
      echo "=== $t === (SKIP — manual v0.5.0 dogfood, run explicitly)"
      continue ;;
    test_execute_design_v060_dogfood.sh)
      echo "=== $t === (SKIP — manual v0.6.0 dogfood, run explicitly)"
      continue ;;
  esac
  echo "=== $t ==="
  if bash "$t"; then
    echo "  $t: ok"
  else
    echo "  $t: FAIL"
    fail=1
  fi
done

exit "$fail"
