# CLAUDE.md prune + CHANGELOG relocation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prune `CLAUDE.md` from 405 lines to ≤200 by relocating 38 versions of release history to a new `docs/CHANGELOG.md`, dropping fully-historical sections, and adding an "Execution discipline in this repo" section that reinforces the global background-work rule.

**Architecture:** Two file changes, one commit. (1) Create `docs/CHANGELOG.md` from the current CLAUDE.md "Status" section, newest-first, compressed ~60% per entry. (2) Full-replacement rewrite of `CLAUDE.md` via Write tool per the 10-section outline in the spec. No code touched, no tests, no version bump.

**Tech Stack:** None. Pure markdown editing via Read/Write/Edit tools + git.

**Spec:** [`docs/superpowers/specs/2026-05-16-claude-md-prune-design.md`](../specs/2026-05-16-claude-md-prune-design.md) (committed 2918642).

**Baseline:** branch `docs/claude-md-prune` at 2918642 (spec commit), forked off main at 88336cf.

---

## Task 0: Baseline confirmation

**Files:**
- Read-only: `CLAUDE.md` (current, 405 lines)

- [ ] **Step 1: Verify branch state**

Run:
```bash
cd /home/liupan/CC/clone-wars
git branch --show-current
git log -1 --oneline
git status --short
```

Expected:
- Branch: `docs/claude-md-prune`
- HEAD: `2918642 docs(claude-md): spec — prune history to CHANGELOG, add execution-discipline section`
- Status: `?? .deepseek/` and `?? opencode.json` only (intentionally untracked); no other modified files

- [ ] **Step 2: Confirm CLAUDE.md current line count for baseline**

Run: `wc -l /home/liupan/CC/clone-wars/CLAUDE.md`
Expected: `405 /home/liupan/CC/clone-wars/CLAUDE.md`

- [ ] **Step 3: Confirm docs/CHANGELOG.md does NOT exist yet**

Run: `ls /home/liupan/CC/clone-wars/docs/CHANGELOG.md 2>&1`
Expected: `ls: cannot access ... No such file or directory`

---

## Task 1: Create docs/CHANGELOG.md

**Files:**
- Create: `/home/liupan/CC/clone-wars/docs/CHANGELOG.md`
- Read source: `/home/liupan/CC/clone-wars/CLAUDE.md` (the `## Status` section, lines ~200-405)

**Format rules** (per spec §Design → CHANGELOG.md format):

Each version is one block:

```markdown
## vN.M.P — <YYYY-MM-DD if known, else "undated"> — <one-line summary>

- <2-4 bullets compressing the current CLAUDE.md paragraph; preserve concrete
  noun phrases (helper names, env vars, file paths, bug ids); drop narrative
  framing>
- Strict-dogfood: [ ] OR [x] <one-line gate result if exercised>
```

**Ordering:** newest-first. v0.38.0 at top, v0.0.1-pre1 at bottom.

**Dates:** the current CLAUDE.md "Status" entries usually do NOT have explicit dates. Where the prose mentions a concrete date (e.g. v0.13.0's "2026-05-07 dogfood", v0.28.0's "2026-05-13"), use it. Where no date is named, write `undated` — git history can resolve later if needed.

**Compression target:** ~25-line current entries → ~10-line CHANGELOG entries. Use the v0.38.0 worked example in the spec (lines 132-152 of the spec file) as the calibration reference. If an entry in the current CLAUDE.md is already short (≤10 lines), keep it nearly as-is — don't pad.

**Skip the "release gate" rows** that say `- [ ] vN.M.P strict-dogfood pass on a real machine (release gate ...)` as standalone entries. Fold them into the version they belong to via the `Strict-dogfood:` bullet at the end of that version's block.

**v0.6 ghost entry:** the current CLAUDE.md has `[x] v0.6: drop config/identity-template.md back-compat symlink + sweep tracer/*.sh + README.md legacy refs (completed in v0.29.0)`. This is a meta-row, not a real version. Drop it from CHANGELOG — the fact it was completed in v0.29.0 is already captured in the v0.29.0 entry.

**Submission-pending row:** `[ ] Submit to claude-plugins-official (post v0.5.x dogfood)` is also a meta-row, not a version. Drop from CHANGELOG.

- [ ] **Step 1: Read the source Status section**

Run: read `/home/liupan/CC/clone-wars/CLAUDE.md`. Locate the `## Status` heading (around line 200). Everything from that heading to EOF is the source corpus for CHANGELOG entries.

- [ ] **Step 2: Enumerate the version list and lock the expected count**

Run:
```bash
cd /home/liupan/CC/clone-wars
# Real versioned entries — exclude strict-dogfood gate rows, the Submit
# meta-row, the v0.6 ghost row, and any pre-versioned "Design doc written"
# style scaffolding rows (those lack a vN.M.P prefix and will be folded
# into a single "v0.0.x — early scaffolding" CHANGELOG entry).
grep -E '^- \[[ x]\] v[0-9]+\.[0-9]+' CLAUDE.md \
  | grep -vE 'strict-dogfood' \
  | grep -vE '^- \[ \] Submit' \
  | grep -vE '^- \[x\] v0\.6:' \
  | sed -E 's/^- \[[ x]\] (v[0-9.x]+).*/\1/' \
  | sort -u \
  | tee /tmp/cw-changelog-versions.txt \
  | wc -l
```
Output: prints the unique-version count to stderr and writes the version list to `/tmp/cw-changelog-versions.txt`. Note this number — call it `$EXPECTED_VERSIONS`. It is whatever the current CLAUDE.md actually contains (likely 50-65, possibly more); the spec's "38 versions" was a planning-time undercount and the plan adapts to ground truth.

Additionally count the pre-versioned scaffolding rows (rows like `- [x] Design doc written`, `- [x] Repo created on GitHub`, etc. that predate the `v0.1.x` line):
```bash
awk '/^## Status/{f=1; next} f && /^- \[[ x]\] v0\.1\.x/{exit} f' CLAUDE.md \
  | grep -cE '^- \[[ x]\]'
```
Note this count — these are folded into ONE bundled `## v0.0.x — early scaffolding` CHANGELOG entry, so they do NOT bump `$EXPECTED_VERSIONS`. But add 1 for the bundled scaffolding entry itself: the FINAL expected CHANGELOG `## v` count is `$EXPECTED_VERSIONS + 1`.

- [ ] **Step 3: Write CHANGELOG.md**

Use the Write tool. `file_path`: `/home/liupan/CC/clone-wars/docs/CHANGELOG.md`. `content`: a full markdown file starting with:

```markdown
# Changelog

All releases of the Clone Wars Claude Code plugin, newest first.
Per-version design specs live under `docs/superpowers/specs/` and plans
under `docs/superpowers/plans/`. This file is a release-note index, not
a design trail.

---
```

Then for each version in `/tmp/cw-changelog-versions.txt`, in **descending order** (v0.38.0 at top, v0.1.x near bottom), write one CHANGELOG block. Use the v0.38.0 worked example in the spec as the template.

At the bottom, add one bundled entry for the pre-versioned scaffolding rows:

```markdown
## v0.0.x — early scaffolding and tracer validation

Pre-versioned development that predates the `v0.1.x` release line: design doc,
repo creation, marketplace shell, lib/ helpers, /clone-wars:medic, README,
tracer-bullet for codex, real implementations of spawn/send/collect/list/teardown
(landed in v0.0.6+). Full row-by-row history available in `git log`.
```

For each versioned entry, extract from current CLAUDE.md's Status section and compress per the format rules above. Preserve `Strict-dogfood: [x]` from any version that has a documented dogfood pass (notably v0.13.0 and v0.28.0 partial); use `Strict-dogfood: [ ]` otherwise.

**Tip for compression:** the current entries usually open with a colon and a topic name (e.g., `v0.38.0: state-root split — closes the medic→consult chain break...`). Use the colon-prefixed topic as the H2 one-line summary, then bulletize the rest. Drop redundant "see spec at" lines (they're already obvious from `docs/superpowers/specs/`).

- [ ] **Step 4: Verify version count**

Run: `grep -c '^## v' /home/liupan/CC/clone-wars/docs/CHANGELOG.md`
Expected: `$EXPECTED_VERSIONS + 1` (from Step 2 — the unique versioned releases plus one bundled `v0.0.x` scaffolding entry).

If the count differs, list the CHANGELOG's actual versions and diff against Step 2's source list:
```bash
grep -E '^## v' /home/liupan/CC/clone-wars/docs/CHANGELOG.md | sed -E 's/^## (v[0-9.x]+).*/\1/' | sort -u > /tmp/cw-changelog-actual.txt
diff /tmp/cw-changelog-versions.txt /tmp/cw-changelog-actual.txt
```
…and reconcile. (`v0.0.x` should appear in actual but NOT in versions — that's intentional, the bundled scaffolding entry.)

- [ ] **Step 5: Verify newest-first ordering**

Run: `grep -E '^## v' /home/liupan/CC/clone-wars/docs/CHANGELOG.md | head -3`
Expected (first three lines, in order):
```
## v0.38.0 — ...
## v0.37.0 — ...
## v0.36.0 — ...
```

If wrong, fix the ordering (Write tool full replacement).

- [ ] **Step 6: Sanity-check file size**

Run: `wc -l /home/liupan/CC/clone-wars/docs/CHANGELOG.md`
Expected: roughly `$EXPECTED_VERSIONS × 10 + 30` lines (each versioned block ~10 lines + 5-line header + 10-line v0.0.x scaffolding entry + spacing). For ~60 versions that's ~630 lines; for ~50 versions ~530 lines. If the count is wildly off (<300 or >900), recheck the compression and reconcile.

---

## Task 2: Rewrite CLAUDE.md

**Files:**
- Modify (full replacement): `/home/liupan/CC/clone-wars/CLAUDE.md`
- Read source: same file (sections 4, 5, 6, 8, 9, 10 are extracted from current content)

**The new file is exactly these 10 sections in order.** Sections marked "verbatim text below" are written exactly as shown. Sections marked "extract from current" copy from the existing CLAUDE.md with specific edits noted.

- [ ] **Step 1: Read current CLAUDE.md to identify extract regions**

Run: read `/home/liupan/CC/clone-wars/CLAUDE.md`. Note the byte positions of these headings (you'll copy text underneath them):
- `## Repository layout` (the file-tree section)
- `## Design summary (one-page version)`
- `## Conventions`
- `## What is explicitly out of scope`
- `## Local development`
- `## Conventional commits`

- [ ] **Step 2: Compose the new CLAUDE.md content**

Use the Write tool. `file_path`: `/home/liupan/CC/clone-wars/CLAUDE.md`. `content`: the full new file built from the 10 sections below. Concatenate them in order with one blank line between sections.

### Section 1 — Header + "what this is" (verbatim text below):

```markdown
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Clone Wars — what this is

A Claude Code **plugin** that lets a Claude Code session orchestrate
multiple model TUIs (`codex`, `gemini`, `claude`, `opencode`) as **real tmux
panes** the user can attach to and watch live. File-based IPC (inbox / outbox /
status) replaces in-process `SendMessage`. Pane identity follows clone-trooper
naming: `<commander>-<model>-<topic>` (e.g. `rex-codex-auth-review`). The plugin
is deliberately the trimmed primitive — see `## What is explicitly out of scope`
below for the closed-set boundary.
```

### Section 2 — Canonical references (verbatim text below):

```markdown
## Canonical references

- **`docs/DESIGN.md`** — architecture, IPC protocol, contracts table, identity
  prompt. Read first when changing the runtime.
- **`docs/CHANGELOG.md`** — every shipped release, newest-first. Per-version
  release-gate dogfood status lives here.
- **`docs/superpowers/specs/`** — per-version design docs (frozen at design
  time; the design trail for every feature).
- **`docs/superpowers/plans/`** — implementation plans paired with specs.
- **`/home/liupan/ref/oh-my-claudecode`** — the source pattern (grep for
  `CONTRACTS`, `buildWorkerStartCommand`, `createTeamSession` if you need the
  reference implementation; line numbers drift — search by symbol).
```

### Section 3 — Current focus (verbatim text below):

```markdown
## Current focus

- **Most recent merge:** v0.38.0 (state-root split — per-machine vs per-project).
- **Next priority:** strict-dogfood passes for v0.31.0 through v0.38.0
  (release-gate items tracked in `docs/CHANGELOG.md`); v0.38.0 highest priority
  because it validates the medic→consult chain on fresh installs.
- **No code freeze.** Feature work in flight should still go through the
  brainstorm → spec → plan → PR loop per `docs/superpowers/`.
```

### Section 4 — Repository layout (extract from current with edits):

Copy the existing `## Repository layout` section's heading + intro sentence + the entire fenced file-tree block, **with these specific deletions inside the tree:**

- Remove the lines:
  ```
  └── tracer/
      └── tracer-bullet.sh       ← end-to-end validation script (build this FIRST)
  ```
- Remove the entire paragraph after the file-tree that begins `v0.0.1-pre1 populates ...` and ends `...load-bearing tmux/IPC assumptions in 'docs/DESIGN.md' actually hold on this machine.`
- Remove the standalone trailing sentence `Slash commands are markdown directives that invoke the matching 'bin/*.sh' via the Bash tool — they are not themselves bash scripts.`

Keep the file-tree intact otherwise. The result should be ~35-40 lines.

### Section 5 — Design summary one-pager (extract from current verbatim):

Copy the existing `## Design summary (one-page version)` section in its entirety, unchanged. Approximately 30 lines.

### Section 6 — Conventions (extract from current verbatim):

Copy the existing `## Conventions` section in its entirety, unchanged. Approximately 15 lines.

### Section 7 — Execution discipline in this repo (verbatim text below):

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

### Section 8 — What is explicitly out of scope (extract from current verbatim):

Copy the existing `## What is explicitly out of scope` section in its entirety, unchanged. Approximately 18 lines (including the bullet list and trailing paragraph).

### Section 9 — Local development (extract from current verbatim):

Copy the existing `## Local development` section in its entirety, unchanged. Approximately 6 lines.

### Section 10 — Conventional commits (extract from current verbatim):

Copy the existing `## Conventional commits` section in its entirety, unchanged. Approximately 10 lines.

**Drop entirely (not in the new file):** `## Why this exists`, `## Commands`, `## Build order` (steps 1-8), `## Things to verify in the tracer (the load-bearing unknowns)`, `## Reference repos to mine`, `## Status`.

- [ ] **Step 3: Verify line count**

Run: `wc -l /home/liupan/CC/clone-wars/CLAUDE.md`
Expected: `≤ 200 /home/liupan/CC/clone-wars/CLAUDE.md` (target ~145-180)

If over 200, identify the bloated section with `awk '/^## /{print NR": "$0}' CLAUDE.md` and trim.

- [ ] **Step 4: Verify all required sections present**

Run:
```bash
grep -cE '^## (Clone Wars|Canonical references|Current focus|Repository layout|Design summary|Conventions|Execution discipline|What is explicitly out of scope|Local development|Conventional commits)' /home/liupan/CC/clone-wars/CLAUDE.md
```
Expected: `10`

- [ ] **Step 5: Verify deleted sections are absent**

Run:
```bash
grep -cE '^## (Why this exists|Commands|Build order|Things to verify in the tracer|Reference repos to mine|Status)' /home/liupan/CC/clone-wars/CLAUDE.md
```
Expected: `0`

- [ ] **Step 6: Verify tracer/ tree entry gone**

Run: `grep -c '^└── tracer/' /home/liupan/CC/clone-wars/CLAUDE.md`
Expected: `0`

- [ ] **Step 7: Verify Execution discipline section's load-bearing bullet survives**

Run: `grep -c 'fire-and-notify' /home/liupan/CC/clone-wars/CLAUDE.md`
Expected: `1`

---

## Task 3: Commit

**Files:**
- Stage: `docs/CHANGELOG.md` (new), `CLAUDE.md` (modified)

- [ ] **Step 1: Confirm working tree shape**

Run: `git status --short`
Expected (order may vary, intentionally-untracked entries still listed):
```
 M CLAUDE.md
?? .deepseek/
?? docs/CHANGELOG.md
?? opencode.json
```

If you see modifications to anything else (`bin/`, `lib/`, `commands/`, etc.), STOP — the plan only covers CLAUDE.md + docs/CHANGELOG.md.

- [ ] **Step 2: Stage exactly the two intended files**

Run: `git add CLAUDE.md docs/CHANGELOG.md`

Verify: `git status --short` should now show:
```
A  docs/CHANGELOG.md
M  CLAUDE.md
?? .deepseek/
?? opencode.json
```

(`.deepseek/` and `opencode.json` MUST remain untracked. Per CLAUDE.md's project context they are local-env artifacts and never get committed.)

- [ ] **Step 3: Commit**

Run:
```bash
git commit -m "$(cat <<'EOF'
docs(claude-md): prune history to CHANGELOG, add execution-discipline section

Relocate the Status section's release history from CLAUDE.md to a
new docs/CHANGELOG.md (newest-first, ~60% compressed per entry). Drop
fully-historical sections: tracer-bullet build-order (tracer/ deleted v0.29.0),
"things to verify in the tracer" (resolved by v0.0.6+), v0.0.1-pre1 commands
prose, reference-repo cli.cjs:LINE citations (drift-prone). Add "Execution
discipline in this repo" section reinforcing the global background-work rule
(after run_in_background, the harness fires task-notification; do not poll,
do not schedule a second background task to wait).

CLAUDE.md: 405 lines → ≤200 lines. No code touched; no version bump; no tests
affected (CLAUDE.md not covered by static-wiring locks).

Spec: docs/superpowers/specs/2026-05-16-claude-md-prune-design.md
Plan: docs/superpowers/plans/2026-05-16-claude-md-prune-plan.md

Validation hypothesis: post-prune CLAUDE.md injects ~3-4k tokens of session
preamble instead of ~10-12k. If the stop-and-wait failure mode observed in
this repo stops, hypothesis confirmed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: Verify commit landed**

Run: `git log -1 --stat`
Expected:
- Commit message body matches the message above
- Two files changed: `CLAUDE.md` (large negative delta), `docs/CHANGELOG.md` (large positive delta)
- No `bin/`, `lib/`, `commands/`, `tests/`, `.claude-plugin/` files in the stat

Run: `git status --short`
Expected: only `?? .deepseek/` and `?? opencode.json`.

---

## Task 4: Push + open PR

**Files:** none (git operations only)

- [ ] **Step 1: Push branch to origin**

Run: `git push -u origin docs/claude-md-prune`
Expected: branch created on origin; remote-tracking established.

- [ ] **Step 2: Open PR via gh CLI**

Run:
```bash
gh pr create --base main --head docs/claude-md-prune --title "docs(claude-md): prune history to CHANGELOG, add execution-discipline section" --body "$(cat <<'EOF'
## Summary

- Prunes `CLAUDE.md` from 405 lines to ≤200 by relocating the Status section's release history to a new `docs/CHANGELOG.md` (newest-first, ~60% compressed per entry).
- Drops fully-historical sections: tracer-bullet Build Order (tracer/ deleted v0.29.0), "Things to verify in the tracer" (resolved by v0.0.6+), v0.0.1-pre1 Commands prose, drift-prone `cli.cjs:LINE` citations in Reference repos.
- Adds an "Execution discipline in this repo" section reinforcing the global background-work rule from `~/.claude/CLAUDE.md` (after `run_in_background`, the harness fires `<task-notification>` — do not poll, do not schedule a second background task to wait).

## Why

CLAUDE.md is auto-injected into every conversation in this repo. At 405 lines / ~10-12k tokens it had become the largest single document in the session preamble, with ~75% of that being a 38-version `[x]` paragraph list that grew linearly with each release. Historical sections referenced `tracer/` (deleted in v0.29.0) and 5 resolved investigation items from v0.0.x.

## Hypothesis being tested

In this repo (and only this repo), Claude sessions exhibit a "stop-and-wait" failure mode where a background bash task is launched, the harness fires `<task-notification>` on exit, and Claude pauses indefinitely instead of continuing. The user's global `~/.claude/CLAUDE.md` has the correct rule, but the repo CLAUDE.md didn't reinforce it.

Post-prune CLAUDE.md injects ~3-4k tokens of preamble instead of ~10-12k, and the new Execution discipline section restates the background-work rule in repo-local language. If the failure mode stops, hypothesis confirmed.

## Scope

- No code touched (`bin/`, `lib/`, `commands/`, `.claude-plugin/`, `tests/` unchanged).
- No version bump (CLAUDE.md isn't covered by static-wiring locks).
- Two files: `CLAUDE.md` (modified), `docs/CHANGELOG.md` (new).

## Test plan

- [ ] `wc -l CLAUDE.md` returns ≤200
- [ ] `grep -c '^## v' docs/CHANGELOG.md` matches the unique-version count from `CLAUDE.md` plus 1 for the bundled `v0.0.x` scaffolding entry
- [ ] `grep -c 'fire-and-notify' CLAUDE.md` returns 1
- [ ] `grep -cE '^## (Why this exists|Build order|Things to verify in the tracer|Reference repos to mine|Status)' CLAUDE.md` returns 0
- [ ] Sanity-check by starting a fresh Claude Code session in this repo and observing whether the stop-and-wait pattern recurs on the next background `bash tests/run.sh` invocation

Spec: `docs/superpowers/specs/2026-05-16-claude-md-prune-design.md`
Plan: `docs/superpowers/plans/2026-05-16-claude-md-prune-plan.md`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: gh prints the PR URL.

- [ ] **Step 3: Print PR URL for user reference**

The PR URL from Step 2 is the deliverable. Surface it in chat so the user can click through.

---

## Done criteria

- Branch `docs/claude-md-prune` pushed to origin
- PR open against `main` with title `docs(claude-md): prune history to CHANGELOG, add execution-discipline section`
- `CLAUDE.md` ≤ 200 lines
- `docs/CHANGELOG.md` exists with all unique-version entries from CLAUDE.md's Status section plus one bundled `v0.0.x` scaffolding entry, newest-first
- No code files modified anywhere in the diff
