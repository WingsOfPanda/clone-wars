# /clone-wars:consult v0.2 — Split Orchestrator with Conductor-Reachable Steps

**Status:** Design (locked pending user approval)
**Date:** 2026-04-29
**Target version:** v0.2.0 — replaces v0.1.x's monolithic `bin/consult.sh` + `bin/consult-finalize.sh`
**Supersedes:** `docs/superpowers/specs/2026-04-28-clone-wars-consult-design.md` (v0.1 architecture)

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
                            │ writes one line each to _consult/research_offsets.txt
                            │ format: <commander>:<model>:<offset>
                            ▼
                      bin/consult-research-wait.sh <topic>
                            │ reads research_offsets.txt; cw_outbox_wait_all
                            │ writes _consult/research_status.txt
                            │   REX_FS=ok|empty|malformed|missing
                            │   CODY_FS=ok|empty|malformed|missing
                            ▼
                      bin/consult-diff.sh <topic>
                            │ cw_consult_diff
                            │ writes diff.md + rex_only_items.txt + cody_only_items.txt
                            ▼
                      ┌── bin/consult-verify-send.sh <topic> rex codex   ─┐ PARALLEL
                      └── bin/consult-verify-send.sh <topic> cody claude  ┘ (each conditional —
                            │                                               skips if peer's
                            │                                               _ONLY file is empty)
                            │ writes one line each to _consult/verify_offsets.txt
                            ▼
                      bin/consult-verify-wait.sh <topic>
                            │ reads verify_offsets.txt; cw_outbox_wait_all
                            │ writes _consult/verify_status.txt
                            │   REX_VS=ok|skipped|send-failed|timeout|error|missing|empty
                            │   CODY_VS=...
                            ▼
                      bin/consult-adjudicate.sh <topic>
                            │ writes adjudicated.md (with PENDING items)
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

**10 sub-scripts. 11 conductor-controlled steps** (init, 2 spawn-parallel, 2
research-send-parallel, research-wait, diff, 2 verify-send-parallel,
verify-wait, adjudicate, synthesize, teardown, archive — counting parallel
pairs as one step each from the conductor's POV; 11 step boundaries between
init and final archive).

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
- Atomically appends `<commander>:<model>:<offset>` to
  `_consult/research_offsets.txt`. **Refuses if a line for this
  `<commander>` is already present** (idempotency).
- Invokes `bin/send.sh <commander> <topic> "@<prompt-path>"`.
- Returns rc=0 on success, ≥1 on send failure (with the offset already
  appended — so the conductor knows a send was attempted).

### `bin/consult-research-wait.sh <topic>`

- Reads `_consult/research_offsets.txt`; refuses if absent (must come after
  both `research-send` calls).
- Builds the troopers file expected by `cw_outbox_wait_all`
  (`<commander>:<model>:<topic>:<offset>` per line).
- Reads research timeout from `cw_consult_timeout research`.
- Calls `cw_outbox_wait_all "$file" done error "$timeout"`.
- For each trooper, sets findings status via `cw_consult_findings_status`
  (ok / empty / malformed / missing).
- Writes `_consult/research_status.txt` with `REX_FS=...` / `CODY_FS=...`.
- Returns rc=0 if both were dispatched (regardless of `_FS` value — degraded
  paths are downstream's problem). Returns rc=1 only if `cw_outbox_wait_all`
  itself timed out without seeing either side's `done`.

### `bin/consult-diff.sh <topic>`

- Refuses if `diff.md` already exists.
- Refuses if either `<rex-dir>/findings.md` or `<cody-dir>/findings.md` is
  missing (degraded path: status file already has `missing` → conductor
  decides to skip diff or to `cw_send` a follow-up).
- Calls `cw_consult_diff` → writes `_consult/diff.md`.
- Extracts `_only_items.txt` files for verify-send.

### `bin/consult-verify-send.sh <topic> <commander> <model>`

- Validates topic; resolves trooper state.
- Reads peer's `_only_items.txt` (rex sends → reads `cody_only_items.txt`,
  cody sends → reads `rex_only_items.txt`).
- If empty → exits rc=0 with stdout `SKIPPED` (conductor knows no dispatch
  happened; `verify-wait` later will see no offset entry for this commander
  and mark its status `skipped`).
- Otherwise: builds verify prompt, captures offset, appends to
  `verify_offsets.txt`, sends. Same idempotency + failure semantics as
  `research-send`.

### `bin/consult-verify-wait.sh <topic>`

Mirrors `research-wait` but reads `verify_offsets.txt` and writes
`verify_status.txt` (REX_VS / CODY_VS). Both sides' status defaults to
`skipped` if no offset entry exists; otherwise resolved per the v0.1
state-machine (ok / send-failed / timeout / error / missing / empty).

### `bin/consult-adjudicate.sh <topic>`

- Reads `verify_status.txt`, `research_status.txt`, both verify.md files,
  both _only_items.txt files.
- Calls into the existing adjudicate-section-emitting logic from v0.1's
  `bin/consult.sh` Phase 5 (which is straightforward awk; will be extracted
  to `lib/consult.sh` as `cw_consult_write_adjudicated`).
- Writes `_consult/adjudicated.md` with `## Cross-verified` + `## Adjudicated
  (PENDING items)` + `## Contested` + `## Not-verified` sections.
- **May be re-run** if the conductor wants to regenerate after `cw_send`-ing
  a trooper a follow-up that produces a fresh `verify.md`. The
  fail-loud-on-existing-output rule is **relaxed for adjudicate only** —
  this is the one sub-script that supports re-run, because the conductor
  intervention pattern explicitly requires it. Implementation: emit a
  warning to stderr if `adjudicated.md` already exists, then overwrite. The
  warning makes the re-run intentional (the conductor must have decided to
  re-adjudicate).

### `bin/consult-synthesize.sh <topic>`

- Refuses if `synthesis.md` already exists (idempotency).
- Refuses if `adjudicated.md` contains any `^- PENDING:` line. Print the
  offending line(s) and the path the conductor should edit. Exit 1.
- Loads statuses via `cw_consult_status_load`
  (whitelisted KEY=VAL parser — promoted from v0.1's `consult-finalize.sh`).
- Calls `cw_consult_synthesize` → writes `synthesis.md`.
- **Prints the synthesis to stdout** so the conductor / user sees it inline.

### `bin/consult-teardown.sh <topic>`

- Calls `bin/teardown.sh <topic>` (existing).
- The existing teardown handles both trooper-pane kill and trooper-state
  archive. Does NOT touch `_consult/`.
- Returns rc=0 even if some panes were already gone (teardown.sh's behavior).

### `bin/consult-archive.sh <topic>`

- Moves `<topic-dir>/_consult/` to
  `<archive-root>/<topic>/_consult-<ts>/`.
- Removes the now-empty `<topic-dir>` (rmdir, ignore failure).
- Refuses if `_consult/` is missing (already archived) — fail-loud.

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

- **`_consult/research_offsets.txt`** — one line per dispatched trooper:
  `<commander>:<model>:<offset>`. Written incrementally by `research-send`,
  read once by `research-wait`.
- **`_consult/verify_offsets.txt`** — same shape, for verify dispatches.

These offset files are internal plumbing; not part of any external contract.

---

## Idempotency contract

**Rule (per Q2A): every sub-script fails loud if its expected output already
exists.** Two exceptions, documented above:

- `bin/consult-adjudicate.sh` may overwrite `adjudicated.md` with a stderr
  warning. This is the explicit support for the conductor-mediated
  re-dispatch pattern: after `cw_send`-ing a trooper a clarifying prompt and
  receiving a fresh `verify.md`, the conductor re-runs adjudicate to refresh
  the PENDING list.
- `bin/spawn.sh` (existing v0.0.x) already refuses duplicate
  `<commander>` on a topic — that's where idempotency for spawn lives.

**Failure mode**: any sub-script that detects its output already present
exits rc=1 with a stderr message naming the file. The conductor must
explicitly clean up (e.g., `rm <topic>/_consult/diff.md` or run
`bin/consult-teardown.sh + bin/consult-archive.sh`) before retrying.

This is intentional: silent re-runs can corrupt the offset cursor (the
second `research-send` would record an offset *past* the trooper's first
`done` event, and `research-wait` would never see new events).

---

## Intervention patterns

The whole point of the split. Three concrete examples documented in the
spec; the slash directive references these so users know what's possible:

### Pattern 1: Malformed findings → re-prompt before diff

After `consult-research-wait`, if `research_status.txt` shows
`REX_FS=malformed`:

```
The conductor reads rex's findings.md, sees the trooper wrote
prose without [citation] format, and:

1. Uses /clone-wars:send rex <topic> "Re-format your findings using
   [<citation>] tags before each claim, per the original prompt.
   END_OF_INSTRUCTION"
2. Captures the new outbox offset; appends it to research_offsets.txt
   (manually overwrites rex's old line — this is one of the few cases
   where idempotency-fail-loud doesn't apply, because the conductor
   is intentionally re-driving).
3. Re-runs bin/consult-research-wait.sh — but only if it can refresh
   the offset. Easier path: the conductor calls /clone-wars:collect
   rex <topic> directly, then re-runs bin/consult-diff.sh with the
   updated findings.md.
```

The exact mechanic isn't fully prescribed; the design preserves the option
without claiming a one-size-fits-all recipe. The slash directive's
"Troubleshooting" section will document the most common pattern (rebuild
the offsets file, re-run wait) for completeness.

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
`UNCERTAIN`, the trooper couldn't form an opinion. The conductor:

- Reads the trooper's `verify.md` to see whether the items lacked
  evidence-bearing context.
- Either `cw_send`s a follow-up (e.g., "For each UNCERTAIN item, read the
  cited source files at <path> and re-grade") and re-runs adjudicate (which
  is allowed to overwrite per the exception above), OR
- Accepts the partial verification and proceeds to adjudicate / synthesize
  with the UNCERTAIN items flowing into PENDING for conductor adjudication.

---

## Failure modes

| Failure | Sub-script | Behavior |
|---|---|---|
| Topic arg missing or path-traversal | any | rc=2 with stderr; no state mutation |
| Topic dir already exists at init | `consult-init` | conflict resolver bumps `-N` up to 999, then rc=1 |
| Research-send fails on send.sh | `consult-research-send` | rc=1; offset already appended (so wait can see the failure later as missing-done) |
| Research-wait timeout | `consult-research-wait` | writes `research_status.txt` with whichever side reached `done`; rc=1 if neither |
| Diff: missing findings | `consult-diff` | rc=1 with stderr naming the missing file; conductor decides next step |
| Verify-send: peer's _only file empty | `consult-verify-send` | rc=0 + stdout `SKIPPED`; no offset appended |
| Verify-wait timeout | `consult-verify-wait` | writes `verify_status.txt`; rc=0 always (statuses convey what happened) |
| Adjudicate: missing input files | `consult-adjudicate` | rc=1 with stderr |
| Adjudicate: re-run on existing | `consult-adjudicate` | warns to stderr, overwrites |
| Synthesize: PENDING remains | `consult-synthesize` | rc=1 with the offending line |
| Synthesize: synthesis.md already exists | `consult-synthesize` | rc=1; conductor must `rm` first |
| Teardown: panes already gone | `consult-teardown` | rc=0 (delegates to existing teardown) |
| Archive: `_consult/` missing | `consult-archive` | rc=1 |

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

1. **`bin/consult.sh`** (v0.1 monolith) — **deleted**. Anyone depending on
   the old path gets a 404; the slash directive is the supported surface.
2. **`bin/consult-finalize.sh`** — **deleted**. Logic is split across
   `consult-synthesize.sh`, `consult-teardown.sh`, `consult-archive.sh`.
   The no-PENDING gate moves into `consult-synthesize.sh`.
3. **Existing v0.1.x archives** — unchanged. They're immutable; v0.2 reads
   from the same archive layout.
4. **Slash directive** (`commands/consult.md`) — fully rewritten. New
   step-by-step walks the conductor through 11 step boundaries with
   `TaskUpdate` between each.
5. **`lib/consult.sh`** — gains `cw_consult_topic_validate`,
   `cw_consult_status_load`, `cw_consult_write_adjudicated`. Existing
   helpers (path, parse, diff, prompt builders, synthesizer) unchanged.

The v0.2 release is a major-bump (0.1.x → 0.2.0) because the bin-script
surface changes incompatibly. Users with their own wrappers calling
`bin/consult.sh` directly will need to update.

---

## Testing

Each new sub-script gets a focused test in `tests/test_consult_<name>.sh`:

- `test_consult_init.sh` — replaces today's `test_consult_slug.sh`. Same
  slug-cap-to-20 / conflict-bound / empty-rejection cases. Adds a check
  that `topic.txt` is written.
- `test_consult_research_send.sh` — given a fixture topic dir + a stub
  trooper outbox, verify offset captured + appended to
  `research_offsets.txt` + idempotency-fail-loud on second call.
- `test_consult_research_wait.sh` — fixture with two trooper outboxes
  pre-populated with `done` events, verify status file written.
- `test_consult_diff.sh` (existing, lightly amended) — already covers the
  diff helper itself; add a smoke test that exercises the new sub-script
  wrapper.
- `test_consult_verify_send.sh` — peer-empty → `SKIPPED`; peer-non-empty
  → offset captured.
- `test_consult_verify_wait.sh` — same shape as research-wait.
- `test_consult_adjudicate.sh` — input verify.md fixtures → produces
  expected adjudicated.md sections; re-run case asserts the warning +
  overwrite behavior.
- `test_consult_synthesize.sh` (replaces part of today's
  `test_consult_finalize.sh`) — PENDING → rc=1; clean → rc=0 + writes
  synthesis.md; re-run on existing → rc=1.
- `test_consult_teardown.sh` (replaces part of today's
  `test_consult_finalize.sh`) — calls existing `bin/teardown.sh`; smoke.
- `test_consult_archive.sh` (replaces part of today's
  `test_consult_finalize.sh`) — moves `_consult/` to archive; smoke.

`tests/test_consult_finalize.sh` is **deleted** (the script it tested no
longer exists). Its assertions are split across the three new test files.

End-to-end live test (manual, dogfood): run `/clone-wars:consult` against a
real topic, observe the task list updates at every boundary, deliberately
trigger a malformed-findings scenario to exercise Pattern 1.

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

- 10 new bin scripts (init, research-send, research-wait, diff, verify-send,
  verify-wait, adjudicate, synthesize, teardown, archive)
- 3 new helpers in `lib/consult.sh` (topic-validate, status-load,
  write-adjudicated)
- Rewritten `commands/consult.md` slash directive walking 11 step
  boundaries with `TaskCreate` × 13 + `TaskUpdate` between each
- 9 new test files (most replacing or augmenting v0.1 tests)
- Removed: `bin/consult.sh`, `bin/consult-finalize.sh`,
  `tests/test_consult_finalize.sh`
- Version bump v0.1.x → v0.2.0
- README + CHANGELOG entry
