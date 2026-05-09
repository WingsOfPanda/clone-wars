---
description: Audit a design doc, dispatch to codex troopers (claude on plugin repos) for plan/implement/self-verify, then cross-verify and fix-loop. Multi-repo DAG-aware (v0.20.0).
argument-hint: [--no-branch] [--branch <n>] [--topic <slug>] [--provider codex|claude] [--max-rounds 5] [<design-doc-path>]
allowed-tools: Bash, Write, Read, Edit, AskUserQuestion
---

# /clone-wars:deploy

Run a trooper-implements / Yoda-verifies pipeline on `$ARGUMENTS`.

**When to use this command.** Invoke `/clone-wars:deploy` when the user
asks to implement, ship, or execute a design doc produced by
`/clone-wars:consult`. Trigger phrases: "deploy this design", "implement
the spec at <path>", "ship <design-path>", "execute the design-doc",
"spawn troopers for <design>". Single-repo design docs run today's
single-trooper flow; multi-repo design docs (`**Target Sub-Project(s):**`
header + `## Execution DAG` section) automatically route through the
v0.20.0 multi-repo DAG flow.

The cody pane stays attached for the entire run — `tmux select-pane` to watch.

Spec: `docs/superpowers/specs/2026-05-09-deploy-multi-repo-dag-design.md` (v0.20.0 — current);
`docs/superpowers/specs/2026-05-02-clone-wars-execute-design.md` (v0.6 baseline).

## Source defaulting

If `$ARGUMENTS` does not include a `.md` path, find the most recent
consult-produced audit-passing design doc:

```
STATE_ROOT="${CLONE_WARS_HOME:-$HOME/.clone-wars}/state"
DESIGN_DOC=$(find "$STATE_ROOT" -path '*/_consult/design-doc/*-design.md' \
    -printf '%T@ %p\n' 2>/dev/null \
  | sort -n | tail -1 | cut -d' ' -f2-)
[[ -n "$DESIGN_DOC" ]] || { log_error "no consult design-doc found; run /clone-wars:consult first or pass <path>"; exit 1; }
```

`AskUserQuestion` to confirm: "Use most recent consult design-doc:
<DESIGN_DOC>?" Options: `Use this` / `Cancel`. On "Use this", append
the path to the args file (so init.sh receives it as the positional
argument). On "Cancel", exit 0.

(v0.20.0: dropped pre-v0.12 `--design-doc` flag and `synthesis.md`
fallback. The `/clone-wars:spec` command was removed in v0.17.0; consult
v0.17+ produces audit-passing design-docs directly.)

## Task list (TaskCreate × N BEFORE step 0)

Create the task list using `TaskCreate`. Single-repo runs uses tasks
0/1.1/1/2/3/4 (N=6, like v0.19.0). Multi-repo runs use tasks
0/3a/3b/3c/3d/4 (N=6 also; the 1.1/1/2/3 single-repo tasks are skipped).
Pick one set after Step 0's routing branch decides.

| # | subject | activeForm |
|---|---|---|
| 0   | `0   Audit + routing detect [yoda]`               | `Auditing design doc + routing` |
| 1.1 | `1.1 Spawn cody (single-repo)  [yoda]`            | `Spawning cody-${PROVIDER}` |
| 1   | `1   Run trooper turn (round N) [cody]`           | `Cody running turn (round N)` |
| 2   | `2   Cross-verify (round N) [yoda]`               | `Yoda cross-verifying (round N)` |
| 3   | `3   Author fix bundle (if needed) [yoda]`        | `Authoring fix bundle` |
| 3a  | `3a  Preflight pane allocation (multi-repo) [yoda]` | `Multi-repo preflight` |
| 3b  | `3b  DAG wave dispatch (multi-repo) [yoda+troopers]` | `Multi-repo DAG dispatch` |
| 3c  | `3c  Final verification (multi-repo) [yoda]`      | `Multi-repo final verify` |
| 3d  | `3d  Fix-loop (multi-repo) [yoda+troopers]`       | `Multi-repo fix-loop` |
| 4   | `4   Teardown + archive [yoda]`                   | `Tearing down` |

## Steps

The user's `$ARGUMENTS` may contain shell metacharacters. Write it via the
Write tool, then invoke sub-scripts with the resolved values.

### Step 0 — Audit design doc

Set task `0` → `in_progress`.

1. Resolve args path:
   ```
   ARGS_DIR="${CLONE_WARS_HOME:-$HOME/.clone-wars}/_args"
   mkdir -p "$ARGS_DIR"; echo "$ARGS_DIR/deploy.txt"
   ```
2. Parse `--max-rounds <N>` out of `$ARGUMENTS` BEFORE writing the args file.
   The init script rejects unknown flags, so this flag must never reach it.
   Scan `$ARGUMENTS` token-by-token: when you see `--max-rounds`, capture the
   NEXT token into `MAX_ROUNDS_OVERRIDE` (export it for Step 2's loop init)
   and drop both tokens. Write the REMAINING tokens (space-joined) to the
   args file via the Write tool — not `$ARGUMENTS` verbatim.

   Example transformation:
   - `$ARGUMENTS` = `path/to/spec.md --topic foo --max-rounds 3 --no-branch`
   - `MAX_ROUNDS_OVERRIDE` = `3`
   - args-file contents = `path/to/spec.md --topic foo --no-branch`

   If `--max-rounds` is absent, leave `MAX_ROUNDS_OVERRIDE` unset (Step 2
   defaults to 5) and write `$ARGUMENTS` unchanged.
3. Write tool: `file_path` = the path printed in step 1; `content` = the
   filtered argument string from step 2 (or `$ARGUMENTS` verbatim if no
   `--max-rounds` was found).
4. Inspect the args file to detect "no positional .md arg given". If so,
   apply source defaulting (v0.20.0: only the modern audit-passing
   design-doc shape is considered; pre-v0.12 `--design-doc` flag and
   `synthesis.md` fallback are gone):
   ```
   source "$CLAUDE_PLUGIN_ROOT/lib/state.sh"
   REPO_HASH=$(cw_repo_hash)
   STATE_ROOT="${CLONE_WARS_HOME:-$HOME/.clone-wars}"
   CANDIDATE=$(find "$STATE_ROOT/state/$REPO_HASH" \
                 -path '*/_consult/design-doc/*-design.md' \
                 -type f -printf '%T@ %p\n' 2>/dev/null \
                 | sort -n | tail -1 | cut -d' ' -f2-)
   ```
   - If `CANDIDATE` is non-empty, `AskUserQuestion` (options: "Use this",
     "Cancel"). On "Use this", append the path to the args file (so init.sh
     receives it as the positional argument). On "Cancel", exit 0.
   - If `CANDIDATE` is empty and no `.md` path is in the args file, refuse
     with a usage hint and exit 1.
5. Init (init.sh consumes the args file directly — its argv parser handles
   `--no-branch` / `--branch` / `--topic` / `<design-path>`):
   ```
   source "$CLAUDE_PLUGIN_ROOT/lib/state.sh"
   REPO_HASH=$(cw_repo_hash)
   TOPIC=$("$CLAUDE_PLUGIN_ROOT/bin/deploy-init.sh" \
              --args-file "$ARGS_DIR/deploy.txt")
   TOPIC_DIR="${CLONE_WARS_HOME:-$HOME/.clone-wars}/state/$REPO_HASH/$TOPIC"
   ART_DIR="$TOPIC_DIR/_deploy"
   # Pull TARGET_CWD up here so the branch-base rev-parse below runs in the
   # right working tree. Sub-step 9 logs/re-reads it for downstream steps;
   # this early read is harmless because deploy-init.sh has already written
   # target_cwd.txt by the time it returns.
   TARGET_CWD=$(cat "$ART_DIR/target_cwd.txt")
   # CRITICAL: export so EVERY downstream bin script invocation in this
   # directive (deploy-turn-send, deploy-turn-wait, deploy-archive,
   # deploy-teardown, spawn) inherits it. lib/state.sh's cw_topic_repo_hash
   # honors this var when computing topic-state paths so reads agree with
   # what bin/deploy-init.sh wrote (under the SUB-repo hash, not the HUB).
   export CW_TOPIC_REPO_CWD="$TARGET_CWD"
   # Record branch base for cross-verify diff range (used in Step 2 + Step 4).
   # init.sh creates feat/deploy-<topic> from HEAD on the *trooper's* working
   # tree, so HEAD inside $TARGET_CWD right now IS the commit the new branch
   # was created from — exactly the diff base we want.
   # Do NOT use `git merge-base HEAD main` here: when invoked from a topic
   # branch that already diverged from main, merge-base returns the prior
   # branch's divergence point (over-counting unrelated commits).
   git -C "$TARGET_CWD" rev-parse HEAD > "$ART_DIR/branch-base.sha"
   BRANCH_BASE=$(cat "$ART_DIR/branch-base.sha")
   ```
6. Run audit and persist verdict:
   ```
   source "$CLAUDE_PLUGIN_ROOT/lib/deploy.sh"
   AUDIT=$(cw_deploy_audit_doc "$ART_DIR/design.md" 2>&1) && AUDIT_RC=0 || AUDIT_RC=$?
   printf '%s\n' "$AUDIT" > "$ART_DIR/design-audit.md"
   ```
7. Branch on `AUDIT_RC` — distinguish unreadable doc from FAIL verdict:
   ```
   if (( AUDIT_RC == 2 )); then
     log_error "design-doc unreadable; aborting."
     "$CLAUDE_PLUGIN_ROOT/bin/deploy-archive.sh" "$TOPIC"
     exit 1
   elif (( AUDIT_RC == 1 )); then
     # Audit FAIL — read the design doc yourself, weigh the flagged issues, then:
     # AskUserQuestion (options: "Proceed anyway", "Abort and edit doc").
     # Abort → bin/deploy-archive.sh "$TOPIC" + exit 1
     # Proceed → continue.
     :
   fi
   ```

8. Resolve trooper provider (auto-detect → confirm if claude):

   ```
   AUTO_PROVIDER=$(cat "$ART_DIR/auto_provider.txt")
   ```

   Branch on `$AUTO_PROVIDER`:

   - `codex` → no prompt, just persist:
     ```
     PROVIDER=codex
     log_info "trooper provider: codex (auto-go)"
     ```
   - any other unexpected value (e.g. stale-file corruption) → log warning,
     default to codex without prompting:
     ```
     log_warn "unexpected auto_provider value '$AUTO_PROVIDER'; defaulting to codex"
     PROVIDER=codex
     ```
   - `claude` → AskUserQuestion (the cheap default isn't appropriate for
     plugin repos; ask the user before spending claude tokens):
     ```
     question: "This repo has .claude-plugin/plugin.json — Claude is the
       recommended trooper for plugin testing (it can load slash commands,
       run hooks, exercise the Claude Code surface natively). It will use
       claude tokens. Use claude or fall back to codex?"
     options:
       - "Use claude (recommended for plugin testing)"
       - "Fall back to codex (cheaper)"
     ```
     Set `PROVIDER` to `claude` if user picked "Use claude"; else `codex`.

   Atomically persist the final choice:
   ```
   printf '%s\n' "$PROVIDER" > "$ART_DIR/provider.txt.tmp"
   mv "$ART_DIR/provider.txt.tmp" "$ART_DIR/provider.txt"
   ```

9. Re-confirm the target cwd resolved by `deploy-init.sh` and ensure it is
   exported for downstream bin scripts:

   ```
   TARGET_CWD=$(cat "$ART_DIR/target_cwd.txt")
   export CW_TOPIC_REPO_CWD="$TARGET_CWD"
   log_info "trooper target cwd: $TARGET_CWD"
   ```

   Every downstream bin script (`bin/deploy-turn-send.sh`, `bin/deploy-turn-wait.sh`,
   `bin/deploy-archive.sh`, `bin/spawn.sh`, `bin/teardown.sh`) reads
   `$CW_TOPIC_REPO_CWD` (via `lib/state.sh`'s `cw_topic_repo_hash`) to compute
   topic-state paths against the sub-repo's hash — without this export they
   would key off the conductor's `$PWD` (the HUB) and miss the artifacts that
   `deploy-init.sh` wrote under the SUB-repo hash.

   For single-repo deploys (no `Target Sub-Project` header in the design doc),
   `$TARGET_CWD` equals the conductor's cwd — the env var still gets exported
   but resolves to the same hash, so behavior is unchanged. For hub deploys
   with a header, `$TARGET_CWD` is the absolute path to the named sub-repo.
   Step 1.1 passes this to `spawn.sh --cwd`, and Step 2's cross-verify uses
   it as the `git -C` working tree.

Set task `0` → `completed`.

**Routing branch (v0.20.0).** After audit PASS + provider resolution,
read the routing decision written by `bin/deploy-init.sh`:

```
ROUTING=$(cat "$ART_DIR/routing.txt")
log_info "deploy routing: $ROUTING"
```

- If `$ROUTING == "single-repo"`: continue with Steps 1.1, 1, 2, 3, 4
  exactly as v0.19.0 (single-trooper flow, no multi-repo ceremony).
- If `$ROUTING == "multi-repo"`: SKIP Steps 1.1, 1, 2, 3 entirely;
  jump to NEW Step 3a (multi-repo preflight) → Step 3b (DAG wave
  dispatch) → Step 3c (final verification) → Step 3d (fix-loop) →
  Step 4 (teardown, common to both paths).

### Step 1.1 — Spawn cody-$PROVIDER

**Active only when `$ROUTING == "single-repo"`.**

Set task `1.1` → `in_progress`.
```
PROVIDER=$(cat "$ART_DIR/provider.txt")
TARGET_CWD=$(cat "$ART_DIR/target_cwd.txt")
"$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" cody "$PROVIDER" "$TOPIC" --cwd "$TARGET_CWD"
```
Set task `1.1` → `completed`. If spawn fails, archive `_deploy/` and exit.

The `--cwd "$TARGET_CWD"` flag tells `spawn.sh` to launch the trooper TUI
inside `$TARGET_CWD` (via `tmux split-window -c`). For single-repo deploys
this is the conductor's cwd; for hub deploys with a `Target Sub-Project`
header it is the sub-repo path resolved by `deploy-init.sh`.

### Step 1 — Run trooper turn (round-aware, auto-retry-once)

Set task `1` → `in_progress`. Use the same task across rounds; only the
activeForm reflects the round number (e.g. `Cody running turn (round 2)`).

Initialize (only on first entry, NOT on retry):

```
ROUND=1
RETRY_COUNT=0
MAX_ROUNDS="${MAX_ROUNDS_OVERRIDE:-5}"
```

**Dispatch:**

```
"$CLAUDE_PLUGIN_ROOT/bin/deploy-turn-send.sh" "$TOPIC" "$ROUND"
```

If round 1, the script generates the round-1 prompt (plan + implement +
self-verify in one turn). If round >= 2, the script reads
`$ART_DIR/fix-prompt-$ROUND.md` (which Step 3 wrote on the previous round)
and wraps it with the fix-round preamble. **Yoda authors fix-prompt-$ROUND.md
in Step 3 BEFORE incrementing ROUND and re-entering Step 1.**

**Wait (background — Yoda's pane stays interactive):**

```
Bash(
  command='"$CLAUDE_PLUGIN_ROOT/bin/deploy-turn-wait.sh" "$TOPIC" "$ROUND"',
  run_in_background: true,
  description="master yoda await cody round=$ROUND turn (background)"
)
```

Default timeout is 4 hours (`CW_DEPLOY_TURN_TIMEOUT=14400`). Override
with the env var if your topic is unusually large.

**On harness completion notification:**

Read `TS=` from `$ART_DIR/turn-cody-$ROUND.txt`:

```
TS=$(grep '^TS=' "$ART_DIR/turn-cody-$ROUND.txt" | tail -1 | cut -d= -f2)
```

Branch on TS:

- `TS=ok` → set task `1` → `completed` for this round; jump to Step 2.
- `TS=failed` or `TS=timeout` → auto-retry path:

  ```
  if (( RETRY_COUNT == 0 )); then
    log "auto-retry round=$ROUND attempt=2"
    rm -f "$ART_DIR/turn-cody-$ROUND.txt" "$ART_DIR/turn-cody-$ROUND.done"
    rm -f "$ART_DIR/cody_turn_prompt_$ROUND.md"
    RETRY_COUNT=1
    # re-dispatch turn-send + turn-wait (loop back to top of Step 1)
  else
    # Two attempts failed.
    AskUserQuestion (Hand-off / Abort / Try-again).
    Hand-off: write $ART_DIR/RESUME.md with topic dir + branch + last
      cross-verify summary; preserve cody pane (do NOT teardown); exit.
    Abort: bin/deploy-teardown.sh + bin/deploy-archive.sh; exit.
    Try-again: RETRY_COUNT=0; loop back to top of Step 1.
  fi
  ```

  **Trooper-not-idle case on retry.** `bin/deploy-turn-send.sh` reads
  `cody-$PROVIDER/status.json` and refuses with `trooper not idle (state=...)`
  when the previous turn never reset to idle (most common after
  `TS=timeout` — the trooper is still mid-work). On that error,
  AskUserQuestion (Wait 60s and retry / Force-retry / Abort):
  - *Wait 60s and retry* — sleep 60, re-attempt `deploy-turn-send.sh`
    (do NOT clear state files first; the previous attempt already cleared
    them).
  - *Force-retry* — write `{"state":"idle","updated":"<iso>","last_event":"force-reset"}`
    to `cody-$PROVIDER/status.json` (atomic tmp+rename), then re-attempt
    `deploy-turn-send.sh`. The trooper's next inbox.md write will overlap
    its previous read but the END_OF_INSTRUCTION sentinel keeps the new
    payload safe.
  - *Abort* — `bin/deploy-teardown.sh` + `bin/deploy-archive.sh`; exit.

### Step 2 — Cross-verify (per round)

Set task `2` → `in_progress`.

**Skill:** invoke `superpowers:verification-before-completion`.

Yoda's reads (capped):
- `$ART_DIR/verify-report-$ROUND.md`
- `$ART_DIR/test-output-$ROUND.log` (grep tail for pass/fail counts)
- `git -C "$TARGET_CWD" log --oneline "$BRANCH_BASE"..HEAD`
- `git -C "$TARGET_CWD" diff --stat "$BRANCH_BASE"..HEAD`
- Up to 3 spot-checks: pick the highest-stakes diff hunk per critical
  requirement and Read just that hunk. File paths reported by
  `git -C "$TARGET_CWD" diff` are RELATIVE to `$TARGET_CWD`; the Read tool
  needs absolute paths, so prefix with `$TARGET_CWD/<path>` (e.g.
  `$TARGET_CWD/lib/foo.sh`).

(`$BRANCH_BASE` was captured into `$ART_DIR/branch-base.sha` in Step 0,
and `$TARGET_CWD` was loaded alongside it from `$ART_DIR/target_cwd.txt`.)

Write the verdict to `$ART_DIR/cross-verify-$ROUND.md`:
- Top-line `VERDICT: PASS` or `VERDICT: FAIL`.
- If FAIL: bullet list of issues, each tagged `[bug]`, `[regression]`, or
  `[spec-gap]`, with (a) requirement reference, (b) evidence (file:line or
  commit), (c) suggested fix direction.

If `VERDICT: PASS` → set task `2` → `completed`, exit the loop, jump to
Step 4.

If `VERDICT: FAIL` and `ROUND > MAX_ROUNDS`:
- Write `$ART_DIR/RESUME.md` with the topic dir, branch name, latest
  cross-verify summary, and instructions for manual takeover.
- AskUserQuestion: "5 fix rounds exhausted. Continue (1 more round) /
  Hand off (preserve state) / Abort (teardown + archive)." Default: hand off.
- Hand off: log the topic dir + RESUME.md path, exit (do not teardown). Set
  task `3` → `completed` and task `4` → `completed` with note.
- Abort: teardown + archive, exit.
- Continue: increment `MAX_ROUNDS` by 1 and continue the loop.

If `VERDICT: FAIL` and `ROUND <= MAX_ROUNDS` → continue to Step 3.

### Step 3 — Author fix bundle

Set task `3` → `in_progress`.

Read `cross-verify-$ROUND.md`. For every issue listed under `## Issues`,
preserve its tag (`[bug]`, `[regression]`, `[spec-gap]`) and its
`(file:line)` evidence. Group all issues into a single fix bundle file:

```
$ART_DIR/fix-prompt-$((ROUND + 1)).md
```

The fix bundle is a markdown body — NO preamble, NO skill mention, NO
END_OF_INSTRUCTION sentinel. The turn-send script wraps it with all of
those when it dispatches. Just list the issues, one per markdown bullet,
each starting with the tag:

```markdown
- [bug] <evidence> — <suggested fix direction>
- [spec-gap] <evidence> — <suggested fix direction>
```

After writing the bundle:

```
ROUND=$((ROUND + 1))
RETRY_COUNT=0
```

Set task `3` → `completed`; loop back to Step 1.

### Step 3a — Preflight pane allocation (multi-repo)

**Active only when `$ROUTING == "multi-repo"`.**

Set task `3a` → `in_progress`.

`bin/deploy-init.sh` already invoked `bin/deploy-dag-parse.sh`
(NEW v0.20.0) to produce `_deploy/<topic>/dag-waves.txt` +
`dag-edges.txt`, and `bin/deploy-multi-init.sh` to produce
`_deploy/<topic>/troopers.txt`. Defensive check:

```
[[ -f "$ART_DIR/dag-waves.txt"  ]] || { log_error "dag-waves.txt missing — re-run deploy-init"; exit 1; }
[[ -f "$ART_DIR/dag-edges.txt"  ]] || { log_error "dag-edges.txt missing — re-run deploy-init"; exit 1; }
[[ -f "$ART_DIR/troopers.txt"   ]] || { log_error "troopers.txt missing — re-run deploy-init"; exit 1; }
```

Initialize the spawn retry counter:

```
SPAWN_RETRY_COUNT=0
```

Count troopers and run preflight:

```
N=$(wc -l < "$ART_DIR/troopers.txt")
"$CLAUDE_PLUGIN_ROOT/bin/preflight-layout.sh" --art-dir "$ART_DIR" "$TOPIC" "$N"
```

The `--art-dir` flag points preflight at the deploy art-dir
(preflight-layout.sh accepts this flag as of v0.20.0).

Load pane assignments:

```
declare -A PREFLIGHT_PANES
while IFS=$'\t' read -r cmdr pane; do
  [[ -n "$cmdr" && -n "$pane" ]] && PREFLIGHT_PANES["$cmdr"]="$pane"
done < "$ART_DIR/preflight-panes.txt"
```

Set task `3a` → `completed`.

### Step 3b — DAG wave dispatch (multi-repo)

**Active only when `$ROUTING == "multi-repo"`.**

Set task `3b` → `in_progress`.

Walk `_deploy/<topic>/dag-waves.txt` wave-by-wave. For each wave: issue
K parallel `bin/spawn.sh --target-pane <pane> --cwd <sub-repo-cwd>`
calls (one per sub-repo in the wave); send the DAG-unit prompt to
each trooper's inbox; background-await for K done events.

```
mapfile -t WAVES < "$ART_DIR/dag-waves.txt"
declare -A REPO_TO_CMDR
declare -A REPO_TO_CWD
declare -A REPO_TO_PROVIDER
while IFS=$'\t' read -r cmdr cwd provider; do
  repo=$(basename "$cwd")
  REPO_TO_CMDR["$repo"]="$cmdr"
  REPO_TO_CWD["$repo"]="$cwd"
  REPO_TO_PROVIDER["$repo"]="$provider"
done < "$ART_DIR/troopers.txt"

declare -a WAVE_GROUPS=()
current_wave=""
group_buf=""
for line in "${WAVES[@]}"; do
  IFS=$'\t' read -r wave step repo desc <<<"$line"
  if [[ "$wave" != "$current_wave" ]]; then
    [[ -n "$group_buf" ]] && WAVE_GROUPS+=( "$group_buf" )
    group_buf="$repo"
    current_wave="$wave"
  else
    group_buf="$group_buf,$repo"
  fi
done
[[ -n "$group_buf" ]] && WAVE_GROUPS+=( "$group_buf" )
```

For each wave, **issue K parallel `Bash` tool calls in a single message**
— one per repo in the wave. Each call spawns a codex (or claude) trooper
into its pre-allocated pane, pinned to its sub-repo cwd.

Canonical wave dispatch per repo:

```
"$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" "${REPO_TO_CMDR[$repo]}" "${REPO_TO_PROVIDER[$repo]}" \
  "$TOPIC" \
  --target-pane "${PREFLIGHT_PANES[${REPO_TO_CMDR[$repo]}]}" \
  --cwd "${REPO_TO_CWD[$repo]}"
```

DAG-unit inbox prompt (write via `bin/send.sh` after spawn returns ready):

```
Read /path/to/design-doc. Your sub-repo is "<slug>".

Multi-repo design docs use `### <slug>` subsection headings inside the
Architecture and Components sections — focus on the subsections matching
your slug. The DAG context (Step <N> of <total>) is in the
"## Execution DAG" section; you depend on: <upstream-slug-list>.

Run the full superpowers ceremony for your sub-repo:
1. superpowers:writing-plans — produce an implementation plan from the
   design-doc's slice for "<slug>", saved to
   docs/superpowers/plans/YYYY-MM-DD-<topic>-<slug>-plan.md
2. superpowers:subagent-driven-development — execute the plan task-by-
   task, two-stage review per task
3. superpowers:verification-before-completion — confirm tests pass,
   diff matches the plan, no half-finished work, before reporting done

Report status via outbox: emit {"event":"done"} when all tasks are
complete and verified. Emit {"event":"error", "reason":"..."} on any
unrecoverable failure.
END_OF_INSTRUCTION
```

After dispatching the wave's K spawn+send pairs, **issue K parallel
background `Bash` tool calls** for `bin/deploy-turn-wait.sh` — one per
trooper. Each runs in `run_in_background: true`; emits a notification
on completion.

Wait until ALL K notifications have arrived AND all K state files show
`TS=ok` (or terminal failure state). Then proceed to the next wave.

#### Failure handling — Stage 1 retry-once + Stage 2 partial-success (multi-repo)

After a wave's K spawns return rc tuples:

- **All K succeed** → continue to next wave. After last wave, set task
  `3b` → `completed`.

- **At least one fails AND `SPAWN_RETRY_COUNT == 0`** → **Stage 1
  retry-once**: full teardown + re-preflight + re-dispatch the entire
  wave (mirrors v0.19.0 consult Step 3b).

- **At least one fails AND `SPAWN_RETRY_COUNT == 1`** → **Stage 2
  partial-success offer**: AskUserQuestion ("M/K spawned in this wave
  after retry. Proceed degraded with N=M / Abort all?"). On "Proceed
  degraded": rewrite `_deploy/troopers.txt` to drop the failed entry +
  continue. On "Abort all": full teardown + `rm -rf "$TOPIC_DIR"` +
  exit 1.

Set task `3b` → `completed` only after ALL waves succeed.

### Step 3c — Final verification (multi-repo)

**Active only when `$ROUTING == "multi-repo"`.**

Set task `3c` → `in_progress`.

After all waves complete, the conductor (Yoda) does its own verification.
Default = cross-repo invariants only. Escalate to full check (all tests
+ Success Criteria diff review) on any of three "feels unsafe" triggers.

**Compute the unsafe signal:**

```
source "$CLAUDE_PLUGIN_ROOT/lib/deploy-dag.sh"
WAVE_COUNT=$(awk -F$'\t' '{print $1}' "$ART_DIR/dag-waves.txt" | sort -u | wc -l)
FAN_IN_REPOS=$(cw_deploy_dag_fan_in_repos "$ART_DIR/dag-edges.txt" "$ART_DIR/dag-waves.txt")
SHARED_PATHS=""
declare -A PATH_COUNT
while IFS=$'\t' read -r cmdr cwd provider; do
  branch_base=$(cat "$ART_DIR/$cmdr-branch-base.sha" 2>/dev/null) || continue
  while IFS= read -r p; do
    PATH_COUNT["$p"]=$(( ${PATH_COUNT["$p"]:-0} + 1 ))
  done < <(git -C "$cwd" diff --name-only "${branch_base}..HEAD" 2>/dev/null)
done < "$ART_DIR/troopers.txt"
for p in "${!PATH_COUNT[@]}"; do
  (( ${PATH_COUNT[$p]} >= 2 )) && SHARED_PATHS="$SHARED_PATHS $p"
done

UNSAFE=0
[[ "$WAVE_COUNT" -ge 3 ]] && { UNSAFE=1; log_warn "feels unsafe: wave count $WAVE_COUNT >= 3"; }
[[ -n "$FAN_IN_REPOS" ]]   && { UNSAFE=1; log_warn "feels unsafe: fan-in repos: $FAN_IN_REPOS"; }
[[ -n "$SHARED_PATHS" ]]   && { UNSAFE=1; log_warn "feels unsafe: shared filesystem paths: $SHARED_PATHS"; }
```

**Default verification (UNSAFE=0):** cross-repo invariants only.
Yoda reads the design-doc's `## Architecture` section and verifies
that any cross-repo interface declared there is implemented
consistently across sub-repos. If no cross-repo interfaces are
declared, default verification is a no-op.

**Escalated verification (UNSAFE=1):** run full check.
- Per sub-repo: `git -C "<cwd>" status --short` (no uncommitted leftovers)
- Per sub-repo: `bash <cwd>/tests/run.sh` if present, else `<cwd>/Makefile test` if present, else skip
- Yoda reads the design-doc's `## Success Criteria` checklist and
  evaluates each `- [ ]` bullet against the diffs

If any verification check finds a bug, proceed to Step 3d fix-loop.
If all green, set task `3c` → `completed` and proceed to Step 4.

### Step 3d — Fix-loop (multi-repo)

**Active only when `$ROUTING == "multi-repo"` AND Step 3c found bugs.**

Set task `3d` → `in_progress`.

For each bug found in Step 3c, identify the offending sub-repo. The
trooper that owns that sub-repo is still alive in its pre-allocated
pane (commander + cwd both available from `_deploy/troopers.txt`).

Initialize per-sub-repo fix-round counter:

```
declare -A FIX_ROUNDS
MAX_FIX_ROUNDS=3
```

For each (sub-repo, bug-description) pair:

1. Look up the trooper:
   ```
   CMDR=$(awk -F$'\t' -v r="$REPO" '$2 ~ ("/" r "$") { print $1 }' "$ART_DIR/troopers.txt")
   ```

2. Send a fix-prompt via the trooper's inbox:

   ```
   /clone-wars:send --from master-yoda "$CMDR" "$TOPIC" "FIX REQUEST (round ${FIX_ROUNDS[$REPO]:-1} of $MAX_FIX_ROUNDS):
   
   I detected the following issue in your sub-repo:
   
   <bug-description>
   
   Please fix it using the same superpowers ceremony (writing-plans for
   the fix → subagent-driven-development → verification-before-completion).
   Report done via outbox when verified.
   END_OF_INSTRUCTION"
   ```

3. Background-await for the trooper's done event (mirrors Step 3b's
   await pattern).

4. Re-run Step 3c's verification for THIS sub-repo. If green, mark fix
   resolved.

5. If still buggy AND `${FIX_ROUNDS[$REPO]} -lt $MAX_FIX_ROUNDS`:
   `FIX_ROUNDS[$REPO]=$(( ${FIX_ROUNDS[$REPO]:-0} + 1 ))` and loop back
   to step 2.

6. If still buggy AND `${FIX_ROUNDS[$REPO]} -ge $MAX_FIX_ROUNDS`:
   AskUserQuestion:
   - Question: "Sub-repo '$REPO' hit MAX_FIX_ROUNDS=3 fix attempts.
     Bug remains: <bug>. What now?"
   - Options:
     - `Give up on this sub-repo` — mark FAILED in `_deploy/results.txt`;
       continue verification for other sub-repos
     - `Continue more rounds` — bump `FIX_ROUNDS[$REPO]` and re-loop
     - `Escalate to different commander` — pick next available
       commander from the pool, spawn fresh trooper with same `--cwd`,
       reset `FIX_ROUNDS[$REPO]=0`

After all bugs resolved (or given up on), set task `3d` → `completed`.

### Step 4 — Teardown + archive

Set task `4` → `in_progress`.
```
"$CLAUDE_PLUGIN_ROOT/bin/deploy-teardown.sh" "$TOPIC"
"$CLAUDE_PLUGIN_ROOT/bin/deploy-archive.sh" "$TOPIC"
```

Print final summary to the user:
- Branch name (with commit count from `git -C "$TARGET_CWD" log --oneline "$BRANCH_BASE"..HEAD`).
- Final cross-verify verdict (PASS or hand-off note).
- Archive path.

Set task `4` → `completed`.

## Environment variables

- `CW_DEPLOY_TURN_TIMEOUT` (default `14400` / 4hr) — max wall time for one
  trooper turn (plan+implement+verify in round 1; fix+verify in fix
  rounds). Set to a larger value for very long-running specs; reduce
  only for testing.
- `MAX_ROUNDS_OVERRIDE` (default `5`) — fix-round ceiling before
  exhaustion AskUserQuestion fires.

The following legacy env vars are **deprecated and ignored** (medic warns
when set):
- `CW_DEPLOY_PLAN_TIMEOUT`
- `CW_DEPLOY_IMPLEMENT_TIMEOUT`
- `CW_DEPLOY_VERIFY_TIMEOUT`
- `CW_DEPLOY_FIX_TIMEOUT`

## State files (per topic)

Files written under `$ART_DIR` (= `$TOPIC_DIR/_deploy/`):

- `_deploy/target_cwd.txt` — absolute path to the trooper's working dir. Equal to the
  conductor's cwd in single-repo mode; equal to `<conductor-cwd>/<sub-repo>` when the
  design doc declares `**Target Sub-Project:** <sub-repo>`. Set by `bin/deploy-init.sh`,
  read by Step 0 + Step 1.1 + Step 2.
- `_deploy/auto_provider.txt` — what `cw_deploy_detect_provider` chose (codex/claude).
- `_deploy/provider.txt` — what was actually used (after any user override).
- `_deploy/branch-base.sha` — the commit SHA the deploy branch was created from
  (captured by Step 0; consumed by Step 2 + Step 4 as the diff range base).
- `_deploy/design.md` — the design doc init.sh copied into place.
- `_deploy/design-audit.md` — verdict from `cw_deploy_audit_doc`.
- `_deploy/turn-cody-N.txt` — per-round trooper-turn status (TS=ok/failed/timeout).
- `_deploy/verify-report-N.md` — trooper's own verification report for round N.
- `_deploy/cross-verify-N.md` — Yoda's verdict for round N (PASS / FAIL + issues).
- `_deploy/fix-prompt-N.md` — fix bundle Yoda authored for round N (Step 3 output;
  Step 1 input on the next round).
- `_deploy/RESUME.md` — written on hand-off (5 rounds exhausted or auto-retry
  abandoned); documents how to take over manually.

## Intervention patterns

### Abandoned run cleanup
If a previous run wedged (panes alive, state intact), tear down explicitly:
```
"$CLAUDE_PLUGIN_ROOT/bin/deploy-teardown.sh" <topic>
"$CLAUDE_PLUGIN_ROOT/bin/deploy-archive.sh" <topic>
```

### Manual takeover (after hand-off)
The cody pane stays alive after a 5-round hand-off. Attach:
```
tmux select-pane -t <pane_id>   # printed by spawn.sh
```
Use the cody session directly. RESUME.md in `$ART_DIR/` documents context.

### Auto-created branch survives audit-FAIL and spawn-FAIL
If the audit or spawn fails, the directive aborts and archives `_deploy/`
but the auto-created `feat/deploy-<topic>` branch is left in place. Clean up
manually if undesired (run inside the trooper's working tree — the conductor's
cwd for single-repo deploys, the sub-repo path for hub deploys):
```
git -C "$TARGET_CWD" checkout - \
  && git -C "$TARGET_CWD" branch -D feat/deploy-<topic>
```
