# /clone-wars:consult — Unified Smart-Control + Design-Doc Output (v0.16.0)

**Status:** approved (brainstorming → writing-plans handoff)
**Author:** liupan + Master Yoda
**Date:** 2026-05-08
**Branch base:** main (post-v0.15.0 merge)

## Summary

Fold the original v0.16 `/clone-wars:ask` proposal back INTO `/clone-wars:consult`
as a fast-path. Single entry point — the user no longer has to triage
question complexity. Yoda decides per-invocation whether to answer solo
or escalate to the trooper roster, and **always** writes a canonical
design-doc-formatted file to `_consult/design-doc/<date>-<slug>-design.md`.
The header trust label distinguishes solo from N-verified.

`/clone-wars:spec` reads that one design-doc path. No source-defaulting
precedence chain.

## Motivation

The user's stepped-back insight: forcing the user to choose between a
quick command and a thorough command pushes complexity-triage onto them
("is this question simple enough to skip troopers?"). Wrong call → either
wasted time (over-spawn for trivia) or unverified answer mistaken for
verified (under-spawn on a complex topic). The cleaner UX is one command
where Yoda makes the call **with explicit overrides** when the user
disagrees.

The original anti-pattern concern — "single-source wearing a verified-
answer label silently breaks trust" — is addressed by making the trust
label LOAD-BEARING in every output. Every design-doc has a `Source:`
header line stating exactly which path produced it (Yoda solo, N=2
verified, N=3 verified) and what triggered the path (fast / escalated-
from-signals / escalated-from-flag / escalated-from-phrasing).

The output format unifies on **brainstorming-style design doc** because:
1. The user's actual /consult invocations are design-grade questions
   (LRU vs LFU eviction, mutex vs spinlock, sync.Mutex vs sync.RWMutex,
   "should we add a smart-control to /consult", etc.) where structured
   tradeoff analysis is the natural shape.
2. /spec already walks design docs. One format end-to-end means /spec
   has nothing to switch on.
3. Pre-v0.12 had a `--design-doc` mode that wrote here; this restores
   that path as the default.

## Scope

### In
- Add `--use-force` flag to `/clone-wars:consult` (always escalates to troopers, skips fast-path entirely)
- Add Yoda fast-path before the existing trooper pipeline:
  - Yoda researches with full toolkit (Read/Grep/Bash/WebSearch/Tavily/skills)
  - 4-signal complexity check (favor rigor: borderline → escalate)
  - Topic-phrasing check (escalation trigger keywords)
  - On no-escalate: Yoda drafts the design-doc directly, exits
- Restructure /consult output: ALWAYS writes `_consult/design-doc/<YYYY-MM-DD>-<slug>-design.md` (rigid 6-section format)
- Header carries trust label (Source / Generated / Path)
- Drop `_consult/synthesis.md` as a final-output artifact (kept as intermediate inside trooper path)
- Update `commands/spec.md` + `bin/spec-init.sh` source-defaulting to read the single design-doc path
- Tests for: fast-path solo design-doc generation, --use-force flag, phrasing triggers, 4-signal escalation, /spec consumption

### Out
- Separate `/clone-wars:ask` command (rejected; folded into /consult)
- `_ask/answer.md`, `_consult/seed.md`, `_consult/synthesis.md` as user-facing outputs (replaced by design-doc)
- /spec source-defaulting chain (collapses to single path)
- Auto-invocation from /consult to /spec (still user-invoked)
- Argument flags beyond `--use-force` (e.g. `--save`, `--quick`, `--force` — not added)
- Section-set flexibility (rigid 6 sections; missing → `_(not applicable)_`)
- Re-run history rotation (overwrites previous design-doc with same slug+date)

## Architecture

### Command shape

```
/clone-wars:consult [--use-force] <topic>
```

- `--use-force` is a **prefix flag** (parsed before topic). Star-Wars-themed name; semantically equivalent to "skip fast-path, always trooper-spawn".
- Topic positional argument unchanged.
- All other arg-parsing (the `--design-doc` deprecation warn, etc.) preserved from v0.15.

### Decision tree (in order)

```
1. --use-force flag set?              → trooper path (skip fast-path)
2. Topic contains escalation phrasing? → trooper path (skip fast-path)
3. Yoda fast-path:
   a. Yoda researches the topic
   b. 4-signal complexity check
   c. Any signal fires (favor rigor)? → trooper path
   d. Otherwise                        → solo path: write design-doc, done
```

**Escalation phrasing keywords** (Yoda checks topic for these tokens, case-insensitive):
- "deeply"
- "verify" / "verify rigorously" / "cross-verify" / "verify carefully"
- "compare carefully"
- "second opinion"
- "consult thoroughly"

Yoda's parser is prose-described in the directive (no rigid tokenization). It interprets the topic and decides whether the phrasing fits the spirit of "user wants cross-verification". On match → trooper path.

**4-signal complexity check** (post-Yoda-research, evaluated by Yoda's judgment):

1. **Conflicting evidence** — Yoda's research surfaced sources that disagreed with each other.
2. **Significant assumptions** — Yoda had to assume facts not in evidence to give a complete answer.
3. **High-stakes decision** — topic implicates architecture / security / irreversibility / production data.
4. **Subjective tradeoffs** — no objectively right answer ("compare A vs B", "should we do X?").

Any 1+ → trooper path (favor rigor).

### Solo path (Yoda fast-path completes)

1. Yoda already researched the topic (with full toolkit).
2. Yoda drafts the design-doc inline, populating each of the 6 sections.
3. Atomic write to `_consult/design-doc/<YYYY-MM-DD>-<slug>-design.md`.
4. Print full design-doc to chat.
5. Done. No `_consult/` working artifacts (no troopers spawned, no diff/adjudicate/synthesize).

Topic dir layout for solo path:
```
~/.clone-wars/state/<repo-hash>/<topic>/
├── topic.txt                          ← raw topic
└── _consult/
    └── design-doc/
        └── 2026-05-08-<slug>-design.md
```

### Trooper path (escalated)

Same as v0.15 N=2/N=3 pipeline (spawn → research → diff → verify → adjudicate → synthesize) BUT the synthesize step now writes the canonical design-doc INSTEAD OF `_consult/synthesis.md`:

1. Spawn N troopers (rex/cody/bly per `troopers.txt`).
2. Research-send + research-wait per trooper.
3. `consult-diff.sh` produces N-way Venn buckets.
4. Verify-send + verify-wait per trooper.
5. `consult-adjudicate.sh` writes 5-tier `_consult/adjudicated.md` (working artifact, intermediate).
6. `consult-synthesize.sh` reads adjudicated.md and writes the **canonical design-doc** at `_consult/design-doc/<YYYY-MM-DD>-<slug>-design.md` (drops the historical `_consult/synthesis.md` output entirely).
7. Drilldown step (Step 8.4) unchanged — still optional, still writes to `_consult/drilldowns/_scratch/`.
8. Teardown + archive.

Topic dir layout for trooper path:
```
~/.clone-wars/state/<repo-hash>/<topic>/
├── topic.txt
├── rex-codex/      cody-claude/      bly-opencode/    ← per-trooper subdirs
└── _consult/
    ├── troopers.txt          ← N=2/N=3 roster
    ├── findings-*.md         ← per-trooper findings (intermediate)
    ├── diff.md               ← N-way Venn (intermediate)
    ├── *_only.txt            ← bucket files (intermediate)
    ├── adjudicated.md        ← 5-tier verdict (intermediate)
    ├── drilldowns/           ← optional drill artifacts
    │   └── _scratch/
    └── design-doc/
        └── 2026-05-08-<slug>-design.md   ← CANONICAL output (same path as solo)
```

### Design-doc schema (rigid 6 sections)

```markdown
# <Topic Title-Cased>

> **Source:** <one of:>
>   - Master Yoda (single-source)
>   - rex+cody cross-verified (N=2)
>   - rex+cody+bly cross-verified (N=3)
> **Generated:** <ISO-8601 UTC>
> **Path:** <one of: fast | escalated-from-signals | escalated-from-flag | escalated-from-phrasing>

## Summary
<1-3 sentences — the question + the recommendation>

## Findings
<what the research uncovered; for trooper path, the cross-verified content from adjudicated.md>

## Tradeoffs
<alternatives considered, with pros/cons>

## Recommendation
<chosen path + why>

## Open Questions
<what remains uncertain; useful when /spec walks this doc>

## Sources
- `path/to/file:line` — short context
- `https://url` — short context
- `runtime: <description>` — observation from a tool run
```

**Rigid sections** — Yoda always emits all 6, even if a section doesn't apply. Empty sections get `_(not applicable)_`.

Trust-label vocabulary is **fixed** (one of the listed strings). Path-label vocabulary is **fixed** (one of `fast` / `escalated-from-signals` / `escalated-from-flag` / `escalated-from-phrasing`). Tests assert these regex patterns to catch drift.

### `/spec` source-defaulting collapses

Pre-v0.16 source-defaulting (3 patterns):
1. `_consult/design-doc/<date>-<slug>-design.md`
2. `_consult/synthesis.md`
3. *(was-going-to-be: `_ask/answer.md`)*

v0.16 source-defaulting (1 pattern):
1. `_consult/design-doc/<date>-<slug>-design.md`

When multiple design-docs exist (e.g. user re-ran /consult on different
topics in the same repo), the AskUserQuestion picker still applies — but
within the design-doc directory only. The 2nd-and-3rd patterns get
deleted from `commands/spec.md` and any source-defaulting helper.

### Filename collision

If `/consult` runs twice on the same topic on the same day, the slug+date
collide. v0.16 **overwrites** the previous design-doc (per the locked
re-run decision Q4-a from earlier brainstorm). User wanting history can
copy the file before re-running, or use a different topic phrasing to
get a different slug.

### `_consult/synthesis.md` deletion

The v0.15 `bin/consult-synthesize.sh` writes `_consult/synthesis.md` at
the end. v0.16 changes this script to write the design-doc directly. The
old path is **dropped** entirely (no back-compat shim).

This is a breaking change for users with archived `_consult-<ts>/` dirs
that contain `synthesis.md`. /spec on archived seeds will need either:
- Manual rename of the archived `synthesis.md` to fit the new pattern, OR
- The user re-runs /consult to regenerate

Per the v0.14 precedent (no back-compat for archived hub-mode markers),
this is acceptable.

### File-level diff plan

#### Modify
| File | Change |
|---|---|
| `commands/consult.md` | Add `--use-force` flag parsing; add fast-path block (Yoda research + 4-signal check + escalation logic + solo design-doc write); update task list table; trooper-path final step writes design-doc directly |
| `bin/consult-init.sh` | Initialize `_consult/design-doc/` subdir during skeleton creation |
| `bin/consult-synthesize.sh` | Write design-doc to `_consult/design-doc/<date>-<slug>-design.md` instead of `_consult/synthesis.md`; drop synthesis.md write |
| `lib/consult.sh` | Possibly add `cw_consult_design_doc_path` helper that derives the canonical path from topic + date; possibly extend `cw_consult_design_doc_filename` if it exists |
| `commands/spec.md` | Drop the multi-pattern source-defaulting; read single path |
| `bin/spec-init.sh` | Same; one path lookup, AskUserQuestion still applies if multiple design-docs exist on disk |
| `.claude-plugin/plugin.json`, `marketplace.json` | Bump 0.15.0 → 0.16.0 |
| `CLAUDE.md` | Add v0.16.0 status entry + dogfood gate |

#### Create
| File | Contents |
|---|---|
| `bin/consult-fastpath.sh` | NEW — orchestrates Yoda fast-path: research prompt + 4-signal check + design-doc write. Called by directive when no escalation triggers fired. |
| `tests/test_consult_fastpath.sh` | Asserts fast-path produces design-doc with `Source: Master Yoda` + `Path: fast` headers |
| `tests/test_consult_use_force_flag.sh` | Asserts `--use-force` skips fast-path and goes straight to trooper spawn |
| `tests/test_consult_phrasing_triggers.sh` | Asserts each of the 6 phrasing triggers escalates to troopers |
| `tests/test_consult_design_doc_output.sh` | Asserts design-doc has rigid 6 sections, fixed Source/Path vocabulary |
| `tests/test_spec_reads_design_doc.sh` | Asserts /spec source-defaulting picks up design-doc (replaces 3-pattern test if any) |
| `docs/superpowers/specs/2026-05-08-unified-consult-design.md` | This spec |
| `docs/superpowers/plans/2026-05-08-unified-consult-plan.md` | Implementation plan (next step) |

#### Delete
| File | Reason |
|---|---|
| `bin/consult-synthesize.sh` (or the synthesis.md write line within) | Replaced by design-doc output; bin script may stay as a thin wrapper that calls the new design-doc writer |
| Any test file that asserts `_consult/synthesis.md` exists | Update to assert `_consult/design-doc/...` instead |

#### Untouched
- `bin/spawn.sh`, `bin/teardown.sh`, `bin/send.sh`, `bin/list.sh` — provider-agnostic, no change
- `bin/medic.sh`, `commands/medic.md`, `bin/deploy-*.sh`, `commands/deploy.md` — separate concerns
- `bin/consult-diff.sh`, `bin/consult-verify-send.sh`, `bin/consult-verify-wait.sh`, `bin/consult-adjudicate.sh`, `bin/consult-drilldown.sh`, `bin/consult-research-send.sh`, `bin/consult-research-wait.sh`, `bin/consult-teardown.sh`, `bin/consult-archive.sh`, `bin/consult-offset-reset.sh` — trooper-path internals; only synthesize changes
- `lib/spec.sh`, `bin/spec-assemble.sh` — /spec output (final repo spec) unchanged
- All v0.15.0 trooper enumeration helpers in `lib/consult.sh` — preserved

## Test plan

1. **Pre-implementation baseline.** `bash tests/run.sh` on post-v0.15.0 main.
2. **Per-task green.** TDD per task; full suite green after each.
3. **Unit: design-doc filename derivation.** Topic + date → expected filename.
4. **Unit: fast-path solo flow.** Stub Yoda research output, invoke fast-path bin, assert design-doc written with `Source: Master Yoda` header.
5. **Unit: --use-force flag parsing.** Directive static wiring asserts the flag is parsed and skips fast-path.
6. **Unit: phrasing trigger detection.** For each of the 6 keywords, asserting topic with that keyword would escalate. (May be directive-static-wiring rather than runtime.)
7. **Unit: 4-signal escalation language.** Directive grep for the 4 signal names ("conflicting evidence" / "significant assumptions" / "high-stakes" / "subjective tradeoffs") + escalation language.
8. **Unit: rigid 6-section schema.** Stage a fast-path output, assert all 6 H2 headers present.
9. **Unit: trust-label vocabulary.** Stage outputs from each path (fast, escalated-from-flag, escalated-from-phrasing, escalated-from-signals) and assert exact header strings match.
10. **Unit: trooper-path synthesize writes design-doc.** Existing v0.15 synthesize test gets updated; design-doc replaces synthesis.md.
11. **Unit: /spec source-defaulting reads design-doc.** Stage `_consult/design-doc/<date>-<slug>-design.md`, invoke spec-init with no positional, assert it picks up the design-doc.
12. **Unit: /spec rejects deprecated paths.** Stage `_consult/synthesis.md` (no design-doc), invoke spec-init, assert it does NOT pick up synthesis.md (per the deletion of pattern 2).
13. **Integration: dogfood (release gate, manual).**
    - **Simple topic** → fast-path: "What does `cw_repo_hash` do?" Expect Yoda-solo design-doc, Source/Path headers correct, 4 signals don't fire.
    - **Phrasing trigger** → trooper escalation: "compare LRU vs LFU carefully" — should fire phrasing trigger before Yoda runs.
    - **Flag escalation**: `/clone-wars:consult --use-force "what is JIT?"` — should skip fast-path even though topic is simple.
    - **Signal escalation**: "Should we add MCP server support to Clone Wars?" — high-stakes + subjective tradeoffs should fire post-research; fast-path escalates to troopers.
    - **/spec consumption**: invoke `/clone-wars:spec` after one of the above; confirm it reads `_consult/design-doc/...` cleanly.

## Risks + rollback

**Risk: 4-signal heuristic over-/under-fires.** Yoda's classification is subjective. Early dogfood may show recommendations on simple topics or skips on complex ones. Mitigation: favor-rigor default means false-positives (over-spawn) cost time, not correctness. Tune the prose descriptions in the directive based on dogfood feedback.

**Risk: Phrasing-trigger false-positives.** Topic phrased "compare A and B" innocently triggers escalation when user just wanted a quick lookup. Mitigation: keyword list is conservative ("compare carefully" requires the qualifier; "compare" alone doesn't trigger). Yoda has prose flexibility to interpret; tune in dogfood.

**Risk: Design-doc rigid sections forcing awkward output.** A trivia question "what does X do?" doesn't naturally have Tradeoffs or Open Questions. The `_(not applicable)_` placeholder may feel verbose. Mitigation: Yoda's prose-fill of empty sections can be terse ("No competing alternatives in scope for this question."); tests check for sections existing, not for substantive content.

**Risk: Breaking change to /spec source-defaulting.** Users with archived `_consult/synthesis.md` lose /spec on those archives. Mitigation: per v0.14 precedent (no back-compat for archived hub-mode), this is acceptable. Document in CLAUDE.md status block.

**Rollback:** single PR; git revert if dogfood reveals fundamental flaws. v0.15.0 stays installable from marketplace history.

## Versioning

- Bump plugin to **v0.16.0** (additive within /consult; breaking for /spec source-defaulting)
- CLAUDE.md status block:
  - `[x] v0.16.0: /consult unified smart-control — single entry point with --use-force flag, phrasing triggers, and 4-signal complexity check; output is always a design-doc at _consult/design-doc/<date>-<slug>-design.md (rigid 6 sections); fast-path skips trooper spawn when topic is simple; favor-rigor escalation; /spec source-defaulting collapses to single path. Drops _consult/synthesis.md (replaced by design-doc); breaking change for archived consult dirs without back-compat.`
  - `[ ] v0.16.0 strict-dogfood pass on a real machine (release gate — verify simple topic → fast-path; phrasing trigger → escalate; --use-force → escalate; signal-fire → escalate; /spec consumes the design-doc cleanly).`

## Out of scope (re-stated)

- Separate `/clone-wars:ask` command (rejected)
- Multiple output formats (only design-doc)
- /spec source-defaulting precedence chain
- Auto-invocation of /spec from /consult
- Re-run history rotation (overwrites)
- Argument flags beyond `--use-force`
- Section-set flexibility (rigid 6)
- Back-compat for `_consult/synthesis.md` consumers

## Acceptance

- All tests in `tests/run.sh` pass after the implementation
- `/clone-wars:consult <simple-topic>` produces a Yoda-solo design-doc without spawning troopers
- `/clone-wars:consult --use-force <simple-topic>` always spawns troopers
- `/clone-wars:consult <topic-with-trigger-keyword>` always spawns troopers
- `/clone-wars:consult <complex-topic>` triggers signal escalation post-research and spawns troopers
- All 4 paths produce a design-doc at `_consult/design-doc/<date>-<slug>-design.md` with the correct Source/Path header
- `/clone-wars:spec` consumes the design-doc cleanly with no source-defaulting chain
- `bin/medic.sh` exits OK on a clean repo
