# /clone-wars:consult — Cross-Verified Dual-Model Research

**Status:** Design (locked pending user approval)
**Date:** 2026-04-28
**Target version:** v0.1.0 — first real orchestration command on top of the spawn/send/collect/teardown primitives.

---

## Goal

Give the user one command that runs an independent two-model investigation, surfaces both
agreement and disagreement, and lets the conductor adjudicate the gaps.

```
/clone-wars:consult <topic>
```

→ a single synthesized report combining what codex and claude both found (and where they
diverged), with each model's reasoning visible in attachable tmux panes the entire run.

The conductor (the Claude Code session running `/clone-wars:consult`) **organizes**. It does
not research. The two troopers do all the actual investigation and grading.

---

## Architecture

```
              ┌────────────────────────────────────────────┐
              │  USER → /clone-wars:consult <topic>         │
              └──────────────────┬─────────────────────────┘
                                 │
        ┌────────────────────────▼─────────────────────────┐
        │  PHASE 1  Spawn two troopers, ONCE   [CONDUCTOR] │
        │   /clone-wars:spawn rex  codex  consult-<slug>    │
        │   /clone-wars:spawn cody claude consult-<slug>    │
        │   wait for both ready                             │
        └────────────────────────┬─────────────────────────┘
                                 │
        ┌────────────────────────▼─────────────────────────┐
        │  PHASE 2  Independent research (parallel, call#1) │
        │                                                   │
        │   ┌─ REX/codex ───────┐   ┌─ CODY/claude ──────┐  │
        │   │ inbox ← topic     │   │ inbox ← topic      │  │
        │   │ research          │   │ research           │  │
        │   │ → findings.md     │   │ → findings.md      │  │
        │   │ done → idle       │   │ done → idle        │  │
        │   │ PANE STAYS UP     │   │ PANE STAYS UP      │  │
        │   └────────┬──────────┘   └────────┬───────────┘  │
        │            └──── conductor waits ──┘              │
        └────────────────────────┬─────────────────────────┘
                                 │
        ┌────────────────────────▼─────────────────────────┐
        │  PHASE 3  Diff the findings        [CONDUCTOR]    │
        │  Bucket every claim:                              │
        │   • AGREE      — both raised it                   │
        │   • REX_ONLY   — only codex raised it             │
        │   • CODY_ONLY  — only claude raised it            │
        └────────────────────────┬─────────────────────────┘
                                 │
        ┌────────────────────────▼─────────────────────────┐
        │  PHASE 4  Cross-verify (parallel, call#2)         │
        │                                                   │
        │   ┌─ REX/codex ────────────┐  ┌─ CODY/claude ───┐ │
        │   │ inbox ← CODY_ONLY list │  │ inbox ← REX_ONLY│ │
        │   │  + verify protocol     │  │  + same protocol│ │
        │   │ → verify.md            │  │ → verify.md     │ │
        │   │ done → idle            │  │ done → idle     │ │
        │   │ SAME PANE              │  │ SAME PANE       │ │
        │   └──────────┬─────────────┘  └────────┬────────┘ │
        │              └──── conductor waits ────┘          │
        └────────────────────────┬─────────────────────────┘
                                 │
        ┌────────────────────────▼─────────────────────────┐
        │  PHASE 5  Adjudicate              [CONDUCTOR]     │
        │  For each cross-verify item:                      │
        │   • original claim + verifier's verdict            │
        │   • if verdict=AGREE      → CONFIRMED              │
        │   • if verdict=DISPUTE    → conductor reads        │
        │     source, decides CONFIRMED/REFUTED/CONTESTED    │
        │   • if verdict=UNCERTAIN  → conductor reads        │
        │     source, decides                                │
        └────────────────────────┬─────────────────────────┘
                                 │
        ┌────────────────────────▼─────────────────────────┐
        │  PHASE 6  Synthesize        [CONDUCTOR]           │
        │   • Agreed findings (passthrough — both raised)   │
        │   • Cross-verified findings (raised once,         │
        │     confirmed by other)                            │
        │   • Adjudicated findings (CONFIRMED / REFUTED)    │
        │   • Contested (still unresolved — present both)   │
        │   → synthesis.md → printed to user                │
        └────────────────────────┬─────────────────────────┘
                                 │
        ┌────────────────────────▼─────────────────────────┐
        │  PHASE 7  Teardown      [CONDUCTOR]               │
        │   /clone-wars:teardown consult-<slug>             │
        └───────────────────────────────────────────────────┘
```

### Pane lifecycle (each trooper)

```
spawn ─► ready ─► [P2 research]→done→idle ─► [P4 verify]→done→idle ─► teardown
   ↑                                                                     ↑
   ONE spawn                                                  ONE teardown
```

Two inbox dispatches per pane, same pane the whole run. Codex and Claude TUIs preserve
in-session memory between the dispatches — Phase 4's verify prompt can refer to "the
items you researched in your previous turn" without re-shipping context.

### Role split

| Actor | Phase 2 (call #1) | Phase 4 (call #2) |
|---|---|---|
| **REX/codex pane** | Research topic → `findings.md` | Verify CODY's unique items → `verify.md` |
| **CODY/claude pane** | Research topic → `findings.md` | Verify REX's unique items → `verify.md` |
| **Conductor** | Phases 1, 3, 5, 6, 7 + waiting | Diff, dispatch verify prompts, adjudicate from source, synthesize, teardown |

The conductor never researches the topic itself. The only files it reads are (a) the four
trooper artifacts, and (b) the source files cited in disputed claims (Phase 5 adjudication).

---

## Components

### 1. The `/clone-wars:consult` command

A new slash command that orchestrates Phases 1–7. Lives at `commands/consult.md` +
`bin/consult.sh`. Same pattern as the existing five commands: the markdown directive
delegates to the bash script via the Bash tool with an `--args-file` envelope (so topic
text with spaces and shell metacharacters doesn't reach the shell directly).

**Argument:**
- `<topic>` — free-form research question (≤512 bytes after `--args-file` round-trip).

**Slug derivation:**
- `consult-<slug>` where `<slug>` is the first 32 chars of the topic, kebab-cased,
  `[a-z0-9-]+` only. Conflicts (existing topic with the same slug) are resolved by
  appending `-2`, `-3`, etc.

**Commander selection:**
- Hardcoded for v0.1.0: `rex` for codex, `cody` for claude. Rationale: the consult command
  is a primitive itself; commander randomization can come later when consult is wrapped by
  higher-level orchestration. If either name is already in use on the chosen slug,
  `cw_commander_pick_random` falls back to a different name from the pool.

### 2. Trooper findings format

Each research call writes a structured markdown file the conductor can diff. Format:

```markdown
# Findings: <topic>

## Summary
<2-3 sentence overview, free-form prose>

## Claims
1. [<source citation>] <one-sentence claim>
2. [<source citation>] <one-sentence claim>
3. ...

## Notes
<any free-form additions; not parsed by conductor>
```

**Source citation format** is one of:
- `<file path>:<line>` — e.g. `src/auth/store.py:42`
- `<file path>:<line-range>` — e.g. `src/auth/refresh.py:15-30`
- `<URL>` — for web sources
- `runtime: <one-sentence command>` — e.g. `runtime: pytest tests/test_auth.py::test_refresh`

**Why structured claims?** The conductor needs to bucket claims into AGREE / REX_ONLY /
CODY_ONLY in Phase 3. Free-form prose is too noisy to diff. The Phase 2 inbox prompt
specifies the format and the trooper writes it.

### 3. Trooper verify format

Phase 4's output:

```markdown
# Verify: <topic>

## Verdicts
1. <verdict-tag> [<original citation>] <other side's claim>
   <evidence: file paths, quoted lines, web sources>
2. <verdict-tag> [...] ...
```

**Verdict tags:** `AGREE`, `DISPUTE`, `UNCERTAIN`. The trooper picks one per item, with
a one-line evidence note.

### 4. Conductor's diff logic (Phase 3)

Two claims agree iff they:
1. Cite the same source (file path with overlapping line range, or same URL), AND
2. Make the same essential assertion (judged by the conductor).

The conductor walks both `findings.md` claim lists, matches by citation overlap, then by
free-text similarity for any unmatched. Output:

```
$RUN_DIR/diff.md
  ## Agreed
  - [src/auth/store.py:42] tokens stored in plaintext
  ## Rex-only
  - [src/auth/refresh.py:15-30] no retry logic
  ## Cody-only
  - [src/oauth/callback.py:88] state param not validated
```

The conductor's bucketing is recorded in `diff.md` for audit-trail value (so a user
running consult can later see exactly what was sent to whom in Phase 4).

### 5. Conductor's adjudication (Phase 5)

For each cross-verify item, conductor decides:

| Other side's verdict (from `verify.md`) | Conductor action |
|---|---|
| `AGREE` | Mark **CONFIRMED**. Both endorse. |
| `DISPUTE` | Read the cited source. Pick **CONFIRMED** (verifier wrong), **REFUTED** (original wrong), or **CONTESTED** (genuinely ambiguous). |
| `UNCERTAIN` | Read the cited source. Pick **CONFIRMED** or **REFUTED**. |

The conductor's rule for adjudication: read the cited source and decide on the merits.
No third-party referee, no second round of trooper dispatch. If the source is ambiguous,
**CONTESTED** is a valid outcome — the synthesis presents both positions and the user
decides.

### 6. Synthesis report (Phase 6)

```markdown
# Consultation: <topic>

## Recommendation
<conductor's one-paragraph TL;DR if findings imply a clear action>

## Agreed findings (both raised independently)
- [src/...] <claim>
- ...

## Cross-verified (one raised, the other confirmed)
- [src/...] <claim> — CODY confirmed (src ref)
- ...

## Adjudicated (one raised, other disputed; conductor judged)
- CONFIRMED: [src/...] <claim> — REX raised; CODY disputed; verdict: <conductor evidence>
- REFUTED:  [src/...] <claim> — CODY raised; REX disputed; verdict: <conductor evidence>
- CONTESTED: [src/...] <claim> — both positions presented, no resolution

## Trooper artifacts
- REX research:  ~/.clone-wars/state/.../rex-codex/findings.md
- REX verify:    ~/.clone-wars/state/.../rex-codex/verify.md
- CODY research: ~/.clone-wars/state/.../cody-claude/findings.md
- CODY verify:   ~/.clone-wars/state/.../cody-claude/verify.md
```

The synthesis is committed to `<state-root>/state/<repo-hash>/consult-<slug>/_consult/synthesis.md`
(sibling to the trooper dirs). On teardown, the entire `consult-<slug>/` subtree archives
together — consult artifacts and trooper state stay co-located forever.

---

## Data flow & file conventions

```
~/.clone-wars/state/<repo-hash>/consult-<slug>/
├── _consult/                 ← conductor-owned artifacts
│   ├── manifest.json         ← phase status, timestamps, slug, troopers
│   ├── diff.md               ← Phase 3 output (audit trail)
│   └── synthesis.md          ← Phase 6 output (the report)
├── rex-codex/                ← trooper state (existing layout)
│   ├── identity.md           ← spawn-time
│   ├── inbox.md              ← P2 then P4 (overwritten)
│   ├── outbox.jsonl          ← append-only across both calls
│   ├── status.json           ← idle ↔ working
│   ├── pane.json
│   ├── findings.md           ← NEW — trooper writes in Phase 2
│   └── verify.md             ← NEW — trooper writes in Phase 4
└── cody-claude/              ← symmetric
    └── ...
```

After teardown, the entire `consult-<slug>/` directory moves to
`~/.clone-wars/archive/<repo-hash>/consult-<slug>-<ts>/`. Conductor artifacts and trooper
artifacts archive together — single forensic record.

---

## Prerequisites (changes to clone-wars before consult can ship)

These are not part of the consult command itself but must land first:

### P1. Multi-task identity prompt

`config/identity-template.md` currently implies one-task lifecycle. Update language to:
- "You may receive multiple tasks. After each `done`, return to idle and wait for the next inbox nudge. Do not exit."
- "When you receive a task, write your output to the path specified in the inbox prompt before emitting the `done` event."

This affects all troopers, not just consult. Test: existing tracer/runtime smoke still passes
after the language change.

### P2. Conductor outbox cursor

`cw_outbox_wait` today scans the whole file. For multi-task usage, the conductor needs to
wait for the *next* `done` after a known offset. Add:

```bash
cw_outbox_wait_since <state-dir> <event...> <byte-offset> <timeout-s>
```

Returns the matching event line; the byte-offset is the file size at the moment the
inbox was nudged. Backwards-compatible: existing single-call usage passes offset=0.

### P3. `/clone-wars:send` accepts `@file`

Verify-prompts run 1–4 KB and contain newlines/markdown — not safe on the command line.
Today's `/send` already supports `@file`; verify it survives the args-file round trip and
add a regression test.

### P4. Trooper-side findings file

The Phase 2 / Phase 4 inbox prompts instruct the trooper to write `findings.md` /
`verify.md` in its state dir. The `done` event payload includes the file path. No new
helpers needed — just convention enforced via the inbox prompt and one helper:

```bash
cw_trooper_findings_path <state-dir>   # echoes <state-dir>/findings.md
cw_trooper_verify_path   <state-dir>   # echoes <state-dir>/verify.md
```

### P5. `cw_outbox_wait_all`

Convenience wrapper for the conductor to block until N troopers all emit `done`. Loops
over per-trooper `cw_outbox_wait_since`. Returns 0 only if all matched within timeout.

These five changes are bundled into the consult command's plan; consult itself is the
thin shell on top.

---

## Failure modes

| Failure | Conductor action |
|---|---|
| Either trooper fails to spawn (Phase 1) | Abort. Teardown the one that did spawn. Print the trooper's outbox tail for diagnosis. |
| Trooper Phase 2 errors (`{event:"error"}`) | Abort. Teardown both. Print the error event. |
| Trooper Phase 2 times out (no `done` within `consult_research_timeout_s`) | Abort. Teardown both. Print last 25 lines of the stalled pane (mirrors `bin/spawn.sh` failure path). |
| Trooper Phase 2 produces unparseable `findings.md` | Conductor degrades: treats every claim as `<commander>_ONLY`. Synthesis flags this in a banner: "<commander> findings unstructured; cross-verification ran on best-effort parse." |
| One trooper Phase 4 fails (error or timeout) | Synthesis ships with one-sided cross-verification. The other trooper's unique items go into Phase 5 adjudication; the failed side's unique items get a `NOT_VERIFIED` tag in the report. |
| Both Phase 4 calls fail | Synthesis ships with original findings only, banner: "Cross-verification unavailable; agreed findings only." |
| `tmux kill-pane` happens mid-run (user manually closes a pane) | Next conductor call to that trooper detects pane death via `tmux list-panes`; abort with same teardown semantics as the spawn-fail case. |

Timeout config goes in `config/contracts.yaml` as a top-level `consult:` block:

```yaml
consult:
  research_timeout_s: 600
  verify_timeout_s: 300
```

Default `research_timeout_s=600` (10 min) is generous for a research turn. `verify_timeout_s=300`
(5 min) is shorter because the verify prompt is narrower (just grade these N items).

---

## Out of scope (v0.1.0)

These were considered and explicitly dropped:

- **Literature track / third trooper.** /forcevision optionally invokes a literature-review
  skill. Consult v0.1.0 ships with two troopers only. Revisit after dogfood if there's a
  proven need.
- **Mode selection (Simple/Deep).** /forcevision has both. Consult is one-mode-only:
  always 2 panes × 2 calls. Less surface area, less to misuse.
- **Grading rubric.** No STRONG/ADEQUATE/WEAK. Two outcomes only: do they agree, or not.
- **Confidence taxonomy (HIGH/MEDIUM/LOW + verification gates).** /forcevision has a
  multi-tier confidence system. Consult uses four tags: AGREED / CONFIRMED / REFUTED /
  CONTESTED. The first three carry sufficient evidence by construction. CONTESTED is the
  explicit "user decides" tag.
- **Re-research rounds.** /forcevision allows up to 2 quality-gate-triggered re-runs.
  Consult does one round of cross-verify, no further rounds. Re-research belongs in a
  follow-up consult invocation if the user wants it.
- **Independence sentinel.** /forcevision uses `.claude_research_done` to enforce the
  conductor doesn't read Codex's output before completing its own. Consult's conductor
  doesn't research at all, so the sentinel is unnecessary.
- **Multi-conductor coordination.** Two consults running on the same repo concurrently
  must use different slugs (enforced by the slug-conflict resolver). No shared state
  between consults.

---

## Testing

Pure-bash test files following the existing pattern (`tests/test_*.sh` discovered by
`tests/run.sh`):

1. **`test_consult_diff.sh`** — unit test the conductor's diff logic against fixture
   `findings.md` files (one with overlap, one with disjoint claims, one with empty
   claim list, one malformed). Asserts AGREE / REX_ONLY / CODY_ONLY bucketing.
2. **`test_consult_findings_format.sh`** — static parse check: given a well-formed
   `findings.md`, does the parser extract the right claim list and citations?
3. **`test_consult_verify_format.sh`** — same for `verify.md`.
4. **`test_consult_outbox_cursor.sh`** — `cw_outbox_wait_since` ignores events before
   the offset, returns the next matching event after.
5. **`test_consult_synthesis_shape.sh`** — given mocked artifacts, the synthesizer
   produces the expected sections (Recommendation, Agreed, Cross-verified, Adjudicated).
6. **`test_consult_failure_modes.sh`** — Phase 2 timeout, Phase 4 timeout, malformed
   findings, all produce the documented degraded synthesis.

End-to-end live test (manual, dogfood):
- `/clone-wars:consult "review src/auth/oauth.py for token-refresh edge cases"` against
  a real codebase. Verify both panes spawn, both produce findings, the diff bucket is
  visible, both verify, and synthesis ships.

No mocked-trooper integration test in v0.1.0 — the live dogfood plus the unit tests on
diff/parse/synthesis cover enough of the contract. A test fixture that simulates a
trooper writing `findings.md` would help, but it's a follow-up.

---

## Design decisions (locked)

**Trooper memory in Phase 4 — trust the TUI's in-session memory.** The verify prompt
references the trooper's prior turn ("You researched <topic> in your previous turn — now
verify these N items raised by the other researcher") without re-including the original
`findings.md`. This is the clone-wars-shaped advantage over /forcevision's `--fresh`
single-shot model: the persistent pane gives us continuity for free, and reusing it
keeps the verify prompt narrow. If dogfood reveals TUI memory drift, a re-include flag
can be added in a follow-up.

---

## What ships in v0.1.0

- `commands/consult.md` + `bin/consult.sh`
- New `lib/consult.sh` with diff/adjudication/synthesis helpers
- Updates to `config/identity-template.md` (multi-task language)
- New helpers in `lib/ipc.sh`: `cw_outbox_wait_since`, `cw_outbox_wait_all`
- New helpers in `lib/state.sh` (or new `lib/consult.sh`): `cw_trooper_findings_path`,
  `cw_trooper_verify_path`
- New section in `config/contracts.yaml`: `consult:` block with timeouts
- 6 new test files
- README update: new section explaining `/clone-wars:consult`
- CHANGELOG entry

The consult command is the **first orchestration primitive built on top of the spawn/send/collect
primitives**. v0.0.x was foundation; v0.1.0 demonstrates the foundation can compose.
