# /clone-wars:consult v0.11 — Hub Mode Design

**Date:** 2026-05-04
**Status:** Draft
**Owner:** liupan

## Goal

Extend `/clone-wars:consult` so that, when invoked from a hub repo (one
that coordinates multiple sub-repos) or a super-hub repo (a hub of hubs),
the resulting design doc declares its target sub-projects, exposes a strict
**Execution DAG**, surfaces **Cross-Repo Dependencies**, and tags every
acceptance test with the Step it belongs to — producing an artifact that a
future v0.11 `/clone-wars:deploy` (or today's `/executeorder66`) can split
into per-Step plans without further interactive design work.

Single-repo consult runs remain byte-identical to v0.10. The hub-mode track
is gated entirely on hub detection at Step 0.

## Why

The existing consult output is a flat single-repo design doc. For multi-repo
work the user currently has to (a) run consult to get research + synthesis,
(b) hand-edit the spec to add header lines, DAG, and per-repo dependency
tables in the shape `/executeorder66`'s template requires. That hand-edit
step is the friction this spec removes — Yoda walks the DAG, Cross-Repo
Deps, and tagged tests interactively from the troopers' findings, and emits
a deploy-ready spec.

This is also the prerequisite for v0.12 `/clone-wars:deploy` multi-target
support: deploy can't dispatch DAG-batched troopers without a spec that
declares the DAG. Authoring the DAG in deploy would re-do consult's job.

## Architecture

`/clone-wars:consult` v0.11 adds a hub-mode track alongside the existing
single-repo track. The two tracks share the same 13-step pipeline (research
→ diff → verify → adjudicate → synthesize → optional design-doc walk →
teardown → archive). Hub-mode only changes:

1. **Hub detection at Step 0**: `cw_consult_detect_hub` (extended) classifies
   cwd as `single-repo`, `hub-subrepo`, or `super-hub`. Mode persists in
   `_consult/hub-mode.txt`.
2. **Target selection at Step 2 prelude**: in hub mode, an AskUserQuestion
   (or two-step for super-hub) chooses the leaf sub-projects + their hubs.
   Selection persists in `_consult/targets.txt` as `<hub>/<leaf>` lines.
3. **Trooper prompt scope-widening**: research and verify prompts include
   the targets list so both troopers structure their `findings.md` with
   `## <sub-project>` sub-sections covering each chosen leaf.
4. **Design-doc walk in hub mode**: the per-section walk is augmented with a
   per-sub-project drill axis, and three new sections get authored:
   **Execution DAG**, **Cross-Repo Dependencies**, and (renamed) **Acceptance
   Tests** with `**Step N**` tags.
5. **Spec assembly in hub mode**: `cw_consult_design_doc_assemble` prepends
   the `**Target Hub(s):**` + `**Target Sub-Project(s):**` headers and
   inserts the DAG / Cross-Repo Deps / tagged-tests blocks at canonical
   positions matching `~/.claude/templates/design-doc.md`.

Single-repo runs are byte-identical to v0.10 — no DAG block, no Cross-Repo
Deps, no Step tags. The hub-mode code paths are gated on
`hub-mode.txt != "single-repo"`.

Trooper spawn point is unchanged: both troopers spawn at the conductor's cwd
(the hub or super-hub root). They navigate sub-repos via absolute paths from
there. Coding only ever lands in leaf sub-repos; hubs are pure coordinators.

## Components

### New / changed lib helpers (`lib/consult.sh`)

| Helper | Status | Purpose |
|---|---|---|
| `cw_consult_detect_hub <cwd>` | **modified** | Returns 3-line stdout: `MODE=<single-repo\|hub-subrepo\|super-hub>`, `HUBS=<comma-list>` (only if super-hub), `LEAVES=<comma-list of <hub>/<leaf>>`. Backward-compat: `single-repo` mode rc=1; `hub-subrepo` and `super-hub` rc=0. |
| `cw_consult_hub_mode_persist <art-dir> <mode>` | new | Atomic-writes `<art-dir>/hub-mode.txt`. |
| `cw_consult_hub_mode_load <art-dir>` | new | Echoes mode (`single-repo` if file missing). |
| `cw_consult_targets_persist <art-dir>` | new | Reads stdin (`<hub>/<leaf>` lines), atomic-writes `<art-dir>/targets.txt`. Validates each line matches `^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$`. |
| `cw_consult_targets_load <art-dir>` | new | Echoes targets one per line; rc=1 if file missing or empty. |
| `cw_consult_targets_to_header_pair <art-dir>` | new | Reads `targets.txt`, emits two lines: `**Target Hub(s):** <comma-hubs>` and `**Target Sub-Project(s):** <comma-leaves>` for spec-assembly insertion. |
| `cw_consult_dag_validate <art-dir>` | new | Reads stdin (the `## Execution DAG` body). Parses strict grammar, runs Kahn topological sort, rejects cycles + unknown step refs + repos outside `targets.txt`'s leaf set. Emits `OK` or `ERROR: <reason>` to stderr; rc=0/1. |
| `cw_consult_xrepo_deps_validate <art-dir>` | new | Reads stdin (pipe-table body). Validates header row + 4 columns + Type ∈ {internal, external} + producer/consumer references valid (internal must be in targets.txt). |
| `cw_consult_acceptance_tests_validate <art-dir>` | new | Reads stdin (`## Acceptance Tests` body). Validates each entry starts `**Step N** [<sub-project>]` and references a Step that exists in the DAG. |
| `cw_consult_design_doc_assemble` | **modified** | New optional 6th arg `<targets-path>`. When non-empty, prepends header pair after the H1; inserts `## Execution DAG` after `## Design`-equivalent sections; inserts `### Cross-Repo Dependencies` under DAG; renames `## Testing` to `## Acceptance Tests` (entries already tagged `**Step N**` from the author phase). |
| `cw_consult_design_doc_drilldown_prompt` | **modified** | Optional 6th arg `<sub-project-name>`. When set, prompt instructs trooper to drill into `<section> for <sub-project>`. Output path becomes `_scratch/drilldown-<section-slug>-<sub-project>-<commander>.md`. |

### New bin scripts

None. All new logic lives in `lib/consult.sh` + the `commands/consult.md`
directive Step 0, Step 2 prelude, and Step 8.5.

### Modified bin scripts

| Script | Change |
|---|---|
| `bin/consult-init.sh` | Calls `cw_consult_detect_hub` after creating `_consult/`, persists `hub-mode.txt`. No change to topic-state path keying. |
| `bin/consult-design-doc.sh` | When `targets.txt` exists, passes it to `cw_consult_design_doc_assemble` and runs the three new validators before commit. Self-review extended to fail on missing DAG / Cross-Repo Deps / tagged-tests blocks when in hub mode. |

### Modified prompt templates (`config/prompt-templates/consult/`)

| Template | Change |
|---|---|
| `research.md` | New `{{TARGETS}}` placeholder. When non-empty, appends a "Per-sub-project structure" instruction telling the trooper to organize `findings.md` with `## <sub-project>` subsections covering each named leaf. |
| `verify.md` | New `{{TARGETS}}` placeholder. Same per-sub-project structuring instruction for `verify.md`. |
| `drilldown.md` | New optional `{{SUBPROJECT}}` placeholder. When set, prompt scope narrows to that sub-project within the section; output path includes the sub-project slug. |

### Directive (`commands/consult.md`)

| Step | Change |
|---|---|
| 0 | After `consult-init.sh` returns, source `lib/consult.sh`, call `cw_consult_detect_hub "$(pwd)"`, persist mode. Single-repo mode is unchanged from v0.10. |
| 2 (research dispatch prelude) | When `hub-mode.txt != "single-repo"`, run target-selection AskUserQuestion(s) BEFORE research-send (so the prompts can include `TARGETS=<csv>`). Persist via `cw_consult_targets_persist`. |
| 3 (research wait) | No change. |
| 5 (verify dispatch) | Pass `TARGETS=<csv>` to verify-send when `targets.txt` exists. |
| 8.5 (design-doc walk) | New per-sub-project drill option in the trooper-choice AskUserQuestion (rex / cody / both / **per-sub-project drill**). After the existing 5 sections, three new sections get their own per-section walks: **Execution DAG**, **Cross-Repo Dependencies**, **Acceptance Tests**. Each follows the existing draft → AskUserQuestion (Approve/Revise/Drill/Skip) pattern. |

### State files (per topic)

| File | Notes |
|---|---|
| `_consult/hub-mode.txt` | new — `single-repo` / `hub-subrepo` / `super-hub` |
| `_consult/targets.txt` | new — `<hub>/<leaf>` lines, only when hub-mode |
| `_consult/design-doc/dag.md` | new section file — same shape as `architecture.md` etc. |
| `_consult/design-doc/xrepo-deps.md` | new section file |
| `_consult/design-doc/acceptance-tests.md` | new section file (replaces `testing.md` in hub mode; single-repo keeps `testing.md`) |

## Data Flow

### Hub-mode entry (Step 0)

```
conductor cwd ──► cw_consult_detect_hub
                       │
                       ├─► single-repo (rc=1) ──► hub-mode.txt = "single-repo" ─► proceed v0.10 path
                       ├─► hub-subrepo (rc=0)  ──► hub-mode.txt = "hub-subrepo"
                       │                          HUBS=<self>
                       │                          LEAVES=<self>/<leaf1>, <self>/<leaf2>, ...
                       └─► super-hub   (rc=0)  ──► hub-mode.txt = "super-hub"
                                                 HUBS=<hub1>, <hub2>, ...
                                                 LEAVES=<hub1>/<leaf>, <hub2>/<leaf>, ...
```

### Target selection (Step 2 prelude, hub-mode only)

```
hub-subrepo:
  AskUserQuestion("Which sub-projects?", multi-select, options=LEAVES)
    └─► chosen leaves ─► cw_consult_targets_persist ─► targets.txt

super-hub:
  AskUserQuestion("Which hubs?", multi-select, options=HUBS)
    └─► chosen hubs
        └─► AskUserQuestion("Which leaves?", multi-select, options=LEAVES filtered to chosen hubs)
            └─► cw_consult_targets_persist ─► targets.txt
```

`targets.txt` after persistence (example, super-hub):

```
ars_fleet/ARS-TaskServe
ars_fleet/ARS-LVMGateway
ars_lab/ARS-Foo
```

### Research dispatch (Step 2, modified)

```
TARGETS=$(cw_consult_targets_load $ART_DIR | tr '\n' ',' | sed 's/,$//')

consult-research-send.sh $CONSULT_TOPIC rex codex
  └─► cw_consult_load_prompt(consult/research.md, TOPIC=..., WRITE_TO=..., TARGETS=$TARGETS)
  └─► trooper inbox.md → trooper writes findings.md with `## <leaf1>`, `## <leaf2>`, ...
```

Same for `cody claude`. Both troopers structure findings per-sub-project.

`findings.md` shape (hub mode):

```markdown
## Findings

### ars_fleet/ARS-TaskServe
1. [src/registry.py:42] ...

### ars_fleet/ARS-LVMGateway
1. [src/dispatcher.py:118] ...

### ars_lab/ARS-Foo
1. [src/foo.py:7] ...
```

Single-repo mode: no `TARGETS` placeholder substituted (template's
`{{TARGETS}}` resolves to empty), no per-sub-project structure instruction
emitted. Backward-compatible.

### Diff + verify (Steps 4-5)

The existing per-claim citation-overlap diff already keys on citation
strings (`<file>:<line>`), not on heading structure. Per-sub-project
sub-sections in `findings.md` don't break parsing because
`cw_consult_parse_claims` walks the `## Claims` block, and we'll keep that
same heading at hub-mode top level (the per-sub-project headings sit
*inside* the `## Findings` parent — the parser still finds claims by
`^[0-9]+\.` lines). Verify dispatch is unchanged in shape; the `TARGETS`
placeholder propagates so the verify trooper structures `verify.md`
similarly.

### Adjudicate + synthesize (Steps 6-8)

Unchanged. Yoda's adjudication, PENDING resolution, and synthesis already
operate per-claim, not per-sub-project. The synthesis report's "Trooper
artifacts" pointers stay accurate.

### Design-doc walk (Step 8.5, hub mode extension)

Section list expands from 5 to 8:

```
[1] Architecture
[2] Components
[3] Data Flow
[4] Error Handling
[5] Testing                  ← in single-repo this stays "Testing";
                                in hub-mode it becomes "Acceptance Tests" with tagged entries
[6] Execution DAG            ← hub-mode only
[7] Cross-Repo Dependencies  ← hub-mode only
```

Per-section loop (existing draft → AskUserQuestion approve/revise/drill/skip)
runs the same for each.

When user picks **Drill deeper** in hub-mode, the trooper-choice
AskUserQuestion adds an axis:

```
1. rex (codex)
2. cody (claude)
3. both (parallel)
4. ────────────────────────
5. rex on <leaf1>
6. cody on <leaf1>
7. both on <leaf1>
   ... (one row per leaf)
```

Drill output path: `_scratch/drilldown-<section-slug>-<sub-project>-<commander>.md`
when sub-project axis is chosen; falls back to existing
`_scratch/drilldown-<section-slug>-<commander>.md` for global drills.

### Spec assembly (Step 8.5 finalize)

```
cw_consult_design_doc_assemble \
   $DD_DIR \
   $OUT_PATH \
   $TITLE \
   $TOPIC_TEXT \
   $SYNTHESIS_PATH \
   $TARGETS_PATH      ← new 6th arg

  output structure (hub mode):
    # <Title>
    **Date:** YYYY-MM-DD
    **Status:** Draft
    **Target Hub(s):** <comma-hubs>          ← from cw_consult_targets_to_header_pair
    **Target Sub-Project(s):** <comma-leaves>
    **Goal:** ...
    **Architecture:** ...
    **Tech Stack:** ...
    ---
    ## Architecture
    ...
    ## Components
    ## Data Flow
    ## Error Handling
    ## Acceptance Tests        ← renamed; entries already tagged **Step N** [<sub-project>]
    ## Execution DAG
    ## Cross-Repo Dependencies
```

For single-repo (no `targets.txt`): assembly emits the v0.10-shape doc
unchanged.

### Self-review + commit (Step 8.5 finalize, modified)

`cw_consult_design_doc_self_review` (existing) + three new validators in
hub mode:

```
cw_consult_dag_validate < ${DD_DIR}/dag.md
cw_consult_xrepo_deps_validate < ${DD_DIR}/xrepo-deps.md
cw_consult_acceptance_tests_validate < ${DD_DIR}/acceptance-tests.md
```

Failure → re-enter the offending section's per-section walk for revision;
rerun on next assemble. Loop until clean or user aborts.

After clean review + commit, teardown + archive (existing flow) →
user-review gate.

## Error Handling

### Hub detection failures (Step 0)

| Failure | Behavior |
|---|---|
| `cw_consult_detect_hub` errors (e.g. cwd not readable) | Log warning, fall back to `single-repo` mode. Consult continues v0.10 path. |
| Detector classifies `super-hub` but a hub child has zero leaf sub-repos | Skip that hub from the AskUserQuestion options. If all hubs are empty, fall back to single-repo with a log note. |
| User picks zero options in target-selection AskUserQuestion | Re-prompt once. Second empty selection → `AskUserQuestion("No targets chosen. Continue as single-repo / Abort?")`. Continue → write `hub-mode.txt = "single-repo"`, drop targets.txt, proceed v0.10 path. Abort → teardown + archive + exit. |
| `targets.txt` validation fails (slug regex) | Hard fail before research dispatch — log the offending line, archive `_consult/`, exit 1. |
| Immediate git child has no subdirectories (bare git repo) | Skip the child with `log_warn`; classification proceeds without it. Bare repos can't carry meaningful targets. |

### Trooper findings without per-sub-project structure (hub mode)

The `TARGETS=<csv>` placeholder makes the per-sub-project structure an
*instruction*, not a contract enforced by the parser. If a trooper ignores
it and writes a flat `## Findings` block:

| Detection | Behavior |
|---|---|
| `findings.md` has `^### ` heading matching no leaf in `targets.txt` | Log warning, parse anyway (existing claim regex is heading-agnostic). Cross-verify still runs. |
| `findings.md` has zero `^### <leaf>` sub-headings in hub mode | Log warning, banner the synthesis with `> NOTE: <commander> findings not structured per-sub-project — verify coverage manually.` Continue. |

We do NOT re-prompt the trooper — that doubles the research cost and the
existing claim-level cross-verify already catches divergence.

### DAG validator failures (Step 8.5 finalize)

`cw_consult_dag_validate` failure modes, each surfaced to stderr via
`ERROR: <reason>`:

| Failure mode | Re-entry point |
|---|---|
| Free-form prose between Step blocks | Re-enter `## Execution DAG` per-section walk; show user the offending lines. |
| Step references unknown earlier id | Same — show `Step <N> depends on Step <M> which doesn't exist`. |
| Cycle detected | Same — show the cycle edges. |
| Step `<repo>` not in `targets.txt` leaf set | Same — show `Step <N>: <repo> — '<repo>' not in targets`. |
| Empty DAG (no Step blocks) | Same — re-enter walk. |

Validator runs at finalize, not during the per-section walk. Walk produces
the draft text; validator gates the commit. Failure → rerun walk for that
section only → re-validate. No retry cap; user can abort at any
AskUserQuestion turn.

### Cross-Repo Deps validator failures

Same re-entry pattern. Specific errors:

| Failure | Message |
|---|---|
| Header row missing or wrong columns | `xrepo-deps.md must have header: \| Producer \| Artifact \| Consumer \| Type \|` |
| Type ∉ {internal, external} | `row N: Type='<x>' must be 'internal' or 'external'` |
| internal Producer not in `targets.txt` | `row N: Producer '<p>' marked internal but not in targets` |
| internal Consumer not in `targets.txt` | Same shape |

### Acceptance-tests validator failures

| Failure | Message |
|---|---|
| Entry missing `**Step N**` prefix | `entry N: missing **Step <id>** tag` |
| Entry missing `[<sub-project>]` | `entry N: missing [sub-project] tag` |
| Tag references Step not in DAG | `entry N: tagged **Step <id>** which doesn't exist in DAG` |
| Tag references sub-project not in `targets.txt` | `entry N: tagged [<repo>] which isn't in targets` |

DAG validator must run **before** acceptance-tests validator (the latter
cross-references DAG step ids). Order:

1. DAG validator
2. Cross-Repo Deps validator
3. Acceptance-tests validator

Sequential; first failure halts and re-enters that section's walk.

### Bootstrap target attempt (deferred per Section 1 decision)

If during the per-section walk the user types `[new]` against a sub-project
name in any of: target-selection, DAG step, Cross-Repo Deps, or acceptance
test:

| Detection | Behavior |
|---|---|
| `[new]` annotation appears in any draft section text | Validator fails with `bootstrap targets ([new]) not supported in v0.11; remove the annotation or wait for v0.12+`. Re-enter the section walk. |
| Synthesis (Step 8) detects `[new]` in topic text | After synthesis, before Step 8.5, banner the synthesis with `> NOTE: bootstrap targets requested but unsupported in v0.11. Design doc walk will refuse [new] annotations.` Continue (user can still author a deployable spec without bootstrap). |

### AskUserQuestion option count overflow (super-hub mode)

If detector finds >24 leaves total (CC's option-list practical ceiling), we
still offer two-step flow but cap each AskUserQuestion at 24 options:

| Condition | Behavior |
|---|---|
| Hub list >24 in step #1 | Show first 24 + `Show more...`. "Show more" re-runs AskUserQuestion with the next 24. |
| Leaf list >24 in step #2 | Same. |

This is unlikely in practice (typical super-hub has 4–8 hubs × 3–6 leaves =
12–48 leaves) but the cap prevents a UI explosion.

### Trooper question protocol (existing, unchanged)

The `FS=question` / `VS=question` re-arm flow from v0.5+ continues to work
in hub mode. Yoda answers per the existing classification (critical →
AskUserQuestion; non-critical → answer from topic context). Per-sub-project
context is available via `targets.txt` for non-critical answers.

### Concurrent / interrupted runs

| Scenario | Behavior |
|---|---|
| Hub-mode consult interrupted before target-selection completes | `targets.txt` absent → next invocation treats as fresh. `hub-mode.txt` may exist; gets overwritten. |
| Hub-mode consult interrupted mid-design-doc walk | Existing `cw_consult_design_doc_resume_state` handles per-section resume. New `dag.md`, `xrepo-deps.md`, `acceptance-tests.md` participate in the same scan (they're under `$DD_DIR/*.md`). The resume gate (Reuse / Redo / Skip) applies. |

### Stale state (from v0.5.0+ pattern)

`cw_consult_state_stale` (existing helper) — no change. Hub-mode adds no
new stale-state classes.

## Testing

### Unit tests (added to `tests/run.sh`, all PASS-gated)

| Test file | Coverage |
|---|---|
| `test_consult_detect_hub_super.sh` | Fixture: dir `super/` with git children `super/hub_a/`, `super/hub_b/`, each containing git grandchildren. Asserts `MODE=super-hub`, `HUBS=hub_a,hub_b`, `LEAVES=hub_a/leaf1,hub_a/leaf2,hub_b/leaf3`, rc=0. |
| `test_consult_detect_hub_subrepo.sh` | Fixture: dir `hub/` with git children that are leaves (no git grandchildren). Asserts `MODE=hub-subrepo`, `LEAVES=hub/leaf1,hub/leaf2`, no `HUBS=` line, rc=0. |
| `test_consult_detect_hub_single.sh` | Fixture: plain git dir, no git children. Asserts rc=1, stdout empty. (Backward-compat with v0.10 callers.) |
| `test_consult_detect_hub_mixed.sh` | Fixture: super-hub where one child has git grandchildren and another doesn't. Asserts the leaf-less hub is dropped from `HUBS=` and `LEAVES=`. |
| `test_consult_detect_hub_empty.sh` | Fixture: super-hub where ALL hubs are leaf-less. Asserts rc=1 (falls back to single-repo classification). |
| `test_consult_targets_persist.sh` | Round-trip: persist `[hub_a/leaf1, hub_b/leaf3]` → load → assert exact match. Slug-validation: persist `../escape/leaf` → asserts rc=1 + log_error. |
| `test_consult_targets_to_header_pair.sh` | Persist 3 leaves spanning 2 hubs → assert output is exactly two lines: `**Target Hub(s):** hub_a, hub_b` and `**Target Sub-Project(s):** leaf1, leaf2, leaf3`. |
| `test_consult_dag_validate.sh` | 6 cases: (a) happy 3-step linear, (b) happy 4-step diamond, (c) cycle Step 1→2→1, (d) unknown ref Step 2 depends Step 99, (e) repo not in targets.txt, (f) free-form prose `Phase 2 (sequential)` between Step blocks. Each case asserts rc + stderr substring. |
| `test_consult_xrepo_deps_validate.sh` | 5 cases: (a) happy 2-row, (b) header missing, (c) wrong column count, (d) Type='maybe', (e) internal Producer not in targets. |
| `test_consult_acceptance_tests_validate.sh` | 5 cases: (a) happy 3-entry, (b) entry missing `**Step N**` tag, (c) entry missing `[<sub-project>]` tag, (d) tag references unknown Step, (e) tag references unknown sub-project. |
| `test_consult_design_doc_assemble_hub.sh` | Build `$DD_DIR` with all 8 sections + `targets.txt`, run assemble, grep the output for: header pair lines present, DAG block present, Cross-Repo Deps present under DAG, Acceptance Tests heading present (not "Testing"), tagged entries preserved. |
| `test_consult_design_doc_assemble_single_unchanged.sh` | Build `$DD_DIR` with original 5 sections + NO `targets.txt`, run assemble, byte-equal compare against committed v0.10 baseline fixture (`tests/fixtures/v0.10-single-repo-design.md`). Catches any single-repo regression. |
| `test_consult_research_prompt_with_targets.sh` | Render `consult/research.md` with `TARGETS=hub_a/leaf1,hub_a/leaf2`, grep for the per-sub-project structuring instruction. Then render with empty `TARGETS=`, grep that the instruction is absent (single-repo unchanged). |
| `test_consult_verify_prompt_with_targets.sh` | Same shape for `consult/verify.md`. |
| `test_consult_drilldown_prompt_subproject.sh` | Render `consult/drilldown.md` with `SUBPROJECT=ARS-TaskServe`, assert prompt scopes to that sub-project + output path is `_scratch/drilldown-architecture-ARS-TaskServe-rex.md`. |

### Static-wiring tests (existing pattern)

| Test file | Coverage |
|---|---|
| `test_consult_directive_hub_mode.sh` | Static grep on `commands/consult.md`: assert Step 0 sources `lib/consult.sh`, calls `cw_consult_detect_hub`, persists `hub-mode.txt`. Assert Step 2 reads `targets.txt` and threads `TARGETS=` into research-send. Assert Step 8.5 has the new section list (8 entries) and the trooper-choice AskUserQuestion has the per-sub-project axis. |
| `test_consult_init_persists_hub_mode.sh` | Run `bin/consult-init.sh` against a fixture super-hub fixture; assert `_consult/hub-mode.txt` == `super-hub`. Run against a single-repo fixture; assert == `single-repo`. |

### Backward-compat regression baseline

`tests/fixtures/v0.10-single-repo-design.md` — captured from a clean v0.10
single-repo run, byte-fixed. `test_consult_design_doc_assemble_single_unchanged.sh`
diffs against it. Any change to assembly for the no-targets path fails this
test.

Same baseline approach as `tests/fixtures/v0.4.2-research-prompt.txt` —
proven pattern for catching unintended regression on the legacy code path.

### Manual / dogfood gates (skipped by `tests/run.sh`)

| Test file | Purpose |
|---|---|
| `test_consult_design_doc_walkthrough.sh` (existing) | Extended scenarios for hub mode: scenario H1 (hub-subrepo, 2 leaves, 4-step DAG), scenario H2 (super-hub, 4 leaves across 2 hubs, 6-step diamond DAG with Cross-Repo Deps), scenario H3 (validator failure → revision → re-validate loop). Stays SKIPPED in `run.sh`; runs manually via `bash tests/test_consult_design_doc_walkthrough.sh`. |
| `test_consult_v011_hub_dogfood.sh` (new manual gate) | End-to-end: spawns real codex + claude troopers in a fixture super-hub, walks the full pipeline including AskUserQuestion turns (uses `expect`-style stub or `CW_DOGFOOD_AUTO_SELECT=...` env-driven choices). Skipped in `run.sh`. |

### Coverage gaps explicitly accepted

| Gap | Why accepted |
|---|---|
| No live integration test for "trooper writes hub-mode findings.md correctly" | Costs a real-CLI dogfood run per CI cycle; structure-following is an instruction, not a contract — the warning-and-banner fallback in Section 4 handles non-conforming output. |
| No test for AskUserQuestion overflow >24 options | Unreachable in any current ARS-shape repo; behavior is degraded-graceful. |
| No test for concurrent hub-mode + single-repo runs in same `$CLONE_WARS_HOME` | Existing topic-dir uniqueness already prevents collision; v0.10 already works. |

### Release gate — v0.11.0 strict-dogfood pass

Added to `tests/test_consult_v011_dogfood.sh` (skipped in `run.sh`):

- **CW-DF-CONS-1**: from `/home/liupan/ARS/`, run `/clone-wars:consult plan a cross-fleet auth refactor`. Verify super-hub detected, two-step AskUserQuestion presented, hub-mode design doc lands at `docs/clone-wars/specs/...` with header pair + DAG + Cross-Repo Deps + tagged tests. Manual user-review gate fires.
- **CW-DF-CONS-2**: from `/home/liupan/ARS/ars_fleet/`, run consult on a 2-leaf topic. Verify hub-subrepo detected, single-step multi-select AskUserQuestion, doc lands with hub-mode shape.
- **CW-DF-CONS-3**: from `/home/liupan/CC/clone-wars/` (single-repo). Verify single-repo path unchanged, no DAG / Cross-Repo / tagged-tests blocks emitted, byte-equal to v0.10 shape.
- **CW-DF-CONS-4**: hub-mode validator failure path — author a deliberately-cyclic DAG in the walk, verify validator catches + re-enters walk + accepts the corrected DAG.

## Out of scope

Explicitly deferred to later versions:

- **Bootstrap targets (`[new]` annotation)** — sub-projects the design itself
  creates. Validator rejects `[new]` until v0.12+ delivers sub-repo creation
  mechanics on the deploy side.
- **Multi-target deploy execution** — `/clone-wars:deploy` v0.10 still
  dispatches to a single sub-repo. Consuming the DAG to fan out to N
  troopers ships in v0.11 deploy or later, as a separate spec.
- **Cross-repo integration audit at consult time** — consult emits the spec
  but does not run cross-repo tests itself. That's a deploy-side Phase 4
  concern.
- **Per-Step plan generation** — consult produces the master spec; per-Step
  plans (`<sub-repo>/docs/plans/YYYY-MM-DD-<topic>.md`) are a deploy-side
  splitter concern, mirroring `/executeorder66`'s Step 1d.
- **DAG-aware drilldown** — drilldown into a specific Step (rather than a
  section or sub-project) is deferred. Today's per-sub-project drill axis
  covers most cases.

## Success criteria

- [ ] All unit tests in `tests/run.sh` pass; `tests/test_consult_load_prompt_migration.sh` baseline still byte-equals v0.4.2/v0.5.3 captures.
- [ ] `test_consult_design_doc_assemble_single_unchanged.sh` byte-equal compare against v0.10 fixture passes — proves single-repo backward-compat.
- [ ] Static-wiring tests confirm directive Step 0 / Step 2 / Step 8.5 wire to the new helpers.
- [ ] Manual dogfood scenarios CW-DF-CONS-1 through CW-DF-CONS-4 pass on a real machine before tagging v0.11.0.
- [ ] Generated hub-mode spec is consumable by `/executeorder66` Step 1a–1e (DAG parser, target-match, Cross-Repo Deps validator) without manual edits — proves the spec shape contract.
