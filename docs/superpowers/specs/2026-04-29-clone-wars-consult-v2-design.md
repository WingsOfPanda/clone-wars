# /clone-wars:consult v0.2 — Split Orchestrator with Conductor-Reachable Steps

**Status:** Design — Revision 1 (post-Codex adversarial review, 2026-04-29)
**Date:** 2026-04-29
**Target version:** v0.2.0 — replaces v0.1.x's monolithic `bin/consult.sh` + `bin/consult-finalize.sh`
**Supersedes:** `docs/superpowers/specs/2026-04-28-clone-wars-consult-design.md` (v0.1 architecture)

## Revision 1 changelog (closes Codex adversarial findings)

| # | Codex finding | Resolution in this revision |
|---|---|---|
| 1 | Offset files poison retry — no executable contract for re-prompt | Per-commander state files (`_consult/research-<commander>.txt`) replace the shared `research_offsets.txt`; new `bin/consult-offset-reset.sh <topic> <commander> <phase>` primitive provides the documented retry path |
| 2 | `cw_outbox_wait_all` returns on first timeout — can't surface per-trooper status | Wait split per-commander: `bin/consult-research-wait.sh <topic> <commander>` × 2 parallel; each writes its own commander state file. Helper change scoped to switching from `cw_outbox_wait_all` to a single-trooper `cw_outbox_wait_since` per script |
| 3 | Parallel spawn drops rollback guarantee | Spawn-group rollback added to slash directive contract: if either parallel `bin/spawn.sh` returns nonzero, conductor immediately tears down the surviving pane and removes `_consult/`. Test fixture covers one-success/one-failure |
| 4 | Adjudicate overwrite deletes resolved decisions | Adjudicated file split: `consult-adjudicate.sh` writes `adjudicated-draft.md` (regenerable). Conductor copies to `adjudicated.md` and resolves PENDINGs there. `consult-synthesize.sh` reads only `adjudicated.md` |

---

## Goal

Refactor the `/clone-wars:consult` orchestration surface so the conductor (the
Claude Code session running the slash directive) regains control between every
phase of the consult lifecycle. This unlocks two concrete wins:

1. **Live task-list progress.** v0.1.x's monolithic `bin/consult.sh` runs
   Phases 1–5 in a single opaque `Bash(...)` call. Once the conductor invokes
   it, the task list spinner is stuck on "Spawning rex" for the entire
   research + diff + cross-verify duration (5–15 min). Splitting into
   per-phase sub-scripts lets the conductor flip task statuses at every step
   boundary, so the user sees real progress.
2. **Conductor-mediated trooper intervention between phases.** When something
   goes wrong mid-consult — a trooper writes prose findings without the
   `[citation]` format, a diff produces zero AGREED items, a verify returns
   all-UNCERTAIN — the conductor today has no way to react before
   `bin/consult.sh` blindly steamrolls into the next phase. With per-phase
   sub-scripts, the conductor can `cw_send` a clarifying prompt to a trooper,
   re-run a step, or pause and ask the user for new direction.

The v0.2 design is a clean break: there is no monolith. Anyone who needs
end-to-end automation can write their own wrapper composing the sub-scripts.

---

## Motivation

The v0.1 architecture has three concrete problems we observed in dogfood:

- **Stale spinner**: in the v0.1.2 dogfood run, task `1.1 Spawning rex` stayed
  `in_progress` for the entire `bin/consult.sh` invocation. Tasks 1.2–1.7 only
  flipped to `completed` in one batch when the bash call returned. The user
  reported this directly.
- **No intervention point** between research and verify, or between verify and
  adjudicate. If the dispatch produces nonsense, the conductor watches it
  burn through the rest of the timeout budget.
- **Sequential spawn**: `bin/consult.sh` spawns rex, waits for ready, THEN
  spawns cody. In tmux + codex/claude bootstrap times, this serializes ~15s
  of unnecessary wall time.

v0.2 fixes all three by structure, not by streaming-output hacks.

---

## Architecture

```
slash directive  ──▶  bin/consult-init.sh <topic-text>
                            │ slug-derive, _consult/ dir, topic.txt
                            │ prints: consult-<slug>
                            ▼
                      ┌── bin/spawn.sh rex codex <topic>      ─┐ PARALLEL
                      └── bin/spawn.sh cody claude <topic>     ┘ (existing scripts;
                            │                                    conductor invokes
                            │                                    both as parallel
                            │                                    Bash tool calls)
                            ▼
                      ┌── bin/consult-research-send.sh <topic> rex codex   ─┐ PARALLEL
                      └── bin/consult-research-send.sh <topic> cody claude  ┘
                            │ each writes its own _consult/research-<commander>.txt
                            │ with OFFSET=<n>; idempotency-fail-loud per file
                            ▼
                      ┌── bin/consult-research-wait.sh <topic> rex codex   ─┐ PARALLEL
                      └── bin/consult-research-wait.sh <topic> cody claude  ┘
                            │ each appends FS=<status> to its own commander
                            │ state file; per-trooper status survives even
                            │ if its peer times out
                            ▼
                      bin/consult-diff.sh <topic>
                            │ cw_consult_diff
                            │ writes diff.md + rex_only_items.txt + cody_only_items.txt
                            ▼
                      ┌── bin/consult-verify-send.sh <topic> rex codex   ─┐ PARALLEL
                      └── bin/consult-verify-send.sh <topic> cody claude  ┘ (each conditional —
                            │                                               skips if peer's
                            │                                               _ONLY file is empty)
                            │ each writes _consult/verify-<commander>.txt
                            │ with OFFSET=<n> (or VS=skipped if no peer items)
                            ▼
                      ┌── bin/consult-verify-wait.sh <topic> rex codex   ─┐ PARALLEL
                      └── bin/consult-verify-wait.sh <topic> cody claude  ┘
                            │ each appends VS=<status> to its own state file
                            ▼
                      bin/consult-adjudicate.sh <topic>
                            │ reads research-*.txt + verify-*.txt + verify.md files
                            │ writes adjudicated-DRAFT.md (regenerable, idempotent)
                            ▼
                      conductor: cp adjudicated-draft.md adjudicated.md
                            │ (no script — explicit shell step in directive)
                            ▼
            ┃ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            ┃   INTERMEDIATE INTERVENTION POINT — see "Intervention patterns"
            ┃   conductor:
            ┃     - reads adjudicated.md
            ┃     - resolves PENDINGs via Edit
            ┃     - OR cw_sends a follow-up to a trooper if findings are
            ┃       degraded; can re-run consult-adjudicate after
            ┃     - OR pauses and asks the user
            ┃ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                            ▼
                      bin/consult-synthesize.sh <topic>
                            │ refuses on any ^- PENDING: line in adjudicated.md
                            │ writes synthesis.md
                            ▼
                      bin/consult-teardown.sh <topic>
                            │ kills both panes; archives trooper dirs
                            ▼
                      bin/consult-archive.sh <topic>
                            │ moves _consult/ → archive/.../_consult-<ts>/
                            ▼
            slash directive presents synthesis.md to user
```

**12 sub-scripts. 13 conductor-controlled step boundaries** (init, 2
spawn-parallel, 2 research-send-parallel, 2 research-wait-parallel, diff, 2
verify-send-parallel, 2 verify-wait-parallel, adjudicate, draft-copy,
synthesize, teardown, archive — plus `consult-offset-reset.sh` invoked
on-demand inside intervention loops).

---

## Components (sub-script contracts)

Each sub-script takes `<consult-topic>` as its first argument (after init,
which takes the raw topic text). All sub-scripts:

- Source `lib/log.sh`, `lib/state.sh`, `lib/consult.sh` and validate the
  topic argument via `cw_consult_topic_validate <topic>` (a new helper that
  rejects path-traversal patterns, enforces `^[A-Za-z0-9_.-]+$`, and confirms
  `consult-` prefix).
- Set `set -uo pipefail` (matching existing `bin/*.sh` convention).
- Print INFO messages to stderr via `log_info`; the only stdout output is
  data the next step needs (e.g., the consult topic from `init`, the offset
  from `research-send`).
- Are **fail-loud non-idempotent** — refuse to run if their expected output
  already exists (more detail in "Idempotency contract" below).
- Return **rc=0 on success**, **rc≥1 on failure** with a meaningful stderr
  message.

### `bin/consult-init.sh <topic-text>`

Replaces the slug-derivation half of v0.1's `bin/consult.sh`.

- Lowercases + slugifies + caps base slug to 20 chars (per v0.1 fix #1).
- Resolves conflicts up to `consult-<slug>-999`; exits 1 beyond.
- Creates `<state-root>/state/<repo-hash>/<topic>/_consult/`.
- Writes `topic.txt` with the raw topic-text (no newline trimming).
- Prints the resolved `<consult-topic>` to **stdout** (one line, no
  trailing whitespace).
- Prints info messages to **stderr** for the conductor's log.

The conductor captures `CONSULT_TOPIC=$(bin/consult-init.sh "$ARGUMENTS")` and
passes it to subsequent calls.

### `bin/consult-research-send.sh <topic> <commander> <model>`

- Validates topic; resolves trooper state dir.
- Builds the research prompt via `cw_consult_build_research_prompt`.
- Captures the trooper's outbox file size: `OFFSET=$(wc -c < <outbox>)`.
- Writes per-commander state file `_consult/research-<commander>.txt` with
  one line: `OFFSET=<n>`. **Refuses if the file already exists**
  (idempotency-fail-loud). To re-prompt, the conductor first runs
  `bin/consult-offset-reset.sh <topic> <commander> research` which removes
  the file.
- Invokes `bin/send.sh <commander> <topic> "@<prompt-path>"`.
- Returns rc=0 on success, ≥1 on send failure (with the state file already
  written — so the conductor knows a send was attempted; reset to retry).

### `bin/consult-research-wait.sh <topic> <commander> <model>`

Per-trooper wait. The conductor invokes 2× in parallel.

- Refuses if `_consult/research-<commander>.txt` is missing (no offset to
  wait against — `research-send` must have run first).
- Reads `OFFSET=<n>` from the file; reads research timeout from
  `cw_consult_timeout research`.
- Calls `cw_outbox_wait_since <commander> <model> <topic> "$OFFSET" done error "$timeout"`.
- After wait, computes findings status via `cw_consult_findings_status`
  (ok / empty / malformed / missing) — even if the wait timed out, status
  is computed against whatever findings.md the trooper produced.
- Appends `FS=<status>` to `_consult/research-<commander>.txt`.
- Returns rc=0 always — the status field carries what happened. (The
  conductor gates downstream steps on the status, not the rc.) Stderr gets
  a log line on timeout.

**Per-trooper-file design rationale**: parallel writers each touch their
own commander file, so there's no append-race on a shared
`research_status.txt`. The split also fixes Codex finding #2: if rex times
out and cody finishes, cody's status survives.

### `bin/consult-diff.sh <topic>`

- Refuses if `diff.md` already exists.
- Refuses if either `<rex-dir>/findings.md` or `<cody-dir>/findings.md` is
  missing (degraded path: status file already has `missing` → conductor
  decides to skip diff or to `cw_send` a follow-up).
- Calls `cw_consult_diff` → writes `_consult/diff.md`.
- Extracts `_only_items.txt` files for verify-send.

### `bin/consult-verify-send.sh <topic> <commander> <model>`

Symmetric to `research-send`, but conditional.

- Validates topic; resolves trooper state.
- Refuses if `_consult/verify-<commander>.txt` already exists.
- Reads peer's `_only_items.txt` (rex sends → reads `cody_only_items.txt`).
- If peer file empty → writes `_consult/verify-<commander>.txt` with one
  line `VS=skipped` and exits rc=0. (No prompt sent; `verify-wait` will
  see the skipped status and short-circuit.)
- Otherwise: builds verify prompt, captures offset, writes
  `_consult/verify-<commander>.txt` with `OFFSET=<n>`, sends. Same
  failure semantics as `research-send`.

### `bin/consult-verify-wait.sh <topic> <commander> <model>`

Per-trooper wait, mirrors `research-wait`.

- Refuses if `_consult/verify-<commander>.txt` is missing.
- If file contains `VS=skipped` (no dispatch happened) → exits rc=0; nothing to wait.
- Else reads `OFFSET=<n>`, calls `cw_outbox_wait_since`, derives verify
  status (ok / empty / missing / timeout / error / send-failed) by
  examining the resulting `verify.md` and the wait rc.
- Appends `VS=<status>` to `_consult/verify-<commander>.txt`.
- Returns rc=0 always.

### `bin/consult-offset-reset.sh <topic> <commander> <phase>`

NEW (post-Codex-rev1). Required executable primitive for the intervention
patterns. Removes the per-commander state file so the conductor can re-run
`research-send` or `verify-send` after re-prompting a trooper.

- `<phase>` is `research` or `verify`.
- Refuses if topic / commander / phase invalid.
- Atomically removes `_consult/<phase>-<commander>.txt`. Removal is the
  reset signal — the absence of the file is what `research-send` /
  `verify-send` requires to re-run.
- ALSO removes any downstream artifacts that depend on this commander's
  state for that phase (e.g., reset of `research-rex.txt` removes `diff.md`
  and `*_only_items.txt` and `adjudicated-draft.md` if they exist, since
  they're computed from the now-stale findings).
- Returns rc=0 always (idempotent: removing a missing file is fine).
- Documented as "the only way to retry a phase for one commander" — the
  spec forbids manual editing of state files.

### `bin/consult-adjudicate.sh <topic>`

- Reads all four `research-<commander>.txt` and `verify-<commander>.txt`
  files via `cw_consult_status_load` (per-file env-var parse).
- Reads both `verify.md` files and `_only_items.txt` files.
- Writes `_consult/adjudicated-draft.md` (NOT `adjudicated.md`) with the
  four-section schema.
- **Idempotent on the draft** — overwrites `adjudicated-draft.md` freely
  on re-run. No warning, no backup. The draft is regenerable computation
  output, never edited by the conductor.
- The conductor's PENDING-resolution work lives in `adjudicated.md`, NOT
  the draft. The two-file split (Codex finding #4 closure) is the contract
  that prevents conductor edits from being silently destroyed.

After `consult-adjudicate.sh` produces the draft, the slash directive
instructs the conductor:

```
cp _consult/adjudicated-draft.md _consult/adjudicated.md
```

(or skips the cp if `_consult/adjudicated.md` already exists, since that
means the conductor's prior resolution work survives a re-adjudicate). The
conductor edits `adjudicated.md` to resolve PENDINGs.

### `bin/consult-synthesize.sh <topic>`

- Refuses if `synthesis.md` already exists (idempotency).
- Refuses if `_consult/adjudicated.md` is missing — the conductor must
  have copied the draft and resolved PENDINGs.
- Refuses if `adjudicated.md` contains any `^- PENDING:` line. Print the
  offending line(s) and the path the conductor should edit. Exit 1.
- Loads statuses via `cw_consult_status_load` (per-commander env-var
  parser).
- Calls `cw_consult_synthesize` → writes `synthesis.md`.
- **Prints the synthesis to stdout** so the conductor / user sees it inline.

### `bin/consult-teardown.sh <topic>`

- Calls `bin/teardown.sh <topic>` (existing).
- The existing teardown handles both trooper-pane kill and trooper-state
  archive. Does NOT touch `_consult/`.
- Returns rc=0 even if some panes were already gone (teardown.sh's behavior).

**Note** (Codex finding #6): existing `bin/teardown.sh` ends with `rmdir
"$topic_dir" 2>/dev/null || true`, which silently no-ops when `_consult/`
is still present. The contract: teardown's rmdir is a "remove if empty"
hint; the actual topic-dir cleanup is `consult-archive`'s job. The dual
rmdir is benign — teardown's fails silently because `_consult/` is still
inside; archive's succeeds after the move.

### `bin/consult-archive.sh <topic>`

- Refuses if `_consult/` is missing (already archived) — fail-loud.
- Moves `<topic-dir>/_consult/` to
  `<archive-root>/<topic>/_consult-<ts>/`.
- Removes the now-empty `<topic-dir>` (rmdir, ignore failure — if some
  unexpected sibling remains, leave it for forensics).

---

## File-IPC contracts (unchanged from v0.1)

These are the contracts between bash and troopers. v0.2 only refactors
orchestration; data formats stay the same:

- **`findings.md`** — same `## Summary` / `## Claims` (`N. [<cite>] <text>`) /
  `## Notes` schema as v0.1.
- **`verify.md`** — same `## Verdicts` (`N. <TAG> [<cite>] <text>` +
  indented evidence line) schema. Parser captures all 4 columns.
- **`diff.md`** — same `## Agreed` / `## Rex-only` / `## Cody-only` schema.
- **`adjudicated.md`** — same `## Cross-verified` / `## Adjudicated` /
  `## Contested` / `## Not-verified` schema with `- PENDING:` lines as the
  no-PENDING enforcement signal.
- **`synthesis.md`** — same 6-section schema (Title, Agreed, Cross-verified,
  Adjudicated, Contested, Not-verified, Trooper artifacts).

New files (v0.2 only):

- **`_consult/research-<commander>.txt`** — per-commander state for the
  research phase. Two-line shape after `research-wait` completes:

  ```
  OFFSET=<n>
  FS=<ok|empty|malformed|missing>
  ```

  Written by `research-send` (just `OFFSET=`), then appended by
  `research-wait` (`FS=`). One file per commander → no shared-file race.

- **`_consult/verify-<commander>.txt`** — per-commander state for verify.
  Same shape with `VS=` after `verify-wait`. Special case: if peer's
  `_only_items.txt` is empty, `verify-send` writes only `VS=skipped` and
  no `OFFSET=`.

- **`_consult/adjudicated-draft.md`** — generated by `consult-adjudicate`,
  freely overwritable. Never edited by conductor.

- **`_consult/adjudicated.md`** — conductor's resolution surface. Created
  by `cp` from the draft, edited via `Edit` tool to resolve `^- PENDING:`
  lines into `^- CONFIRMED:`/`^- REFUTED:`/move-to-Contested. Read by
  `consult-synthesize`. **Never overwritten by any sub-script** — this is
  the contract that prevents Codex finding #4.

These per-commander files and the draft/resolved split are internal
plumbing; the only externally visible artifacts are `findings.md`,
`verify.md`, `diff.md`, `synthesis.md`, and the trooper-state archive.

---

## Idempotency contract

**Rule (per Q2A): every sub-script fails loud if its expected output already
exists.** Two exceptions:

- `bin/consult-adjudicate.sh` writes `adjudicated-draft.md`, which IS
  freely overwritable on re-run. The conductor-edited `adjudicated.md` is
  a separate file that adjudicate **never** touches (Codex finding #4
  closure).
- `bin/consult-offset-reset.sh` is the **only** documented retry tool. It
  removes per-commander state to permit a new `research-send` /
  `verify-send`. Calling reset on a non-existent file is a no-op.

`bin/spawn.sh` (existing v0.0.x) already refuses duplicate `<commander>`
on a topic — that's where idempotency for spawn lives.

**Retry contract (Codex finding #1 closure)**. The intervention patterns
require executable steps, not narrative. The supported retry sequence for
re-prompting a trooper is:

```
1. /clone-wars:send <commander> <topic> "<clarifying prompt>"   # nudges trooper
2. bin/consult-offset-reset.sh <topic> <commander> research     # removes
                                                                # research-<commander>.txt
                                                                # AND derived artifacts
3. bin/consult-research-send.sh <topic> <commander> <model>     # re-records OFFSET=<new>
4. bin/consult-research-wait.sh <topic> <commander> <model>     # waits for done; sets FS
5. bin/consult-diff.sh <topic>                                  # recomputes diff (was
                                                                # cleared by reset)
```

The reset script's removal of derived artifacts (diff.md, _only_items.txt,
adjudicated-draft.md) is the documented executable contract for state
hygiene. Without reset, the conductor would have to manually `rm` 4 files
in a specific order — exactly the "undocumented state surgery" Codex
flagged.

**Failure mode**: any sub-script that detects its output already present
exits rc=1 with a stderr message naming the file AND the reset command to
clear it. The conductor must explicitly run reset (or for non-trooper
artifacts, just `rm`) before retrying.

**Why fail-loud over silent overwrite**: silent re-runs can corrupt the
offset cursor. The second `research-send` would record an offset *past*
the trooper's first `done` event, and `research-wait` would never see new
events. Reset makes the retry explicit and idempotent.

---

## Intervention patterns

The whole point of the split. Three concrete examples documented in the
spec; the slash directive references these so users know what's possible:

### Pattern 1: Malformed findings → re-prompt before diff

After `consult-research-wait rex codex`, if `research-rex.txt` shows
`FS=malformed`, the conductor uses the documented retry contract:

```
1. /clone-wars:send rex <topic> "Reformat your findings — every claim
   needs a [<citation>] prefix. Write to <state-dir>/findings.md.
   END_OF_INSTRUCTION"
2. bin/consult-offset-reset.sh <topic> rex research
3. bin/consult-research-send.sh <topic> rex codex
4. bin/consult-research-wait.sh <topic> rex codex
5. bin/consult-diff.sh <topic>          # diff.md was reset; recompute
```

After step 5, status check `research-rex.txt` again; if `FS=ok`, proceed
to verify-send. If still malformed, escalate to the user.

**Constraint on the re-prompt content**: the cw_send message MUST tell
the trooper to write to `<state-dir>/findings.md` (matching the original
research prompt's contract). A free-form re-prompt that doesn't specify
the path will leave findings.md unchanged — research-wait will see the
same `FS=malformed` and the loop fails to advance.

### Pattern 2: Zero-AGREED diff → user pause

After `consult-diff`, if `diff.md`'s `## Agreed` section is empty AND
`## Rex-only` + `## Cody-only` are both populated, the topic likely lacks
a shared frame of reference. The conductor asks the user before proceeding:

> "Both troopers researched the topic but agreed on zero claims. They
> may be researching different things. Should we re-research with a
> clarified topic, or proceed with cross-verification?"

If the user says re-research, the conductor calls `consult-teardown` +
`consult-archive`, then re-runs the full flow with a refined topic. If
proceed, the conductor moves to `consult-verify-send`.

### Pattern 3: All-UNCERTAIN verify → escalate or re-prompt

After `consult-verify-wait`, if every verdict in either `verify.md` is
`UNCERTAIN`, the trooper couldn't form an opinion. The conductor uses the
verify retry contract (mirror of Pattern 1 but for `verify` phase):

```
1. /clone-wars:send rex <topic> "For each UNCERTAIN item, read the cited
   source at the file:line and re-grade. Write to
   <state-dir>/verify.md. END_OF_INSTRUCTION"
2. bin/consult-offset-reset.sh <topic> rex verify
3. bin/consult-verify-send.sh <topic> rex codex
4. bin/consult-verify-wait.sh <topic> rex codex
5. bin/consult-adjudicate.sh <topic>   # regenerates adjudicated-draft.md
```

Then the conductor copies the fresh draft to `adjudicated.md` (overwriting
any prior resolution work — but since the verify changed, prior
resolutions were against stale data anyway). Or, if the conductor wants
to preserve specific prior resolutions, they manually merge the new
draft into the existing `adjudicated.md` instead of `cp`-overwriting.

Alternative: accept the partial verification and proceed straight to
synthesize with UNCERTAIN items flowing into PENDING for conductor
adjudication via Edit.

### Pattern 4: Spawn-group rollback (Codex finding #3 closure)

The conductor invokes `bin/spawn.sh rex codex <topic>` and `bin/spawn.sh
cody claude <topic>` as parallel Bash tool calls. v0.1's sequential spawn
gave a free rollback (rex failure → cody never starts), but parallel spawn
loses that. The slash directive enforces explicit transactional rollback:

```
After both parallel spawn invocations return:
  if (rex_rc != 0 && cody_rc != 0):
      log "both spawns failed"; remove _consult/, exit 1.
  elif (rex_rc != 0 && cody_rc == 0):
      bin/teardown.sh cody <topic>     # kill the survivor
      remove _consult/                  # remove init artifacts
      log "rex spawn failed; tore down cody"; exit 1
  elif (rex_rc == 0 && cody_rc != 0):
      bin/teardown.sh rex <topic>      # symmetric
      remove _consult/
      log "cody spawn failed; tore down rex"; exit 1
```

The slash directive carries this pseudo-code as explicit step 1.5 in the
runbook. A test fixture (`tests/test_consult_spawn_rollback.sh` or
extension to `test_spawn_rollback.sh`) covers the one-success/one-failure
case by mocking `bin/spawn.sh` to fail for one commander.

---

## Failure modes

| Failure | Sub-script | Behavior |
|---|---|---|
| Topic arg missing or path-traversal | any | rc=2 with stderr; no state mutation |
| Topic dir already exists at init | `consult-init` | conflict resolver bumps `-N` up to 999, then rc=1 |
| One spawn fails, peer succeeds | (slash directive) | rollback: teardown peer, remove `_consult/`, exit 1 |
| Research-send fails on send.sh | `consult-research-send` | rc=1; `research-<commander>.txt` already has OFFSET (so reset is required to retry) |
| Research-wait per-trooper timeout | `consult-research-wait` | appends `FS=missing` (or `empty`/`malformed`) to that commander's file; rc=0 always — peer's wait runs unaffected |
| Diff: missing findings | `consult-diff` | rc=1 with stderr naming the missing file; conductor decides next step |
| Verify-send: peer's _only file empty | `consult-verify-send` | rc=0; writes `VS=skipped` |
| Verify-wait per-trooper timeout | `consult-verify-wait` | appends `VS=timeout` (or other terminal state); rc=0 always |
| Adjudicate: missing input files | `consult-adjudicate` | rc=1 with stderr |
| Adjudicate: re-run | `consult-adjudicate` | overwrites `adjudicated-draft.md` freely (no warning); never touches `adjudicated.md` |
| Synthesize: `adjudicated.md` missing | `consult-synthesize` | rc=1 — conductor forgot to `cp adjudicated-draft.md adjudicated.md` |
| Synthesize: PENDING remains | `consult-synthesize` | rc=1 with the offending line |
| Synthesize: synthesis.md already exists | `consult-synthesize` | rc=1; conductor must `rm` first |
| Teardown: panes already gone | `consult-teardown` | rc=0 (delegates to existing teardown) |
| Archive: `_consult/` missing | `consult-archive` | rc=1 |
| Offset reset: file missing | `consult-offset-reset` | rc=0 (idempotent — the desired state is "absent") |

The conductor handles each by reading stderr, deciding whether to retry,
intervene, or escalate to the user.

---

## Out of scope (v0.2.0)

- **End-to-end automation wrapper** (the v0.1 `bin/consult.sh` monolith).
  Removed per Q1A. Anyone needing CI / scripted runs writes their own
  composer; the sub-scripts are the supported surface.
- **Streaming progress within a sub-script.** Each sub-script is a discrete
  unit; the granularity of task-status updates is fixed by the sub-script
  boundaries. If the user wants finer detail (e.g., "rex finished research
  but cody is still working"), that's a follow-up — would need
  per-trooper waits and `run_in_background` polling.
- **Auto-recovery patterns.** The intervention patterns above are
  documented but executed by the conductor (the model). The bash side
  doesn't auto-recover; that would re-introduce the monolith problem.
- **Generalizing to N troopers.** v0.2 still hardcodes `rex` (codex) +
  `cody` (claude). The split makes adding a third trooper easier
  (fan-out becomes "send to N", `_offsets.txt` already supports N entries),
  but the slash directive and adjudicate logic still assume two.

---

## Migration

v0.1.x → v0.2.0:

1. **`bin/consult.sh`** (v0.1 monolith) — **deleted**.
2. **`bin/consult-finalize.sh`** — **deleted**. Logic is split across
   `consult-synthesize.sh`, `consult-teardown.sh`, `consult-archive.sh`.
   The no-PENDING gate moves into `consult-synthesize.sh`.
3. **Existing v0.1.x archives** — unchanged. They're immutable; v0.2 reads
   from the same archive layout.
4. **Slash directive** (`commands/consult.md`) — fully rewritten. New
   step-by-step walks the conductor through 13 step boundaries with
   `TaskUpdate` between each.
5. **`lib/consult.sh`** — gains `cw_consult_topic_validate`,
   `cw_consult_status_load` (per-commander env-var parser, simpler than
   v0.1's whitelisted parser since per-commander files aren't appended in
   parallel — Codex finding #7 simplification), and
   `cw_consult_write_adjudicated`. Existing helpers (path, parse, diff,
   prompt builders, synthesizer) unchanged.

**Public API surface (Codex finding #9 closure)**: the supported user
surface is the slash command `/clone-wars:consult`. The `bin/` directory
is plugin-internal — not a stable contract. Users should not call sub-
scripts directly from their own scripts; the slash directive is the
versioned surface. The v0.2 → 0.2.0 major bump is for users who wrap the
slash command itself; bin-script changes are not externally visible.

`cw_consult_status_load` design note (Codex finding #7): v0.1 hardened
this against trooper-injection because troopers can write to state dirs.
In v0.2, status files are written exclusively by sub-scripts (research-
wait / verify-wait); troopers write findings.md / verify.md but never
status files. The threat model that motivated v0.1's whitelist parser
doesn't apply, so v0.2's status loader is a plain `source` of the per-
commander file. The defense-in-depth rationale (status files live under
`$CLONE_WARS_HOME/state/...` which is user-writable but not externally
attacker-controlled) makes plain `source` acceptable.

---

## Testing

Per Codex finding #10, the test surface is **not** simply "one focused
test per sub-script". Most sub-scripts are thin wrappers around lib
helpers that already have dedicated unit tests. The v0.2 testing strategy:

**Library-helper unit tests (existing, mostly unchanged)**:
- `test_consult_findings_parse.sh` — claims parser
- `test_consult_diff.sh` — citation overlap + diff bucketing
- `test_consult_prompts.sh` — research + verify prompt builders + verdict parser
- `test_consult_synthesis.sh` — synthesis assembler

**New v0.2 sub-script smoke tests** (just the bits not covered by lib unit tests):
- `test_consult_init.sh` — replaces `test_consult_slug.sh`. Slug cap + conflict bound + topic.txt write + path-traversal rejection.
- `test_consult_research_send.sh` — offset captured into per-commander file + idempotency-fail-loud + reset enables retry.
- `test_consult_research_wait.sh` — wait_since per-commander → file gets FS=. Asserts the per-trooper-survives-peer-timeout case (Codex finding #2 fixture).
- `test_consult_verify_send.sh` — peer-empty → VS=skipped; peer-non-empty → OFFSET=.
- `test_consult_verify_wait.sh` — mirrors research-wait.
- `test_consult_offset_reset.sh` — removes per-commander file + cascades to derived artifacts (diff.md, _only_items.txt, adjudicated-draft.md). Idempotent on missing file.
- `test_consult_adjudicate.sh` — generates `adjudicated-draft.md`; re-run overwrites draft but never touches `adjudicated.md`. Asserts the file split (Codex finding #4 fixture).
- `test_consult_synthesize.sh` — PENDING in `adjudicated.md` → rc=1; missing `adjudicated.md` → rc=1; clean → rc=0 + synthesis.md.
- `test_consult_teardown.sh` — smoke; delegates to `bin/teardown.sh`.
- `test_consult_archive.sh` — moves `_consult/` to archive; smoke.
- `test_consult_spawn_rollback.sh` — NEW. Mocks `bin/spawn.sh` to fail for one commander; asserts the spawn-group rollback (peer torn down + `_consult/` removed). Codex finding #3 fixture.

`tests/test_consult_finalize.sh` is **deleted**.

**Why not one integration test instead of the 10+ smoke tests**: each
sub-script has a unique state-machine contract (which file it reads,
which it writes, which idempotency rule applies). A single end-to-end
test wouldn't exercise the failure-mode matrix above; we'd lose the
ability to localize regressions when a single sub-script breaks. The
sub-script smoke tests are deliberately small (~30 lines each) and run
fast in pure bash.

End-to-end live test (manual, dogfood): run `/clone-wars:consult` against
a real topic, observe the task list updates at every boundary,
deliberately trigger a malformed-findings scenario to exercise Pattern 1's
re-prompt → reset → re-send → re-wait loop.

---

## Locked decision

**`bin/consult-init.sh` is the only script that creates `_consult/`.**
Every other sub-script's topic-dir validation fails loud if `_consult/` is
missing — that's how the conductor finds out it skipped init. Lazy
creation is rejected: would mask a forgotten-init bug AND introduce
race conditions if two parallel sub-scripts both tried to mkdir the
same dir.

---

## What ships in v0.2.0

- **11 new bin scripts**: init, research-send, research-wait, diff,
  verify-send, verify-wait, adjudicate, synthesize, teardown, archive,
  **offset-reset** (the executable retry primitive added in Revision 1)
- **3 new helpers in `lib/consult.sh`**: `cw_consult_topic_validate`,
  `cw_consult_status_load` (per-commander env-var parser), and
  `cw_consult_write_adjudicated`
- **Rewritten `commands/consult.md` slash directive** walking 13 step
  boundaries with `TaskCreate` × 13 + `TaskUpdate` between each. Includes
  spawn-group rollback runbook and the executable retry sequences from
  Patterns 1 + 3.
- **11 new test files** (most replacing or augmenting v0.1 tests +
  `test_consult_offset_reset.sh` and `test_consult_spawn_rollback.sh`)
- Removed: `bin/consult.sh`, `bin/consult-finalize.sh`,
  `tests/test_consult_finalize.sh`, `tests/test_consult_slug.sh` (renamed
  to `test_consult_init.sh`)
- Version bump v0.1.x → v0.2.0
- README + CHANGELOG entry
