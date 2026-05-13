---
description: Advisor-driven autoresearch — conductor plans, 2-3 codex troopers execute experiments persistently, advisor decides metric/dispatch/stop adaptively
argument-hint: <topic-with-metric> [--seed-from PATH]
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, AskUserQuestion, Skill, WebSearch, WebFetch
---

# /clone-wars:deep-research

Run advisor-driven executable autoresearch on `$ARGUMENTS`. **Conductor
(Yoda / claude) acts as a research advisor; 2-3 codex troopers act as
PhD students.** Spawn the roster ONCE; dispatch experiments adaptively
across the session; trooper context persists across all their
experiments. Stop on time-budget hit OR 5-experiment stagnation.

> ⚠️ **DANGER — read first.** Spawns codex troopers under
> `--dangerously-bypass-approvals-and-sandbox`; troopers write +
> execute arbitrary code in your repo. Sandboxing is **honor-system**
> (troopers told to stay inside branch dir; not enforced). Net access
> is **permitted by default** in v0.27.0 (was opt-in via `--allow-net`
> in v0.26.0). Do not run on machines with sensitive credentials,
> production data, or shared state. Use a scratch worktree if uncertain.

**When to use this command.** Invoke when the user wants to actually
**run experiments** to find the best approach to a measurable
objective. Phrases that route here: "find the best approach to X",
"run experiments to optimize X", "autoresearch X", "AIDE-style search",
"implement and benchmark several approaches".

Phrases that should NOT route here:
- "explore SOTA X" (no execution → use `/clone-wars:meditate`)
- "design X" (no experiments → use `/clone-wars:consult`)
- "compare A vs B" via discussion → `/clone-wars:consult`

Intended workflow: `meditate → consult` for non-executable topics, or
`meditate → deep-research → deploy` for executable autoresearch.
`/clone-wars:meditate`'s `## Approaches` section can seed Phase 1+3
hints via `--seed-from <landscape-path>`.

**Codex required.** `bin/deep-research-init.sh` refuses if codex is
absent from `providers-available.txt`. Medic active-set is IGNORED
(roster is fixed at codex; Yoda picks N=2 or N=3 in directive prose).

Spec: `docs/superpowers/specs/2026-05-12-v0.27.0-deep-research-advisor-rewrite-design.md`.

## Task list (TaskCreate × 8 BEFORE Phase 0)

| # | subject | activeForm |
|---|---|---|
| 0 | 0 Args + init (no budget flags) [yoda]            | Staging args |
| 1 | 1 Metric discussion [yoda + user]                 | Discussing metric |
| 2 | 2 Preflight (roster + time limit) [yoda + user]   | Picking roster + time limit |
| 3 | 3 Spawn roster (parallel) [yoda]                  | Spawning troopers |
| 4 | 4 Research loop (advisor-driven) [yoda]           | Running research loop |
| 5 | 5 Synthesis (write landscape doc) [yoda]          | Writing landscape doc |
| 6 | 6 Teardown + archive [yoda]                       | Tearing down |
| 7 | 7 Present final doc [yoda]                        | Presenting landscape |

Per-experiment sub-rows under task 4 are fired at each dispatch with
subject `4.NNN <Rank> <Commander> on <approach-label>`. `NNN` is the
zero-padded global counter (`001`, `002`, …). Use `cw_cmdr_rank` from
`lib/commanders.sh` for the rank prefix.

## Steps

The user's `$ARGUMENTS` may contain shell metacharacters. Write via the
Write tool, then invoke sub-scripts.

**All Bash tool blocks in this directive use absolute paths verbatim —
env vars do not persist across separate Bash calls in this harness.**
Use this prelude in every Bash block that needs lib helpers:

```bash
source /home/liupan/CC/clone-wars/lib/log.sh
source /home/liupan/CC/clone-wars/lib/state.sh
source /home/liupan/CC/clone-wars/lib/consult.sh
source /home/liupan/CC/clone-wars/lib/deep-research.sh
```

Cache topic + paths to `/tmp` so subsequent Bash calls can read them:

```bash
echo "$DEEP_TOPIC" > /tmp/cw-deep-research-topic.txt
echo "$ART_DIR"     > /tmp/cw-deep-research-art-dir.txt
echo "$TOPIC_DIR"   > /tmp/cw-deep-research-topic-dir.txt
```

### Phase 0 — Args + init (no budget flags)

Set task `0` → `in_progress`.

1. Resolve args path:

   ```bash
   ARGS_DIR="${CLONE_WARS_HOME:-$HOME/.clone-wars}/_args"
   mkdir -p "$ARGS_DIR"
   echo "$ARGS_DIR/deep-research.txt"
   ```

2. Write tool: `file_path` = path printed above; `content` = `$ARGUMENTS`.

3. Initialize the topic:

   ```bash
   source /home/liupan/CC/clone-wars/lib/log.sh
   source /home/liupan/CC/clone-wars/lib/state.sh
   source /home/liupan/CC/clone-wars/lib/consult.sh
   source /home/liupan/CC/clone-wars/lib/deep-research.sh

   ARGS_DIR="${CLONE_WARS_HOME:-$HOME/.clone-wars}/_args"
   ARGS=$(cat "$ARGS_DIR/deep-research.txt")
   # shellcheck disable=SC2086 — splitting intentional for --seed-from + topic
   DEEP_TOPIC=$(/home/liupan/CC/clone-wars/bin/deep-research-init.sh $ARGS)
   echo "$DEEP_TOPIC"
   ```

   If init exits non-zero (codex missing, `--seed-from` path not found,
   unknown flag — including any of the v0.26.0 budget flags), surface
   stderr verbatim, mark task `0` as `pending`, exit.

4. Cache paths to `/tmp` for later Bash blocks:

   ```bash
   source /home/liupan/CC/clone-wars/lib/state.sh
   DEEP_TOPIC=$(cat /tmp/cw-deep-research-topic.txt 2>/dev/null || echo)
   # If the previous block already set $DEEP_TOPIC, reuse it; otherwise
   # re-derive from $ARGS via init's stdout.
   echo "$DEEP_TOPIC" > /tmp/cw-deep-research-topic.txt
   REPO_HASH=$(cw_repo_hash)
   echo "$REPO_HASH" > /tmp/cw-deep-research-repo-hash.txt
   TOPIC_DIR="${CLONE_WARS_HOME:-$HOME/.clone-wars}/state/$REPO_HASH/$DEEP_TOPIC"
   echo "$TOPIC_DIR" > /tmp/cw-deep-research-topic-dir.txt
   echo "$TOPIC_DIR/_deep-research" > /tmp/cw-deep-research-art-dir.txt
   ```

Set task `0` → `completed`.

### Phase 1 — Metric discussion (adaptive dialogue)

Set task `1` → `in_progress`.

Adaptive dialogue with the user. Length scales with topic clarity:
1-2 prompts for clear topics, 3-5 for ambiguous. Produces a structured
`metric.md`.

1. Seed: read the heuristic metric guess from init's metric.txt:

   ```bash
   ART_DIR=$(cat /tmp/cw-deep-research-art-dir.txt)
   SEED_METRIC=$(cat "$ART_DIR/metric.txt" 2>/dev/null | head -1)
   TOPIC_TEXT=$(cat "$ART_DIR/topic.txt")
   echo "SEED_METRIC=$SEED_METRIC"
   echo "TOPIC_TEXT=$TOPIC_TEXT"
   ```

2. Optional: pair `WebSearch` + `mcp__tavily__tavily-search` (per the
   global dual-search rule) if the topic is novel or domain-specific.
   Skip for clearly bounded topics (e.g. "MNIST accuracy").

3. Open with ONE AskUserQuestion proposing the read of the goal.
   Frame it as a confirmation, not an open-ended "what do you want?":

   > **For clear topics** (heuristic returned a recognizable metric):
   > *"I read this as: \<direction> \<metric>, subject to \<constraints
   > inferred from topic>. What's a target threshold — \<example>?"*
   >
   > **For ambiguous topics** (empty heuristic, broad goal):
   > *"I want to make sure I optimize the right thing. What does success
   > look like here — \<2-3 candidate framings>?"*

   Use AskUserQuestion with 3 options + Other-fallback.

4. Based on user's answer, ask zero or more follow-ups until you have
   the K=V pairs for `cw_deep_research_format_metric_block`:
   - `primary_metric` (required, e.g. `accuracy`)
   - `direction` (required, `maximize` or `minimize`)
   - `target` (optional, e.g. `>= 0.99`)
   - `acceptable` (optional, e.g. `>= 0.97`)
   - `hard_constraints` (optional, e.g. `params < 100k`)
   - `notes` (optional, e.g. `MNIST test set`)

5. Format and write `metric.md`:

   ```bash
   source /home/liupan/CC/clone-wars/lib/deep-research.sh
   ART_DIR=$(cat /tmp/cw-deep-research-art-dir.txt)
   cw_deep_research_format_metric_block <<EOF > "$ART_DIR/metric.md"
   primary_metric=accuracy
   direction=maximize
   target=>= 0.99
   acceptable=>= 0.97
   hard_constraints=params < 100k
   notes=MNIST test set
   EOF
   cat "$ART_DIR/metric.md"
   ```

   (Substitute the K=V pairs from the dialogue.)

6. Final confirmation AskUserQuestion:

   > *"Here's how I'll frame the goal — OK to proceed?"*
   >
   > Options: `Looks good` / `Revise` / `Cancel`

   - `Looks good` → continue.
   - `Revise` → re-edit metric.md, re-confirm.
   - `Cancel` → archive topic via teardown.sh, exit directive.

Set task `1` → `completed`.

### Phase 2 — Preflight (roster + time limit)

Set task `2` → `in_progress`.

1. **Pick roster size N (Yoda's call, explained in chat):**

   Apply this rubric:

   - **N=2 (default)** — single objective + tight constraint surface.
     Examples: optimize accuracy under params cap, minimize p99 latency
     on a specific endpoint, find lowest-loss config under fixed compute.
   - **N=3** — multiple sub-goals OR broad survey OR no clear single
     optimum. Examples: find best caching strategy across multiple
     workloads, explore SOTA architectures, compare 3+ approach families.

   When unsure, default to N=2 — the safety-net protects from runaway cost.

   Explain in chat:
   > "Going with N=2 troopers (rex + keeli) — your topic has a clear
   > single optimum (test accuracy) and a tight constraint
   > (<100k params). N=3 would split focus without adding signal."

2. **Time limit AskUserQuestion:**

   Ask the user about an optional time limit before any troopers are
   spawned:

   ```
   Question: "Time limit on this research session?"
   Header: "Time budget"
   Options:
     - "No limit (recommended)" — stop on stagnation or your call
     - "4 hours" — fixed wall-clock budget
     - "12 hours" — fixed wall-clock budget
     - "Other (custom)" — enter hours
   ```

   Parse user's answer to seconds and write:

   ```bash
   ART_DIR=$(cat /tmp/cw-deep-research-art-dir.txt)
   echo "none" > "$ART_DIR/time-budget.txt"      # or the seconds value
   date -u +%Y-%m-%dT%H:%M:%SZ > "$ART_DIR/session-start.txt"
   echo "0" > "$ART_DIR/stagnation-cursor.txt"
   ```

   Encoding:
   - `No limit` → `none`
   - `4 hours` → `14400`
   - `12 hours` → `43200`
   - Other → ask for hours (positive integer), multiply by 3600

3. **Allocate roster (mechanical):**

   ```bash
   source /home/liupan/CC/clone-wars/lib/deep-research.sh
   mapfile -t ROSTER < <(cw_deep_research_pick_roster 2)   # or 3
   echo "Roster: ${ROSTER[*]}"
   printf '%s\n' "${ROSTER[@]}" > /tmp/cw-deep-research-roster.txt
   ```

Set task `2` → `completed`.

### Phase 3 — Spawn roster (parallel Bash calls)

Set task `3` → `in_progress`.

Issue N parallel Bash tool calls (single message). Each call:

```bash
DEEP_TOPIC=$(cat /tmp/cw-deep-research-topic.txt)
/home/liupan/CC/clone-wars/bin/spawn.sh <commander> codex "$DEEP_TOPIC"
```

Capture each rc separately. **Spawn-rollback runbook** (auto-retry-once
on cold-start failure, identical to v0.26.0):

- All N succeed → continue.
- ≥1 fails, retry count = 0:
  ```bash
  DEEP_TOPIC=$(cat /tmp/cw-deep-research-topic.txt)
  mapfile -t ROSTER < /tmp/cw-deep-research-roster.txt
  /home/liupan/CC/clone-wars/bin/teardown.sh --pairs "$DEEP_TOPIC" "${ROSTER[@]}" 2>/dev/null || true
  ```
  Re-issue N parallel spawn calls. Set retry count = 1.
- ≥1 fails, retry count = 1 → AskUserQuestion:
  > `Proceed degraded (N-1 troopers)` / `Abort deep-research`

  If degraded: remove the failed commander from ROSTER, continue.
  If abort: archive via deep-research-teardown.sh, exit.

Set task `3` → `completed`.

### Phase 4 — Research loop (advisor-driven)

Set task `4` → `in_progress`.

**No fixed structure.** Yoda decides each iteration. Use a per-experiment
chronological counter `EXP_NUM` (starts at 1; increment on each dispatch
within the session):

```
LOOP:
  decide next move (Yoda judgment):
    - dispatch a new approach to an idle trooper
    - dispatch a follow-up to a specific trooper that builds on prior turn
    - stop entirely

  derive exp-id:  EXP_ID=$(printf "exp-%03d" "$EXP_NUM")

  dispatch (parallel Bash calls if multiple troopers in same batch):
    DEEP_TOPIC=$(cat /tmp/cw-deep-research-topic.txt)
    /home/liupan/CC/clone-wars/bin/deep-research-experiment-send.sh \
      "$DEEP_TOPIC" <commander> "$EXP_ID" <approach-label> <approach-brief>

  fire TaskCreate sub-row 4.NNN with rank-prefixed commander name
  (use cw_cmdr_rank for the rank).

  wait (foreground, parallel via single message):
    DEEP_TOPIC=$(cat /tmp/cw-deep-research-topic.txt)
    CW_DEEP_RESEARCH_EXPERIMENT_TIMEOUT_OVERRIDE=<seconds> \
    /home/liupan/CC/clone-wars/bin/deep-research-experiment-wait.sh \
      "$DEEP_TOPIC" <commander> codex

  score (mechanical):
    DEEP_TOPIC=$(cat /tmp/cw-deep-research-topic.txt)
    /home/liupan/CC/clone-wars/bin/deep-research-score.sh "$DEEP_TOPIC"

  stop check:
    source /home/liupan/CC/clone-wars/lib/log.sh
    source /home/liupan/CC/clone-wars/lib/deep-research.sh
    ART_DIR=$(cat /tmp/cw-deep-research-art-dir.txt)
    if cw_deep_research_check_time_budget "$ART_DIR/time-budget.txt" "$ART_DIR/session-start.txt"; then
      AskUserQuestion: Continue / Stop / Extend (+T hours)
    elif cw_deep_research_check_plateau "$ART_DIR/scoreboard.md" "$ART_DIR/stagnation-cursor.txt"; then
      AskUserQuestion: Continue / Stop / Adjust direction
    fi

  remove state file (post-wait cleanup) — required before re-dispatching
  the same trooper:
    ART_DIR=$(cat /tmp/cw-deep-research-art-dir.txt)
    rm -f "$ART_DIR/experiment-<commander>.txt"

  EXP_NUM=$((EXP_NUM + 1))

GOTO LOOP
```

**Follow-up dispatch pattern** — Yoda may send a trooper a prompt that
references prior results in their codex session naturally:
> *"Your exp-003 (Modern LeNet + aug) hit 99.03%. For exp-007, try the
> same arch with weight decay 1e-4. Write the new run to exp-007-rex/code/."*

The trooper sees this in their inbox.md; their codex session has full
history of exp-003 (they implemented it).

**On `Stop` answer** at safety-net prompt → break loop, go to Phase 5.

**On `Adjust direction`** → small AskUserQuestion to capture new
direction; optionally re-edit metric.md (Write tool, atomic); reset
stagnation cursor to the latest exp number:

```bash
ART_DIR=$(cat /tmp/cw-deep-research-art-dir.txt)
SB="$ART_DIR/scoreboard.md"
# Grab the highest exp-NNN from the scoreboard (any row).
last_exp=$(grep -oE 'exp-[0-9]+' "$SB" | sort -u | tail -1 | sed 's/exp-//; s/^0*//')
echo "${last_exp:-0}" > "$ART_DIR/stagnation-cursor.txt"
```

**On `Extend (+T hours)`** → update time-budget.txt and refresh
session-start.txt to "now" so the elapsed counter resets:

```bash
ART_DIR=$(cat /tmp/cw-deep-research-art-dir.txt)
current=$(cat "$ART_DIR/time-budget.txt")
new=$(( current + T * 3600 ))
echo "$new" > "$ART_DIR/time-budget.txt"
date -u +%Y-%m-%dT%H:%M:%SZ > "$ART_DIR/session-start.txt"
```

When loop exits, set task `4` → `completed`.

### Phase 5 — Synthesis (landscape doc)

Set task `5` → `in_progress`.

Yoda writes `_deep-research/deep-research-<date>-<slug>.md` via Write
tool (atomic single-shot).

**Doc shape** (each section is REQUIRED):

```markdown
# Deep Research: <slug-titled>

**Generated:** <ISO-8601 UTC>
**Topic:** <verbatim from topic.txt>

**Metric block:**

<verbatim metric.md body>

**Roster:** <comma-separated commander names>
**Time budget:** <none | N hours>
**Outcome:** stopped-by-user | converged-by-judgment | time-budget-exhausted

## Experiment log

| Exp | Commander | Approach | Metric | Status | Runtime |
|---|---|---|---|---|---|
<one row per experiment in chronological order>

## Winner

**<exp-NNN> (commander <cmdr>)** — `Approach: <label>`
- Metric: <value>
- Code path: `_deep-research/experiments/exp-NNN-<cmdr>/code/`
  (absolute archive path printed at Phase 7)
- Runtime: <value>s
- Notes: <result.json notes verbatim>

## Why we stopped

<one paragraph: Yoda's reasoning. Cite scoreboard rows by exp-NNN.>

## Branches preserved

All experiment dirs under `_deep-research/experiments/` preserved in
archive (printed at Phase 7). Each contains `code/`, `result.json`,
`stdout.log`, `stderr.log`, `prompt.md`.

## Suggested next

<emitted ONLY when winner has status=ok AND winner metric is the best
across the session. Otherwise omit + write "No clear winner — review
the experiment log".>

Productionize the winner:

    /clone-wars:deploy <archive-root>/_deep-research/experiments/exp-NNN-<cmdr>/code/
```

Set task `5` → `completed`.

### Phase 6 — Teardown + archive

Set task `6` → `in_progress`.

Single batched teardown via `--pairs` (one 9s graceful banner across N
panes, not N × 9s):

```bash
DEEP_TOPIC=$(cat /tmp/cw-deep-research-topic.txt)
mapfile -t ROSTER < /tmp/cw-deep-research-roster.txt
/home/liupan/CC/clone-wars/bin/teardown.sh --pairs "$DEEP_TOPIC" "${ROSTER[@]}"
ARCHIVE=$(/home/liupan/CC/clone-wars/bin/deep-research-teardown.sh "$DEEP_TOPIC")
echo "$ARCHIVE" > /tmp/cw-deep-research-archive.txt
```

Update the landscape doc inside the archive to bake in the absolute
archive path under "Suggested next". Use the Edit tool (Read first if
the file was last written via Write in Phase 5 — atomic; the file path
changed when teardown moved the topic dir to archive).

Set task `6` → `completed`.

### Phase 7 — Present final doc

Set task `7` → `in_progress`.

Show the user:
- Path to the archived landscape doc.
- Path to the winning experiment's `code/` directory.
- The "Suggested next" line (verbatim) if emitted.
- One-line outcome summary: outcome + best-metric + delta vs first exp.

Set task `7` → `completed`.

## Intervention patterns

If you observe a trooper hanging, producing garbage result.json, or
exceeding cost without `cost_blown` status, you can send a clarifying
prompt mid-loop via `bin/send.sh`. Trooper panes remain attached; the
advisor regains control between every sub-step.

## Budget overrides

`CW_DEEP_RESEARCH_EXPERIMENT_TIMEOUT_OVERRIDE` overrides the
per-experiment wall-clock cap for the wait shim (default lives in
`lib/contracts.sh::cw_consult_timeout experiment`).
