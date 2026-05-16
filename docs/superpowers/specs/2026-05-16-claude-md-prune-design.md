# CLAUDE.md prune + CHANGELOG relocation — design

**Date:** 2026-05-16
**Type:** Documentation maintenance (no version bump)
**Scope:** Single PR, no code touched

## Summary

Prune `/home/liupan/CC/clone-wars/CLAUDE.md` from 405 lines to ~150 lines by
relocating the 38-version Status section to a new `docs/CHANGELOG.md`, dropping
fully-historical sections (tracer-bullet build order, "things to verify in the
tracer", v0.0.1-pre1 commands prose, drift-prone reference-repo line numbers),
and adding a 15-line "Execution discipline in this repo" section that reinforces
the global background-work rule.

## Problem

CLAUDE.md is auto-injected into every conversation in this repo as `claudeMd`
context. At 405 lines / ~10-12k tokens, it is the largest single document in the
session preamble. Three concrete symptoms:

1. **Bloat.** The Status section is ~75% of the file. Each release adds one
   `[x] vN.M.P` paragraph plus a `[ ] strict-dogfood pass` row that rarely gets
   checked. The list grew linearly through 38 versions.
2. **Stale historical sections.** "Build order" steps 1-8 reference the
   `tracer/` directory which was deleted in v0.29.0. "Things to verify in the
   tracer" lists 5 numbered investigation items that were all resolved by
   v0.0.6+. The intro paragraph about v0.0.1-pre1 status is years stale. The
   "Reference repos to mine" section cites `bridge/cli.cjs:28553` etc. — those
   line numbers will drift in the referenced OMC repo.
3. **Suspected execution-discipline contributor.** In this repo (and only this
   repo), Claude sessions exhibit a "stop-and-wait" failure mode where a
   background bash task is launched, the harness fires the `<task-notification>`
   on exit, and Claude pauses indefinitely instead of continuing. The user's
   global `~/.claude/CLAUDE.md` already has the correct rule (after
   `run_in_background` you'll be notified; don't poll, don't schedule a second
   background task to wait), but the repo CLAUDE.md doesn't reinforce it. The
   hypothesis is that the dense status-list context dilutes the global rule
   enough to bias toward over-stopping.

## Goals

1. CLAUDE.md ≤ 200 lines (target ~150)
2. No information loss: every fact currently in CLAUDE.md is either kept,
   relocated to `docs/CHANGELOG.md`, or already documented elsewhere
   (`docs/DESIGN.md`, `docs/superpowers/specs/*`)
3. Add an explicit "Execution discipline in this repo" section that restates
   the background-work rule in repo-local language
4. Validation hypothesis: the next post-prune session in this repo injects
   ~3-4k tokens of CLAUDE.md instead of ~10-12k. If stop-and-wait stops,
   hypothesis confirmed.

## Non-goals

- Not a version bump. No `vN.M.P` release; commit as `docs(claude-md): …`
- Not touching code, lib/, bin/, commands/, tests/, or `.claude-plugin/`
- Not touching `docs/DESIGN.md` (still the canonical architecture reference)
- Not deleting per-version specs/plans under `docs/superpowers/{specs,plans}/`
  — those are the design trail and stay authoritative
- Not adding a static-wiring lock (CLAUDE.md isn't covered by tests)

## Design

### New CLAUDE.md outline (target ~150 lines)

| § | Section | Lines | Status |
|---|---|---|---|
| 1 | Header + one-paragraph "what this is" | 5 | rewritten — compressed from current ~15 |
| 2 | Canonical references (DESIGN.md, CHANGELOG.md, specs dir) | 5 | new |
| 3 | Current focus (in-flight version + immediate next) | 10 | new |
| 4 | Repository layout (file tree) | 40 | kept with edits — drop `tracer/` tree entry (deleted v0.29.0); drop the v0.0.1-pre1 trailing paragraph ("v0.0.1-pre1 populates …" through "…tmux/IPC assumptions in `docs/DESIGN.md` actually hold on this machine."); drop the trailing sentence about slash commands being "markdown directives that invoke the matching `bin/*.sh` via the Bash tool" (already obvious from `commands/` entries above) |
| 5 | Design summary one-pager | 30 | kept |
| 6 | Conventions | 15 | kept |
| 7 | Execution discipline in this repo | 15 | new |
| 8 | What is out of scope (v0.13.0 closed-set decision) | 10 | kept |
| 9 | Local development | 10 | kept |
| 10 | Conventional commits | 5 | kept |
| | **Total** | **~145** | |

### Sections to delete entirely

- **"Why this exists"** — condensed into section 1 (3-line mention of OMC as
  source pattern; specific cli.cjs line numbers dropped)
- **"Commands" section** (v0.0.1-pre1 status prose, `medic.sh` walkthrough,
  Plan B tracer notes) — stale; replaced by section 3 "Current focus"
- **"Build order steps 1-8"** — fully historical; tracer-bullet step is moot
  (tracer/ deleted v0.29.0), steps 5-8 long completed
- **"Things to verify in the tracer (the load-bearing unknowns)"** — all 5
  unknowns resolved by v0.0.6+; section is archaeology
- **"Reference repos to mine"** — drop the cli.cjs:LINE citations entirely
  (they will drift). If a reader needs OMC, they can grep
  `/home/liupan/ref/oh-my-claudecode` themselves
- **Entire "Status" section** — relocate to `docs/CHANGELOG.md`

### "Execution discipline in this repo" section (verbatim)

```markdown
## Execution discipline in this repo

This repo's release pattern (test suite green → version bump → static-wiring
lock → PR) runs many bash blocks in sequence. A few rules that aren't obvious
from the code:

- **Background bash is fire-and-notify.** When you run `bash tests/run.sh` with
  `run_in_background: true`, the harness sends one `<task-notification>` when it
  exits. Continue with other work in the meantime; do NOT poll, do NOT schedule
  a second background task to wait for the first. Your global
  `~/.claude/CLAUDE.md` has the canonical version — this is the repo-local
  restatement so you don't drift.
- **Version-stamped static-wiring locks have skip-guards.** Tests like
  `test_v0_38_0_static_wiring.sh` check `plugin.json` version and `exit 0` if
  the version doesn't match. A locked test that "passes via skip" is not a
  regression — bump the version when you intentionally add the next-version's
  invariants.
- **Read-before-Edit on plugin.json / marketplace.json / CLAUDE.md.** These get
  touched in late stages of a release PR; if the linter or a sibling task races,
  Re-Read then Edit (recovery is one step; do not stop or pivot).
- **Brainstorm before feature/UX changes** (per saved feedback memory).
  Documentation-only changes (`docs:` commits) skip the brainstorm gate;
  spec/plan pairs still go under `docs/superpowers/{specs,plans}/`.
```

### New `docs/CHANGELOG.md` format

Newest-first, one section per `vN.M.P`. Each entry:

```markdown
## vN.M.P — <date> — <one-line summary>

- <2-4 bullets compressing the current CLAUDE.md paragraph>
- Strict-dogfood: [ ] OR [x] <one-line gate result if exercised>
```

Worked example (compressing current v0.38.0 entry):

```markdown
## v0.38.0 — 2026-05-16 — state-root split (per-machine vs per-project)

- Closes medic→consult chain break on fresh installs: medic wrote per-project
  `providers-available.txt` but Step A roster picker read global path → silent
  "skipping trooper selection" warning
- New `cw_global_state_root` helper (always `${CLONE_WARS_HOME:-$HOME/.clone-wars}`)
  alongside `cw_state_root` (per-project); 15+ sites migrated per data ownership
- Archive dir converges on `~/.clone-wars/archive/` (matches meditate, matches
  pre-v0.31.0 default)
- New permanent lint `tests/test_state_root_discipline.sh` (no skip-guard);
  10-invariant static-wiring lock
- Breaking: v0.31-v0.37 project-local copies become inert; users re-run `/medic`
  once after upgrade
- Strict-dogfood: [ ]
```

This compresses ~25-line current CLAUDE.md entries to ~10-line CHANGELOG
entries, ~60% reduction. Across 38 versions: ~950 lines current → ~380 lines
CHANGELOG. (Acceptable in CHANGELOG.md; it's not auto-loaded into sessions.)

### Migration sequence

1. Create `docs/CHANGELOG.md` with all 38 versions in newest-first order,
   following the format above
2. Rewrite `CLAUDE.md` to the new outline (full replacement via Write tool —
   too many changes for incremental Edit)
3. Verify `wc -l CLAUDE.md` ≤ 200
4. Verify CHANGELOG has all 38 versions (`grep -c '^## v' docs/CHANGELOG.md`
   returns 38)
5. Single commit: `docs(claude-md): prune history to CHANGELOG, add execution-discipline section`
6. PR with body explaining the validation hypothesis

## Validation

Post-prune, the next fresh session in this repo will inject CLAUDE.md at
~3-4k tokens instead of ~10-12k. Two observable outcomes:

- **If stop-and-wait pattern stops** → hypothesis confirmed; CLAUDE.md size
  was contributing
- **If it persists** → hypothesis falsified; investigate user-CLAUDE.md
  interaction or tool-use surface as a separate follow-up

Either way the prune is independently valuable (less noise, no info loss).

## Risks

- **Reference drift on the cli.cjs:LINE citations being dropped:** mitigated
  by noting in section 2 (canonical references) that OMC's source pattern is
  available at `/home/liupan/ref/oh-my-claudecode`; readers grep themselves
- **Future-Claude misses a load-bearing fact buried in a deleted version
  paragraph:** mitigated by CHANGELOG.md being grep-able from the repo and
  per-version specs/plans staying in place under `docs/superpowers/`
- **The "Current focus" section becomes stale:** mitigated by making it
  short (10 lines) and naming the most recent merged version + the next
  open release-gate dogfood item; updates on every minor release

## Out of scope (deferred)

- Automating CLAUDE.md updates on release (a `bin/release.sh` that appends
  to CHANGELOG and updates "Current focus") — possible v0.39.0 work
- Touching `docs/DESIGN.md` (separate concern; still load-bearing)
- Per-subproject CLAUDE.md (`/home/liupan/CC/CLAUDE.md`) — separate doc
