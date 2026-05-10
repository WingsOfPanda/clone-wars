#!/usr/bin/env bash
# tests/test_consult_lib_shim_sources_all.sh — proves lib/consult.sh shim
# sources lib/consult-prompts.sh and exposes every v0.14.0 function.
# (Hub-mode helpers + format validators were removed in v0.14.0; the shim
# no longer needs to source consult-hub.sh / consult-validators.sh.)
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# Source ONLY the shim — must transitively pull in consult-prompts.sh.
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

# Enumerate every v0.14.0 function name that must remain callable.
# MUST be updated whenever a cw_consult_* function is added or removed in
# lib/consult.sh or lib/consult-prompts.sh. The count assertion below
# catches drift automatically.
EXPECTED=(
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
  cw_consult_design_doc_self_review
  # v0.15.0 additions
  cw_consult_provider_to_commander
  cw_consult_eligible_providers
  cw_consult_load_troopers
  # v0.16.0 additions
  cw_consult_design_doc_canonical_path
  cw_consult_parse_use_force_flag
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
pass "shim sources all ${#EXPECTED[@]} v0.16.0 functions (incl. parse_use_force_flag)"

# Also assert each split file exists.
for f in lib/consult.sh lib/consult-prompts.sh; do
  [[ -f "$PLUGIN_ROOT/$f" ]] || { echo "FAIL: split file missing: $f"; exit 1; }
done
pass "all 2 split files present on disk"

# Drift detection: count actual function definitions across both files and
# assert they match the EXPECTED enumeration count. Catches functions added
# without updating EXPECTED above.
actual_count=$(grep -hcE '^cw_consult_[a-z_]+\(\)' \
  "$PLUGIN_ROOT"/lib/consult.sh \
  "$PLUGIN_ROOT"/lib/consult-prompts.sh \
  | awk '{s+=$1} END {print s}')
expected_count="${#EXPECTED[@]}"
if [[ "$actual_count" != "$expected_count" ]]; then
  echo "FAIL: function-count drift — EXPECTED has $expected_count entries but lib/consult*.sh defines $actual_count cw_consult_* functions. Add or remove from EXPECTED."
  exit 1
fi
pass "function-count drift check ($actual_count = $expected_count)"

# Symlink regression: source the shim via a symlink, assert it still resolves siblings
SYMTMP=$(mktemp -d -t cw-symtest.XXXXXX)
trap 'rm -rf "$SYMTMP"' EXIT
ln -s "$PLUGIN_ROOT/lib/consult.sh" "$SYMTMP/symlinked-consult.sh"
# Source in a subshell to avoid polluting current state
( source "$PLUGIN_ROOT/lib/state.sh"
  source "$PLUGIN_ROOT/lib/log.sh"
  source "$SYMTMP/symlinked-consult.sh"
  declare -F cw_consult_build_research_prompt >/dev/null \
    || { echo "FAIL symlink: cw_consult_build_research_prompt not loaded via symlinked shim"; exit 1; } ) \
  || exit 1
pass "shim resolves siblings correctly when sourced via symlink"
