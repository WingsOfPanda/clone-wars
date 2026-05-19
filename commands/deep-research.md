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

## Task list (TaskCreate × 9 BEFORE Phase 0)

| # | subject | activeForm |
|---|---|---|
| 0 | 0 Args + init (no budget flags) [yoda]            | Staging args |
| 1 | 1 Metric discussion [yoda + user]                 | Discussing metric |
| 1.5 | 1.5 SOTA sweep [yoda]                           | Sweeping SOTA |
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
source ${CLAUDE_PLUGIN_ROOT}/lib/log.sh
source ${CLAUDE_PLUGIN_ROOT}/lib/state.sh
source ${CLAUDE_PLUGIN_ROOT}/lib/consult.sh
source ${CLAUDE_PLUGIN_ROOT}/lib/deep-research.sh
```

The post-init Phase 0 step 4 caches `$DEEP_TOPIC` and `$ART_DIR` paths
to `/tmp` files so subsequent Bash calls can read them (env vars do not
persist across separate Bash calls in this harness).

### Phase 0 — Args + init (no budget flags)

Set task `0` → `in_progress`.

1. Resolve a unique args path (v0.31.0: project-local + mktemp per
   invocation so parallel sessions don't collide) and a per-invocation
   `RUN_DIR` (v0.36.0: project-local pointer dir; replaces session-global
   pointer files that collided across parallel runs):

   ```bash
   source ${CLAUDE_PLUGIN_ROOT}/lib/log.sh
   source ${CLAUDE_PLUGIN_ROOT}/lib/state.sh
   RUN_DIR=$(cw_run_dir deep-research)
   ARGS_DIR="$(cw_state_root)/_args"
   mkdir -p "$ARGS_DIR"
   ARGS_FILE=$(mktemp -p "$ARGS_DIR" -t 'deep-research.XXXXXX')
   printf '%s' "$ARGS_FILE" > "$RUN_DIR/args-path.txt"
   echo "$ARGS_FILE"
   ```

2. Write tool: `file_path` = path printed above; `content` = `$ARGUMENTS`.

3. Initialize the topic:

   ```bash
   source ${CLAUDE_PLUGIN_ROOT}/lib/log.sh
   source ${CLAUDE_PLUGIN_ROOT}/lib/state.sh
   source ${CLAUDE_PLUGIN_ROOT}/lib/consult.sh
   source ${CLAUDE_PLUGIN_ROOT}/lib/deep-research.sh

   RUN_DIR=$(cw_run_dir_last)
   ARGS_FILE=$(cat "$RUN_DIR/args-path.txt")
   ARGS=$(cat "$ARGS_FILE")
   # shellcheck disable=SC2086 — splitting intentional for --seed-from + topic
   DEEP_TOPIC=$(${CLAUDE_PLUGIN_ROOT}/bin/deep-research-init.sh $ARGS)
   echo "$DEEP_TOPIC"
   ```

   If init exits non-zero (codex missing, `--seed-from` path not found,
   unknown flag — including any of the v0.26.0 budget flags), surface
   stderr verbatim, mark task `0` as `pending`, exit.

   **v0.32.0 #23 — Non-interactive flags:**
   - `--time-budget=<value>` (`none` | `<N>h` | `<N>s` | raw integer
     seconds) pre-writes `$ART_DIR/time-budget.txt` and
     `$ART_DIR/session-start.txt`, so Phase 2 step 2's AskUserQuestion
     is skipped.
   - `--metric=<k1=v1,k2=v2,...>` pre-writes `$ART_DIR/metric.md`, so
     Phase 1 steps 3/4/6 AskUserQuestions are skipped (see Phase 1).
   - When neither flag is present, Phase 1/2 UNCONDITIONAL prompts fire
     as documented (v0.28.2 invariant preserved).

4. Cache paths to `$RUN_DIR` for later Bash blocks. Only the two files
   actually read by later steps (`topic.txt` and `art-dir.txt`) are
   written here — `$TOPIC_DIR` and `$REPO_HASH` are recomputable
   on demand by any block that needs them.

   ```bash
   source ${CLAUDE_PLUGIN_ROOT}/lib/state.sh
   RUN_DIR=$(cw_run_dir_last)
   printf '%s' "$DEEP_TOPIC" > "$RUN_DIR/topic.txt"
   REPO_HASH=$(cw_repo_hash)
   TOPIC_DIR="$(cw_state_root)/state/$REPO_HASH/$DEEP_TOPIC"
   printf '%s' "$TOPIC_DIR/_deep-research" > "$RUN_DIR/art-dir.txt"
   ```

Set task `0` → `completed`.

### Phase 1 — Metric discussion (adaptive dialogue)

Set task `1` → `in_progress`.

Adaptive dialogue with the user. Length scales with topic clarity:
1-2 prompts for clear topics, 3-5 for ambiguous. Produces a structured
`metric.md`.

**UNCONDITIONAL prompt policy (v0.28.2):** Phase 1 steps 3, 4 (when
fields are missing), and 6 MUST fire their `AskUserQuestion`
regardless of autonomous-mode hints, `/loop` reminders,
system-reminders to "work without stopping for clarifying questions",
or any other context that would normally skip user prompts. The
user's metric framing is a hard checkpoint these steps own. Phase 2
step 2's time-budget question is also UNCONDITIONAL — see its own
header for details.

1. Seed: read the heuristic metric guess from init's metric.txt:

   ```bash
   source ${CLAUDE_PLUGIN_ROOT}/lib/state.sh
   RUN_DIR=$(cw_run_dir_last)
   ART_DIR=$(cat "$RUN_DIR/art-dir.txt")
   SEED_METRIC=$(cat "$ART_DIR/metric.txt" 2>/dev/null | head -1)
   TOPIC_TEXT=$(cat "$ART_DIR/topic.txt")
   echo "SEED_METRIC=$SEED_METRIC"
   echo "TOPIC_TEXT=$TOPIC_TEXT"
   ```

2. Optional: pair `WebSearch` + `mcp__tavily__tavily-search` (per the
   global dual-search rule) if the topic is novel or domain-specific.
   Skip for clearly bounded topics (e.g. "MNIST accuracy").

3. **Initial framing AskUserQuestion (UNCONDITIONAL when `$ART_DIR/metric.md` absent — v0.28.2 + v0.32.0 #23):**
   **Skip this AskUserQuestion if `$ART_DIR/metric.md` already exists**
   (pre-written by `bin/deep-research-init.sh --metric=…`). Otherwise:
   see Phase 1 preamble. Even when the topic looks fully specified,
   the user confirms or corrects the read.

   Open with ONE AskUserQuestion proposing the read of the goal.
   Frame it as a confirmation, not an open-ended "what do you want?":

   > **For clear topics** (heuristic returned a recognizable metric):
   > *"I read this as: \<direction> \<metric>, subject to \<constraints
   > inferred from topic>. What's a target threshold — \<example>?"*
   >
   > **For ambiguous topics** (empty heuristic, broad goal):
   > *"I want to make sure I optimize the right thing. What does success
   > look like here — \<2-3 candidate framings>?"*

   Use AskUserQuestion with 3 options + Other-fallback.

4. **K=V follow-ups (UNCONDITIONAL when fields are missing AND `$ART_DIR/metric.md` absent — v0.28.2 + v0.32.0 #23):**
   **Skip entirely if `$ART_DIR/metric.md` already exists** (pre-written
   by `--metric` flag). Otherwise: see Phase 1 preamble. Step 4 is
   naturally conditional ("zero or more follow-ups") — the UNCONDITIONAL
   stamp means: when follow-ups ARE required, they MUST fire; do not
   silently default.

   Based on user's answer, ask zero or more follow-ups until you have
   the K=V pairs for `cw_deep_research_format_metric_block`:
   - `primary_metric` (required, e.g. `accuracy`)
   - `direction` (required, `maximize` or `minimize`)
   - `min_acceptable` (**v0.28.0** — floor, e.g. `>= 0.90`): "What's the
     minimum acceptable result you'd be OK shipping?" Below this we
     never stop the research loop.
   - `target` (optional aspirational, e.g. `>= 0.99`)
   - `K_corroboration` (**v0.28.0** — default 1): "How many experiments
     at target before we call it done?" Higher K reduces variance risk
     for reproducible wins.
   - `hard_constraints` (optional, e.g. `params < 100k`)
   - `notes` (optional, e.g. `MNIST test set`)

   Defaults for `plateau_window=5` and `plateau_threshold=0.01` apply
   automatically; user can edit metric.md directly if they want different
   values.

5. Format and write `metric.md`:

   ```bash
   source ${CLAUDE_PLUGIN_ROOT}/lib/state.sh
   source ${CLAUDE_PLUGIN_ROOT}/lib/deep-research.sh
   RUN_DIR=$(cw_run_dir_last)
   ART_DIR=$(cat "$RUN_DIR/art-dir.txt")
   cw_deep_research_format_metric_block <<EOF > "$ART_DIR/metric.md"
   primary_metric=accuracy
   direction=maximize
   min_acceptable=>= 0.90
   target=>= 0.99
   K_corroboration=1
   hard_constraints=params < 100k
   notes=MNIST test set
   EOF
   cat "$ART_DIR/metric.md"
   ```

   (Substitute the K=V pairs from the dialogue.)

6. **Final confirmation AskUserQuestion (UNCONDITIONAL when `$ART_DIR/metric.md` was just authored — v0.28.2 + v0.32.0 #23):**
   **Skip this AskUserQuestion if metric.md was pre-written by the
   `--metric` flag at init time** (user already committed to the
   framing on the command line). Otherwise: see Phase 1 preamble.
   Last chance to revise metric framing before any troopers spawn.

   > *"Here's how I'll frame the goal — OK to proceed?"*
   >
   > Options: `Looks good` / `Revise` / `Cancel`

   - `Looks good` → continue.
   - `Revise` → re-edit metric.md, re-confirm.
   - `Cancel` → archive topic via teardown.sh, exit directive.

Set task `1` → `completed`.

### Phase 1.5 — SOTA sweep

Set task `1.5` → `in_progress`.

One round of dual-search to seed a shared SOTA reference for the
session. Always runs (cost is ~30-90s wall-clock + 4 web calls); no
skip flag. Write-once at this phase; do not mutate `sota.md` after
this step (mid-session refresh deferred to v0.45.0 candidate).

#### Security note

Web access in this phase relies on:
- Yoda's `WebSearch` + `mcp__tavily__tavily-search` tool availability
  (Claude Code default in 2026).
- Trooper-side net access, permitted-by-default since v0.27.0
  (sandboxing is honor-system; not enforced).

If you need hard-block, do it at OS/firewall/network-namespace level
before invoking `/clone-wars:deep-research`. The skill does not expose
an opt-out flag.

1. Read the locked metric to seed search terms:

   ```bash
   source ${CLAUDE_PLUGIN_ROOT}/lib/log.sh
   source ${CLAUDE_PLUGIN_ROOT}/lib/state.sh
   ART_DIR=$(cat /tmp/cw-deep-research-art-dir.txt)
   DEEP_TOPIC=$(cat /tmp/cw-deep-research-topic.txt)
   TOPIC_TEXT=$(cat "$ART_DIR/topic.txt")
   PRIMARY_METRIC=$(grep -E '^\*\*Primary metric:' "$ART_DIR/metric.md" | sed -E 's/.*: //')
   HARD_CONSTRAINT=$(grep -E '^\*\*Hard constraints:' "$ART_DIR/metric.md" | sed -E 's/.*: //' || true)
   echo "PRIMARY_METRIC=$PRIMARY_METRIC"
   echo "HARD_CONSTRAINT=$HARD_CONSTRAINT"
   ```

2. Fire dual-search in **one tool-call message** (4 calls parallel):
   - `WebSearch`: `SOTA <PRIMARY_METRIC> <TOPIC_TEXT>`
   - `WebSearch`: `<TOPIC_TEXT> under <HARD_CONSTRAINT>` (skip if no
     hard_constraint in metric.md)
   - `mcp__tavily__tavily-search`: `SOTA <PRIMARY_METRIC> <TOPIC_TEXT>`
   - `mcp__tavily__tavily-search`: `<TOPIC_TEXT> under <HARD_CONSTRAINT>`
     (skip if no hard_constraint)

3. Merge result sets per the global dual-search rule:
   - Dedupe by URL.
   - On overlapping hits, prefer Tavily's longer paragraph-level
     snippet.
   - Surface unique results from each engine.

4. Curate **≤7 most relevant references** — variety over completeness;
   prefer one row per approach family (CNN, transformer, kernel
   method, etc.). If the merged set is smaller, write fewer rows;
   if it has nothing usable, write zero rows and let the helper emit
   the empty-table fallback.

5. Write `sota.md` via the helper (atomic tmp + mv):

   ```bash
   source ${CLAUDE_PLUGIN_ROOT}/lib/log.sh
   source ${CLAUDE_PLUGIN_ROOT}/lib/state.sh
   source ${CLAUDE_PLUGIN_ROOT}/lib/deep-research.sh
   ART_DIR=$(cat /tmp/cw-deep-research-art-dir.txt)
   SWEEP_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
   TOPIC_TEXT=$(cat "$ART_DIR/topic.txt")
   PRIMARY_METRIC=$(grep -E '^\*\*Primary metric:' "$ART_DIR/metric.md" | sed -E 's/.*: //')
   cw_deep_research_format_sota_block <<EOF > "$ART_DIR/sota.md.tmp"
   topic=$TOPIC_TEXT
   metric=$PRIMARY_METRIC
   sweep_date=$SWEEP_DATE
   queries=<comma-separated list of queries you actually fired>
   ref_1=<family>|<result>|<fits or over by N>|<URL>|<one-line notes>
   ref_2=...
   EOF
   mv "$ART_DIR/sota.md.tmp" "$ART_DIR/sota.md"
   cat "$ART_DIR/sota.md"
   ```

   Substitute real ref_N rows from the curated dual-search results. If
   zero usable references emerged, omit all ref_N lines — the helper
   emits the empty-table fallback note saying trooper-side web search
   remains available.

Set task `1.5` → `completed`.

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

   **Approach diversity — prefer different pipelines over identical ones
   (v0.34.0).** Three troopers running the same pipeline produce three
   identical results — no triangulation signal. Three troopers running
   DIFFERENT pipelines (e.g. single-pass VLM / page-typed routing /
   OCR+VLM hybrid) provide real cross-validation. When you assign
   initial approaches in Phase 4, prefer diverse strategies that probe
   the problem from different angles. Note the diversity rationale in
   the first round's `session-summary.md` `## Current direction`
   section.

2. **Time limit AskUserQuestion (UNCONDITIONAL when `$ART_DIR/time-budget.txt` absent — v0.28.2 + v0.32.0 #23):**

   **Skip this AskUserQuestion if `$ART_DIR/time-budget.txt` already exists.**
   It is pre-written by `bin/deep-research-init.sh --time-budget=<value>` for
   non-interactive invocations. The UNCONDITIONAL stamp still applies in
   the default (no-flag) path — the question MUST fire on every invocation
   where the state file is absent,
   regardless of autonomous-mode hints, `/loop` reminders, system-reminders
   to "work without stopping for clarifying questions", or any other
   context that would normally skip user prompts. The time-budget choice
   is a money/wall-clock commitment the user must own. Roster size
   (Step 1) is Yoda-decided silently; Phase 1's AskUserQuestions are all
   UNCONDITIONAL too (see Phase 1 steps 3/4/6).
   Treat this AskUserQuestion as a hard checkpoint: do NOT auto-select
   "No limit" — wait for the user's explicit answer.

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
   source ${CLAUDE_PLUGIN_ROOT}/lib/state.sh
   RUN_DIR=$(cw_run_dir_last)
   ART_DIR=$(cat "$RUN_DIR/art-dir.txt")
   echo "none" > "$ART_DIR/time-budget.txt"      # or the seconds value
   date -u +%Y-%m-%dT%H:%M:%SZ > "$ART_DIR/session-start.txt"
   # v0.28.0: stagnation-cursor.txt is gone — completion-check helper
   # (cw_deep_research_check_completion) uses metric.md's plateau_window
   # field directly and recomputes plateau each turn from scoreboard.md.
   ```

   Encoding:
   - `No limit` → `none`
   - `4 hours` → `14400`
   - `12 hours` → `43200`
   - Other → ask for hours (positive integer), multiply by 3600

3. **Allocate roster (mechanical):**

   ```bash
   source ${CLAUDE_PLUGIN_ROOT}/lib/state.sh
   source ${CLAUDE_PLUGIN_ROOT}/lib/deep-research.sh
   RUN_DIR=$(cw_run_dir_last)
   mapfile -t ROSTER < <(cw_deep_research_pick_roster 2)   # or 3
   echo "Roster: ${ROSTER[*]}"
   printf '%s\n' "${ROSTER[@]}" > "$RUN_DIR/roster.txt"
   ```

Set task `2` → `completed`.

### Phase 3a — Preflight pane allocation (foreground)

Set task `3` → `in_progress`.

**v0.28.3 architecture.** Phase 3 is split into 3a (preflight, foreground)
and 3b (parallel dispatch). 3a allocates N panes upfront in a single bash
process and applies `tmux select-layout main-vertical` so all panes appear
visually atomic with even heights. 3b then fires N truly-parallel
`bin/spawn.sh --target-pane` calls that `tmux respawn-pane` into the
pre-allocated panes — no `.last_pane` race, no chained-split half-sizing.

This mirrors `/clone-wars:meditate` Step 2 (v0.25.0+) and
`/clone-wars:consult` Step 3a/3b (v0.19.0+). Spec:
`docs/superpowers/specs/2026-05-13-v0.28.3-deep-research-preflight-port-design.md`.

1. **Write the consult-shaped sidecar.** `bin/preflight-layout.sh` reads a
   2-col TSV (`<provider>\t<commander>`); deep-research's native
   `troopers.txt` is 1-col commander-only. The sidecar bridges the schema
   gap (deploy v0.22.0 precedent):

   ```bash
   source ${CLAUDE_PLUGIN_ROOT}/lib/log.sh
   source ${CLAUDE_PLUGIN_ROOT}/lib/state.sh
   source ${CLAUDE_PLUGIN_ROOT}/lib/consult.sh
   source ${CLAUDE_PLUGIN_ROOT}/lib/deep-research.sh
   RUN_DIR=$(cw_run_dir_last)
   ART_DIR=$(cat "$RUN_DIR/art-dir.txt")
   mapfile -t ROSTER < "$RUN_DIR/roster.txt"
   cw_deep_research_write_preflight_sidecar "$ART_DIR" "${ROSTER[@]}"
   ```

2. **Initialize the retry counter ONCE** (shared between 3a and 3b — same
   counter governs both preflight-fail retry and spawn-fail retry):

   ```bash
   SPAWN_RETRY_COUNT=0
   ```

3. **Invoke preflight-layout.** Foreground; allocates N panes off Yoda's
   pane, applies main-vertical layout, writes `preflight-panes.txt`:

   ```bash
   source ${CLAUDE_PLUGIN_ROOT}/lib/state.sh
   RUN_DIR=$(cw_run_dir_last)
   DEEP_TOPIC=$(cat "$RUN_DIR/topic.txt")
   ART_DIR=$(cat "$RUN_DIR/art-dir.txt")
   ${CLAUDE_PLUGIN_ROOT}/bin/preflight-layout.sh \
     --art-dir "$ART_DIR" \
     --troopers-from "$ART_DIR/troopers-preflight.txt" \
     "$DEEP_TOPIC" "$N"
   ```

4. **On preflight rc=0:** load `preflight-panes.txt` into a per-commander
   pane-id lookup for 3b's parallel dispatch:

   ```bash
   declare -A PREFLIGHT_PANES
   while IFS=$'\t' read -r cmdr pane; do
     PREFLIGHT_PANES["$cmdr"]="$pane"
   done < "$ART_DIR/preflight-panes.txt"
   ```

5. **On preflight rc≠0 AND `SPAWN_RETRY_COUNT == 0`:** Stage 1 retry. Tear
   down any survivors + re-run from step 1 above. Set
   `SPAWN_RETRY_COUNT=1`.

   ```bash
   source ${CLAUDE_PLUGIN_ROOT}/lib/state.sh
   RUN_DIR=$(cw_run_dir_last)
   DEEP_TOPIC=$(cat "$RUN_DIR/topic.txt")
   ${CLAUDE_PLUGIN_ROOT}/bin/deep-research-teardown.sh "$DEEP_TOPIC" 2>/dev/null || true
   SPAWN_RETRY_COUNT=1
   log_info "preflight failed (cold start?); retrying preflight + parallel spawn"
   ```

6. **On preflight rc≠0 AND `SPAWN_RETRY_COUNT == 1`:** retry exhausted.
   Archive + exit (no Stage 2 prompt for preflight; if preflight fails
   twice the run is unrecoverable):

   ```bash
   ${CLAUDE_PLUGIN_ROOT}/bin/deep-research-teardown.sh "$DEEP_TOPIC" 2>/dev/null || true
   exit 1
   ```

### Phase 3b — Parallel dispatch (N parallel Bash tool calls)

**Issue N parallel `Bash` tool calls in a single message** — one per
ROSTER entry. Each call passes `--target-pane` (pre-allocated pane ID
from `PREFLIGHT_PANES`) and `--preflight-art-dir` (so spawn.sh validates
the pane ID against the correct preflight-panes.txt):

```bash
source ${CLAUDE_PLUGIN_ROOT}/lib/state.sh
RUN_DIR=$(cw_run_dir_last)
DEEP_TOPIC=$(cat "$RUN_DIR/topic.txt")
ART_DIR=$(cat "$RUN_DIR/art-dir.txt")
${CLAUDE_PLUGIN_ROOT}/bin/spawn.sh \
  <commander> codex "$DEEP_TOPIC" \
  --target-pane "${PREFLIGHT_PANES[<commander>]}" \
  --preflight-art-dir "$ART_DIR"
```

(Use the same iteration pattern as Phase 4.a — substitute each
commander in ROSTER for `<commander>`.)

Capture each rc separately. Evaluate the rc tuple after the parallel
block:

- **All N succeed** → continue to Phase 4. Set task `3` → `completed`.

- **Any failed AND `SPAWN_RETRY_COUNT == 0`** → Stage 1 retry-once:

  ```bash
  source ${CLAUDE_PLUGIN_ROOT}/lib/state.sh
  RUN_DIR=$(cw_run_dir_last)
  DEEP_TOPIC=$(cat "$RUN_DIR/topic.txt")
  ${CLAUDE_PLUGIN_ROOT}/bin/deep-research-teardown.sh "$DEEP_TOPIC" 2>/dev/null || true
  SPAWN_RETRY_COUNT=1
  log_info "spawn failed (cold start?); retrying preflight + parallel spawn"
  ```

  Then jump back to Phase 3a step 1 (re-write sidecar, re-run preflight,
  re-issue N parallel spawns). The teardown call clears any partially-
  spawned trooper state AND kills preflight sentinel panes (via the
  v0.28.3 orphan-cleanup extension in `bin/deep-research-teardown.sh`).

- **Any failed AND `SPAWN_RETRY_COUNT == 1`** → Stage 2 partial-success
  AskUserQuestion. Determine which troopers succeeded (look for
  `pane.json` in each `<commander>-codex/` state dir):

  ```bash
  SUCCESS=(); FAILED=()
  for cmdr in "${ROSTER[@]}"; do
    if [[ -f "$TOPIC_DIR/$cmdr-codex/pane.json" ]]; then
      SUCCESS+=("$cmdr")
    else
      FAILED+=("$cmdr")
    fi
  done
  ```

  Then AskUserQuestion with two options:
  - `Proceed degraded (${#SUCCESS[@]}/$N troopers)` — drop failed commanders
    from ROSTER + `$RUN_DIR/roster.txt` (resolve via `RUN_DIR=$(cw_run_dir_last)`)
    + `troopers.txt`, kill
    their preflight panes via `cw_preflight_kill_orphans`, continue to
    Phase 4 with the reduced roster. Force abort if `${#SUCCESS[@]} < 2`
    (deep-research min N=2).
  - `Abort deep-research` — archive via `deep-research-teardown.sh`, exit 1.

Set task `3` → `completed`.

### Phase 4 — Per-trooper turn loop (initial entry)

Set task `4` → `in_progress`.

**v0.28.0 architecture.** Phase 4 has TWO entry modes:
- **4.a (initial entry, this section)** — runs once when `/clone-wars:deep-research`
  is invoked. Sets up Monitor tasks per trooper, writes initial session-summary,
  dispatches first experiments, ends turn.
- **3.b (re-entry handler)** — fires on every subsequent turn (triggered by a
  trooper-completion notification OR a user message). Lives in
  `commands/deep-research-resume.md` (loaded via the UserPromptSubmit hook in
  `hooks/user-prompt-submit-active-session.sh` when active-<session-id>.txt is present).

**Architectural principle:** Yoda gives direction, not detailed plans.
Continuity lives in `session-summary.md` (Recent decisions + Current direction
sections), not in re-derived per-turn context.

**Brief length (v0.34.0):** Briefs may be 1-2 sentences for simple tasks
or 1-2 paragraphs for complex ones. Anything past ~300 tokens should go
in a per-experiment `task_context.md` file (pass via
`bin/deep-research-experiment-send.sh --context-file=<path>`). Long
inline briefs pollute `session-summary.md` and make `scoreboard.md`
hard to scan. The `--context-file` content is interpolated into the
trooper's prompt via the `{{TASK_CONTEXT}}` placeholder.

**Context belongs in prompt.md (v0.43.0 clarification — Item 9):**
Per-experiment context belongs in `prompt.md` via `--context-file`.
Do NOT write per-trooper `context.md` files in `troopers/<cmdr>/`.
The skill writes `prompt.md` from the experiment template with
`{{TASK_CONTEXT}}` interpolated; a separately-authored
`exp-NNN-context.md` drifts from the actual dispatch payload and
causes confusion at archive time.

**SOTA reference inlined into every prompt.md (v0.44.0):**
When `$ART_DIR/sota.md` exists (written once at Phase 1.5),
`bin/deep-research-experiment-send.sh` inlines its contents into the
dispatched `prompt.md` under a `## Reference: SOTA` section followed
by a "Web search affordance" two-liner authorizing curl/pip/arXiv
lookups when the trooper hits a plateau or before scale-up. When
sota.md is absent (legacy session, manual test harness, etc.) the
section is omitted entirely — back-compat preserved.

**Peer visibility inlined into every prompt.md (v0.45.0):**
When the session has ≥2 troopers, `bin/deep-research-experiment-send.sh`
inlines a `## Peers` section into each dispatched `prompt.md` showing
each peer trooper's current phase, last experiment, approach, and best
metric so far. The default editorial bias is **diverge**: the prompt
instructs the trooper to explore a different corner of the space
than their peers. Convergence on a peer's approach is allowed but
must be justified in `notes.md`. When the session has only one
trooper (N=1 solo), the section is omitted entirely.

#### 4.a — Initial entry (this turn only)

1. **Seed per-trooper state.** For each commander in `troopers.txt`:

   ```bash
   source ${CLAUDE_PLUGIN_ROOT}/lib/log.sh
   source ${CLAUDE_PLUGIN_ROOT}/lib/state.sh
   source ${CLAUDE_PLUGIN_ROOT}/lib/deep-research.sh
   RUN_DIR=$(cw_run_dir_last)
   ART_DIR=$(cat "$RUN_DIR/art-dir.txt")
   mapfile -t ROSTER < "$RUN_DIR/roster.txt"
   # v0.28.2: write durable roster file so render_summary / status_brief /
   # finalize.sh can iterate commanders without the directive's /tmp cache.
   # Was read-but-never-written in v0.28.0 — left the Status table empty in
   # session-summary.md.
   #
   # Format note: one-commander-per-line (NOT TSV `provider\tcommander`
   # like consult-init.sh writes). Deep-research is codex-fixed, so the
   # provider column would be redundant — keep this scheme aligned with
   # cw_deep_research_render_summary's `read -r cmdr` parse loop.
   #
   # Atomic write (tmp + mv) so a partial write under a concurrent crash
   # doesn't leave an empty/truncated roster file.
   printf '%s\n' "${ROSTER[@]}" > "$ART_DIR/troopers.txt.tmp" \
     && mv "$ART_DIR/troopers.txt.tmp" "$ART_DIR/troopers.txt"
   for cmdr in "${ROSTER[@]}"; do
     mkdir -p "$ART_DIR/troopers/$cmdr/experiments"
     : > "$ART_DIR/troopers/$cmdr/liveness-cursor.txt"
     cw_deep_research_trooper_state_write "$ART_DIR" "$cmdr" \
       exp_counter=0 phase=idle current_exp_id= \
       last_event_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       last_event=spawn probe_sent_ts=
   done
   ```

   (init.sh has already touched `active-${CLAUDE_CODE_SESSION_ID}.txt` at the art-dir root.)

   **Trooper `phase` values** (set in `state.txt`):
   - `idle` — between experiments; eligible for dispatch via Step 5.
   - `working` — currently executing an experiment.
   - `stale` / `stuck` — Monitor probe escalation (no outbox events past threshold).
   - `blocked` — trooper emitted a `question` event; awaiting user direction.
   - `failed` — run errored; manual recovery required.
   - `complete` / `incomplete` — terminal states set by `finalize.sh`.
   - `abandoned` (v0.43.0) — Yoda retired the lane via
     `cw_deep_research_lane_abandon`; criteria documented in
     `commands/deep-research-resume.md` Step 5. Reason recorded in
     `lane_abandon_reason`. Dispatch refuses (`bin/deep-research-experiment-send.sh`
     exits rc=2).

2. **Start one Monitor task per commander.** Each watches its trooper's outbox
   for `done/error/question/heartbeat` events AND fires `stale/stuck` events
   when outbox mtime exceeds `CW_DEEP_RESEARCH_PROBE_S` / `_STUCK_S` thresholds.

   For each commander, use the Monitor tool with config:
   - `command`: `bash ${CLAUDE_PLUGIN_ROOT}/bin/deep-research-monitor.sh "$ART_DIR" "<cmdr>"`
   - `persistent`: `true`
   - `description`: `deep-research monitor for <cmdr>`

   Capture each task ID and append to `$ART_DIR/monitor-tasks.txt`, one per line.

3. **Write initial `session-summary.md`:**

   ```bash
   source ${CLAUDE_PLUGIN_ROOT}/lib/state.sh
   source ${CLAUDE_PLUGIN_ROOT}/lib/deep-research.sh
   RUN_DIR=$(cw_run_dir_last)
   ART_DIR=$(cat "$RUN_DIR/art-dir.txt")
   cw_deep_research_render_summary "$ART_DIR" > "$ART_DIR/session-summary.md"
   ```

   Yoda then appends initial `## Current direction` (1-3 sentence opening
   strategy note) and `## Recent decisions` (placeholder bullets to be filled
   on first dispatch) via Write/Edit tool.

4. **First dispatch round.** For each trooper, Yoda composes a 1-2 sentence
   opening direction informed by `topic.txt`, `metric.md`, and `seed-from.txt`
   (if present). Dispatch via parallel Bash tool calls (one per commander in
   a single message):

   ```bash
   source ${CLAUDE_PLUGIN_ROOT}/lib/state.sh
   RUN_DIR=$(cw_run_dir_last)
   DEEP_TOPIC=$(cat "$RUN_DIR/topic.txt")
   ${CLAUDE_PLUGIN_ROOT}/bin/deep-research-experiment-send.sh \
     "$DEEP_TOPIC" "<cmdr>" "exp-001" "<approach-label>" "<short direction>"
   ```

   Each dispatch:
   - Creates `troopers/<cmdr>/experiments/exp-001/code/`
   - Updates `troopers/<cmdr>/state.txt` to `phase=working, current_exp_id=exp-001, exp_counter=1`
   - Writes `troopers/<cmdr>/experiments/exp-001/prompt.md` from the experiment template
   - Nudges the trooper pane via `bin/send.sh`

   For each dispatch, also fire a TaskCreate sub-row with subject
   `4.001 <Rank> <Commander> on <approach-label>` (use `cw_cmdr_rank` for the
   rank prefix).

   **Asymmetric-framing convergence — leverage observed quality gaps
   (v0.34.0).** When dispatching subsequent rounds (not the first one),
   if one trooper consistently produces lower-quality outputs across
   multiple experiments (visible in `scoreboard.md` or `consensus.md`'s
   `## Contested` section), explicitly frame the next direction to
   defer: "Trooper X has been more accurate on this task; for this
   experiment, use their values as a baseline unless you have strong
   contrary evidence." This converges the laggard faster than uniform
   direction. Document the asymmetry in `session-summary.md`'s
   `## Recent decisions` section.

5. **Render initial status brief (v0.28.2).** After dispatching the first
   round, render the status brief so the user sees the format that will
   repeat on every landed experiment. Approach labels come from each
   trooper's freshly-written `prompt.md` (via the `Approach label:` line);
   metric shows `(running)` since no `result.json` exists yet; scoreboard
   section will say `_(scoreboard absent)_`:

   ```bash
   cw_deep_research_render_status_brief "$ART_DIR"
   ```

   No `<latest-cmdr>` / `<latest-exp-id>` args on initial entry — the
   helper emits the generic `## Experiment status` header (no "just
   landed" suffix). Print the helper's output verbatim to chat, then
   continue to step 6.

6. **End the turn.** Emit a chat message:

   > N troopers running first experiments (rex on <approach-A>, cody on
   > <approach-B>). I'll pick up when they report back — you can ask me
   > anything in the meantime.

   Leave task `4` in `in_progress`. It transitions to `completed` only when
   handler 3.b reaches Step 2's exit (halt-flag detected OR completion-check
   triggers stop). Future turns are triggered by:

   - Monitor notifications (trooper events + liveness signals) — `<task-notification>`
     arrives natively.
   - User messages — the UserPromptSubmit hook (`hooks/user-prompt-submit-active-session.sh`)
     detects `$ART_DIR/active-${CLAUDE_CODE_SESSION_ID}.txt` and injects a context block pointing Yoda
     at `commands/deep-research-resume.md`.

   Both paths converge on handler 3.b. **Do not loop in this turn.**

### Phase 5 — Synthesis (landscape doc)

Set task `5` → `in_progress`.

Yoda writes `_deep-research/deep-research-<date>-<slug>.md` via Write
tool (atomic single-shot). **v0.28.0:** synthesis consumes
`session-summary.md` (rolling continuity record updated every turn by
handler 3.b step 7) as primary input alongside `scoreboard.md`. The
Recent decisions section is particularly useful for narrating the
session's research arc in the landscape doc.

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

    /clone-wars:deploy <archive-root>/_deep-research/winner/
```

Set task `5` → `completed`.

### Phase 6 — Teardown + archive

Set task `6` → `in_progress`.

**v0.28.0:** before the panes teardown, stop the Monitor tasks. Read
each task ID from `$ART_DIR/monitor-tasks.txt` and call `TaskStop` on
it (the TaskStop tool is a Claude Code harness primitive, not a shell
command — invoke it from this turn for each ID). `bin/deep-research-finalize.sh`
may have already run this; TaskStop is idempotent.

Then single batched panes teardown via `--pairs` (one 9s graceful banner
across N panes, not N × 9s):

```bash
source ${CLAUDE_PLUGIN_ROOT}/lib/state.sh
RUN_DIR=$(cw_run_dir_last)
DEEP_TOPIC=$(cat "$RUN_DIR/topic.txt")
mapfile -t ROSTER < "$RUN_DIR/roster.txt"
${CLAUDE_PLUGIN_ROOT}/bin/teardown.sh --pairs "$DEEP_TOPIC" "${ROSTER[@]}"
${CLAUDE_PLUGIN_ROOT}/bin/deep-research-teardown.sh "$DEEP_TOPIC"
```

(`deep-research-teardown.sh` prints the absolute archive path to stdout; use it
for the bake-in step below.)

The teardown's `mv` move preserves the entire `troopers/<cmdr>/` subtree
plus `session-summary.md`, `monitor-tasks.txt`, and the final scoreboard
in the archive.

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

## halt.flag format

v0.43.0 standardizes `$ART_DIR/halt.flag` as a structured `key=value`
file (one entry per line), readable via `awk -F=`. All three writers —
`bin/deep-research-abort.sh`, `commands/deep-research-resume.md`
Step 6 (user-halt), and Yoda's synthesis-time halt — emit this shape.

**Required keys (every write site):**

```
halted_by=user|yoda
halted_at=<ISO-8601-UTC>
reason=<short prose, single line>
```

**Optional keys (Yoda's target-met / corroboration halt SHOULD include):**

```
target_met=yes|no
floor_met=yes|no
k_so_far=<N>
k_required=<N>
plateau=yes|no
plateau_window=<N>
final_leader=<cmdr>/<exp-id>
final_leader_metric=<value>
architectures_corroborated=<comma-separated-labels>
```

Readers (`bin/deep-research-finalize.sh`, the existence checks in
`commands/deep-research-resume.md`) parse via awk and tolerate
legacy free-form prose from pre-v0.43.0 archives — single-line bodies
without `=` fall through gracefully.

## Intervention patterns

If you observe a trooper hanging, producing garbage result.json, or
exceeding cost without `cost_blown` status, you can send a clarifying
prompt mid-loop via `bin/send.sh`. Trooper panes remain attached; the
advisor regains control between every sub-step.

## Budget overrides

`CW_DEEP_RESEARCH_EXPERIMENT_TIMEOUT_OVERRIDE` overrides the
per-experiment wall-clock cap for the wait shim (default lives in
`lib/contracts.sh::cw_consult_timeout experiment`).
