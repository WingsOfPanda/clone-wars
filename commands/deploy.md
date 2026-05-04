---
description: Audit a design doc, dispatch it to an auto-detected trooper (codex by default; claude on plugin repos with confirmation) for plan/implement/self-verify, then cross-verify and fix-loop until PASS or 5 rounds.
argument-hint: [<design-path>] [--no-branch] [--branch <name>] [--topic <slug>] [--max-rounds 5]
---

# /clone-wars:deploy

Run a trooper-implements / Yoda-verifies pipeline on `$ARGUMENTS`. Master Yoda
audits the design doc; spawns one persistent cody trooper (`cody-<provider>-<topic>`,
where `<provider>` is auto-detected — `claude` for plugin repos with user
confirmation, else `codex`); delegates plan + implementation + self-verification
to the trooper using superpowers skills; and cross-verifies after every trooper
self-verify pass, sending fix bundles back until PASS or 5 rounds (then
`AskUserQuestion`).

The cody pane stays attached for the entire run — `tmux select-pane` to watch.

Spec: `docs/superpowers/specs/2026-05-02-clone-wars-execute-design.md`

## Source defaulting

If `$ARGUMENTS` does not include a `.md` path, look for the most recent
consult artifact under this repo's state root (`$CLONE_WARS_HOME`).
Candidates considered, in order of preference:

1. `state/<repo-hash>/<topic>/_consult/design-doc/<YYYY-MM-DD>-<slug>-design.md`
   (produced by `/clone-wars:consult --design-doc` — full audit-passable spec
   that maps directly to deploy's audit gates)
2. `state/<repo-hash>/<topic>/_consult/synthesis.md`
   (produced by every consult run — looser shape; may not pass the audit
   without manual editing)

Prompt the user via `AskUserQuestion` to confirm whichever is most-recent.
If neither is found and no explicit path was given, refuse with a usage hint.

## Task list (TaskCreate × 6 BEFORE step 0)

| # | subject | activeForm |
|---|---|---|
| 0   | `0   Audit design doc [yoda]`              | `Auditing design doc` |
| 1.1 | `1.1 Spawn cody (auto-provider) [yoda]`    | `Spawning cody-${PROVIDER}` |
| 1   | `1   Run trooper turn (round N) [cody]`    | `Cody running turn (round N)` |
| 2   | `2   Cross-verify (round N) [yoda]`        | `Yoda cross-verifying (round N)` |
| 3   | `3   Author fix bundle (if needed) [yoda]` | `Authoring fix bundle` |
| 4   | `4   Teardown + archive [yoda]`            | `Tearing down` |

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
   apply source defaulting:
   - Find the most recent consult artifact under this repo's state root.
     Prefer a design-doc-mode spec (audit-passable) over a bare synthesis:
     ```
     source "$CLAUDE_PLUGIN_ROOT/lib/state.sh"
     REPO_HASH=$(cw_repo_hash)
     STATE_ROOT="${CLONE_WARS_HOME:-$HOME/.clone-wars}"
     CANDIDATE=$(find "$STATE_ROOT/state/$REPO_HASH" \
                   \( -path '*/_consult/design-doc/*-design.md' \
                      -o -path '*/_consult/synthesis.md' \) \
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
   # Record branch base for cross-verify diff range (used in Step 2 + Step 4).
   # init.sh creates feat/deploy-<topic> from HEAD, so HEAD right now IS the
   # commit the new branch was created from — exactly the diff base we want.
   # Do NOT use `git merge-base HEAD main` here: when invoked from a topic
   # branch that already diverged from main, merge-base returns the prior
   # branch's divergence point (over-counting unrelated commits).
   git rev-parse HEAD > "$ART_DIR/branch-base.sha"
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

Set task `0` → `completed`.

### Step 1.1 — Spawn cody-$PROVIDER

Set task `1.1` → `in_progress`.
```
PROVIDER=$(cat "$ART_DIR/provider.txt")
"$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" cody "$PROVIDER" "$TOPIC"
```
Set task `1.1` → `completed`. If spawn fails, archive `_deploy/` and exit.

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
  description='master yoda await cody round=$ROUND turn (background)'
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
- `git log --oneline "$BRANCH_BASE"..HEAD`
- `git diff --stat "$BRANCH_BASE"..HEAD`
- Up to 3 spot-checks: pick the highest-stakes diff hunk per critical
  requirement and Read just that hunk.

(`$BRANCH_BASE` was captured into `$ART_DIR/branch-base.sha` in Step 0.)

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

### Step 4 — Teardown + archive

Set task `4` → `in_progress`.
```
"$CLAUDE_PLUGIN_ROOT/bin/deploy-teardown.sh" "$TOPIC"
"$CLAUDE_PLUGIN_ROOT/bin/deploy-archive.sh" "$TOPIC"
```

Print final summary to the user:
- Branch name (with commit count from `git log --oneline "$BRANCH_BASE"..HEAD`).
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
manually if undesired:
```
git checkout - && git branch -D feat/deploy-<topic>
```
