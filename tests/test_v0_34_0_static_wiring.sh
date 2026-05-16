#!/usr/bin/env bash
# tests/test_v0_34_0_static_wiring.sh
# Version-stamped invariant lock for v0.34.0. Skips with PASS when the
# plugin version != 0.34.0 so future versions don't re-fire this lock.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"

PV=$(grep -E '^  "version":' "$PLUGIN_ROOT/.claude-plugin/plugin.json" \
  | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')

if [[ "$PV" != "0.34.0" ]]; then
  pass "skip — plugin version $PV ≠ 0.34.0"
  exit 0
fi

# --- Invariant 1: plugin.json reports 0.34.0 ---
assert_eq "$PV" "0.34.0" "invariant 1: plugin.json version"
pass "1. plugin.json reads 0.34.0"

# --- Invariant 2: bin/deep-research-fresh-trooper.sh exists + executable ---
assert_file_exists "$PLUGIN_ROOT/bin/deep-research-fresh-trooper.sh" \
  "invariant 2: fresh-trooper script exists"
[[ -x "$PLUGIN_ROOT/bin/deep-research-fresh-trooper.sh" ]] \
  || { echo "FAIL: invariant 2: fresh-trooper not executable" >&2; exit 1; }
pass "2. bin/deep-research-fresh-trooper.sh exists + executable"

# --- Invariant 3: bin/deep-research-refine.sh exists + executable ---
assert_file_exists "$PLUGIN_ROOT/bin/deep-research-refine.sh" \
  "invariant 3: refine script exists"
[[ -x "$PLUGIN_ROOT/bin/deep-research-refine.sh" ]] \
  || { echo "FAIL: invariant 3: refine not executable" >&2; exit 1; }
pass "3. bin/deep-research-refine.sh exists + executable"

# --- Invariant 4: experiment-send.sh parses --inputs and --context-file ---
grep -q '\-\-inputs' "$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
  || { echo "FAIL: invariant 4a: --inputs parser missing" >&2; exit 1; }
grep -q '\-\-context-file' "$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
  || { echo "FAIL: invariant 4b: --context-file parser missing" >&2; exit 1; }
pass "4. experiment-send.sh parses --inputs and --context-file"

# --- Invariant 5: deep-research-init.sh parses --slug ---
grep -q '\-\-slug' "$PLUGIN_ROOT/bin/deep-research-init.sh" \
  || { echo "FAIL: invariant 5: --slug parser missing in init.sh" >&2; exit 1; }
pass "5. deep-research-init.sh parses --slug"

# --- Invariant 6: experiment.md template contains {{TASK_CONTEXT}} ---
grep -q '{{TASK_CONTEXT}}' "$PLUGIN_ROOT/config/prompt-templates/deep-research/experiment.md" \
  || { echo "FAIL: invariant 6: {{TASK_CONTEXT}} placeholder missing" >&2; exit 1; }
pass "6. experiment.md template contains {{TASK_CONTEXT}}"

# --- Invariant 7: directive Phase 4 brief-length wording includes "1-2 paragraphs" ---
grep -q '1-2 paragraphs' "$PLUGIN_ROOT/commands/deep-research.md" \
  || { echo "FAIL: invariant 7: brief-length wording missing '1-2 paragraphs'" >&2; exit 1; }
pass "7. directive contains relaxed brief-length wording"

# --- Invariant 8: directive contains approach-diversity prose ---
grep -qE 'Approach diversity|approach-diversity' "$PLUGIN_ROOT/commands/deep-research.md" \
  || { echo "FAIL: invariant 8: approach-diversity prose missing" >&2; exit 1; }
pass "8. directive contains approach-diversity prose"

# --- Invariant 9: directive contains asymmetric-framing prose ---
grep -qE 'Asymmetric-framing|asymmetric-framing' "$PLUGIN_ROOT/commands/deep-research.md" \
  || { echo "FAIL: invariant 9: asymmetric-framing prose missing" >&2; exit 1; }
pass "9. directive contains asymmetric-framing prose"

# --- Invariant 10: CLAUDE.md has v0.34.0 status + release-gate rows ---
grep -q '^- \[x\] v0.34.0' "$PLUGIN_ROOT/CLAUDE.md" \
  || { echo "FAIL: invariant 10a: CLAUDE.md missing v0.34.0 done row" >&2; exit 1; }
grep -q '^- \[ \] v0.34.0 strict-dogfood' "$PLUGIN_ROOT/CLAUDE.md" \
  || { echo "FAIL: invariant 10b: CLAUDE.md missing v0.34.0 release-gate row" >&2; exit 1; }
pass "10. CLAUDE.md has v0.34.0 status + release-gate rows"

echo "test_v0_34_0_static_wiring: 10 invariants locked"
