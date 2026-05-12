---
description: AIDE-pattern executable autoresearch — conductor plans, codex troopers run experiments, K branches/round × N rounds tree search
argument-hint: <topic-with-explicit-metric> [--max-rounds N] [--branches-per-round K] [--time-budget DURATION] [--cost-warning USD] [--allow-net] [--seed-from PATH]
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, AskUserQuestion, Skill, WebSearch, WebFetch
---

# /clone-wars:deep-research

Run AIDE-pattern executable autoresearch on `$ARGUMENTS`. **Conductor
(Yoda / claude) plans; codex troopers execute.** Each round Yoda
hypothesizes K branches, spawns K codex troopers (each in its own
sandbox dir), waits for each trooper to implement + run the experiment +
write a `result.json` in a single turn, scores the round, selects top-M
survivors, and proposes next-round branches inspired by the winners.
Loop until convergence (`delta < 1%` × 2 rounds), divergence (all
branches failed), or budget exhausted.

> ⚠️ **DANGER — read first.** This command spawns codex troopers under
> `--dangerously-bypass-approvals-and-sandbox` and has them write +
> execute arbitrary code in your repo. **v1 sandboxing is honor-system**
> — troopers are *told* to stay inside their branch dir; enforcement is
> not mechanical. Do **not** run on machines with sensitive credentials,
> production data, or shared state. Use a scratch worktree if uncertain
> (this command does **not** create one for you). `--allow-net=false`
> (default) tells troopers not to fetch external resources; also
> honor-system.

**When to use this command.** Invoke `/clone-wars:deep-research` when
the user wants to actually **run experiments** to find the best approach
to a measurable objective. Phrases that should route here:

- "find the best approach to maximize/minimize X"
- "run experiments to optimize X"
- "autoresearch X", "automl X", "AIDE-style search on X"
- "implement and benchmark several approaches to X"

Phrases that should NOT route here (route to `/clone-wars:meditate` for
landscape exploration, or `/clone-wars:consult` for a design doc):

- "explore SOTA X" (no metric → use /meditate)
- "design X" (no execution → use /consult)
- "compare A vs B" (decide via discussion → use /consult)

The intended workflow is `meditate → consult` for non-executable topics,
and `meditate → deep-research → deploy` for executable autoresearch.
Meditate's `## Approaches` section can seed deep-research's round 1 via
`--seed-from <landscape-path>`.

**Codex required.** `bin/deep-research-init.sh` refuses if codex is not
in `providers-available.txt`. Medic active-set is IGNORED for
deep-research (roster is fixed at codex; commanders rotate via
`cw_deep_research_allocate_commanders`).

Spec: `docs/superpowers/specs/2026-05-12-v0.26.0-deep-research-design.md`.

## Task list (TaskCreate BEFORE Step 0)

Create the task list using `TaskCreate`. Update statuses at the
boundaries below. Per-round sub-rows are added at round entry (Step 2a
fires `K` TaskCreate calls, one per branch, after `branches.txt` is
written).

| # | subject | activeForm |
|---|---|---|
| 0 | `0 Args + init + budget [yoda]`                | `Staging args` |
| 1 | `1 Preflight confirmation [yoda + user]`       | `Confirming budget` |
| 2 | `2 Round loop (hypothesize→experiment→score)`  | `Running round loop` |
| 3 | `3 Final synthesis [yoda]`                     | `Writing landscape doc` |
| 4 | `4 Teardown + archive [yoda]`                  | `Tearing down` |
| 5 | `5 Present final doc + next step [yoda]`       | `Presenting landscape` |

## Steps

The user's `$ARGUMENTS` may contain shell metacharacters. Write it via
the Write tool, then invoke sub-scripts.

### Step 0 — Args + init + budget

Set task `0` → `in_progress`.

1. Resolve args path:

   ```
   ARGS_DIR="${CLONE_WARS_HOME:-$HOME/.clone-wars}/_args"
   mkdir -p "$ARGS_DIR"
   echo "$ARGS_DIR/deep-research.txt"
   ```

2. Write tool: `file_path` = the path printed; `content` = `$ARGUMENTS`.

3. Initialize the deep-research topic:

   ```
   source "$CLAUDE_PLUGIN_ROOT/lib/state.sh"
   source "$CLAUDE_PLUGIN_ROOT/lib/consult.sh"
   source "$CLAUDE_PLUGIN_ROOT/lib/deep-research.sh"

   ARGS_DIR="${CLONE_WARS_HOME:-$HOME/.clone-wars}/_args"
   ARGS=$(cat "$ARGS_DIR/deep-research.txt")
   # shellcheck disable=SC2086 — splitting is intentional for flag args
   DEEP_TOPIC=$("$CLAUDE_PLUGIN_ROOT/bin/deep-research-init.sh" $ARGS)
   REPO_HASH=$(cw_repo_hash)
   TOPIC_DIR="${CLONE_WARS_HOME:-$HOME/.clone-wars}/state/$REPO_HASH/$DEEP_TOPIC"
   ART_DIR="$TOPIC_DIR/_deep-research"
   echo "$DEEP_TOPIC"
   ```

   If `deep-research-init.sh` exits non-zero (codex missing, bad budget,
   `--seed-from` path not found), surface the stderr verbatim to the
   user, mark task `0` as `pending` (kept for retry), and exit the
   directive. Do NOT continue.

4. Load budget knobs into directive variables:

   ```
   MAX_ROUNDS=$(grep '^max-rounds=' "$ART_DIR/budget.txt" | cut -d= -f2)
   K=$(grep '^branches-per-round=' "$ART_DIR/budget.txt" | cut -d= -f2)
   TIME_BUDGET_S=$(grep '^time-budget-s=' "$ART_DIR/budget.txt" | cut -d= -f2)
   PER_BRANCH_TIMEOUT=$(grep '^per-branch-timeout-s=' "$ART_DIR/budget.txt" | cut -d= -f2)
   COST_WARNING=$(grep '^cost-warning-usd=' "$ART_DIR/budget.txt" | cut -d= -f2)
   ALLOW_NET=$(grep '^allow-net=' "$ART_DIR/budget.txt" | cut -d= -f2)
   METRIC=$(cat "$ART_DIR/metric.txt")
   TOPIC_TEXT=$(cat "$ART_DIR/topic.txt")
   ```

5. If `$METRIC` is empty (heuristic extraction couldn't parse the topic),
   fire one `AskUserQuestion`:

   - Question: `"Which metric should be optimized? Topic: '$TOPIC_TEXT'"`
   - Header: `"Metric"`
   - Options: 4 candidates from common metrics (accuracy / latency /
     loss / throughput / "Other"). User's choice → write to
     `$ART_DIR/metric.txt` via Write tool (atomic).

Set task `0` → `completed`.

### Step 1 — Preflight confirmation (single user gate)

Set task `1` → `in_progress`.

Compute total planned branches and confirm spend:

```
TOTAL_BRANCHES=$((MAX_ROUNDS * K))
```

Fire ONE `AskUserQuestion`:

- Question: `"About to run $K branches/round × $MAX_ROUNDS rounds = $TOTAL_BRANCHES total codex trooper invocations. Per-branch wall-clock cap ${PER_BRANCH_TIMEOUT}s; total budget ${TIME_BUDGET_S}s; informational cost ceiling \$$COST_WARNING. Continue?"`
- Header: `"Confirm"`
- Options:
  - `Continue` (default recommended) — start the loop
  - `Adjust budget` — cancel and re-invoke with different flags
  - `Cancel` — full abort + teardown

If the user chooses `Adjust budget` or `Cancel`:
- Invoke `bin/deep-research-teardown.sh "$DEEP_TOPIC"` to archive the
  state dir (init's writes are preserved under archive).
- Mark all remaining tasks as `completed` (UX-only — work is aborted).
- Exit the directive with a message: "Aborted; re-invoke with different
  flags." or "Aborted." accordingly.

If the user chooses `Continue`:

Set task `1` → `completed`.

### Step 2 — Round loop

Set task `2` → `in_progress`.

Initialize loop-control variables:

```
CONSECUTIVE_CONVERGENCE=0
DIVERGED=0
CONVERGED=0
PREVIOUS_BEST_METRIC=""
```

For each `n` in `1..MAX_ROUNDS`:

```
for ((n=1; n<=MAX_ROUNDS; n++)); do
  # … sub-steps 2a–2i below …
done
```

#### Step 2a — Hypothesize (Yoda inline)

Yoda directly proposes K branches for round `n`. Behavior depends on `n`:

**Round 1:**

If `$ART_DIR/seed-from.txt` exists, read its content and bootstrap from
the meditate landscape doc's `## Approaches`:

```
if [[ -f "$ART_DIR/seed-from.txt" ]]; then
  SEED=$(cat "$ART_DIR/seed-from.txt")
  source "$CLAUDE_PLUGIN_ROOT/lib/deep-research.sh"
  SEEDED_APPROACHES=$(cw_deep_research_extract_approaches "$SEED" | head -n "$K")
fi
```

Otherwise, research the topic yourself (WebSearch + Tavily paired per
the global dual-search rule), then propose K distinct approaches to the
metric optimization problem.

**Round n > 1:**

Read `$ART_DIR/round-$((n-1))/scoreboard.md` to see what won. Top-M
survivors (where `M = ceil(K/2)`) inform the new branches: vary the
winning approaches (different hyperparameters, alternative algorithms
that share the winner's structure, etc.). Also propose 1–2 wholly new
approaches if the round-1 surface didn't get much explored. K branches
total per round.

Allocate K commanders for the round:

```
mkdir -p "$ART_DIR/round-$n"
mapfile -t ROUND_COMMANDERS < <(cw_deep_research_allocate_commanders "$n" "$K")
```

Write `branches.txt` as TSV `branch_id\tcommander\tapproach_label\tapproach_brief`:

```
# Use the Write tool with content built as:
#   "b1\trex\tAIDE tree search\tDepth-3 tree search with UCB1 selection\n"
#   "b2\tkeeli\tSequential MCTS\tMCTS with 100 rollouts/depth\n"
#   …
# Branch IDs are b1..bK (lowercase 'b' + 1-based index).
# Commanders come from ROUND_COMMANDERS in order.
```

Fire K `TaskCreate` calls — one sub-row per branch — with subjects
shaped `2a.$n.$bid <Rank> <Commander> on <approach_label>` (use
`cw_cmdr_rank "$cmdr"` from `lib/commanders.sh` for the rank prefix,
matching v0.23.1's per-trooper sub-row pattern):

```
# Example: subject="2a.1.b1 Captain Rex on AIDE tree search"
#          activeForm="Captain Rex implementing AIDE"
```

#### Step 2b — Spawn K codex troopers (parallel Bash calls)

Issue `K` parallel `Bash` tool calls in a single message. Each call:

```
"$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" <commander> codex "$DEEP_TOPIC"
```

Capture each rc separately. Stage-1 retry-once on cold-start failure
(codex bootstrap timeout) — tear down survivors via
`bin/teardown.sh --pairs "$DEEP_TOPIC" <commander1> [<commander2>...]`,
re-issue the K parallel spawn calls. Stage-2 AskUserQuestion on partial
success: `Proceed degraded` (drop failed troopers; run K-fail branches
this round) / `Abort round (continue to next)` / `Abort deep-research`.

Update per-branch sub-rows: `in_progress` after spawn rc=0 for each
commander.

#### Step 2c — Dispatch experiments (parallel Bash calls)

Issue `K` parallel `Bash` tool calls in a single message:

```
"$CLAUDE_PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
  "$DEEP_TOPIC" "$n" <commander> <branch_id>
```

(One call per `(commander, branch_id)` pair from `branches.txt`.)

#### Step 2d — Wait for K codex troopers (parallel Bash calls, foreground)

Issue `K` parallel `Bash` tool calls in a single message. Each call:

```
CW_DEEP_RESEARCH_EXPERIMENT_TIMEOUT_OVERRIDE="$PER_BRANCH_TIMEOUT" \
"$CLAUDE_PLUGIN_ROOT/bin/deep-research-experiment-wait.sh" \
  "$DEEP_TOPIC" <commander> codex
```

The env var override caps each trooper's wait at the budget slice.

Update per-branch sub-rows: `completed` for each trooper as their
wait shim returns (rc=0 done, rc=1 error/timeout). The score phase
treats timeout/error branches as `status: fail`.

#### Step 2e — Score round (mechanical)

Single Bash call:

```
"$CLAUDE_PLUGIN_ROOT/bin/deep-research-score.sh" "$DEEP_TOPIC" "$n"
```

Reads each branch's `result.json`, validates via
`cw_deep_research_validate_result_json`, writes
`$ART_DIR/round-$n/scoreboard.md` with all branches sorted descending
by `metric_value`. Failed/invalid branches grouped at the bottom.

#### Step 2f — Select survivors + check loop-exit conditions

Read `$ART_DIR/round-$n/scoreboard.md`. Identify:

- **OK count** — number of branches with `status: ok` in this round.
- **Best metric this round** — first `ok` row's `metric_value`.

Branches.txt for next round will reference winners; record them in
memory for the next iteration's hypothesize phase.

**Divergence check:** if OK count == 0:

```
DIVERGED=1
```

Mark task `2` → `completed` with note "diverged at round $n". Break the
round loop.

**Convergence check:** if `n >= 2` and `$PREVIOUS_BEST_METRIC` is set,
compute the percentage delta:

```
# delta% = abs(best_this_round - previous_best) / previous_best * 100
# Using awk for floating-point comparison:
DELTA_PCT=$(awk -v new="$BEST_METRIC" -v old="$PREVIOUS_BEST_METRIC" \
  'BEGIN { d = (new > old ? new - old : old - new); printf "%.4f", (old==0 ? 100 : d / old * 100) }')

if awk -v d="$DELTA_PCT" 'BEGIN { exit !(d < 1.0) }'; then
  CONSECUTIVE_CONVERGENCE=$((CONSECUTIVE_CONVERGENCE + 1))
else
  CONSECUTIVE_CONVERGENCE=0
fi

if (( CONSECUTIVE_CONVERGENCE >= 2 )); then
  CONVERGED=1
fi
```

Update `PREVIOUS_BEST_METRIC=$BEST_METRIC` for next iteration.

If `CONVERGED=1`: break the round loop.

#### Step 2g — Teardown round troopers (single batched call)

Pull the round's commanders from `branches.txt`:

```
mapfile -t TEARDOWN_CMDRS < <(awk -F'\t' '{print $2}' "$ART_DIR/round-$n/branches.txt")
"$CLAUDE_PLUGIN_ROOT/bin/teardown.sh" --pairs "$DEEP_TOPIC" "${TEARDOWN_CMDRS[@]}"
```

This is the v0.20.5 batched pattern: **one 9-second graceful banner
across all K panes**, not K × 9-second waits.

Also remove the round's experiment state files so the next round's
commander allocations don't collide:

```
rm -f "$ART_DIR"/experiment-*.txt
```

End of `n` iteration — back to `for` loop.

### Step 3 — Final synthesis (Yoda inline)

Set task `3` → `in_progress`.

Yoda writes `$ART_DIR/deep-research-$(date +%Y-%m-%d)-$SLUG.md` (where
`$SLUG` is extracted from `$DEEP_TOPIC` after the `deep-research-`
prefix) using the Write tool (atomic single-shot).

**Outcome determination:**

```
if (( CONVERGED == 1 )); then
  OUTCOME="converged"
elif (( DIVERGED == 1 )); then
  OUTCOME="diverged"
elif (( n > MAX_ROUNDS )); then
  OUTCOME="rounds-exhausted"
else
  OUTCOME="budget-exhausted"
fi
```

(Note: `n` after loop holds either the round that triggered an early
exit, or `MAX_ROUNDS + 1` if the loop completed normally.)

**Doc shape** (each section is REQUIRED):

```markdown
# Deep Research: <slug-titled>

**Generated:** <ISO-8601 UTC>
**Topic:** <verbatim from topic.txt>
**Metric:** <verbatim from metric.txt>
**Budget:** <verbatim KEY=VALUE block from budget.txt>
**Seed:** `<seed-from.txt path>` or `none`
**Outcome:** converged | diverged | rounds-exhausted | budget-exhausted
**Best metric:** <value> (vs. round-1 best: <value>; delta: +X.X%)

## Round-by-round

### Round 1 (<K> branches, <N_OK> ok, <N_FAIL> failed)

| Branch | Commander | Approach | Metric | Status | Runtime |
|---|---|---|---|---|---|
…

**Survivors:** <branch_ids that fed round 2>

### Round 2
…

## Winner

**<branch_id> (round <r>)** — `Approach: <label>`
- Metric: <value>
- Code path: `~/.clone-wars/archive/<repo_hash>/<topic>-<ts>/_deep-research/round-<r>-<cmdr>-<bid>/code/`
- Runtime: <value>s
- Notes: <result.json notes verbatim>

## Convergence

<one paragraph: why we stopped; cite the delta values that triggered
convergence or "all branches failed" for diverged, etc.>

## Branches preserved

All branch sandbox dirs (with `code/`, `result.json`, `stdout.log`,
`stderr.log`) are archived under
`~/.clone-wars/archive/<repo_hash>/<topic>-<ts>/_deep-research/`.

## Suggested next

<emitted ONLY when OUTCOME ∈ {converged, rounds-exhausted} AND
 best-metric > round-1-best AND winner is `status: ok`. Otherwise
 omit this section and write a 1-line "No clear winner — see Outcome
 section above." note.>

Productionize the winner:

    /clone-wars:deploy ~/.clone-wars/archive/<repo_hash>/<topic>-<ts>/_deep-research/round-<r>-<cmdr>-<bid>/code/
```

Each round table reads from `$ART_DIR/round-$r/scoreboard.md` (already
sorted). Winner = first row with `status: ok` from the highest-numbered
round that has any ok branches.

Set task `3` → `completed`.

### Step 4 — Teardown + archive

Set task `4` → `in_progress`.

Final archive:

```
ARCHIVE=$("$CLAUDE_PLUGIN_ROOT/bin/deep-research-teardown.sh" "$DEEP_TOPIC")
echo "$ARCHIVE"
```

(`deep-research-teardown.sh` archives the entire topic state dir to
`~/.clone-wars/archive/<repo_hash>/<topic>-<ts>/`, preserving all
branches' code/, result.json, log files, and the final landscape doc.)

Set task `4` → `completed`.

### Step 5 — Present final doc

Set task `5` → `in_progress`.

Show the user:
- Path to the archived landscape doc:
  `$ARCHIVE/_deep-research/deep-research-<date>-<slug>.md`
- Path to the winning branch's `code/` directory.
- The "Suggested next" line (verbatim) if it was emitted.
- A one-line outcome summary: outcome + best-metric + delta.

Set task `5` → `completed`.

## Intervention patterns

If you observe a trooper hanging, producing garbage result.json, or
exceeding cost without `cost_blown` status, you can `cw_send <cmdr>
<topic> "clarifying prompt"` between any sub-steps of Step 2. The
trooper pane remains attached; the conductor regains control between
every sub-step. Use this sparingly — the design assumes troopers
self-manage within their single-turn budget.

## Budget overrides

Environment variable `CW_DEEP_RESEARCH_EXPERIMENT_TIMEOUT_OVERRIDE`
overrides the per-branch wall-clock cap for the wait shim. Step 2d sets
it from `budget.txt`; set externally to override at runtime (debugging).
