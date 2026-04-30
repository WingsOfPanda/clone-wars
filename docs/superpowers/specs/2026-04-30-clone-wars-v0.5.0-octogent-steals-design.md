# Clone Wars v0.5.0 — Octogent Steals Design

> **Status:** Spec accepted 2026-04-30. Plan to follow via `superpowers:writing-plans`.

## Goal

Borrow four orchestration primitives from [octogent](https://github.com/hesamsheikh/octogent) — adapted to clone-wars' pure-shell + tmux + file-IPC model — to make Master Yoda observable, interactive during waits, identifiable in messages, and maintainable as v0.6+ phases land.

## Architecture

v0.5.0 ships four independent subsystems as one bundle. None depends on another at runtime, but they ship together because each is small on its own and together they round out the orchestration surface that v0.4.x left rough.

```
┌─────────────────────────────────────────────────────────────────┐
│  A. Prompt-template registry      [config/prompt-templates/]     │
│     Inline prompts in send-scripts → versioned .md templates     │
│     with {{VAR}} mustache substitution. In-tree only.            │
├─────────────────────────────────────────────────────────────────┤
│  B. Lifecycle "stale" state       [bin/list.sh]                  │
│     /clone-wars:list classifies working troopers as `stale`      │
│     when outbox.jsonl mtime > 180s. Display-only; no protocol    │
│     change. CW_STALE_THRESHOLD_S env override.                   │
├─────────────────────────────────────────────────────────────────┤
│  C. cw_send --from sender attr.   [lib/ipc.sh]                   │
│     Optional --from <sender> flag prepends `From: <sender>`      │
│     header to inbox.md. Default sender = master-yoda.            │
├─────────────────────────────────────────────────────────────────┤
│  D. Background-await pattern      [commands/consult.md +         │
│                                    bin/consult-*-wait.sh]        │
│     Long waits run with run_in_background:true. Yoda's pane      │
│     stays interactive. Wait-scripts write FS= to state file      │
│     before exit; controller reads FS= on completion notify.      │
└─────────────────────────────────────────────────────────────────┘
```

**Task ordering:** A first (pure refactor, ships green), then B (additive), then C (additive), then D (heaviest; most directive churn).

**Out of scope (octogent has it; we don't ship it):**

- Worktree workspace mode (rejected per `CLAUDE.md`).
- HTTP API / web dashboard (rejected per `CLAUDE.md`).
- Per-user prompt-template overrides (in-tree only; revisit in v0.7+ if demand emerges).
- In-memory volatile message channel (clone-wars stays files-only; load-bearing simplicity).
- Meta-ops sweepers (`octoboss-clean-contexts.md` style); skip.

**Future considerations (deliberately deferred):**

- **Multi-attach tentacle (v0.6.1 candidate)** — octogent allows multiple terminals to attach to one tentacle directory; clone-wars stays 1:1 commander:topic in v0.5. Revisit as a v0.6.1 feature.

## Components

### A. Prompt-template registry

**New directory:** `config/prompt-templates/`

```
config/prompt-templates/
├── identity.md                          (moved from config/identity-template.md)
└── consult/
    ├── research.md                      (extracted from bin/consult-research-send.sh)
    ├── verify.md                        (extracted from bin/consult-verify-send.sh)
    ├── drilldown.md                     (extracted from cw_consult_design_doc_drilldown_prompt)
    └── design-doc/
        ├── architecture.md
        ├── components.md
        ├── data-flow.md
        ├── error-handling.md
        └── testing.md
```

**New helper in `lib/consult.sh`:**

```
cw_consult_load_prompt <template-relpath> [VAR1=value1 VAR2=value2 ...]
```

- Reads `$CLAUDE_PLUGIN_ROOT/config/prompt-templates/<relpath>`.
- Substitutes each `{{VAR}}` token via sed pipeline. Variable values are escaped against sed delimiters (`|`, `&`, `\`) and newlines.
- Single-pass substitution (no recursive expansion).
- After substitution, scans output for surviving `{{VAR}}` tokens and refuses (rc=2; lists unresolved vars to stderr) — loud failure beats silently sending an unrendered placeholder to the trooper.
- Emits the rendered template on stdout.
- Refuses if `CLAUDE_PLUGIN_ROOT` is unset (rc=2).

**Migration plan:** each send-script's heredoc collapses to a single `cw_consult_load_prompt` call. Estimated reduction: ~40 lines per send-script. `config/identity-template.md` is moved to `config/prompt-templates/identity.md`; the old path becomes a symlink for one release (drop in v0.6).

### B. Lifecycle stale state

**Threshold logic in `bin/list.sh`:**

```bash
status=$(jq -r '.state' "$STATUS_FILE")
if [[ "$status" == "working" ]]; then
  age=$(( $(date +%s) - $(_outbox_mtime "$OUTBOX_FILE") ))
  threshold="${CW_STALE_THRESHOLD_S:-180}"
  [[ ! "$threshold" =~ ^[0-9]+$ ]] && { log_warn "invalid CW_STALE_THRESHOLD_S; using 180"; threshold=180; }
  [[ "$age" -gt 0 && "$age" -gt "$threshold" ]] && status="stale"
fi
```

- `_outbox_mtime` is a small helper that tries `stat -c %Y` (GNU) and falls back to `stat -f %m` (BSD/macOS).
- Display-only: rendered in `/clone-wars:list` output. `status.json` schema is unchanged.
- Negative age (clock skew) treated as not-stale.
- Missing `outbox.jsonl` → skip stale check (trooper hasn't started outboxing yet; not stale, just not-yet-started).

### C. `cw_send` sender attribution

**`lib/ipc.sh` change to `cw_send`:**

- New flag `--from <sender>` (default `master-yoda`).
- Prepends `From: <sender>\n\n` to `inbox.md` before existing body.
- Sender name validated against `^[a-zA-Z0-9_-]+$`; invalid → rc=2 with stderr message.
- `--from` with no value → rc=2.
- All current call sites work unchanged: they get a `From: master-yoda` header they didn't have before, which troopers ignore harmlessly thanks to the identity-template line below.

**Identity-template addition:**

> Inbox messages may begin with `From: <sender>` — treat that as metadata, not part of the task.

### D. Background-await pattern

**Wait-script changes (`bin/consult-research-wait.sh` + `bin/consult-verify-wait.sh`):**

- Continue writing `FS=<state>` as last line of `_consult/research-<commander>.txt` (existing behavior).
- New: `touch "$STATE_FILE.done"` immediately before exit, after the FS= line. Acts as a sentinel so the controller can confirm the wait-script reached its terminal write — distinguishes a clean exit from a notification-arrived-before-write race.
- Exit 0 always (so the harness's completion notification fires cleanly even on `FS=failed` / `FS=timeout`).

**Directive (`commands/consult.md`) — Step 3 + Step 5 rewrites:**

- Each wait-script invocation flips to `Bash(..., run_in_background: true)`.
- Controller spawns 2 background tasks, awaits 2 completion notifications (the harness fires one notification per task).
- After each notification: read `FS=` last line and the `.done` sentinel from the state file. Missing `.done` → treat as `FS=failed`.
- Question protocol (Pattern 4) unchanged in spirit:
  - On `FS=question`, controller reads payload + findings.md, classifies, AskUserQuestion or self-answers, calls `cw_send --from master-yoda <commander> "$TOPIC" "ANSWER: ..."`, then **re-spawns the wait-script in background** (no foreground await).
- Both troopers' wait state files must show `FS ∈ {ok, empty, missing, failed, timeout, malformed}` before Step 4 (diff) proceeds. `FS=question` is a transient state that triggers re-arm.

**Foreground-only operations** (no backgrounding):

- `bin/spawn.sh` (~5–15s) — bootstrap should feel atomic.
- `bin/send.sh` / `cw_send` — instant.
- `bin/consult-diff.sh`, `bin/consult-adjudicate.sh`, `bin/consult-synthesize.sh` (<2s each).
- `bin/consult-teardown.sh`, `bin/consult-archive.sh` (<2s each).
- `bin/consult-design-doc.sh` (<2s).

Backgrounding these adds notification overhead with no UX gain. Only the `cw_outbox_wait_since`-bound wait scripts (potentially minutes) flip to background.

## Data Flow

### Flow 1: Prompt rendering (A) — research-send

```
bin/consult-research-send.sh
  │
  ├─ TOPIC_TEXT=$(cat $TOPIC_DIR/_consult/topic.txt)
  ├─ COMMANDER=rex   MODEL=codex   TROOPER_DIR=…/rex-codex
  │
  └─→ cw_consult_load_prompt consult/research.md \
        TOPIC="$TOPIC_TEXT" COMMANDER=rex MODEL=codex \
        TROOPER_DIR="$TROOPER_DIR" SKILL_HINT="$SKILL_HINT_BLOCK"
        │
        ├─ reads $CLAUDE_PLUGIN_ROOT/config/prompt-templates/consult/research.md
        ├─ sed pipeline replaces {{TOPIC}} {{COMMANDER}} {{MODEL}} {{TROOPER_DIR}} {{SKILL_HINT}}
        ├─ scans output for surviving {{...}} → rc=2 if any
        └─ stdout: rendered prompt body

  └─→ cw_send --from master-yoda rex "$TOPIC" "$rendered"
        ├─ writes "From: master-yoda\n\n" + body to inbox.md
        └─ tmux paste-buffer the inbox path to nudge trooper
```

### Flow 2: Stale rendering (B) — `/clone-wars:list`

```
bin/list.sh
  │
  └─→ for each $TROOPER_DIR in state/<repo-hash>/<topic>/<commander>-<model>/:
        ├─ status=$(jq -r .state status.json)
        ├─ if status==working:
        │     age = now - mtime(outbox.jsonl)
        │     threshold = ${CW_STALE_THRESHOLD_S:-180}
        │     [[ age > 0 && age > threshold ]] && status=stale
        └─ render row: <commander> <model> <topic> <status> <age>s
```

No file writes. Pure read-only display logic. `status.json` never carries `stale`.

### Flow 3: Background-await (D) — Step 3 (research-wait)

```
commands/consult.md (Step 3, after parallel send returns)
  │
  ├─ Bash("...consult-research-wait.sh ... rex codex",  run_in_background: true)  → task_id_1
  ├─ Bash("...consult-research-wait.sh ... cody claude", run_in_background: true) → task_id_2
  │
  │   [Yoda's pane is now FREE — user can chat, /clone-wars:list, anything]
  │
  ├─ ⟨notification: task_id_1 completed⟩
  │   ├─ Read _consult/research-rex.txt:last-line → FS=question
  │   ├─ Read _consult/question-rex.txt → TEXT, OPTIONS
  │   ├─ Read findings.md (so far)
  │   ├─ classify: critical → AskUserQuestion(TEXT, OPTIONS)
  │   ├─ cw_send --from master-yoda rex "$TOPIC" "ANSWER: <user choice>"
  │   └─ Bash(...consult-research-wait.sh ... rex codex, run_in_background: true) → task_id_3
  │
  ├─ ⟨notification: task_id_2 completed⟩
  │   └─ FS=ok → no re-arm
  │
  └─ ⟨notification: task_id_3 completed⟩
      └─ FS=ok → both done, proceed to Step 4 (diff)
```

**Key invariant:** notifications can arrive in any order; controller checks both state files for terminal `FS=` before advancing. The Pattern 4 question loop fires whenever `FS=question` appears, regardless of which task notified.

### Flow 4: Sender attribution (C) — trooper-to-trooper (future)

```
rex's inbox.md after `cw_send --from cody`:
  From: cody

  Hey rex, check claim 7 in your findings.md — I disagree.

  END_OF_INSTRUCTION
```

The identity-template tells the trooper to read the `From:` header as metadata, never as task content.

## Error Handling

### A. Prompt-template registry

| Failure | Detection | Recovery |
|---|---|---|
| Template file missing | `cw_consult_load_prompt` rc=1 with `template not found: <path>` to stderr | Send-script aborts; controller surfaces error to user (likely a botched install or branch). |
| Surviving `{{VAR}}` after substitution | Post-sed grep `'{{[A-Z_]\+}}'`; rc=2 with list of unresolved tokens | Loud failure — caller forgot to pass a var, or template references a stale name. Better than silently sending `{{TOPIC}}` to the trooper. |
| Variable value contains shell metacharacters / sed delimiters | sed with `\|` delimiter + value escaping helper that escapes `\`, `&`, `\|` | Substitution stays robust against `&`, `\|`, `/`, newlines in values like `$TOPIC_TEXT`. |
| Variable value contains `{{...}}` itself (recursive substitution) | Single-pass sed (no re-scan) | The recursive token survives → caught by the surviving-token check. Better to fail loudly than to recursively substitute. |
| `CLAUDE_PLUGIN_ROOT` unset | Helper checks at entry | rc=2; stderr "CLAUDE_PLUGIN_ROOT not set". |

### B. Stale state

| Failure | Detection | Recovery |
|---|---|---|
| `outbox.jsonl` missing | `stat` returns rc!=0 | Skip stale check; render status as-is. |
| `stat` syntax differs (GNU vs BSD) | Try `stat -c %Y` first; fall back to `stat -f %m` on rc!=0 | Cross-platform compat without OS detection. |
| Clock skew between system and outbox mtime | Possible negative `age` | Treat negative age as 0 (not stale). |
| Threshold env override is non-numeric | bash regex check at top of script | Warn to stderr, fall back to 180. |

### C. `cw_send` sender attribution

| Failure | Detection | Recovery |
|---|---|---|
| `--from` passed without value | argparse loop sees flag-as-value or end-of-args | rc=2; stderr "—from requires a sender name". |
| Sender name contains `\n` or other invalid chars | Validate `[[ "$sender" =~ ^[a-zA-Z0-9_-]+$ ]]` | rc=2; stderr "invalid sender name". |
| Backward compat: existing call sites without `--from` | Default sender = `master-yoda`; header always present | Troopers see `From: master-yoda` on every previously-unattributed message. Identity-template line covers this. |

### D. Background-await pattern

| Failure | Detection | Recovery |
|---|---|---|
| Wait-script crashes before writing FS= | Notification fires; controller reads state file → no FS= line OR no `.done` sentinel | Treat as `FS=failed`, surface error, consider Pattern 1 re-prompt. |
| Background task hangs forever | Wait-script's own internal `WAIT_TIMEOUT_S` (existing) fires → emits `FS=timeout` and exits | Controller proceeds with degraded result OR considers Pattern 1. Same as foreground today. |
| Notification arrives before state file is written (race) | `mv`-on-exit pattern: wait-script `printf 'FS=%s\n' "$status" >> "$STATE_FILE"` then `touch "${STATE_FILE%.txt}.done"` then `exit` | Controller checks `.done` sentinel; if missing, treats as `failed`. |
| Two simultaneous notifications interleave | Each notification handler reads its own task's state file independently | No shared state between handlers; safe. |
| User issues `/clone-wars:teardown` mid-wait | Teardown's `tmux kill-pane` cascades; wait-script sees its outbox vanish, errors out | Notification fires (with bash rc!=0); controller already in teardown path. Acceptable. |
| User exits Claude Code session entirely while background task is running | Harness cleans up background bash subprocesses on exit | Trooper panes survive (per existing `CLAUDE.md`); next session can `/clone-wars:list` and recover. |

**Cross-cutting invariants:**

- Every wait-script writes `FS=<state>` as its last line **before** exiting.
- Every wait-script touches a `.done` sentinel after the FS= line, before exit.
- The directive's controller is the single source of truth for "is the consult done?" — it gates on having read terminal `FS=` for both troopers, not on bash rc.

## Testing

### Unit tests (bash, run via `tests/run.sh`)

| # | Test file | What it covers |
|---|---|---|
| T1 | `tests/test_consult_load_prompt.sh` | A: substitution, missing template (rc=1), surviving `{{VAR}}` (rc=2), values with `\|`/`&`/newlines, multi-var rendering, missing CLAUDE_PLUGIN_ROOT (rc=2). ~8 cases. |
| T2 | `tests/test_consult_load_prompt_migration.sh` | A: render each migrated template (research, verify, drilldown, design-doc/*) with realistic vars; assert output matches the v0.4.2 inline-prompt output byte-for-byte. Regression guard for the refactor. |
| T3 | `tests/test_list_stale.sh` | B: fixture trooper dirs with mtime backdated via `touch -t`. Cases: working+age<threshold→working, working+age>threshold→stale, idle→idle, missing outbox→working, negative age→working, env override accepted, non-numeric env override warns and falls back to 180. ~7 cases. |
| T4 | `tests/test_send_from_flag.sh` | C: default sender adds `From: master-yoda`, explicit `--from cody` adds `From: cody`, `--from` with no value→rc=2, invalid sender chars→rc=2, body unchanged after header. ~5 cases. |
| T5 | `tests/test_consult_wait_state_file.sh` | D: mock outbox feeds → wait-script writes `FS=<expected>` last line + creates `.done` sentinel for each terminal state (ok/failed/timeout/question/malformed). ~6 cases. Pure shell mock; no tmux needed. |
| T6 | `tests/test_consult_wait_question_rearm.sh` | D: wait-script emits FS=question + .done; re-spawn with new outbox content emits FS=ok. Asserts state file has ≥2 OFFSET= lines and last FS=ok. Verifies the question→re-arm loop survives the foreground→background flip. ~3 cases. |

### Integration / dogfood

**T7 manual** — `tests/test_consult_v050_dogfood.sh` (skipped by `tests/run.sh`, runnable by hand):

- Real consult run on a small topic (e.g., "decide between mutex vs spin-lock for the foo cache").
- During Step 3 (research wait), tester types arbitrary chat into Yoda's pane → confirms responsiveness.
- Tester runs `/clone-wars:list` mid-wait → confirms `working` shows; if test pauses long enough, confirms transition to `stale`.
- Tester answers any FS=question prompts → confirms re-arm + completion.
- Final synthesis matches expected shape.

### Test-fixture conventions

- All tests source `lib/consult.sh` + `lib/state.sh` + `lib/log.sh` and run inside a `mktemp -d` sandbox with `CLONE_WARS_HOME` pointed at it. No real `~/.clone-wars/` writes.
- D tests mock the outbox by piping pre-canned JSONL into a real `outbox.jsonl` file in a fixture trooper dir; they never invoke tmux.
- A tests use a `CLAUDE_PLUGIN_ROOT=$(mktemp -d)` with stub templates so the loader has a real path to read.

### What we explicitly don't test

- Real-CLI dogfood of background-await for codex/gemini/claude in CI — same gating as v0.3 H3 (tmux + provider binary + `$TMUX`); ship as informational manual test only.
- Multi-attach tentacle behavior — out of scope (v0.6.1 candidate).
- Prompt template user overrides — feature explicitly absent in v0.5.0.

### Coverage targets

- Every new helper has at least one happy-path + one error-path test.
- Every directive code-path change in `commands/consult.md` (background dispatch, notification handler, re-arm) has at least one unit-level test that exercises the equivalent shell logic.
- Total expected new tests: ~32 cases across 6 new test files.

## Out of Scope

Re-stated for clarity (some duplicates with Architecture's "out of scope" block):

- Worktree workspace mode.
- HTTP API / web dashboard.
- In-memory volatile message channel.
- Per-user prompt-template overrides.
- Meta-ops sweepers (octobosss-style cleanups).
- Multi-attach tentacle (v0.6.1 candidate).

## Release Notes (preview)

**v0.5.0 — "Octogent Steals"**

- 🦑 **Yoda stays interactive during consult waits.** Background-await pattern means you can chat with Master Yoda or run `/clone-wars:list` while troopers are working — no more "busy" lockout.
- 👁 **`/clone-wars:list` now flags stale troopers.** Working troopers whose outbox has been silent for >180s render as `stale`. Override via `CW_STALE_THRESHOLD_S`.
- ✉️ **`cw_send --from <sender>`** lets messages carry sender attribution (default `master-yoda`); paves the way for v0.6+ trooper-to-trooper messaging.
- 🧱 **Prompts are now versioned templates.** Per-phase markdown under `config/prompt-templates/consult/` makes them grep-able, diff-able, and easier to evolve when v0.5+ adds new agent roles.
