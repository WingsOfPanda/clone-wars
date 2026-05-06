# Split `/clone-wars:consult` into `/consult` + `/spec` — Design

**Date:** 2026-05-06
**Status:** Draft (awaiting user review per brainstorming gate)
**Target version:** v0.12.0

## Goal

Break the monolithic `/clone-wars:consult` directive at its natural seam (Step 8.5 — design-doc walk) into two commands:

- **`/clone-wars:consult`** — multi-trooper research → diff → verify → adjudicate → synthesis. Terminates at `synthesis.md`.
- **`/clone-wars:spec`** — conductor-only design-doc walk that consumes a synthesis seed and produces a committed `<date>-<slug>-<hash>-design.md`.

Each command is independently invokable. `/spec` does **not** spawn troopers; the conductor (you/Yoda) does the entire walk by reading archived findings.

## Background — why split

1. **Context bloat.** The current consult directive is ~750 lines. Splitting halves the surface each command loads.
2. **Resumability.** Today, finishing synthesis and wanting to draft a spec next week means re-running the full investigation. Post-split, archived `synthesis.md` is the seed; `/spec <topic>` works any time.
3. **Re-runnable from any seed.** `/spec` accepts hand-written outlines too — not just consult output. Useful for one-shot spec work without a multi-trooper investigation.
4. **Mental clarity.** "Investigate" and "draft spec from investigation" are genuinely different intents.

## Non-goals (v0.12.0)

- No changes to research / verify / adjudicate / synthesis behavior. The pre-Step-8.5 chain stays byte-identical.
- No changes to the assembled design-doc format. Sacred regression baseline `test_consult_design_doc_assemble_single_unchanged.sh` (renamed) still byte-equal.
- No new section types in `/spec` — same 5 single-repo sections + 3 hub-mode sections as today.
- No `/spec` re-spawning troopers — conductor-only, as the user specified.

## Approach

**Pure topology change**, not a feature change. The pre-8.5 chain stays in `/consult`; Step 8.5 lifts wholesale into `/spec`. Drill-deeper relocates from "during section walk" (current 8.5) to a new pre-teardown Step 8.4 in `/consult`, where troopers are still alive.

```
Today:                            Post-split:
                                  
/consult                          /consult                /spec [topic|seed.md]
├─ research                       ├─ research              ├─ source-default seed
├─ verify                         ├─ verify                ├─ section walk (5 or 8)
├─ adjudicate                     ├─ adjudicate            ├─ assemble + self-review
├─ synthesis                      ├─ synthesis             └─ commit + user-review gate
├─ [8.5 design-doc walk]          ├─ [8.4 drill-deeper]
└─ teardown + archive             └─ teardown + archive
```

## Architecture

### Command surface

| File | Today | Post-split |
|---|---|---|
| `commands/consult.md` | 13 steps incl. Step 8.5 | 12 steps; Step 8.5 removed; new Step 8.4 (drill-deeper) |
| `commands/spec.md` | _(does not exist)_ | NEW — design-doc walk lifted from old Step 8.5 |
| `bin/consult-init.sh` | unchanged | unchanged |
| `bin/consult-research-{send,wait}.sh` | unchanged | unchanged |
| `bin/consult-verify-{send,wait}.sh` | unchanged | unchanged |
| `bin/consult-{diff,adjudicate,synthesize}.sh` | unchanged | unchanged |
| `bin/consult-drilldown.sh` | called from old Step 8.5 | called from new Step 8.4 of `/consult` |
| `bin/consult-{teardown,archive,offset-reset}.sh` | unchanged | unchanged |
| `bin/consult-design-doc.sh` | called from old Step 8.5 | RENAMED → `bin/spec-assemble.sh`, called from `/spec` |
| `bin/spec-init.sh` | _(does not exist)_ | NEW — resolves seed path (source-defaulting), validates |
| `lib/consult.sh` + sub-modules | shared | shared (both commands source `lib/consult-{prompts,validators,hub}.sh`) |

### Data flow

```
/consult ends:
  ~/.clone-wars/state/<repo-hash>/<topic>/
    ├─ rex-codex/findings.md, verify.md
    ├─ cody-claude/findings.md, verify.md
    └─ _consult/
       ├─ synthesis.md          ← /spec's primary seed
       ├─ adjudicated.md         ← /spec reads for context
       ├─ hub-mode.txt           ← /spec routes per-mode
       ├─ targets.txt            ← /spec uses in hub-mode walks
       ├─ skill.txt              ← /spec uses for systematic-debugging skip
       └─ drilldowns/            ← NEW (from Step 8.4); /spec folds in
          └─ <slug>-<commander>.md
  → teardown + archive: state/<repo-hash>/<topic>/  →  archive/<repo-hash>/<topic>/

/spec runs:
  1. Resolve seed: explicit path | most-recent archive scan | error.
  2. Read synthesis.md / adjudicated.md / findings.md / verify.md / hub-mode.txt / targets.txt
     / drilldowns/*.md from the archive.
  3. Walk sections (5 single-repo, 8 hub-mode). Per-section Approve/Revise/Skip.
     (No "Drill deeper" option — drill happened in /consult Step 8.4.)
  4. Invoke bin/spec-assemble.sh — assemble + self-review + git commit.
  5. User-review gate (verbatim from brainstorming skill).
```

### Source defaulting in `/spec`

Mirrors `/clone-wars:deploy`'s pattern:

1. If positional `.md` path given: use that. Validate it has either an explicit `seed-type: synthesis` frontmatter OR contains `## Synthesis` heading (loose accept).
2. Else: scan most-recent archived consult under `~/.clone-wars/archive/<repo-hash>/`:
   ```
   find archive/<repo-hash> -path '*/_consult/synthesis.md' -printf '%T@ %p\n' \
     | sort -n | tail -1 | cut -d' ' -f2-
   ```
   Also check active state (`state/<repo-hash>`) for the rare case consult finished but archive failed.
3. Confirm via `AskUserQuestion` ("Use this", "Cancel").
4. If neither found and no explicit path: refuse with usage hint.

### Drill-deeper relocation (new Step 8.4 in `/consult`)

After Step 8 (synthesis printed), before Step 9 (teardown):

```
AskUserQuestion: "Any aspect to drill deeper before tearing down? (panes still live)"
  options: "Yes — drill" | "No — proceed to teardown"

Loop while user picks "Yes":
  AskUserQuestion: "Topic for this drill?" (free-form)
  AskUserQuestion: "Focus angle?" (free-form)
  AskUserQuestion: "Which trooper?" (rex codex | cody claude | both parallel)
  
  bin/consult-drilldown.sh "$CONSULT_TOPIC" "$TOPIC" "$DRILL_DIR" "$FOCUS" <commander+model...>
  
  Read result file(s). Print summary.
  AskUserQuestion: "Drill another aspect?"
```

Where `DRILL_DIR="$TOPIC_DIR/_consult/drilldowns"` (new location, not `_consult/design-doc/_scratch/`).

`/spec` reads `_consult/drilldowns/*.md` from archive and incorporates findings into the section drafts (Yoda mentions "drilldown found X" inline when relevant).

**Behavior change vs today:** drill is now generic ("drill into TOPIC") instead of section-bound ("drill into Architecture section"). User decides scope. Output is filed under topic-slug, not section-slug.

**Trade-off accepted:** post-split, you can't drill *while* drafting a section in /spec — you have to anticipate at the end of /consult. Per YAGNI: most sections approve on first draft; pre-emptive drilling at end of /consult is acceptable. If dogfood shows users miss mid-walk drilling, revisit in v0.13.

## Components

### `commands/spec.md` (new)

Sections (mirrors current Step 8.5 structure but standalone):

```
# /clone-wars:spec

Walk a design doc from a consult synthesis (or any seed). Conductor-only —
no troopers spawned. Produces docs/clone-wars/specs/<date>-<slug>-<hash>-design.md.

Spec: docs/superpowers/specs/2026-05-06-consult-spec-split-design.md

## Task list (TaskCreate × 7 BEFORE step 0)

| # | subject | activeForm |
|---|---|---|
| 0 | 0 Resolve seed [yoda] | Resolving seed |
| 1 | 1 Detect mode (single/hub) [yoda] | Detecting mode |
| 2 | 2 Walk sections [yoda] | Walking sections |
| 3 | 3 Assemble + self-review [yoda] | Assembling |
| 4 | 4 Commit [yoda] | Committing |
| 5 | 5 User-review gate [yoda] | Awaiting user review |
| 6 | 6 Done [yoda] | Done |

## Steps

### Step 0 — Resolve seed
   bin/spec-init.sh resolves $SEED_PATH (explicit | source-default | refuse).
   Sets $CONSULT_TOPIC (extracted from path) for downstream resume-state.

### Step 1 — Detect mode
   Read _consult/hub-mode.txt from archive. Set $HUB_MODE ∈ {single,hub-subrepo,super-hub}.

### Step 2 — Walk sections
   (Same per-section loop from old Step 8.5: SECTIONS array, resume check via
    cw_consult_design_doc_resume_state, draft → present → Approve/Revise/Skip.
    Drill-deeper option is REMOVED.)

### Step 3 — Assemble + self-review
   bin/spec-assemble.sh "$CONSULT_TOPIC". Handles output collisions and validator failures
   identically to old Step 8.5.

### Step 4 — Commit
   bin/spec-assemble.sh handles git commit. Failure modes: surface git error verbatim.

### Step 5 — User-review gate
   "Spec written and committed to <path>. Please review it and let me know if you want
    to make any changes before we start writing out the implementation plan."
   Wait. If changes requested, edit + amend; re-invoke this gate.

### Step 6 — Done
   Print final path. Done.
```

### `bin/spec-init.sh` (new)

```bash
#!/usr/bin/env bash
# bin/spec-init.sh — resolve seed path and topic for /clone-wars:spec.
# Usage: spec-init.sh [<seed.md>]
#   With arg:   validate, echo "TOPIC=<extracted>\nSEED=<resolved-abs>"
#   Without:    scan archive for most-recent _consult/synthesis.md, ask user.
set -euo pipefail
source "$(dirname "$0")/../lib/state.sh"

SEED="${1:-}"
if [[ -n "$SEED" ]]; then
  [[ -f "$SEED" ]] || { echo "FAIL: seed not found: $SEED" >&2; exit 1; }
  SEED=$(readlink -f "$SEED")
else
  REPO_HASH=$(cw_repo_hash)
  STATE_ROOT="${CLONE_WARS_HOME:-$HOME/.clone-wars}"
  SEED=$(find "$STATE_ROOT/archive/$REPO_HASH" "$STATE_ROOT/state/$REPO_HASH" \
              -path '*/_consult/synthesis.md' -type f -printf '%T@ %p\n' 2>/dev/null \
         | sort -n | tail -1 | cut -d' ' -f2-)
  [[ -n "$SEED" ]] || { echo "FAIL: no synthesis.md found; pass an explicit path" >&2; exit 1; }
fi

# Topic = parent dir of _consult (e.g. .../<topic>/_consult/synthesis.md → <topic>)
TOPIC=$(basename "$(dirname "$(dirname "$SEED")")")
[[ -n "$TOPIC" && "$TOPIC" != "/" ]] || { echo "FAIL: cannot extract topic from $SEED" >&2; exit 1; }

printf 'TOPIC=%s\nSEED=%s\n' "$TOPIC" "$SEED"
```

### `bin/spec-assemble.sh` (rename of `bin/consult-design-doc.sh`)

Pure rename. Same args, same behavior, same exit codes. Updates:
- File rename: `git mv bin/consult-design-doc.sh bin/spec-assemble.sh`.
- Internal references: any `bin/consult-design-doc.sh` mentions in lib/ or tests/ updated.
- `commands/consult.md` no longer references it (Step 8.5 removed).
- `commands/spec.md` references it.

### `commands/consult.md` (modified)

- Step 8.5 (entire section, lines ~497-737) **deleted**.
- Step 8.4 added between Step 8 and Step 9 — drill-deeper loop (see Architecture section above).
- Step 9 (teardown) becomes the unconditional terminal step. The "if Step 8.5 ran, skip" branch removed.
- `--design-doc` flag handling in Step 0: deprecated. If passed, print:
  > `WARN: --design-doc is deprecated as of v0.12.0. Run /clone-wars:spec separately after consult finishes.`
  Continue without entering any design-doc flow.

### Library code (lib/)

**No file moves or renames.** `lib/consult.sh`, `lib/consult-prompts.sh`, `lib/consult-validators.sh`, `lib/consult-hub.sh` stay put. Both commands source them.

Rationale: drill, hub, validators, and prompts are shared concepts. Renaming to `lib/spec-*` would force unnecessary churn in the v0.11.1 shim and the `_cw_consult_*` underscore-prefixed helpers. The lib name reflects the **conceptual domain** (consultation flow), not which command invokes it.

### Tests

| File | Action |
|---|---|
| `tests/test_consult_design_doc_assemble_single_unchanged.sh` | RENAME → `test_spec_assemble_single_unchanged.sh`; update `bin/consult-design-doc.sh` → `bin/spec-assemble.sh`. **Sacred byte-equality baseline preserved.** |
| `tests/test_consult_load_prompt_migration.sh` | UNCHANGED. Tests v0.4.2 prompt templates — still valid. |
| `tests/test_consult_lib_shim_sources_all.sh` | UNCHANGED. Lib structure unchanged. |
| `tests/test_consult_slug_regex_constant.sh` | UNCHANGED. |
| `tests/test_consult_spawn_rollback.sh` | UNCHANGED. v0.11.2 cold-start retry still applies. |
| `tests/test_spec_init_source_defaulting.sh` | NEW — explicit path / archive scan / refuse. |
| `tests/test_spec_resume_state.sh` | NEW — section approval persistence across `/spec` re-runs. |
| `tests/test_consult_step84_drilldown_wiring.sh` | NEW — static wiring: `commands/consult.md` Step 8.4 invokes `bin/consult-drilldown.sh` correctly with new `_consult/drilldowns/` path. |
| `tests/test_consult_design_doc_flag_deprecated.sh` | NEW — `/consult --design-doc` prints deprecation warning, does NOT enter any walk. |
| `tests/test_spec_directive_static_wiring.sh` | NEW — `commands/spec.md` references `bin/spec-init.sh` and `bin/spec-assemble.sh`; does NOT spawn or call any trooper-side script. |

## Error handling

| Failure | Where | Behavior |
|---|---|---|
| Seed path doesn't exist | `bin/spec-init.sh` | Exit 1 with "seed not found: <path>" |
| No synthesis.md in archive | `bin/spec-init.sh` | Exit 1 with "no synthesis.md found; pass an explicit path" |
| Topic dir not extractable | `bin/spec-init.sh` | Exit 1 with "cannot extract topic from <seed>"; for hand-written seeds without a `_consult/<topic>/` parent, suggest `--topic` flag (deferred to v0.13) |
| Output collision | `bin/spec-assemble.sh` | Same as today (Overwrite/Suffix/Abort prompt) |
| Validator failure | `bin/spec-assemble.sh` | Same as today (re-walk offending section) |
| Git commit failure | `bin/spec-assemble.sh` | Surface git stderr; user resolves manually |
| Drill-deeper while no troopers | `commands/consult.md` Step 8.4 | Step 8.4 is BEFORE teardown — troopers always alive when offered |
| Hub-mode mismatch | `commands/spec.md` Step 1 | If `_consult/hub-mode.txt` missing from archive, default to "single" with a warning log line |

## Migration / back-compat

**`/clone-wars:consult --design-doc` flag:** deprecated, not removed. Prints warning, continues to synthesis without walking design-doc. Users must invoke `/clone-wars:spec` separately. Deprecation notice in CLAUDE.md status line and v0.12.0 release notes.

**Existing archives:** `/spec` reads from `~/.clone-wars/archive/<repo-hash>/<topic>/_consult/synthesis.md`. Pre-v0.12 archives have this same layout — no migration needed.

**Existing in-flight design-doc walks:** none can survive a version bump (each `/clone-wars:consult` run is end-to-end within a single conductor session). No drain-and-cutover needed.

## Out of scope (v0.12.0, deferred to v0.13+)

- `/spec --topic <name>` flag for hand-written seeds without a consult parent dir.
- `/spec` re-spawning troopers for mid-walk drill (user explicitly out-scoped this).
- New section types beyond the current 5 single-repo + 3 hub-mode set.
- Auto-chain `/consult --design-doc` (would defeat the split's context-relief goal).
- `lib/consult-*.sh` file renames to `lib/spec-*.sh` (churn for no benefit in v1).

## Self-review (run after writing)

- [x] No "TBD"/"TODO"/"fill in" placeholders.
- [x] Internal consistency: section file paths match across architecture / components / tests sections.
- [x] Scope check: single-implementation plan focused on the split, not bundled with unrelated cleanups.
- [x] Ambiguity check: source-defaulting precedence (explicit > archive > active state > error) explicit; deprecation warning string spelled out verbatim.
- [x] Behavior changes called out: drill-deeper goes from per-section to free-form-topic; flagged as accepted trade-off with revisit criterion.
