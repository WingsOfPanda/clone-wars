# /clone-wars:execute-design — Codex-Implements, Yoda-Verifies Pipeline

> **Renamed in v0.7.0:** the slash command, bin scripts, lib helpers, env vars,
> and artifact directory have been renamed to `deploy` / `bin/deploy-*.sh` /
> `lib/deploy.sh` / `cw_deploy_*` / `CW_DEPLOY_*` / `_deploy/`. This document
> retains the historical "execute-design" terminology to preserve the v0.6.0
> design context. Read it as describing the same pipeline; substitute names as
> needed when cross-referencing live code.

**Status:** Design — Revision 0 (initial)
**Date:** 2026-05-02
**Target version:** v0.6.0
**Companion to:** `/clone-wars:consult` (v0.5.x) — `consult` produces a design doc; `execute-design` implements it.

---

## Goal

Add a slash command that takes a design doc (typically the synthesis from
`/clone-wars:consult`) and drives it through plan → implement → verify, with
**Codex doing the heavy work** (writing-plans, implementation, self-verification)
and **Master Yoda (Claude conductor) acting only at the gates** (design-doc
audit + post-implementation cross-verify + fix-loop dispatch).

The single load-bearing constraint: **save Claude tokens**. Yoda reads the
design doc once, the codex verify-report per round, and `git diff --stat`. Yoda
does NOT read the codex-produced plan, full diffs, test logs, or implementation
code unless cross-verify finds a flagged file worth spot-checking.

## Motivation

`/clone-wars:consult` currently ends at a synthesized design doc. The user then
either implements it manually or delegates to a fresh Claude session. Both
paths burn the conductor's context: the design-doc-aware Claude has to also
write the plan, write the code, run the tests, and verify. That's 5+ phases of
heavy reading and editing in one session.

The proven pattern from `/clone-wars:consult` is the opposite: **a thin
conductor + heavy troopers**. We want the same shape for the implementation
side. Yoda already trusts codex enough to research and verify findings; we can
extend that trust to writing the plan and producing the implementation. Yoda's
job becomes the design-side gate (does the spec contain enough detail to
implement?) and the implementation-side gate (does the resulting code match
the spec, and do the tests pass?).

## Non-goals

- **Multi-trooper implementation.** Only one Codex trooper per run. Parallel
  implementers would race on the working tree. (If a plan is large enough to
  benefit from parallelism, that's a sign it should be decomposed into
  multiple `execute-design` runs against multiple specs.)
- **Worktree isolation.** Out of scope per `docs/DESIGN.md`. The auto-branch
  default (below) is the cheapest substitute.
- **Pluggable implementer.** v1 is codex-only. (`/clone-wars:consult` shows
  Claude implementers don't follow the inbox-driven `done`-event protocol as
  reliably as codex.)
- **Resumable runs.** A failed/abandoned run is torn down on the next
  invocation; no checkpoint replay. (Codex's per-task commits are the
  resumption story.)
- **Yoda re-implementing on codex failure.** If codex blocks 5 rounds in a row,
  Yoda escalates via `AskUserQuestion`. Yoda never picks up the keyboard.

---

## Architecture

```
slash directive  ──▶  bin/execute-design-init.sh <design-path>
                            │ derive topic slug from design filename
                            │ create _execute/ dir, copy design.md
                            │ create feat/exec-<topic> branch (unless --no-branch)
                            │ prints: <topic-slug>
                            ▼
                      ┌── Yoda: design-doc audit  ─────────────────────┐
                      │ reads design.md only                            │
                      │ writes _execute/design-audit.md                 │
                      │ refuses or AskUserQuestion if gaps              │
                      └────────────────────────────────────────────────┘
                            │
                            ▼
                      bin/spawn.sh cody codex <topic>     # one trooper, persistent
                            │
                            ▼
                      bin/execute-design-plan-send.sh <topic>
                            │ inbox: "use superpowers:writing-plans on design.md"
                            ▼
                      bin/execute-design-plan-wait.sh <topic>
                            │ wait for done; PS=ok|failed|timeout
                            ▼
                      bin/execute-design-implement-send.sh <topic>
                            │ inbox: "use superpowers:subagent-driven-development on plan.md"
                            ▼
                      bin/execute-design-implement-wait.sh <topic>
                            │ wait for done; IS=ok|failed|timeout
                            │ (long timeout — implementation is the slow phase)
                            ▼
                      ┌──── Round loop (max 5) ──────────────────────────┐
                      │  bin/execute-design-verify-send.sh <topic>       │
                      │  bin/execute-design-verify-wait.sh <topic>       │
                      │     │ codex runs superpowers:verification-       │
                      │     │ before-completion; writes verify-report.md │
                      │     ▼                                            │
                      │  Yoda: cross-verify (always runs)                │
                      │     │ reads verify-report.md + git log + stats   │
                      │     │ writes _execute/cross-verify-N.md          │
                      │     │ verdict: PASS | FAIL <issues>              │
                      │     ▼                                            │
                      │  PASS? ──▶ exit loop                             │
                      │  FAIL ──▶ bundle issues into fix-prompt-N.md     │
                      │           bin/execute-design-fix-send.sh <topic> │
                      │           loop back to verify-send                │
                      │  Round 5 still failing ──▶ AskUserQuestion       │
                      └──────────────────────────────────────────────────┘
                            │
                            ▼
                      bin/execute-design-teardown.sh <topic>
                            │ kill cody pane; archive _execute/ + trooper dir
                            ▼
                      Yoda: final summary to user
```

### Topic slug derivation

The design doc filename is canonical:
`docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md` → topic slug `<topic>`.

If the filename does not match the convention (no leading date, no `-design.md`
suffix), `--topic <slug>` is required. Slug regex: `^[a-z0-9][a-z0-9-]{0,31}$`
(matches the consult slug rules in `cw_consult_topic_validate`).

### Source defaulting

When invoked without a path:
1. Look for `state/<repo-hash>/consult-*/synthesis.md` (most recent mtime).
2. If found, prompt the user via `AskUserQuestion` to confirm.
3. If none found, refuse with a usage hint.

When invoked with `--source <path>`:
- Path must be a readable file. No checks on filename format if `--topic` is
  also provided.

### Branch model

Default: create `feat/exec-<topic>` from current HEAD before phase 1.
- Refuse if working tree is dirty (suggest `git stash` or `--no-branch`).
- Refuse if branch already exists (suggest `--branch <name>` to override).
- `--no-branch` skips creation and runs on current branch (user's risk).

Codex commits per task on this branch. The slash directive does NOT push or
open a PR — that's the user's call after reviewing.

---

## State layout

```
$CLONE_WARS_HOME/state/<repo-hash>/<topic>/
├── _execute/
│   ├── design.md             ← copy of input design doc (audit reads this)
│   ├── topic.txt             ← derived slug
│   ├── design-audit.md       ← Yoda's pre-flight verdict + notes
│   ├── plan-cody.txt         ← codex plan-phase state (PS=, OFFSET=)
│   ├── plan.md               ← codex writes via writing-plans skill
│   ├── implement-cody.txt    ← codex implement-phase state (IS=, OFFSET=)
│   ├── verify-cody-N.txt     ← codex verify-phase state per round (VS=, OFFSET=)
│   ├── verify-report-N.md    ← codex writes per round (verification-before-completion)
│   ├── test-output-N.log     ← codex writes per round (raw test output)
│   ├── cross-verify-N.md     ← Yoda's per-round verdict + classified issue list
│   └── fix-prompt-N[-debug|-gap].md  ← Yoda → Codex; split if mixed bug/spec-gap
└── cody-codex/
    ├── identity.md           ← standard trooper IPC
    ├── inbox.md
    ├── outbox.jsonl
    ├── status.json
    └── pane.json
```

Per-round suffixes (`-N`) start at 1 and increment each verify pass. The fix
sent in round 1 produces `verify-report-2.md` and `cross-verify-2.md`. This
matches the consult per-commander state file pattern (last-wins on `source`).

After teardown, `_execute/` and `cody-codex/` are moved to
`$CLONE_WARS_HOME/archive/<repo-hash>/<topic>-<timestamp>/`.

---

## Phase contracts

### Phase 0 — Init + Audit (Yoda)

**Input:** `<design-path>` (resolved), `<topic-slug>` (derived or explicit).
**Yoda actions:**
1. Read design doc.
2. Run audit checklist:
   - Goal section present
   - Architecture / approach section present
   - Testing strategy explicit (not "add tests where appropriate")
   - Success criteria explicit (how do we know it's done?)
   - File paths concrete (no `path/to/something/`)
   - No TBD / TODO / "to be determined" / "fill in later"
   - Scope bounded to one implementable feature (not a multi-subsystem epic)
3. Write `_execute/design-audit.md` with PASS or FAIL + issue list.
4. If FAIL: `AskUserQuestion` (proceed anyway / abort / open editor on
   design doc). Default option: abort.

**Output:** `_execute/design-audit.md`. Continue only on PASS or explicit
proceed-anyway.

### Phase 1 — Plan (Codex)

**Send:** inbox prompt — *"Read `_execute/design.md`. Use the
`superpowers:writing-plans` skill. Write the resulting plan to
`_execute/plan.md`. Emit a `done` event when complete. END_OF_INSTRUCTION"*

**Wait:** poll `outbox.jsonl` until `done` or `error`. Long timeout (default
600s — writing-plans is medium-weight).

**State:** `_execute/plan-cody.txt` records `PS=ok|failed|timeout` + final
`OFFSET=`.

**Yoda does not read `plan.md`.** Trust codex's writing-plans skill. (Yoda
will see the plan only if cross-verify flags an issue traceable to a missing
plan element, and only the relevant section.)

### Phase 2 — Implement (Codex)

**Send:** inbox prompt — *"Read `_execute/plan.md`. Use
`superpowers:subagent-driven-development` to implement every task. Commit
per task. Run the tests after each task and confirm they pass before
moving to the next. Emit a `done` event when all tasks are complete and
all tests pass. END_OF_INSTRUCTION"*

**Wait:** very long timeout (default 7200s = 2h — implementation is the
slowest phase). Configurable via `CW_EXECUTE_IMPLEMENT_TIMEOUT` env var.

**State:** `_execute/implement-cody.txt` records `IS=ok|failed|timeout`.

**On `error` or `IS=failed`:** Yoda reads outbox tail (last ~30 lines) and
relays to user via `AskUserQuestion` (retry / abort / hand-off). Yoda does
NOT attempt to fix the implementation itself.

### Phase 3 — Self-Verify (Codex, per round)

**Skill binding:** `superpowers:verification-before-completion` — same skill
Yoda will run in Phase 4, so verdicts are directly comparable.

**Send:** inbox prompt — *"Use `superpowers:verification-before-completion`
against the design doc at `_execute/design.md`. Verify your implementation
satisfies every requirement. Write `_execute/verify-report-<N>.md` with
verdicts (PASS / PARTIAL / FAIL per requirement, plus a top-line overall
verdict). Also write `_execute/test-output-<N>.log` with the raw output
of your test runs (so cross-verify can grep for actual pass/fail counts).
Emit a `done` event when complete. END_OF_INSTRUCTION"*

**Wait:** medium timeout (default 1200s).

**State:** `_execute/verify-cody-<N>.txt` records `VS=ok|failed|timeout` +
`OFFSET=`.

### Phase 4 — Cross-Verify (Yoda, per round, **always runs**)

**Skill binding:** Yoda invokes `superpowers:verification-before-completion`
explicitly. The skill drives the structured pass; the inputs/output below
are how Yoda feeds and frames it. Same skill as codex's Phase 3 — apples-to-
apples comparison, where cross-verify's value is catching what codex's own
pass missed.

**Yoda inputs (capped reads):**
- `_execute/verify-report-<N>.md` (full)
- `_execute/design.md` (already in context from Phase 0; do not re-read)
- `git log --oneline <branch-base>..HEAD` (commit list)
- `git diff --stat <branch-base>..HEAD` (per-file change sizes)
- Up to **3 spot-checks**: for each high-risk requirement, read at most one
  file or one diff hunk identified by codex's verify-report.

**Yoda checklist (driven by the skill):**
1. Codex's verdict says PASS — does the diff actually implement the
   requirements? Read 1-2 of the highest-stakes diff hunks to spot-check.
2. Codex's verdict says PARTIAL/FAIL — does Yoda agree? Are there issues
   codex missed?
3. Tests claim to pass — is there a test artifact (test-output-<N>.log,
   verify-report excerpt) confirming?
4. Was the auto-branch actually used? `git rev-parse --abbrev-ref HEAD`
   matches expected branch.

**Output:** `_execute/cross-verify-<N>.md` with:
- Top-line verdict: PASS / FAIL
- If FAIL: bullet list of issues, each tagged with a **classification**
  (`bug` | `spec-gap` | `regression`), plus (a) requirement reference, (b)
  evidence (file:line or commit), (c) suggested fix direction. The
  classification feeds Phase 5's skill-routing decision.

**On PASS:** exit round loop, proceed to teardown.
**On FAIL:** proceed to Phase 5.

### Phase 5 — Fix Dispatch (Yoda, on FAIL)

**Skill routing:** the `fix-prompt-<N>.md` body tells codex which superpowers
skill to use, based on the issue classification Yoda assigned in Phase 4:

| Classification | Codex skill |
|---|---|
| `bug` (test failure, broken behavior) | `superpowers:systematic-debugging` |
| `regression` (worked before, doesn't now) | `superpowers:systematic-debugging` |
| `spec-gap` (requirement absent or incomplete) | `superpowers:writing-plans` (replan the gap) → then implement |

If a single fix-prompt mixes classifications, **split it**: emit
`fix-prompt-<N>-debug.md` first (bugs/regressions) and `fix-prompt-<N>-gap.md`
second (spec gaps). Codex processes them in order, two inbox dispatches per
round. Bug-fixes precede gap-closures because gap-fix code may depend on
already-correct existing code.

**Yoda actions:**
1. Read `cross-verify-<N>.md`; group issues by classification.
2. Bundle into `_execute/fix-prompt-<N>.md` (or split files if mixed) —
   concrete, file-referenced, ordered most-critical first within each group.
   Each bundle's preamble names the required skill explicitly.
3. Inbox prompt — *"Cross-verification found <N> issues. Read
   `_execute/fix-prompt-<N>.md`. Use the skill named in the file's
   preamble. Resolve each issue, commit per fix, re-run tests after each.
   When all are resolved and tests pass, emit `done`. Do NOT skip any
   issue. END_OF_INSTRUCTION"*
4. Loop back to Phase 3 (self-verify-N+1).

**Round budget:** 5 rounds total (rounds 1-5). On round 6 (i.e., 5 fix
rounds completed and round-6 cross-verify still FAIL):
- `AskUserQuestion`: "5 fix rounds exhausted. Continue / Abort / Hand off
  to user." Default: hand off.
- Hand-off mode: leave the trooper alive, print state-dir path, exit. User
  takes over from the cody pane manually.

### Phase 6 — Teardown (Yoda)

1. `bin/teardown.sh cody <topic>` — kills pane, archives `cody-codex/`.
2. `mv $TOPIC_DIR/_execute $ARCHIVE/<topic>-<ts>/_execute`.
3. Print summary to user: branch name, commit count, final verdict, archive
   path.

---

## Slash directive (sketch)

```
# /clone-wars:execute-design <design-path-or-topic>

## TaskCreate × 8 BEFORE phase 0
| # | subject | activeForm |
|---|---|---|
| 0   | 0   Audit design doc [yoda]               | Auditing design doc |
| 1.1 | 1.1 Spawn cody (codex) [yoda]              | Spawning cody |
| 1.2 | 1.2 Plan [cody/codex]                      | Cody planning |
| 1.3 | 1.3 Implement [cody/codex]                 | Cody implementing |
| 2.1 | 2.1 Self-verify [cody/codex]               | Cody self-verifying |
| 2.2 | 2.2 Cross-verify [yoda]                    | Yoda cross-verifying |
| 3   | 3   Fix loop (if needed) [yoda + cody]     | Running fix loop |
| 4   | 4   Teardown + archive [yoda]              | Tearing down |
```

CLI shape:
- `/clone-wars:execute-design` — auto-source latest synthesis.md
- `/clone-wars:execute-design <design-path>` — explicit path
- `/clone-wars:execute-design --topic foo --source path/to/doc.md` — explicit
  both
- Flags: `--no-branch`, `--branch <name>`, `--max-rounds 5`

Per-phase timeouts are env-var configurable, not CLI flags:
`CW_EXECUTE_PLAN_TIMEOUT` (default 600s), `CW_EXECUTE_IMPLEMENT_TIMEOUT`
(default 7200s), `CW_EXECUTE_VERIFY_TIMEOUT` (default 1200s). Set in the
shell before invoking the slash command.

Mirrors `/clone-wars:consult`'s args-file pattern: write the design path via
the Write tool to `$CLONE_WARS_HOME/_args/execute-design.txt`, then invoke
`bin/execute-design-init.sh --args-file …`.

---

## Helpers (lib/execute_design.sh)

Mirrors `lib/consult.sh`. Functions:

- `cw_execute_design_topic_dir <topic>` — returns `$STATE/<repo-hash>/<topic>`
- `cw_execute_design_art_dir <topic>` — returns `…/<topic>/_execute`
- `cw_execute_design_assert_topic <topic>` — slug-validate or exit 2
- `cw_execute_design_derive_topic <design-path>` — strips date prefix +
  `-design.md` suffix
- `cw_execute_design_audit_doc <design-path> <out-path>` — runs the audit
  checklist; returns 0 (PASS) or 1 (FAIL)
- `cw_execute_design_branch_create <topic>` — creates `feat/exec-<topic>`
  from HEAD; refuses on dirty tree

The audit function is pure-bash heuristics (grep for required headings, scan
for TBD/TODO patterns). It is intentionally cheap: Yoda is the actual auditor;
the helper just produces a checklist so Yoda's reading is structured.

---

## Token-budget table

Per run (no fix loop), Yoda's reads:

| Read | Tokens (est.) |
|---|---|
| Design doc (Phase 0) | 2-5k |
| Audit checklist write | <1k |
| Phase 1-2 outbox tails (on `done` event) | <500 |
| Verify-report-1 (Phase 4) | 1-3k |
| `git log --oneline` + `git diff --stat` | <500 |
| Up to 3 spot-checks | 1-2k |
| Cross-verify-1 write | 1-2k |
| Fix-prompt write (if FAIL) | 1-2k per round |

**Floor (PASS in round 1):** ~6-12k tokens.
**Ceiling (5 fix rounds):** ~30-50k tokens.

By comparison, a pure-Claude implementation of the same plan typically
consumes 100-300k tokens (planning + reading codebase + writing code +
running tests). The shift to codex-side execution is the budget win.

---

## Open questions (deferred to plan)

1. **Audit failure UX.** Should the audit's `AskUserQuestion` include an
   "open editor on design doc" option that pauses the run while the user
   edits, then re-audits? Or just abort and let the user re-run? Lean:
   abort + re-run (simpler, user is already in their editor).
2. **Test-output capture.** ~~Codex's verify report includes test results in
   prose. Should we additionally require codex to write `_execute/test-
   output-<N>.log`?~~ **Resolved:** added to Phase 3 prompt.
3. **`AskUserQuestion` on round-5 exhaustion** — should the hand-off mode
   leave a `RESUME.md` in `_execute/` documenting where the user picks up?
   Lean: yes, write RESUME.md before exit.
4. **Codex's writing-plans output location.** The skill defaults to
   `docs/superpowers/plans/YYYY-MM-DD-<feature>.md`. Should we override to
   `_execute/plan.md` (ephemeral) or let codex write to the canonical path
   too (so the plan persists in the repo as documentation)? Lean: both —
   codex writes to canonical path AND `_execute/plan.md` is a symlink. That
   way the plan lives in `docs/` after teardown.

---

## Out-of-scope (reaffirms `docs/DESIGN.md`)

- Multi-implementer parallelism
- Worktree isolation
- Plan persistence across abandoned runs
- Auto-PR creation
- Yoda implementing on codex-block

---

## Success criteria

A v0.6.0 dogfood run on a real design doc produces:
1. A `feat/exec-<topic>` branch with N commits (N = task count + fix-round
   commits), all green tests.
2. Yoda's total token consumption stays within the table above.
3. The cross-verify pass actually catches an issue codex's self-verify missed
   in at least one of three dogfood runs (otherwise Yoda's role is decoration
   and we should reconsider whether the fix-loop needs Yoda at all).
4. A user can resume a failed-at-round-5 run by attaching to the cody pane
   and continuing manually, using only `RESUME.md` for context.
