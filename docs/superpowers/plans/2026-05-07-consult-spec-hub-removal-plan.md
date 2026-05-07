# Consult/Spec Hub-Mode Removal Implementation Plan (v0.14.0)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete hub-mode awareness from `/clone-wars:consult` and `/clone-wars:spec` so both commands run single-context (at the cwd of interest); preserve `/deploy` `Target Sub-Project:` redirect; bump to v0.14.0.

**Architecture:** Bottom-up removal, ordered to keep `bash tests/run.sh` green between every task. Move the one cross-boundary helper FIRST (`cw_consult_design_doc_resume_state` → `cw_spec_resume_state`), then strip hub branches from directives and bin scripts (top-down callers), then strip hub branches from libs (callees), THEN delete the now-unreferenced `lib/consult-hub.sh` + `lib/consult-validators.sh`, THEN bulk-delete the 25 hub/validator test files, THEN polish.

**Tech Stack:** pure bash, tmux, file-IPC. No Node/Python in runtime. `tests/run.sh` is the only test harness.

**Spec:** `docs/superpowers/specs/2026-05-07-consult-spec-hub-removal-design.md`

---

### Task 1: Branch + baseline

**Files:**
- Create: `feat/v0.14.0-hub-removal` branch off `main`

- [ ] **Step 1: Create branch**

```bash
git checkout main
git pull
git checkout -b feat/v0.14.0-hub-removal
```

- [ ] **Step 2: Run baseline test suite, capture green starting point**

```bash
bash tests/run.sh 2>&1 | tail -20
```

Expected: all tests pass. If any fail BEFORE the v0.14.0 work, stop and report — do not proceed.

- [ ] **Step 3: Commit a marker (empty)**

```bash
git commit --allow-empty -m "chore(v0.14.0): start hub-mode removal branch"
```

---

### Task 2: Move resume helper to lib/spec.sh

**Files:**
- Create: `lib/spec.sh`
- Modify: `lib/consult.sh` (remove `cw_consult_design_doc_resume_state`)
- Modify: `commands/spec.md` (rename caller `cw_consult_design_doc_resume_state` → `cw_spec_resume_state` and update the source-line)
- Modify: `tests/test_consult_design_doc_resume.sh` → rename to `tests/test_spec_resume_state.sh`, update function name + source path

- [ ] **Step 1: Read existing implementation**

```bash
grep -n 'cw_consult_design_doc_resume_state' lib/consult.sh
```

Locate the function definition (likely near drilldown helpers; ~30 lines).

- [ ] **Step 2: Create lib/spec.sh with renamed function**

Copy the function body verbatim, rename `cw_consult_design_doc_resume_state` → `cw_spec_resume_state`. File header:

```bash
# lib/spec.sh — helpers consumed only by /clone-wars:spec.
# Split out from lib/consult.sh in v0.14.0 (hub-mode removal) to make the
# /spec → /consult dependency boundary honest.
```

- [ ] **Step 3: Remove function from lib/consult.sh**

Delete the function definition (and any surrounding header comments specific to it).

- [ ] **Step 4: Update commands/spec.md caller**

```bash
grep -n 'cw_consult_design_doc_resume_state\|lib/consult.sh' commands/spec.md
```

Replace `source "$CLAUDE_PLUGIN_ROOT/lib/consult.sh"` (when used solely for this helper) with `source "$CLAUDE_PLUGIN_ROOT/lib/spec.sh"`. Replace function call name. If `lib/consult.sh` is sourced for OTHER reasons in the same block, keep both source lines.

- [ ] **Step 5: Rename + update test**

```bash
git mv tests/test_consult_design_doc_resume.sh tests/test_spec_resume_state.sh
```

Then edit the renamed file: replace `cw_consult_design_doc_resume_state` → `cw_spec_resume_state`, replace `lib/consult.sh` source line with `lib/spec.sh`.

- [ ] **Step 6: Run tests**

```bash
bash tests/run.sh 2>&1 | tail -20
```

Expected: all tests pass (the renamed test now exercises the new path).

- [ ] **Step 7: Commit**

```bash
git add lib/spec.sh lib/consult.sh commands/spec.md tests/test_spec_resume_state.sh tests/test_consult_design_doc_resume.sh
git commit -m "refactor(spec): move resume helper to lib/spec.sh; rename to cw_spec_resume_state"
```

---

### Task 3: Strip hub from commands/consult.md

**Files:**
- Modify: `commands/consult.md`

- [ ] **Step 1: Identify all hub-mode regions**

```bash
grep -n 'HUB_MODE\|hub-mode\|hub_mode\|cw_consult_detect_hub\|targets.txt\|CW_CONSULT_TARGETS\|Step 0.5\|Step 1.5\|cw_consult_hub_mode_load\|cw_consult_targets_persist\|cw_consult_targets_load\|cw_consult_extract_targets_from_topic\|active_subproject\|cw_consult_findings_active_subproject' commands/consult.md
```

- [ ] **Step 2: Delete Step 0.5 entirely**

Remove the "Hub-mode classification" section (heading + body + the `HUB_MODE=$(cw_consult_hub_mode_load ...)` block).

- [ ] **Step 3: Delete Step 1.5 entirely**

Remove the "Target selection (hub mode only)" section (heading + body + the v0.11.1 prelude + the multi-select picker + the persist call).

- [ ] **Step 4: Strip CW_CONSULT_TARGETS plumbing from Step 2**

In the Step 2 block, remove the `TARGETS=""` if-conditional and revert the dispatch lines to:

```bash
"$CLAUDE_PLUGIN_ROOT/bin/consult-research-send.sh" "$CONSULT_TOPIC" rex  codex
"$CLAUDE_PLUGIN_ROOT/bin/consult-research-send.sh" "$CONSULT_TOPIC" cody claude
```

- [ ] **Step 5: Strip CW_CONSULT_TARGETS plumbing from Step 5**

Same treatment for the verify-send dispatch in Step 5.

- [ ] **Step 6: Strip active-subproject slicing from Step 3**

In the Step 3 question-loop section, remove the entire "v0.11.1 active-subproject context (hub mode only)" block. The classification step now uses the full `findings.md` directly:

```bash
CONTEXT_SLICE=$(cat "$FINDINGS_PATH")
```

(Or simplify away `CONTEXT_SLICE` and read `findings.md` inline if cleaner.)

- [ ] **Step 7: Strip active-subproject slicing from Step 5**

Same treatment for the Step 5 verify question-loop slicing block.

- [ ] **Step 8: Strip drilldown hub-aware advisory from Step 8.4**

Remove the "For hub-mode users, include the sub-project name…" note. The drill prose is now uniformly free-form.

- [ ] **Step 9: Trim task list if any hub-only task IDs exist**

Verify the TaskCreate × 13 list at the top doesn't enumerate any hub-specific tasks. (If it does, drop them and re-number.)

- [ ] **Step 10: Run tests**

```bash
bash tests/run.sh 2>&1 | tail -20
```

Expected: tests that exercise the hub-aware directive wiring (e.g., `test_consult_directive_hub_mode.sh`) still PASS for now — they will be deleted in Task 11. The non-hub directive tests must remain green.

- [ ] **Step 11: Commit**

```bash
git add commands/consult.md
git commit -m "feat(consult): strip hub-mode from /consult directive (v0.14.0)"
```

---

### Task 4: Strip hub from commands/spec.md

**Files:**
- Modify: `commands/spec.md`

- [ ] **Step 1: Identify hub regions**

```bash
grep -n 'HUB_MODE\|hub-mode\|targets.txt\|validator\|dag\|xrepo-deps\|acceptance-tests' commands/spec.md
```

- [ ] **Step 2: Delete Step 1 hub-mode read**

Remove `HUB_MODE=$(cat "$TOPIC_DIR/_consult/hub-mode.txt" 2>/dev/null || echo "single-repo")`. Remove the "Set task `1` → `completed`. Log the detected mode." line.

- [ ] **Step 3: Collapse Step 2 section list to flat 5-section**

Replace the if/else `SECTIONS=(...)` branch with a single unconditional list:

```bash
SECTIONS=(architecture components data-flow error-handling testing)
SECTION_TITLES=(Architecture Components "Data Flow" "Error Handling" Testing)
```

- [ ] **Step 4: Delete Step 3 hub-mode validator failure handling**

Remove the "Hub-mode validator failed" branch from the failure-mode list. Step 3's spec-assemble call now only handles output-collision, placeholders, and git-commit-failed.

- [ ] **Step 5: Run tests**

```bash
bash tests/run.sh 2>&1 | tail -20
```

Expected: green except for hub-targeted spec tests slated for deletion in Task 11.

- [ ] **Step 6: Commit**

```bash
git add commands/spec.md
git commit -m "feat(spec): strip hub-mode from /spec directive (v0.14.0)"
```

---

### Task 5: Strip CW_CONSULT_TARGETS from bin scripts + lib/consult-prompts.sh

**Files:**
- Modify: `bin/consult-research-send.sh`
- Modify: `bin/consult-verify-send.sh`
- Modify: `lib/consult-prompts.sh`

- [ ] **Step 1: Strip env handling from bin/consult-research-send.sh**

```bash
grep -n 'CW_CONSULT_TARGETS\|TARGETS' bin/consult-research-send.sh
```

Remove the env-read block. Drop any `--targets` arg the script forwards. Verify the script still calls `cw_consult_build_research_prompt` with the original (non-targets) signature.

- [ ] **Step 2: Strip env handling from bin/consult-verify-send.sh**

Same pattern.

- [ ] **Step 3: Strip targets branch from lib/consult-prompts.sh**

```bash
grep -n 'TARGETS\|sub-project\|per-subproject\|structure block' lib/consult-prompts.sh
```

Remove the `if [[ -n "${CW_CONSULT_TARGETS:-}" ]]; then ... fi` blocks in `cw_consult_build_research_prompt` and `cw_consult_build_verify_prompt`. The prompt builders now emit the same prompt regardless of cwd.

- [ ] **Step 4: Run tests**

```bash
bash tests/run.sh 2>&1 | tail -20
```

Expected: `test_consult_research_prompt_with_targets.sh` + `test_consult_verify_prompt_with_targets.sh` will FAIL — those will be deleted in Task 11. All non-targets prompt tests must pass.

- [ ] **Step 5: Commit (with note about expected failures)**

```bash
git add bin/consult-research-send.sh bin/consult-verify-send.sh lib/consult-prompts.sh
git commit -m "feat(prompts): drop CW_CONSULT_TARGETS env + per-subproject structure block (v0.14.0)

Targets-tagged tests will fail until Task 11 deletes them."
```

---

### Task 6: Strip hub from bin/consult-init.sh + bin/consult-synthesize.sh

**Files:**
- Modify: `bin/consult-init.sh`
- Modify: `bin/consult-synthesize.sh`

- [ ] **Step 1: Strip hub-mode classification from bin/consult-init.sh**

```bash
grep -n 'hub-mode\|HUB_MODE\|cw_consult_detect_hub\|hub_mode' bin/consult-init.sh
```

Remove the block that calls `cw_consult_detect_hub` and writes `_consult/hub-mode.txt`. The init script now only writes `topic.txt` + creates the `_consult/` skeleton.

- [ ] **Step 2: Strip hub references from bin/consult-synthesize.sh**

```bash
grep -n 'hub-mode\|HUB_MODE\|targets.txt\|validator\|dag\|xrepo' bin/consult-synthesize.sh
```

Remove any conditional that reads `targets.txt` or branches on hub mode. Synthesize is now uniform — refuses on PENDING, otherwise concatenates findings + adjudicated → synthesis.md.

- [ ] **Step 3: Run tests**

```bash
bash tests/run.sh 2>&1 | tail -20
```

Expected: `test_consult_init_persists_hub_mode.sh` will FAIL — deleted in Task 11. Non-hub init tests must pass.

- [ ] **Step 4: Commit**

```bash
git add bin/consult-init.sh bin/consult-synthesize.sh
git commit -m "feat(consult): drop hub-mode classification + hub-mode.txt write from init/synthesize (v0.14.0)"
```

---

### Task 7: Strip validators + flat-section enforcement from bin/spec-assemble.sh

**Files:**
- Modify: `bin/spec-assemble.sh`

- [ ] **Step 1: Read current structure**

```bash
grep -n 'validator\|dag\|xrepo\|acceptance-tests\|targets.txt\|HUB_MODE\|hub-mode' bin/spec-assemble.sh
```

- [ ] **Step 2: Remove validator invocations**

Delete the sequential `dag → xrepo-deps → acceptance-tests` validator calls. Remove the `if [[ -s targets.txt ]]; then` guard.

- [ ] **Step 3: Hardcode flat 5-section assembly**

Confirm the SECTIONS array (or equivalent) is `architecture components data-flow error-handling testing`. Drop any branch that enumerates 7 sections.

- [ ] **Step 4: Drop the source line for lib/consult-validators.sh**

```bash
grep -n 'consult-validators' bin/spec-assemble.sh
```

Remove that source line. Same for any consult-hub source if present.

- [ ] **Step 5: Run tests**

```bash
bash tests/run.sh 2>&1 | tail -20
```

Expected: validator-named tests will fail (deleted in Task 11). Other spec tests pass.

- [ ] **Step 6: Commit**

```bash
git add bin/spec-assemble.sh
git commit -m "feat(spec): drop validators + always assemble flat 5-section design doc (v0.14.0)"
```

---

### Task 8: Strip lib/consult.sh sourcing shim

**Files:**
- Modify: `lib/consult.sh`

- [ ] **Step 1: Identify the sourcing shim block**

```bash
grep -n 'consult-hub\|consult-validators\|consult-prompts' lib/consult.sh
```

The 3-way split sourcing shim was added in v0.11.1 (per CLAUDE.md status). Remove the source lines for `consult-hub.sh` and `consult-validators.sh`. KEEP `consult-prompts.sh` (still needed for non-hub prompt building).

- [ ] **Step 2: Remove any remaining hub-mode parser functions**

```bash
grep -n 'hub_mode\|targets\|active_subproject\|extract_targets' lib/consult.sh
```

Delete any function still referencing hub-mode state (defensive — should already be gone, but verify).

- [ ] **Step 3: Run tests**

```bash
bash tests/run.sh 2>&1 | tail -20
```

Expected: `test_consult_lib_shim_sources_all.sh` will FAIL (asserts the 3-way shim sourced everything). It's slated for surgical edit in Task 11. Other tests pass.

- [ ] **Step 4: Commit**

```bash
git add lib/consult.sh
git commit -m "refactor(consult): drop consult-hub + consult-validators source lines from shim (v0.14.0)"
```

---

### Task 9: Delete lib/consult-hub.sh + lib/consult-validators.sh

**Files:**
- Delete: `lib/consult-hub.sh`
- Delete: `lib/consult-validators.sh`

- [ ] **Step 1: Verify no callers remain**

```bash
grep -rn 'consult-hub\|consult-validators\|cw_consult_detect_hub\|cw_consult_targets_persist\|cw_consult_targets_load\|cw_consult_hub_mode_load\|cw_consult_extract_targets_from_topic\|cw_consult_findings_active_subproject\|cw_consult_validate_dag\|cw_consult_validate_xrepo\|cw_consult_validate_acceptance' commands/ bin/ lib/ 2>/dev/null
```

Expected: zero matches under commands/, bin/, lib/. (Tests will still match — they're handled in Task 11.)

If any matches in non-test paths, STOP and route back to the appropriate prior task.

- [ ] **Step 2: Delete the files**

```bash
git rm lib/consult-hub.sh lib/consult-validators.sh
```

- [ ] **Step 3: Run tests**

```bash
bash tests/run.sh 2>&1 | tail -20
```

Expected: hub-targeted tests still fail (Task 11 deletes them). Non-hub tests pass.

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(consult): delete lib/consult-hub.sh + lib/consult-validators.sh (v0.14.0)"
```

---

### Task 10: Surgical edits to mixed test files

**Files:**
- Modify: `tests/test_consult_init.sh` (drop hub-mode.txt assertion if any)
- Modify: `tests/test_consult_lib_shim_sources_all.sh` (drop consult-hub + consult-validators expectations; the shim now only loads consult-prompts)
- Modify: `tests/test_consult_design_doc_flag_deprecated.sh` (verify still works post-init changes)
- Modify: `tests/test_spec_directive_static_wiring.sh` (drop HUB_MODE assertion if any)

- [ ] **Step 1: Audit each file for what to remove**

```bash
for f in tests/test_consult_init.sh tests/test_consult_lib_shim_sources_all.sh tests/test_consult_design_doc_flag_deprecated.sh tests/test_spec_directive_static_wiring.sh; do
  echo "=== $f ==="
  grep -n 'hub\|HUB_MODE\|targets\|validator' "$f"
done
```

- [ ] **Step 2: Edit test_consult_lib_shim_sources_all.sh**

Replace the assertion that lists `consult-hub.sh` + `consult-validators.sh` as expected sources with one that only expects `consult-prompts.sh`.

- [ ] **Step 3: Edit test_consult_init.sh**

Remove any assertion that `_consult/hub-mode.txt` exists post-init.

- [ ] **Step 4: Edit test_spec_directive_static_wiring.sh**

Remove any grep that asserts `HUB_MODE` appears in commands/spec.md.

- [ ] **Step 5: Verify test_consult_design_doc_flag_deprecated.sh still passes**

If it relied on hub-mode init side effects, fix; otherwise leave untouched.

- [ ] **Step 6: Run tests**

```bash
bash tests/run.sh 2>&1 | tail -20
```

Expected: all surgical-edit tests pass. Hub-targeted tests in Task 11's list still fail.

- [ ] **Step 7: Commit**

```bash
git add tests/test_consult_init.sh tests/test_consult_lib_shim_sources_all.sh tests/test_consult_design_doc_flag_deprecated.sh tests/test_spec_directive_static_wiring.sh
git commit -m "test: update mixed-concern tests for v0.14.0 hub-mode removal"
```

---

### Task 11: Bulk-delete hub/validator test files

**Files:**
- Delete: 25 test files (full list below)

- [ ] **Step 1: Final review of the deletion list**

```bash
ls tests/test_consult_acceptance_tests_validate.sh \
   tests/test_consult_dag_validate.sh \
   tests/test_consult_design_doc_assemble_hub.sh \
   tests/test_consult_design_doc_mode_toggle_warn.sh \
   tests/test_consult_detect_hub_bare_child.sh \
   tests/test_consult_detect_hub_empty.sh \
   tests/test_consult_detect_hub_mixed.sh \
   tests/test_consult_detect_hub_single.sh \
   tests/test_consult_detect_hub_subrepo.sh \
   tests/test_consult_detect_hub_super.sh \
   tests/test_consult_directive_active_subproject_wired.sh \
   tests/test_consult_directive_extract_targets_wired.sh \
   tests/test_consult_directive_hub_mode.sh \
   tests/test_consult_drilldown_prompt_subproject.sh \
   tests/test_consult_extract_targets_from_topic.sh \
   tests/test_consult_findings_active_subproject.sh \
   tests/test_consult_findings_conformance_metric.sh \
   tests/test_consult_init_persists_hub_mode.sh \
   tests/test_consult_research_prompt_with_targets.sh \
   tests/test_consult_targets_persist.sh \
   tests/test_consult_targets_to_header_pair.sh \
   tests/test_consult_v011_dogfood.sh \
   tests/test_consult_validators_dag_warn_when_absent.sh \
   tests/test_consult_verify_prompt_with_targets.sh \
   tests/test_consult_xrepo_deps_validate.sh
```

Expected: all 25 files exist (the `ls` lists them with no errors).

- [ ] **Step 2: Delete via git rm**

```bash
git rm tests/test_consult_acceptance_tests_validate.sh \
       tests/test_consult_dag_validate.sh \
       tests/test_consult_design_doc_assemble_hub.sh \
       tests/test_consult_design_doc_mode_toggle_warn.sh \
       tests/test_consult_detect_hub_bare_child.sh \
       tests/test_consult_detect_hub_empty.sh \
       tests/test_consult_detect_hub_mixed.sh \
       tests/test_consult_detect_hub_single.sh \
       tests/test_consult_detect_hub_subrepo.sh \
       tests/test_consult_detect_hub_super.sh \
       tests/test_consult_directive_active_subproject_wired.sh \
       tests/test_consult_directive_extract_targets_wired.sh \
       tests/test_consult_directive_hub_mode.sh \
       tests/test_consult_drilldown_prompt_subproject.sh \
       tests/test_consult_extract_targets_from_topic.sh \
       tests/test_consult_findings_active_subproject.sh \
       tests/test_consult_findings_conformance_metric.sh \
       tests/test_consult_init_persists_hub_mode.sh \
       tests/test_consult_research_prompt_with_targets.sh \
       tests/test_consult_targets_persist.sh \
       tests/test_consult_targets_to_header_pair.sh \
       tests/test_consult_v011_dogfood.sh \
       tests/test_consult_validators_dag_warn_when_absent.sh \
       tests/test_consult_verify_prompt_with_targets.sh \
       tests/test_consult_xrepo_deps_validate.sh
```

- [ ] **Step 3: Run full test suite**

```bash
bash tests/run.sh 2>&1 | tail -30
```

Expected: ALL TESTS GREEN. If any fail, root-cause + fix in this task before proceeding.

- [ ] **Step 4: Commit**

```bash
git commit -m "test: delete 25 hub-mode + validator test files (v0.14.0)"
```

---

### Task 12: Final grep sweep

**Files:** none modified — verification only.

- [ ] **Step 1: Watchlist grep**

```bash
grep -rn 'HUB_MODE\|hub-mode\|cw_consult_detect_hub\|cw_consult_targets_persist\|cw_consult_targets_load\|cw_consult_hub_mode_load\|cw_consult_extract_targets_from_topic\|cw_consult_findings_active_subproject\|consult-hub\|consult-validators\|CW_CONSULT_TARGETS\|targets\.txt' commands/ bin/ lib/ tests/ 2>/dev/null
```

Expected: zero matches across `commands/`, `bin/`, `lib/`. Test directory may have a few false-positives in unrelated tests — acceptable as long as they're not asserting hub behavior.

If any non-trivial matches surface, route back to the appropriate prior task and fix.

- [ ] **Step 2: Sanity grep on docs (informational only)**

```bash
grep -rn 'HUB_MODE\|hub-mode' docs/ 2>/dev/null | grep -v 'specs/2026-05-07-consult-spec-hub-removal-design'
```

Document hits in older specs are fine — those are historical artifacts, not live wiring.

- [ ] **Step 3: No commit needed (verification task)**

---

### Task 13: Version bump + CLAUDE.md status

**Files:**
- Modify: `.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Bump plugin.json**

```bash
sed -i 's/"version": "0.13.0"/"version": "0.14.0"/' .claude-plugin/plugin.json
grep version .claude-plugin/plugin.json
```

Expected: `"version": "0.14.0"`.

- [ ] **Step 2: Bump marketplace.json**

```bash
grep -n version .claude-plugin/marketplace.json
```

Manually edit any version field referencing 0.13.0 → 0.14.0. (Schema may have multiple version pins.)

- [ ] **Step 3: Add CLAUDE.md status entry**

Open `CLAUDE.md`. After the v0.13.0 dogfood line, insert:

```markdown
- [x] v0.14.0: hub-mode removal — /consult and /spec are single-context (invoked at the cwd to investigate); trooper inherits cwd via tmux split-window -c and reads CLAUDE.md/AGENTS.md from there. Deleted: lib/consult-hub.sh, lib/consult-validators.sh, 25 hub/validator test files. Renamed: cw_consult_design_doc_resume_state → cw_spec_resume_state in new lib/spec.sh. /deploy Target Sub-Project: redirect preserved (separate mechanism).
- [ ] v0.14.0 strict-dogfood pass on a real machine (release gate)
```

- [ ] **Step 4: Run tests one more time**

```bash
bash tests/run.sh 2>&1 | tail -20
```

Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json CLAUDE.md
git commit -m "chore(release): bump plugin to v0.14.0; record hub-mode removal status"
```

---

### Task 14: Dogfood validation (release gate)

**Files:** none modified — empirical validation.

- [ ] **Step 1: Pick a small consult topic**

Any 1-2 sentence topic that exercises a single repo. Example: "When should bash scripts use mapfile vs read-loops for line-by-line input?"

- [ ] **Step 2: Run /clone-wars:medic**

In a Claude Code session inside this repo:

```
/clone-wars:medic
```

Expected: Verdict OK.

- [ ] **Step 3: Run /clone-wars:consult**

```
/clone-wars:consult When should bash scripts use mapfile vs read-loops for line-by-line input?
```

Expected: full happy-path completion (no Step 0.5 / Step 1.5 mention in the trace, no `hub-mode.txt` written, no `targets.txt` written, no per-sub-project prompt structure block in identity-injected prompts).

Verify post-run:

```bash
ls ~/.clone-wars/state/$(bash -c 'cd ~/CC/clone-wars && source lib/state.sh && cw_repo_hash')/*/_consult/
```

Expected files: `topic.txt`, `synthesis.md`, the per-trooper subdirs. NO `hub-mode.txt`. NO `targets.txt`.

- [ ] **Step 4: Run /clone-wars:spec on the resulting synthesis**

```
/clone-wars:spec
```

(Source-defaults to the most recent synthesis.)

Expected: 5-section flat design doc; `cw_spec_resume_state` works on a partial walk if interrupted.

- [ ] **Step 5: Update CLAUDE.md gate**

Flip:

```markdown
- [ ] v0.14.0 strict-dogfood pass on a real machine (release gate)
```

to:

```markdown
- [x] v0.14.0 strict-dogfood pass on a real machine (2026-05-07): /consult ran clean (no hub-mode.txt, no targets.txt); /spec produced flat 5-section spec; cw_spec_resume_state verified on resume.
```

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude): record v0.14.0 dogfood pass"
```

- [ ] **Step 7: Open PR (if controller is the dispatcher)**

```bash
gh pr create --base main --title "v0.14.0: remove hub-mode from consult + spec" --body "$(cat <<'EOF'
## Summary
- Delete hub-mode awareness from /clone-wars:consult and /clone-wars:spec
- Both commands become single-context: invoke at the cwd to investigate; trooper inherits cwd
- Move cw_consult_design_doc_resume_state → lib/spec.sh::cw_spec_resume_state
- Preserve /deploy Target Sub-Project: redirect (separate mechanism)
- Bump 0.13.0 → 0.14.0

## Net change
- Delete: 2 lib files, 25 test files, ~250 directive lines, ~530 lib lines
- Create: 1 lib file (lib/spec.sh)

## Test plan
- [x] Pre-deletion baseline: tests/run.sh green
- [x] Per-task: tests/run.sh re-run, kept green throughout
- [x] Final grep sweep: zero hub-mode hits in commands/bin/lib
- [x] Dogfood: /consult + /spec on a small topic, no hub-mode.txt or targets.txt written, flat 5-section spec output

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-review

Spec coverage check:
- ✅ Hub-mode classification removal → Task 6 (init) + Task 8 (lib shim)
- ✅ Picker (Step 1.5) removal → Task 3
- ✅ Per-sub-project structure block → Task 5
- ✅ Active-subproject context slicing → Task 3 (Steps 6-7)
- ✅ Validators (DAG/xrepo-deps/acceptance-tests) → Task 7 (assemble) + Task 9 (lib delete) + Task 11 (test delete)
- ✅ Renames (resume helper) → Task 2
- ✅ Test deletions (25 files) → Task 11
- ✅ Surgical test edits → Task 10
- ✅ Version bump → Task 13
- ✅ CLAUDE.md status → Task 13 + 14
- ✅ Dogfood gate → Task 14

Type consistency:
- `cw_spec_resume_state` introduced in Task 2, referenced in Task 14 dogfood Step 4 — consistent.
- 25-file deletion list matches between spec and Task 11.

Placeholder scan:
- No "TBD"/"TODO"/"add appropriate"/"similar to" patterns.
- Each step has actual commands or actual code.
- Final dogfood task uses real bash patterns (the `cw_repo_hash` invocation is the canonical way to derive the repo hash).
