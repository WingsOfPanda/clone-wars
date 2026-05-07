# Consult/Spec Hub-Mode Removal Design (v0.14.0)

**Status:** approved (brainstorming → writing-plans handoff)
**Author:** liupan + Master Yoda
**Date:** 2026-05-07

## Summary

Delete hub-mode awareness from `/clone-wars:consult` and `/clone-wars:spec`
entirely. Both commands become single-context: invoked at the working directory
the user wants investigated/specified. Troopers inherit that cwd via
`tmux split-window -c` and read `CLAUDE.md` / `AGENTS.md` from there to learn
project structure on their own.

`/clone-wars:deploy`'s `Target Sub-Project:` redirect is preserved — that
mechanism is genuinely useful (lets the conductor stay in a hub while a
trooper works in a leaf) and operates independently of consult/spec hub-mode.

No back-compat. v0.13.x and earlier consult/spec runs that produced
`hub-mode.txt` / `targets.txt` are silently ignored on v0.14.0 — `/spec` walks
the synthesis as a flat 5-section design doc regardless of archived markers.

## Motivation

The hub-mode infrastructure (added in v0.10/v0.11) was scaffolded around a
mental model where consult ran *outside* the leaves it was investigating, so
the conductor needed an explicit picker + per-sub-project structure-block in
prompts to scope the investigation correctly. The compensating sections in
spec output (DAG, xrepo-deps, acceptance-tests) existed to document
relationships the conductor couldn't otherwise observe.

Once you adopt the principle "invoke the command at the location you want
worked," all of that scaffolding becomes overhead:

- Trooper's `pwd` = the location of interest. `CLAUDE.md`/`AGENTS.md` walk it
  through structure naturally.
- The picker is an extra friction point (8 archived consult runs on the dev
  machine; only ~3 ever exercised the picker).
- The validators (`consult-validators.sh`, 282 lines) only execute against
  multi-section spec outputs the user didn't ask for.
- Per-sub-project context slicing in question loops compensates for findings
  the trooper would have organized correctly anyway if invoked at the right
  cwd.

Net deletion: ~530 lib lines, ~250 directive lines, ~25 test files. Net add:
1 lib file (`lib/spec.sh`) housing the renamed resume helper.

## Scope

### Removed entirely
- Hub-mode classification (`single-repo` / `hub-subrepo` / `super-hub`)
- Auto-target inference from topic prose (KEYWORD_ALL, inferred-leaves prelude)
- Leaf picker (`Step 1.5` of `/consult`)
- Per-sub-project structure-block injection in research/verify prompts
- Active-subproject context slicing in question-loops (Steps 3 + 5)
- DAG / xrepo-deps / acceptance-tests validators
- The 3 hub-only sections in spec output (DAG / xrepo-deps / acceptance-tests)
- `CW_CONSULT_TARGETS` env-var threading
- `_consult/hub-mode.txt` and `_consult/targets.txt` writes

### Preserved
- `Target Sub-Project:` header in design docs → `bin/deploy-init.sh` sub-repo
  redirect (deploy-side, untouched)
- Flat 5 sections in spec output: `architecture` / `components` / `data-flow`
  / `error-handling` / `testing`
- Drilldown loop in `/consult` Step 8.4 (hub-agnostic; topic prose carries any
  sub-project framing)
- Spawn-rollback runbook, question-loop, FS=/VS= state machine — all
  hub-agnostic already
- All other commands (`/medic`, `/list`, `/teardown`, `/deploy`)

### Renamed
- `lib/consult.sh::cw_consult_design_doc_resume_state` →
  `lib/spec.sh::cw_spec_resume_state`
- Test files prefixed `test_consult_design_doc_*` that survive should be
  renamed `test_spec_*` to match the v0.12.0 directive split (cosmetic; can
  defer to a follow-up if it complicates the diff)

## Files affected

### Delete (lib + bin)
- `lib/consult-hub.sh` — all 6 hub helpers
- `lib/consult-validators.sh` — DAG / xrepo-deps / acceptance-tests validators

### Delete (tests, 22 files)
```
test_consult_acceptance_tests_validate.sh
test_consult_dag_validate.sh
test_consult_design_doc_assemble_hub.sh
test_consult_design_doc_mode_toggle_warn.sh
test_consult_detect_hub_bare_child.sh
test_consult_detect_hub_empty.sh
test_consult_detect_hub_mixed.sh
test_consult_detect_hub_single.sh
test_consult_detect_hub_subrepo.sh
test_consult_detect_hub_super.sh
test_consult_directive_active_subproject_wired.sh
test_consult_directive_extract_targets_wired.sh
test_consult_directive_hub_mode.sh
test_consult_drilldown_prompt_subproject.sh
test_consult_extract_targets_from_topic.sh
test_consult_findings_active_subproject.sh
test_consult_findings_conformance_metric.sh
test_consult_init_persists_hub_mode.sh
test_consult_research_prompt_with_targets.sh
test_consult_targets_persist.sh
test_consult_targets_to_header_pair.sh
test_consult_v011_dogfood.sh
test_consult_validators_dag_warn_when_absent.sh
test_consult_verify_prompt_with_targets.sh
test_consult_xrepo_deps_validate.sh
```
(25 files; final list locked during plan phase via
`grep -rl 'hub\|TARGETS\|consult-hub\|consult-validators' tests/`)

### Modify
| File | Changes |
|---|---|
| `lib/consult.sh` | Remove hub parsers; remove the 3-way sourcing shim that pulls in `consult-hub.sh` + `consult-validators.sh`; **extract** `cw_consult_design_doc_resume_state` → `lib/spec.sh::cw_spec_resume_state` |
| `lib/consult-prompts.sh` | Drop per-sub-project structure block from `cw_consult_build_research_prompt` + `cw_consult_build_verify_prompt`; drop `CW_CONSULT_TARGETS` env branches |
| `bin/consult-init.sh` | Remove hub-mode classification + `hub-mode.txt` write |
| `bin/consult-research-send.sh` | Drop `CW_CONSULT_TARGETS` env handling |
| `bin/consult-verify-send.sh` | Drop `CW_CONSULT_TARGETS` env handling |
| `bin/spec-assemble.sh` | Drop validator invocations; always assemble flat 5-section output |
| `bin/spec-init.sh` | Drop hub-mode read if present (verify in plan phase) |
| `commands/consult.md` | Remove Step 0.5 + Step 1.5; strip hub branches from Step 3/5 question-loop slicing; strip `CW_CONSULT_TARGETS` plumbing from Step 2/5; trim task list |
| `commands/spec.md` | Remove `HUB_MODE != single-repo` branch in Step 2 (always 5 sections); drop hub-mode read in Step 1; drop validator-failure handling in Step 3 |
| `tests/test_consult_init.sh` | Drop `hub-mode.txt` write assertions |
| `tests/test_consult_prompts.sh` | Drop hub-mode prompt assertions |
| `tests/test_consult_lib_shim_sources_all.sh` | Update for removed libs |
| `tests/test_consult_question_loop.sh` | Drop hub-mode branch assertions if any |
| `.claude-plugin/plugin.json` | `version: 0.13.0` → `0.14.0` |
| `.claude-plugin/marketplace.json` | Same |
| `CLAUDE.md` | Add `v0.14.0: hub-mode removal from consult/spec` status entry |

### Create
| File | Contents |
|---|---|
| `lib/spec.sh` | `cw_spec_resume_state` (renamed from `cw_consult_design_doc_resume_state`); future spec-only helpers land here |
| `docs/superpowers/specs/2026-05-07-consult-spec-hub-removal-design.md` | This spec |
| `docs/superpowers/plans/2026-05-07-consult-spec-hub-removal-plan.md` | Implementation plan (next step) |

### Untouched
- `lib/deploy.sh` (`cw_deploy_resolve_target` reads `Target Sub-Project:`)
- `bin/deploy-init.sh`, `bin/spawn.sh`, `bin/teardown.sh`, `bin/medic.sh`
- All `commands/{deploy,medic,list,teardown}.md`
- `lib/{ipc,tmux,state,deps,argsfile,log,colors,opencode_preflight,...}.sh`

## Test plan

1. **Pre-deletion baseline.** `bash tests/run.sh` on current `main` to confirm
   green starting point.
2. **Per-deletion sanity.** After each `git rm` of a hub test file, re-run
   `tests/run.sh` to ensure the deletion doesn't break unrelated tests.
3. **Per-modify regression.** After each lib/bin/directive edit, re-run
   `tests/run.sh` and the directly-affected per-file test.
4. **End-to-end dogfood (release gate).** A real `/clone-wars:consult` run on
   a small topic in this repo (single repo, no hub-mode in scope), followed by
   `/clone-wars:spec` against the produced synthesis. Confirm:
   - No `hub-mode.txt` written
   - No `targets.txt` written
   - Spec output has exactly 5 sections (no DAG/xrepo-deps/acceptance-tests)
   - `cw_spec_resume_state` works for resume on a partial /spec walk
5. **Archive cleanup.** Wipe stale `~/.clone-wars/state/*` and
   `~/.clone-wars/archive/*` entries from prior test runs (user authorized
   this in the brainstorming session).

## Risks + rollback

**Risk: tests/test_consult_lib_shim_sources_all.sh** asserts the 3-way split
sourcing chain works. If we forget to update it, the test will FAIL after
deletion. Mitigation: this test is in the explicit "modify" list; the plan
phase task that deletes the lib files MUST also update this test in the same
commit.

**Risk: hidden hub-mode references in commands/consult.md** that I miss in
the directive edit pass. Mitigation: post-edit grep for `HUB_MODE`,
`hub-mode`, `cw_consult_detect_hub`, `targets.txt`, `CW_CONSULT_TARGETS`,
`consult-validators`, `consult-hub`, `findings_active_subproject` across
`commands/`, `bin/`, `lib/`, `tests/`. Zero hits = clean.

**Rollback:** single PR, git revert if a regression surfaces post-merge.
v0.13.0 stays installable from the marketplace history; users can pin if they
need hub-mode back (no one will).

## Versioning + cleanup

- Bump plugin to `v0.14.0` (breaking: deletes hub-mode flow that previous
  versions exposed)
- CLAUDE.md status block gets:
  - `[x] v0.14.0: hub-mode removal — /consult and /spec are single-context;`
    `Target Sub-Project: header (deploy-only) preserved; bumps closed-set 4 → 4`
    `(no provider change)`
- Optional follow-up (low priority): rename `test_consult_design_doc_*` test
  files that survive to `test_spec_*` for naming consistency with v0.12.0
  directive split. Not blocking v0.14.0 release.

## Out of scope

- `/clone-wars:deploy` changes
- Provider changes (closed-set still 4: claude/codex/gemini/opencode)
- Any change to `bin/spawn.sh` / IPC contract / identity template
- Migration tool to convert old hub-mode archives — explicitly chose
  silent-ignore (option a in brainstorming Q2)

## Acceptance

- All tests in `tests/run.sh` pass (with the deletion list applied)
- A clean `/consult` + `/spec` run produces a 5-section flat design doc
- Zero grep hits for the watch-list strings under `commands/`, `bin/`, `lib/`,
  `tests/`
- `bin/medic.sh` exits OK on a clean repo
