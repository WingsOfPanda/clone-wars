# Clone Wars Consult — Design-Doc Mode

**Status:** Design (2026-04-29)
**Target version:** v0.4.0
**Author:** Master Yoda + WingsOfPanda

## Goal

Add an optional **design-doc phase** to `/clone-wars:consult` that consumes
the dual-trooper investigation output and walks the user through a
brainstorming-style approval flow, producing a committed
`docs/clone-wars/specs/YYYY-MM-DD-<topic-slug>-design.md`.

The default consult flow (research → verify → adjudicate → synthesize) is
unchanged. The new phase is opt-in, either implicitly (auto-prompt when the
topic looks design-shaped) or explicitly (`--design-doc` flag).

## Motivation

Today consult ends at `synthesis.md` — a free-form report Master Yoda
prints to chat. For investigation topics (bug hunts, audits, library
comparisons) that's the right shape. For **design topics** (architecture
choices, "should we do X or Y", new-feature scoping) the user often wants
a structured spec they can hand to `superpowers:writing-plans` or commit
as project documentation.

Rather than fork consult into two commands, this design adds a single
optional phase the user can enter when the topic warrants it. The dual
troopers and cross-verification (consult's unique value vs. vanilla
brainstorming) are preserved; the design-doc phase consumes their output.

## Architecture

`/clone-wars:consult` keeps its current 11-step shape. A new **Step 8.5**
(design-doc phase) slots between Step 8 (Synthesize) and Step 9 (Teardown).

Two entry conditions:

1. **Implicit:** `/clone-wars:consult <topic>` (no flag). After Step 8
   prints synthesis, Master Yoda checks `cw_consult_classify_topic`
   (already used for skill routing). If the classifier returned
   `brainstorming` (i.e., the topic is design-shaped), Yoda calls
   `AskUserQuestion`:

   > "Topic looks design-shaped. Write a design doc too? (Walks through
   > Architecture / Components / Data flow / Error handling / Testing,
   > writes to `docs/clone-wars/specs/...`)"

   Yes enters Step 8.5. No proceeds to Step 9.

2. **Explicit:** `/clone-wars:consult --design-doc <topic>`. Step 8.5
   always runs after Step 8 — no prompt.

Step 8.5 reads only artifacts already on disk (`synthesis.md`,
`adjudicated.md`, both troopers' `findings.md` and `verify.md`). Troopers
remain spawned through Step 8.5 (deferred teardown) so Yoda can dispatch
ad-hoc clarifications when the user pushes back on a section. Steps 9-10
(teardown, archive, present) run after Step 8.5 commits the spec — same
shape as today.

## Components

### New sub-script: `bin/consult-design-doc.sh`

~150 lines. Args: `<topic>`. Reads `_consult/topic.txt`, `synthesis.md`,
`adjudicated.md`, both troopers' `findings.md` + `verify.md`. Drives the
section walk-through loop (the actual `AskUserQuestion` calls live in the
directive at `commands/consult.md` — this script provides the helpers and
final assembly). Writes per-section approved drafts to
`_consult/design-doc/<section>.md`. On final approval, assembles into the
output path, runs self-review, commits.

### New helpers in `lib/consult.sh` (~80 lines added)

- `cw_consult_design_doc_filename <topic-slug>` — emits
  `docs/clone-wars/specs/YYYY-MM-DD-<topic-slug>-design.md`. Uses
  `${CW_TEST_DATE:-$(date +%Y-%m-%d)}` for testability.

- `cw_consult_design_doc_assemble <section-dir> <output-path>` —
  concatenates the 5 section files (`architecture.md`, `components.md`,
  `data-flow.md`, `error-handling.md`, `testing.md`) into a single doc
  with the standard header (Goal / Architecture / Tech Stack lines drawn
  from the approved Architecture section + the synthesis takeaway).

- `cw_consult_design_doc_self_review <output-path>` — scans for
  placeholders (`TBD`, `TODO`, bare `\.\.\.`). Returns nonzero with a
  stderr report (`<path>:<lineno>: <line>`) if found. Does NOT auto-fix.

- `cw_consult_design_doc_drilldown_prompt <section> <synthesis-path>
  <commander>` — builds a focused `cw_send` payload that asks the trooper
  to drill into one section, citing `synthesis.md`. Output path is
  `_consult/design-doc/drilldown-<section>-<commander>.md`. Includes the
  `END_OF_INSTRUCTION` sentinel.

- `cw_consult_design_doc_resume_state <design-doc-dir>` — lists already-
  approved sections (one per line) to support partial-resume after a
  user abort. Empty list if dir missing.

### New directive section: `commands/consult.md` Step 8.5 (~120 lines added)

The interactive walk lives here, not in the sub-script, because Master
Yoda owns `AskUserQuestion`. Pseudocode:

```
if --design-doc flag OR (skill.txt == "brainstorming" AND user said yes):
  for section in [architecture, components, data-flow, error-handling, testing]:
    if approved file already exists (resume case):
      ask: reuse / redo / skip
    draft = Yoda reads synthesis + per-section inputs, drafts inline
    loop:
      present draft to user
      AskUserQuestion: Approve / Revise / Drill deeper / Skip section
      case Approve  -> write _consult/design-doc/<section>.md, break
      case Revise   -> ask user for guidance, fold in, re-loop
      case Drill    -> AskUserQuestion: which trooper (rex/cody)?
                       cw_send drilldown payload
                       wait via cw_outbox_wait_since (existing helper)
                       read drilldown-<section>-<commander>.md
                       fold into draft, re-loop
      case Skip     -> write placeholder section, break
  bin/consult-design-doc.sh <topic>  # assembles + self-reviews + commits
  ask user to read the spec (verbatim brainstorming gate text)
```

### Modified: `bin/consult-teardown.sh`

No code change. The directive runs it later (after Step 8.5 if entered).

### New skip clause: `tests/run.sh`

Adds `test_consult_design_doc_walkthrough.sh` to the manual-only skip-list
(matches existing pattern for `test_consult_question_dogfood_*.sh`).

## Data Flow

### Inputs to Step 8.5

All produced by Steps 1-8, already on disk:

```
$TOPIC_DIR/_consult/
├── topic.txt              ← raw topic string
├── synthesis.md           ← reconciled summary (Step 8)
├── adjudicated.md         ← per-claim verdicts post-PENDING resolution
└── skill.txt              ← brainstorming|systematic-debugging|none

$TOPIC_DIR/<commander>-<model>/
├── findings.md            ← raw research (Steps 3-4)
└── verify.md              ← cross-verify verdicts (Steps 5-6)
```

### Step 8.5 working dir

```
$TOPIC_DIR/_consult/design-doc/
├── architecture.md
├── components.md
├── data-flow.md
├── error-handling.md
├── testing.md
└── drilldown-<section>-<commander>.md   ← optional, on user pushback
```

### Per-section loop (5 iterations)

```
1. Yoda reads inputs → drafts section text inline.
2. Yoda presents draft to user.
3. AskUserQuestion: Approve / Revise / Drill deeper / Skip.
   ├── Approve  → write _consult/design-doc/<section>.md, next.
   ├── Revise   → user provides guidance; Yoda incorporates; re-present.
   ├── Drill    → AskUserQuestion: which trooper?
   │              cw_send focused prompt → wait → fold in → re-present.
   └── Skip     → write `## <Section>\n\n_(skipped)_`, next.
```

### Final assembly

```
cw_consult_design_doc_assemble  $TOPIC_DIR/_consult/design-doc/  $OUT_PATH

  $OUT_PATH = docs/clone-wars/specs/YYYY-MM-DD-<topic-slug>-design.md
```

### Header prepended at assembly

```markdown
# <Topic Slug Title-Cased> Design

**Goal:** <one-line synthesis takeaway>

**Architecture:** <2-3 sentence paragraph extracted from approved Architecture section>

**Tech Stack:** <bullet list extracted from Components section>

---

## Architecture
…
## Components
…
## Data Flow
…
## Error Handling
…
## Testing
…
```

### Commit

```
git add docs/clone-wars/specs/YYYY-MM-DD-<topic-slug>-design.md
git commit -m "docs(consult): add design doc for <topic-slug>"
```

The user-review gate (verbatim from brainstorming SKILL) fires before the
commit asks for any further action — user can edit the file before the
commit lands.

### Drill-deeper IPC flow

```
Yoda → trooper inbox via cw_send:
  "Drill into <section>: <user pushback or focus>.
   Write to _consult/design-doc/drilldown-<section>-<commander>.md.
   END_OF_INSTRUCTION"

Trooper writes file. Trooper appends {"event":"done"} to outbox.jsonl.

Yoda waits via cw_outbox_wait_since (existing helper) → reads drilldown
file → folds findings into the section draft → re-presents to user.
```

## Error Handling

In order of likelihood:

### 1. User aborts mid-walkthrough

Approved sections persist as `_consult/design-doc/<section>.md`. No
design.md written; no commit. Teardown + archive still run normally —
the partial design-doc dir is included in archive.

Re-running `/clone-wars:consult --design-doc <topic>` on the same topic
detects existing approved sections via
`cw_consult_design_doc_resume_state` and asks: resume from where you left
off / start over.

### 2. Drill-down trooper times out or errors

`cw_outbox_wait_since` exceeds `findings_timeout_s` from contracts.yaml.

Yoda asks via `AskUserQuestion`: continue with current draft / retry /
pick the other trooper / skip drill-down. No state corruption — partial
drilldown file is overwritten on retry.

### 3. Self-review finds placeholders

`cw_consult_design_doc_self_review` flags `TBD` / `TODO` / bare `\.\.\.`.
Stderr reports `<file>:<lineno>: <line>` per match.

Loops back to per-section walk: Yoda re-presents the offending section as
"Revise" with the placeholder location pre-highlighted. Hard-loops until
clean OR user explicitly aborts (which leaves the doc unwritten —
placeholder failures never reach commit).

### 4. Output path collision

`docs/clone-wars/specs/YYYY-MM-DD-<topic-slug>-design.md` already exists.

Yoda asks via `AskUserQuestion`: overwrite / append timestamp suffix
(`-design-2.md`) / abort. No silent clobber.

### 5. Git commit fails

Pre-commit hook rejects, or working tree dirty in a conflicting way.

File is left written but not committed. Yoda surfaces the git error
verbatim, asks user to resolve manually, then offers re-commit.

### 6. Topic dir missing during Step 8.5

(Defensive — should be impossible since Step 8 just ran.)

Hard fail with `log_error`, exit 1. No partial design.md.

### 7. Trooper pane killed externally during drill-down

`tmux send-keys` succeeds but pane was killed before processing.
`cw_outbox_wait_since` returns timeout/missing. Same response as #2.

### Out of scope

- Concurrent design-doc runs on the same topic (locking). Same
  single-user assumption as today's consult.
- Resume across machines / sessions. Approved-sections-on-disk only; no
  marker for which section was in-flight when interrupted.
- Auto-recovery of corrupted approved-section files. If a file becomes
  invalid, the user re-approves it manually.

## Testing

Five unit/scriptable tests run by `tests/run.sh`. The interactive walk is
exercised manually during dogfood (same pattern as the existing
`test_consult_question_dogfood_*.sh` files).

### 1. `tests/test_consult_design_doc_filename.sh`

- Stub `date` via `CW_TEST_DATE=2026-04-29` env var.
- Assertions:
  - `cw_consult_design_doc_filename "lru-vs-lfu"` →
    `docs/clone-wars/specs/2026-04-29-lru-vs-lfu-design.md`.
- Edge cases:
  - Empty slug rejects with rc=2.
  - Slug with slashes rejects (slug validator already enforces
    `[a-z0-9-]+`).

### 2. `tests/test_consult_design_doc_assemble.sh`

- Fixture: write 5 sample section files to a temp dir.
- Run `cw_consult_design_doc_assemble`.
- grep-assert:
  - `^# .* Design$` header.
  - All 5 `^## ` section headings.
  - `^\*\*Goal:\*\*`, `^\*\*Architecture:\*\*`, `^\*\*Tech Stack:\*\*`
    lines.
  - `^---$` separator before sections.
- Edge case: missing one section file → assemble inserts `_(skipped)_`
  placeholder body; doc is still produced.

### 3. `tests/test_consult_design_doc_self_review.sh`

- Three fixtures:
  - Clean doc → rc=0, no stderr.
  - Doc with `TBD` → rc=1, stderr contains `TBD`.
  - Doc with bare `...` mid-sentence → rc=1.
- Assertion: false-positive guard — `TBD` inside a code fence is still
  flagged (placeholders shouldn't appear anywhere, including examples).

### 4. `tests/test_consult_design_doc_drilldown_prompt.sh`

- Run `cw_consult_design_doc_drilldown_prompt "Architecture" /tmp/synth.md rex`.
- grep-assert:
  - Contains section name `Architecture`.
  - Contains `END_OF_INSTRUCTION` sentinel.
  - Contains `drilldown-architecture-rex.md` (output path).
  - Contains synthesis path reference.

### 5. `tests/test_consult_design_doc_resume.sh`

- Fixture: create `_consult/design-doc/architecture.md` + `components.md`
  (2 sections "approved").
- Call `cw_consult_design_doc_resume_state` → returns
  `architecture\ncomponents` on stdout.
- Edge cases:
  - Missing design-doc dir → empty list, rc=0.
  - Corrupted (zero-byte) file → not counted as approved.

### Skip-list

`tests/run.sh` skips `test_consult_design_doc_walkthrough.sh` (interactive
manual test, lives in repo for documentation).

### Manual dogfood (post-implementation, before tagging)

1. Run `/clone-wars:consult --design-doc "decide between LRU and LFU
   cache eviction"` on this repo.
2. Walk all 5 sections.
3. Use "drill deeper" on at least one section to exercise the cw_send IPC
   path.
4. Verify
   `docs/clone-wars/specs/YYYY-MM-DD-decide-between-lru-and-lfu-cache-eviction-design.md`
   lands and is committed.
5. Re-run with same topic → confirm overwrite prompt fires.
6. Abort mid-section on a third run → confirm resume prompt fires.

## Out of Scope (this spec)

- Auto-decomposition of multi-subsystem topics (brainstorming SKILL does
  this; consult does not — defer to future spec).
- Visual companion (browser-based design preview). Text-only for v0.4.0.
- Re-running `--design-doc` mode on a topic whose synthesis dir was
  already archived. Requires un-archive flow; defer.
- Multiple specs from one consult run (e.g., one for each sub-system
  surfaced). Defer to a separate decomposition feature.

## Open Questions

None at design-time. All decisions explicit above.

## References

- Brainstorming SKILL: `~/.claude/plugins/cache/claude-plugins-official/superpowers/5.0.7/skills/brainstorming/SKILL.md`
- Writing-plans SKILL: `~/.claude/plugins/cache/claude-plugins-official/superpowers/5.0.7/skills/writing-plans/SKILL.md`
- Existing consult engine: `commands/consult.md`, `bin/consult-*.sh`,
  `lib/consult.sh`.
- Topic classifier: `cw_consult_classify_topic` (lib/consult.sh).
- v0.3.0 question protocol design (precedent for skill-routing
  classifier-based prompts):
  `docs/superpowers/specs/2026-04-29-clone-wars-consult-question-protocol-design.md`.
