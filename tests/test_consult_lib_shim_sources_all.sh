#!/usr/bin/env bash
# tests/test_consult_lib_shim_sources_all.sh — proves lib/consult.sh shim
# sources all 3 split files and exposes every v0.11.0 function.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# Source ONLY the shim — must transitively pull in all split files.
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

# Enumerate every v0.11.0 function name that must remain callable.
EXPECTED=(
  # consult-hub.sh
  cw_consult_detect_hub
  cw_consult_hub_mode_persist cw_consult_hub_mode_load
  cw_consult_targets_persist cw_consult_targets_load
  cw_consult_targets_to_header_pair
  # consult-validators.sh
  cw_consult_dag_validate cw_consult_xrepo_deps_validate
  cw_consult_acceptance_tests_validate
  # consult-prompts.sh
  cw_consult_strip_block cw_consult_build_verify_prompt
  cw_consult_build_research_prompt cw_consult_design_doc_drilldown_prompt
  cw_consult_parse_design_doc_flag cw_consult_load_prompt
  # consult.sh residual
  cw_consult_topic_dir cw_consult_art_dir
  cw_consult_findings_path cw_consult_verify_path
  cw_consult_parse_claims cw_consult_findings_status
  cw_consult_citation_overlaps cw_consult_diff
  cw_consult_parse_verdicts cw_consult_synthesize
  cw_consult_topic_validate cw_consult_assert_topic cw_consult_assert_commander
  cw_consult_status_load cw_consult_write_adjudicated
  cw_consult_classify_topic cw_consult_skill_hint_append
  cw_consult_question_payload_write cw_consult_question_payload_read
  cw_consult_question_validate_line cw_consult_question_extract_to_payload
  cw_consult_outbox_match_endbyte
  cw_consult_design_doc_filename cw_consult_design_doc_assemble
  cw_consult_design_doc_self_review cw_consult_design_doc_resume_state
)

missing=()
for fn in "${EXPECTED[@]}"; do
  declare -F "$fn" > /dev/null || missing+=("$fn")
done
if (( ${#missing[@]} > 0 )); then
  printf 'FAIL: missing functions after sourcing shim:\n'
  printf '  - %s\n' "${missing[@]}"
  exit 1
fi
pass "shim sources all 41 v0.11.0 functions"

# Also assert each split file exists.
for f in lib/consult-hub.sh lib/consult-validators.sh lib/consult-prompts.sh; do
  [[ -f "$PLUGIN_ROOT/$f" ]] || { echo "FAIL: split file missing: $f"; exit 1; }
done
pass "all 3 split files present on disk"
