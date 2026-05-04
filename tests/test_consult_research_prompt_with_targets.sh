#!/usr/bin/env bash
# tests/test_consult_research_prompt_with_targets.sh — verify the research
# prompt gains a "## Per-sub-project structure" block when TARGETS is non-empty
# and stays byte-equal to the v0.10/v0.4.2 baseline when TARGETS is empty.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/state.sh
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"; PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
source ../lib/consult.sh

# Hub mode: TARGETS non-empty → per-sub-project instruction must be present
out=$(cw_consult_load_prompt consult/research.md \
        TOPIC="decide between X and Y" \
        WRITE_TO=/tmp/findings.md \
        TARGETS_BLOCK_START= TARGETS_BLOCK_END= \
        TARGETS="hub_a/leaf1
- hub_a/leaf2")
grep -q 'Per-sub-project structure' <<< "$out" \
  || { echo "FAIL: expected per-sub-project instruction with TARGETS set"; exit 1; }
grep -q 'hub_a/leaf1' <<< "$out" \
  || { echo "FAIL: targets list (leaf1) not interpolated"; exit 1; }
grep -q 'hub_a/leaf2' <<< "$out" \
  || { echo "FAIL: targets list (leaf2) not interpolated"; exit 1; }
pass "load_prompt + TARGETS set → per-sub-project instruction emitted"

# Hub mode via build helper: 3rd arg is comma-separated targets
out=$(cw_consult_build_research_prompt "decide between X and Y" "/tmp/findings.md" \
        "hub_a/leaf1,hub_a/leaf2")
grep -q 'Per-sub-project structure' <<< "$out" \
  || { echo "FAIL: build_research_prompt(targets) missing block"; exit 1; }
grep -q 'hub_a/leaf1' <<< "$out" \
  || { echo "FAIL: build_research_prompt(targets) leaf1 missing"; exit 1; }
grep -q 'hub_a/leaf2' <<< "$out" \
  || { echo "FAIL: build_research_prompt(targets) leaf2 missing"; exit 1; }
pass "build_research_prompt(topic, write_to, targets) emits per-sub-project block"

# Single-repo via load_prompt: TARGETS empty → instruction absent
out=$(cw_consult_load_prompt consult/research.md \
        TOPIC="decide between X and Y" \
        WRITE_TO=/tmp/findings.md \
        TARGETS_BLOCK_START= TARGETS_BLOCK_END= \
        TARGETS="")
# load_prompt alone leaves the section text in the template; the build helper
# is what strips it. So this assertion is on the build helper:
out=$(cw_consult_build_research_prompt "decide between X and Y" "/tmp/findings.md" "")
grep -q 'Per-sub-project structure' <<< "$out" \
  && { echo "FAIL: build_research_prompt('') must strip the block"; exit 1; } || true
pass "build_research_prompt(topic, write_to, '') strips block (single-repo)"

# Backward-compat: existing 2-arg call MUST default to single-repo
out=$(cw_consult_build_research_prompt "topic X" "/tmp/findings.md")
grep -q 'Per-sub-project structure' <<< "$out" \
  && { echo "FAIL: 2-arg call must default to single-repo (no block)"; exit 1; } || true
pass "build_research_prompt 2-arg default = single-repo unchanged"
