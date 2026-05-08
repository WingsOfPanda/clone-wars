# Consult-Spec Merge: /consult produces deploy-ready design docs

**Date:** 2026-05-08
**Status:** Draft
**Version target:** v0.17.0
**Supersedes:** v0.12.0 consult/spec split (delete /spec entirely)

## Problem

Today the path from a topic to a deploy-ready design doc is two commands:

```
/clone-wars:consult <topic>          # → cross-verified findings, 6-section investigation report
/clone-wars:spec <synthesis-path>    # → 5-section design doc
/clone-wars:deploy <design-doc>      # → audits + dispatches trooper(s)
```

This has three concrete frictions:

1. **`/spec`'s output doesn't pass `cw_deploy_audit_doc`.** The audit requires `## Goal` and `## Success Criteria` headings; /spec emits Architecture / Components / Data Flow / Error Handling / Testing — neither Goal nor Success appears. Users hand-edit before /deploy will accept the doc.
2. **The two-command surface is ceremony.** The user already invoked /consult; they now have to remember to invoke /spec, and they have to know about the source-defaulting magic that makes /spec find the right archive.
3. **Multi-repo design docs have nowhere to live.** v0.14.0 deleted hub-mode (~530 LoC). The user's personal canonical design template at `~/.claude/templates/design-doc.md` defines plural `**Target Sub-Project(s):**` + Execution DAG grammar that /executeorder66 + /strike-team consume — but Clone Wars doesn't emit any of it.

## Goal

`/clone-wars:consult` is the single command from topic → deploy-audit-passing design doc. /spec is deleted. The output is consumed directly by /deploy (single-repo) or by the user pasting into /executeorder66 (multi-repo, after hand-translating soft DAG to strict grammar).

## Architecture

The merged `/consult` is a single command with two output paths sharing one shape (deploy-audit-passing design doc). The smart-control inherited from v0.16.0 chooses the path. The new tail-end is a brainstorming-style per-section design walk added only to the escalated path.

### Step numbering (v0.17.0)

```
Step 0:  args-file → init.sh → _consult/{topic.txt, troopers.txt, design-doc/.draft/}
Step 1:  phrasing trigger detection (--use-force / "deeply" / "verify" / etc.)
Step 2:  4-signal complexity check + ROUTE
            ├─ FAST PATH (no signals + no --use-force + no --targets):
            │  Yoda drafts 6 sections inline → assemble → cw_deploy_audit_doc → exit
            └─ ESCALATED PATH (continue Step 3+)
Step 3:  spawn troopers (parallel, auto-retry-once)
Step 4:  research dispatch (parallel sends)
Step 5:  research wait (parallel background; question loop)
Step 6:  diff (N-way Venn)
Step 7:  verify dispatch (parallel sends)
Step 8:  verify wait (parallel background; question loop)
Step 9:  adjudicate + Yoda resolves PENDING
Step 10: multi-repo detection (auto + AskUserQuestion confirm) → multi-repo.txt + targets.txt
Step 11: per-section design walk (Approve/Revise/Skip × 6 single-repo or × 8 multi-repo)
Step 12: assemble + cw_deploy_audit_doc gate (auto-retry offending section once)
Step 13: drill-deeper (optional, unchanged from v0.16)
Step 14: teardown
Step 15: archive
Step 16: present final design-doc path
```

17 steps total. Fast path exits at Step 2.

### Routing rules

- `--use-force` → escalated path (existing v0.16)
- Phrasing trigger fires → escalated path (existing v0.16)
- Any 4-signal fires → escalated path (existing v0.16)
- `--targets a,b,c` explicit → escalated path (NEW: treats explicit targets as escalation signal)
- None of the above → fast path

### Multi-repo detection (Step 10)

Runs only on the escalated path. Order of precedence:

1. `--targets a,b,c` explicit on the command line: write `targets.txt` directly, skip auto-detect, skip confirm.
2. Auto-detect: walk cwd siblings for `*/CLAUDE.md` and `*/AGENTS.md`. Grep topic prose for sibling slug names. Hits → `AskUserQuestion` to confirm/edit/reject.
3. 0 hits OR user rejects → `multi-repo.txt = single`.
4. ≥1 hit + user confirms → `multi-repo.txt = multi`, `targets.txt` written.

### Doc shape

**Single-repo (6 sections):**
```
# <Title>

## Problem
## Goal
## Architecture
## Components
## Testing
## Success Criteria
```

**Multi-repo (8 sections + frontmatter):**
```
# <Title>

**Date:** YYYY-MM-DD
**Target Sub-Project(s):** slug-a, slug-b, slug-c

## Problem
## Goal
## Architecture
### slug-a
### slug-b
### slug-c
## Components
## Execution DAG
## Cross-Repo Notes
## Testing
## Success Criteria
```

### Soft DAG format

Numbered prose with explicit `(depends on N)` annotations:

```
## Execution DAG

1. ARS-TaskServe Part A — add registry.yaml field for skill-routing
2. ARS-LVMGateway Part A — consume new registry field in dispatcher (depends on 1)
3. ARS-TaskServe Part B — switch dispatcher callers to new field (depends on 2)
4. ARS-LVMGateway Part B — remove legacy fallback path (depends on 3)
```

Human-readable, copy-pastable. /executeorder66 + /strike-team users hand-translate to strict `Step <N>: <repo>  <description>` grammar before dispatching. /clone-wars:deploy can consume directly (it ignores the DAG section).

## Components

### Files deleted

- `commands/spec.md`
- `bin/spec-init.sh`
- `bin/spec-assemble.sh`
- `lib/spec.sh` (its sole inhabitant `cw_spec_resume_state` becomes dead code)
- `tests/test_spec_*.sh` (all of them)
- `tests/test_consult_design_doc_path.sh` (path canonicalization moves to walk-assemble)

### Files modified

- `commands/consult.md` — major. New step numbering (0-16). Add Step 10 (multi-repo detect), Step 11 (per-section walk), Step 12 (assemble + audit). Fast-path block (Step 2 fast branch) drafts 6 sections inline instead of the current 6 free-form ones.
- `bin/consult-init.sh` — minor. Parse `--targets a,b,c` flag into `_consult/targets.txt` (skip auto-detect when explicit). Validate slugs against `CW_SLUG_REGEX_BASE`.
- `bin/consult-synthesize.sh` — refactor. Currently emits the 6-section consult report directly; instead exposes per-section draft helpers consumed by Step 11. Final assembly moves to a new helper.

### Files added

- `bin/consult-walk-assemble.sh` — new tail script. Concatenates `$DD_DIR/.draft/<section>.md` files into the canonical design doc, injects `**Target Sub-Project(s):** <slugs>` and `**Date:** YYYY-MM-DD` headers in multi-repo mode, runs `cw_deploy_audit_doc`, exits non-zero on FAIL with parsed ISSUE= lines on stderr for the directive to map back to sections.
- `lib/consult-walk.sh` — new helper module:
  - `cw_consult_detect_multi_repo` (cwd siblings + topic prose grep)
  - `cw_consult_walk_section_state` (resume helper, mirrors deleted `cw_spec_resume_state`)
  - `cw_consult_emit_soft_dag` (formats numbered prose with `(depends on N)` annotations from a TSV input)
  - `cw_consult_audit_issue_to_section` (maps ISSUE= keys → section file names for retry routing)

### State directory layout (under `_consult/`)

```
design-doc/
├── <date>-<slug>-design.md         (final output, written by walk-assemble)
├── .draft/                         (per-section in-progress drafts)
│   ├── problem.md
│   ├── goal.md
│   ├── architecture.md
│   ├── components.md
│   ├── execution-dag.md            (multi-repo only)
│   ├── cross-repo-notes.md         (multi-repo only)
│   ├── testing.md
│   └── success-criteria.md
└── audit.log                       (last cw_deploy_audit_doc output)

targets.txt                         (TSV: <slug>\t<absolute-path-to-CLAUDE.md>; absent = single-repo)
multi-repo.txt                      (single line: single | multi)
```

### Components reused unchanged

- All `bin/consult-{init,research-send,research-wait,verify-send,verify-wait,diff,adjudicate,teardown,archive,drilldown,offset-reset}.sh` — the trooper pipeline doesn't change shape.
- `lib/{state,deps,contracts,tmux,ipc,commanders}.sh` — runtime layer.
- `lib/consult.sh` (most of it) — section helpers, prompts, parsers.
- `lib/deploy.sh` — `cw_deploy_audit_doc` already accepts the new shape; `cw_deploy_extract_target` still parses singular `Target Sub-Project:` for the redirect mechanism. No deploy-side changes.

### /deploy boundary

`/clone-wars:deploy` stays strictly single-repo. Multi-repo design docs from /consult are NOT a /deploy input — the user routes them to /executeorder66 (the ARS plugin's job) after hand-translating the soft DAG to strict `Step <N>: <repo>` grammar. We deliberately do NOT extend `cw_deploy_extract_target` to parse plural `Target Sub-Project(s):` — that would conflate /deploy with /executeorder66.

## Data Flow

### Inputs

- `<topic>` user prose
- Optional flags: `--use-force`, `--targets a,b,c`
- `cwd` (for sibling detection)
- `_consult/topic.txt` (written by consult-init.sh)
- `_consult/troopers.txt` (written by consult-init.sh based on `providers-available.txt`)

### Outputs (final)

- `_consult/design-doc/<date>-<slug>-design.md` (deploy-audit-passing)
- `_consult/design-doc/audit.log` (verdict + ISSUE= lines)

### Pipeline

```
USER → /consult <topic> [flags]
        │
        ▼
Step 0: args-file → consult-init.sh → _consult/{topic.txt, troopers.txt, design-doc/.draft/}
        │
        ▼
Step 1: phrasing trigger detection → CW_PATH_LABEL
        │
        ▼
Step 2: 4-signal complexity check + route decision
        │
        ├──── FAST PATH ──────────────────────────────────────────────────────┐
        │ Yoda reads topic + Read/Grep/WebSearch                              │
        │ Drafts 6 sections inline (no Approve turns) → .draft/*.md           │
        │ consult-walk-assemble.sh → design-doc/<date>-<slug>-design.md       │
        │ cw_deploy_audit_doc → PASS or re-draft offending section once       │
        │ Print path → exit                                                   │
        └─────────────────────────────────────────────────────────────────────┘
        │
        ▼ ESCALATED PATH
Steps 3-9: spawn → research → diff → verify → adjudicate → resolve PENDING
        │
        │ INPUT:  trooper findings.md, verify.md
        │ OUTPUT: _consult/adjudicated.md (cross-verified facts, PENDING-free)
        ▼
Step 10: multi-repo detection
        │ if --targets explicit → write targets.txt, skip detect
        │ else cw_consult_detect_multi_repo:
        │   - find */CLAUDE.md, */AGENTS.md siblings of cwd
        │   - grep topic prose for sibling slug names
        │   - if ≥1 hit → AskUserQuestion confirm/edit/reject targets list
        │   - if 0 hits OR user rejects → SINGLE_REPO=1
        │ write _consult/multi-repo.txt (single|multi) + targets.txt
        ▼
Step 11: Per-section walk (Approve/Revise/Skip × N)
        │ For each section in [problem, goal, architecture, components,
        │                      execution-dag*, cross-repo-notes*,
        │                      testing, success-criteria]
        │   (* multi-repo only)
        │   a. Yoda reads adjudicated.md + targets.txt + relevant findings/verify
        │   b. (Architecture only, if multi-repo) Yoda drafts ### per-repo subsections
        │   c. Yoda presents draft → AskUserQuestion Approve/Revise/Skip
        │   d. Approve → .draft/<section>.md
        │      Revise → AskUserQuestion "What should change?" → re-loop (cap 3 rounds)
        │      Skip   → .draft/<section>.md = "_(skipped)_"
        │      [BLOCKED: Skip on goal + architecture; banner explains audit dependency]
        ▼
Step 12: Assemble + audit
        │ consult-walk-assemble.sh:
        │   - Concatenate .draft/*.md → design-doc/<date>-<slug>-design.md
        │   - Inject H1 + (multi-repo) **Target Sub-Project(s):** + **Date:**
        │ cw_deploy_audit_doc:
        │   - PASS → audit.log "VERDICT=PASS" → advance to Step 13
        │   - FAIL → parse ISSUE= lines, map ISSUE→section, re-walk that section
        │            retry once; if still FAIL: AskUserQuestion (Commit failing / Abort)
        ▼
Steps 13-16: drill-deeper (optional) → teardown → archive → present
        │
        ▼
OUTPUT: archive/<repo-hash>/<topic>/_consult-<ts>/design-doc/<date>-<slug>-design.md
        Consumed by:
        - /clone-wars:deploy (single-repo, OR via Target Sub-Project: redirect for sub-repos)
        - /executeorder66 (multi-repo; user hand-translates soft DAG → strict grammar first)
```

### Data invariants

- **Per-section draft files are the unit of redo.** If audit fails on `no_success_section`, only `success-criteria.md` re-walks; other sections stay approved.
- **`adjudicated.md` is the input to every section draft.** Yoda's draft for any section starts by reading the cross-verified facts there, plus the matching trooper's `findings.md` for evidence depth.
- **`targets.txt` is consulted three places:** Step 10 writes it, Step 11 reads it for Per-Repo subsection injection, Step 12 reads it for the header.
- **Multi-repo and fast-path are mutually exclusive.** Fast-path always emits single-repo shape (no Per-Repo subsections, no DAG section). Trivial topics that don't warrant escalation also don't warrant multi-repo orchestration.

## Error Handling

| Failure | Where | Recovery |
|---|---|---|
| Spawn fails (cold-start race) | Step 3 | Auto-retry-once (existing v0.16 runbook); on second fail teardown + exit 1 |
| `FS=question` (research) / `VS=question` (verify) | Steps 5, 8 | Pattern 4 question relay (existing); critical → AskUserQuestion, non-critical → Yoda answers from findings |
| `FS=malformed` / `FS=timeout` | Step 5 | Pattern 1 re-prompt (existing); accept degraded findings if persistent |
| All `VS=UNCERTAIN` | Step 8 | Pattern 3 re-prompt (existing) |
| PENDING items remain after Step 9 | — | Yoda blocks until all resolved (CONFIRMED / REFUTED / CONTESTED); refuses to advance |
| **0 sibling matches in detection** | Step 10 | SINGLE_REPO=1, no AskUserQuestion (silent advance) |
| **User rejects auto-detected targets** | Step 10 | SINGLE_REPO=1; warn but advance |
| **Walk Revise infinite loop** | Step 11 | Cap at 3 Revise rounds per section; on 4th, AskUserQuestion (Force-approve / Skip / Abort consult) |
| **User Skips Goal or Architecture** | Step 11 | Hard refuse (deploy-audit-required); re-loop the section with banner explaining dependency |
| **Skip on Testing / Success Criteria** | Step 11 | Soft warn; record `_(skipped)_`; Step 12 audit will fail and re-walk |
| **Audit FAIL after Step 12** | Step 12 | Parse ISSUE= lines, map: `no_goal_section`→goal.md, `no_arch_section`→architecture.md, `no_testing_section`→testing.md, `no_success_section`→success-criteria.md, `tbd_marker`/`todo_marker`/`fill_in_later_marker`/`to_be_determined_marker`→AskUserQuestion to identify which section, re-walk that one section only, retry. Cap at 1 retry per section; if still failing AskUserQuestion (Commit failing doc / Abort) |
| **Multi-repo flag set but no targets** | Step 10 | Refuse — multi-repo without targets is incoherent. Force re-prompt or fall back to SINGLE_REPO |
| **Slug validation fails on target name** | Step 10 | Use `cw_deploy_extract_target`'s slug regex (`^${CW_SLUG_REGEX_BASE}$`); reject + re-prompt |
| Conductor dies mid-walk | — | Trooper panes survive (existing). User can re-attach and restart /consult; consult-init.sh refuses on existing topic dir, surfaces `consult-teardown` runbook |

### Safety invariants

1. **Critical-section skip block.** `## Goal` and `## Architecture` cannot be skipped during the walk because `cw_deploy_audit_doc` would fail and the user would loop forever. The walk pre-emptively blocks Skip on these two sections (banner: "This section is required by `cw_deploy_audit_doc`; Skip not available — pick Approve or Revise.")

2. **Audit-retry budget cap.** If the same section fails audit twice, /consult does NOT keep looping. It surfaces the FAIL and asks the user to either commit the audit-failing doc (with banner declaring it audit-failing) or abort cleanly.

3. **Walk-Revise budget cap.** If the user picks Revise four times on the same section, /consult surfaces an `AskUserQuestion` to break the loop: Force-approve (writes the last-presented draft verbatim to `.draft/<section>.md`) / Skip (only if section allows) / Abort consult.

## Testing

### New tests

| Test | Purpose |
|---|---|
| `test_consult_detect_multi_repo.sh` | Mock cwd siblings (3 fake `*/CLAUDE.md`); assert `cw_consult_detect_multi_repo` returns hits, single-repo when no siblings, slug filter when topic prose mentions only some |
| `test_consult_walk_section.sh` | Approve / Revise / Skip turn flow; verify per-section draft files written correctly |
| `test_consult_walk_section_resume.sh` | Resume: `.draft/architecture.md` exists from prior run → `cw_consult_walk_section_state` returns "approved" for that key |
| `test_consult_assemble_master_doc_single.sh` | 6-section assembly, no Target Sub-Project header, byte-equal to expected fixture |
| `test_consult_assemble_master_doc_multi.sh` | 8-section assembly, `**Target Sub-Project(s):** a, b, c` header injected, byte-equal to fixture |
| `test_consult_deploy_audit_passes.sh` | Generated doc (both single + multi) passes `cw_deploy_audit_doc` (verdict=PASS) |
| `test_consult_audit_retry_loop.sh` | Doc with deliberately-missing `## Success Criteria` triggers re-walk of success-criteria; passes after second pass |
| `test_consult_critical_skip_blocked.sh` | Walk on `goal` and `architecture` — Skip option not present in AskUserQuestion |
| `test_consult_directive_v017_static_wiring.sh` | commands/consult.md references all 17 step labels in order; no orphan v0.16 step references; no `/spec` references |
| `test_consult_fast_path_design_shape.sh` | Fast-path output has 6 H2 headings + passes audit |
| `test_consult_targets_flag_parse.sh` | `--targets a,b,c` parser; rejects malformed (empty, trailing-comma, slug-invalid) |
| `test_consult_targets_forces_escalation.sh` | `--targets foo` on a topic with no signals fired still routes to escalated path |
| `test_consult_emit_soft_dag.sh` | `cw_consult_emit_soft_dag` produces "1. <repo> Part A — <desc>\n2. ... (depends on 1)" from TSV input |

### Tests deleted

- `test_spec_directive_static_wiring.sh`
- `test_spec_init_source_defaulting.sh`
- `test_spec_assemble_*.sh` (multiple)
- `test_spec_resume_state.sh`
- `test_consult_design_doc_path.sh` (path canonicalization moves to walk-assemble; superseded by `test_consult_assemble_master_doc_single.sh`)

### Tests carried over unchanged

- All trooper-pipeline tests (spawn / research / verify / diff / adjudicate / synthesize internals)
- Question-protocol tests
- Medic preflight tests
- Deploy-side tests (`test_deploy_helpers.sh`, `test_deploy_provider_flag.sh`, etc.)
- `test_consult_directive_v016_static_wiring.sh` updated → renamed to `_v017_`

### Manual dogfood gate (release)

1. **Single-repo trivial:** `/consult what's the diff between mutex and rwlock?` → fast-path stub doc, 6 sections, passes audit.
2. **Single-repo escalated:** `/consult should we add Redis caching to the API layer?` → 4-signal fires, troopers research, walk produces 6-section doc.
3. **Multi-repo escalated:** `/consult plan the migration of session storage from postgres to redis across api-server and auth-service` → auto-detect fires (with 2 sibling matches if dirs exist), walk produces 8-section doc with DAG + Per-Repo subsections + `Target Sub-Project(s):` header.
4. **Audit-fail recovery:** deliberately Skip `success-criteria` during walk → Step 12 audit fails → re-walks just that section → audit passes.
5. **`--targets` forces escalation:** `/consult --targets foo,bar <trivial topic>` → forces escalation despite no signals; produces 8-section multi-repo doc.
6. **Deploy hand-off:** `/clone-wars:deploy` reads /consult's single-repo output cleanly (no manual edit needed). For multi-repo: user pastes into /executeorder66 after hand-translating soft DAG.

## Success Criteria

- [ ] `/clone-wars:spec` is removed; running it surfaces a "use /clone-wars:consult instead" hint or 404
- [ ] `commands/spec.md`, `bin/spec-init.sh`, `bin/spec-assemble.sh`, `lib/spec.sh`, all `tests/test_spec_*.sh` deleted from the tree
- [ ] `/clone-wars:consult <trivial topic>` (no signals) produces a 6-section design doc that passes `cw_deploy_audit_doc` with no manual edit
- [ ] `/clone-wars:consult <complex topic>` enters escalated path, runs trooper roster, then walks 6 sections with Approve/Revise/Skip; final doc passes audit
- [ ] `/clone-wars:consult <multi-repo topic>` (cwd has sibling `*/CLAUDE.md` dirs) auto-detects, asks user to confirm, walks 8 sections, emits doc with `**Target Sub-Project(s):**` header + soft DAG section
- [ ] `cw_deploy_audit_doc` returns VERDICT=PASS on the output of every dogfood scenario above
- [ ] All new tests in the Testing section pass; full suite green
- [ ] CLAUDE.md status entry recorded for v0.17.0 with dogfood gate

## Out of scope

- **Strict DAG grammar emission.** Soft DAG only. User hand-translates if /executeorder66 dispatch is needed.
- **/deploy multi-repo dispatch.** /deploy stays single-repo. Multi-repo docs route to /executeorder66 (separate plugin).
- **Auto-translation soft → strict DAG.** Users do this manually.
- **Resurrecting v0.11.0 hub-mode validators** (`dag.md`, `xrepo-deps.md`, `acceptance-tests.md` separate section files, Kahn topo-sort cycle detection, target-set validators). The 282 LoC of validators stays deleted. Section emission is Yoda-walked, not machine-validated.
- **Auto-detect inside fast path.** Fast-path always single-repo. To get multi-repo output you must escalate (signals, `--use-force`, or `--targets`).
- **Resume across /consult invocations.** If conductor dies mid-walk, user re-runs the whole /consult (init refuses on existing topic dir; user runs teardown first). Walk drafts in `.draft/` give per-section retry within a run, but not across runs.

## References

- `docs/superpowers/specs/2026-05-07-consult-spec-hub-removal-design.md` — v0.14 deletion of hub-mode (rationale this design partially reverses)
- `docs/superpowers/specs/2026-05-04-consult-hub-mode-design.md` — v0.11 hub-mode original design (heaviest precedent)
- `docs/superpowers/specs/2026-05-08-unified-consult-design.md` — v0.16 unified consult + smart-control (the routing bones we keep)
- `~/.claude/templates/design-doc.md` — user's canonical multi-repo template (Target Hub(s)/Sub-Project(s), Execution DAG strict grammar)
- `~/.claude/commands/forcevision.md` — orchestration-style precedent (single command, multi-research, synthesis)
- `lib/deploy.sh:34-78` — `cw_deploy_audit_doc` heuristics (constraint surface)
- `~/.claude/plugins/cache/claude-plugins-official/superpowers/5.0.7/skills/brainstorming/SKILL.md:21-33` — checklist /consult walk realizes (steps 5-9; the "N separate specs" pattern at line 74 is explicitly rejected by this design)
