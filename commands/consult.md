---
description: Spawn rex+codex and cody+claude on a topic; cross-verify their findings; synthesize a final report
argument-hint: <topic — what to research>
---

# /clone-wars:consult

Run a cross-verified dual-model investigation on `$ARGUMENTS`. Master Yoda
orchestrates 13 steps via per-phase sub-scripts under `bin/`. Between every
step, Master Yoda regains control — if a trooper produces unexpected
output, Master Yoda can `cw_send` a clarifying prompt before the next
sub-script runs.

Both panes stay attached for the entire run — `tmux select-pane` to watch.

Spec: `docs/superpowers/specs/2026-04-29-clone-wars-consult-v2-design.md`

## Task list (TaskCreate × 13 BEFORE step 1)

Create the 13-task list using `TaskCreate`. Update statuses at the
boundaries below — do NOT print a markdown checklist in chat.

| # | subject | activeForm |
|---|---|---|
| 0   | `0   Stage args-file [yoda]`               | `Staging args-file` |
| 1.1 | `1.1 Spawn rex (codex) [yoda]`             | `Spawning rex` |
| 1.2 | `1.2 Spawn cody (claude) [yoda]`           | `Spawning cody` |
| 1.3 | `1.3 Research [rex/codex]`                      | `Rex researching` |
| 1.4 | `1.4 Research [cody/claude]`                    | `Cody researching` |
| 1.5 | `1.5 Diff findings [yoda]`                 | `Diffing findings` |
| 1.6 | `1.6 Cross-verify cody-only items [rex/codex]`  | `Rex verifying` |
| 1.7 | `1.7 Cross-verify rex-only items [cody/claude]` | `Cody verifying` |
| 2   | `2   Resolve PENDING items [yoda]`         | `Resolving PENDING items` |
| 3.1 | `3.1 Synthesize report [yoda]`             | `Synthesizing` |
| 3.2 | `3.2 Teardown panes [yoda]`                | `Tearing down` |
| 3.3 | `3.3 Archive _consult/ [yoda]`             | `Archiving` |
| 4   | `4   Present final synthesis [yoda]`       | `Presenting synthesis` |

## Steps

The user's `$ARGUMENTS` may contain shell metacharacters. Write it via the
Write tool, then invoke sub-scripts with the resolved topic.

### Step 0 — args-file + init + compute REPO_HASH

Set task `0` → `in_progress`.

1. Resolve args path:

   ```
   ARGS_DIR="${CLONE_WARS_HOME:-$HOME/.clone-wars}/_args"
   mkdir -p "$ARGS_DIR"; echo "$ARGS_DIR/consult.txt"
   ```

2. Write tool: `file_path` = the path printed; `content` = `$ARGUMENTS`.

3. Initialize the consult topic AND compute the repo hash once:

   ```
   source "$CLAUDE_PLUGIN_ROOT/lib/state.sh"
   REPO_HASH=$(cw_repo_hash)
   CONSULT_TOPIC=$("$CLAUDE_PLUGIN_ROOT/bin/consult-init.sh" "$(cat "$ARGS_DIR/consult.txt")")
   TOPIC_DIR="${CLONE_WARS_HOME:-$HOME/.clone-wars}/state/$REPO_HASH/$CONSULT_TOPIC"
   echo "$CONSULT_TOPIC"   # for use in subsequent steps
   ```

   `$REPO_HASH` and `$TOPIC_DIR` are reused throughout the rest of the
   directive — DO NOT inline a `$(...)` containing a literal `<repo-hash>`
   redirect anywhere (Codex Rev1 #1 — bash interprets `$(< repo-hash )` as
   `cat repo-hash`, which would shell out to read a file named
   `repo-hash`). Always use the `$REPO_HASH` variable computed above.

Set task `0` → `completed`. Set tasks `1.1` and `1.2` → `in_progress`.

### Step 1 — Parallel spawn (with rollback)

Invoke BOTH spawn calls as PARALLEL Bash tool calls in a single message.
Capture each rc.

```
"$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" rex  codex  "$CONSULT_TOPIC"   # parallel 1
"$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" cody claude "$CONSULT_TOPIC"   # parallel 2
```

#### Spawn-rollback runbook (CRITICAL — Codex finding #3)

After both parallel spawn calls return, evaluate:

- If both succeed: continue to step 1.3. Set tasks `1.1` and `1.2` →
  `completed`.
- If both fail: log "both spawns failed", `rm -rf` the `_consult/` dir,
  exit. Mark tasks `1.1` and `1.2` as `pending` (not completed).
- If exactly one succeeds (one-success/one-failure):

  ```
  # Tear down the surviving trooper, remove _consult/, exit 1.
  "$CLAUDE_PLUGIN_ROOT/bin/consult-teardown.sh" "$CONSULT_TOPIC"
  rm -rf "$TOPIC_DIR"
  ```

  Mark only the successful spawn task as `completed`; leave the failed one
  `pending`. Tell the user which side failed and why.

### Step 2 — Parallel research dispatch

Set tasks `1.3` and `1.4` → `in_progress`.

PARALLEL Bash tool calls:

```
"$CLAUDE_PLUGIN_ROOT/bin/consult-research-send.sh" "$CONSULT_TOPIC" rex  codex
"$CLAUDE_PLUGIN_ROOT/bin/consult-research-send.sh" "$CONSULT_TOPIC" cody claude
```

### Step 3 — Parallel research wait

Both calls in PARALLEL:

```
"$CLAUDE_PLUGIN_ROOT/bin/consult-research-wait.sh" "$CONSULT_TOPIC" rex  codex
"$CLAUDE_PLUGIN_ROOT/bin/consult-research-wait.sh" "$CONSULT_TOPIC" cody claude
```

After both return, read each commander's state file to determine status
(reusing `$TOPIC_DIR` from Step 0):

```
grep '^FS=' "$TOPIC_DIR/_consult/research-rex.txt"
grep '^FS=' "$TOPIC_DIR/_consult/research-cody.txt"
```

- If either is `FS=malformed` → consider Pattern 1 intervention (see
  below) before proceeding.
- If both are `FS=ok` (or `empty`/`missing` you accept) → set tasks
  `1.3` and `1.4` → `completed`.

### Step 4 — Diff

Set task `1.5` → `in_progress`.

```
"$CLAUDE_PLUGIN_ROOT/bin/consult-diff.sh" "$CONSULT_TOPIC"
```

Set task `1.5` → `completed`.

### Step 5 — Parallel verify dispatch + wait

Set tasks `1.6` and `1.7` → `in_progress`.

```
# Parallel send
"$CLAUDE_PLUGIN_ROOT/bin/consult-verify-send.sh" "$CONSULT_TOPIC" rex  codex
"$CLAUDE_PLUGIN_ROOT/bin/consult-verify-send.sh" "$CONSULT_TOPIC" cody claude

# Parallel wait
"$CLAUDE_PLUGIN_ROOT/bin/consult-verify-wait.sh" "$CONSULT_TOPIC" rex  codex
"$CLAUDE_PLUGIN_ROOT/bin/consult-verify-wait.sh" "$CONSULT_TOPIC" cody claude
```

Read `verify-{rex,cody}.txt` for VS status. If all-UNCERTAIN, consider
Pattern 3 intervention. Else set `1.6` and `1.7` → `completed`.

### Step 6 — Adjudicate (writes draft)

```
"$CLAUDE_PLUGIN_ROOT/bin/consult-adjudicate.sh" "$CONSULT_TOPIC"
```

This writes `_consult/adjudicated-draft.md`. Then copy it to the
Master Yoda's resolution surface:

```
cp "$TOPIC_DIR/_consult/adjudicated-draft.md" "$TOPIC_DIR/_consult/adjudicated.md"
```

Set task `2` → `in_progress`.

### Step 7 — Resolve PENDING items

Open `_consult/adjudicated.md` with the Read tool. For every line
beginning `- PENDING:`:

a. Note `[citation]` + claim.
b. Read the cited source (file or WebFetch URL).
c. Decide CONFIRMED / REFUTED / CONTESTED.
d. Edit tool to rewrite:
   - CONFIRMED / REFUTED: replace `- PENDING:` with the verdict + evidence.
   - CONTESTED: move under `## Contested`, drop the prefix.

When no `^- PENDING:` remains, set task `2` → `completed` and task `3.1` →
`in_progress`.

### Step 8 — Synthesize

```
"$CLAUDE_PLUGIN_ROOT/bin/consult-synthesize.sh" "$CONSULT_TOPIC"
```

Refuses if PENDING remains. On success, prints synthesis.md. Set task
`3.1` → `completed`.

### Step 9 — Teardown + archive

```
"$CLAUDE_PLUGIN_ROOT/bin/consult-teardown.sh" "$CONSULT_TOPIC"
```

Set task `3.2` → `completed`.

```
"$CLAUDE_PLUGIN_ROOT/bin/consult-archive.sh" "$CONSULT_TOPIC"
```

Set task `3.3` → `completed`. Set task `4` → `in_progress`.

### Step 10 — Present synthesis

Show the user the final synthesis (already printed by step 8). Set task
`4` → `completed`.

## Intervention patterns

### Pattern 1: Malformed findings re-prompt

If `research-<commander>.txt` shows `FS=malformed`:

```
/clone-wars:send <commander> "$CONSULT_TOPIC" "Reformat your findings —
   every claim needs a [<citation>] prefix. Write to <state-dir>/findings.md.
   END_OF_INSTRUCTION"
"$CLAUDE_PLUGIN_ROOT/bin/consult-offset-reset.sh" "$CONSULT_TOPIC" <commander> research
"$CLAUDE_PLUGIN_ROOT/bin/consult-research-send.sh" "$CONSULT_TOPIC" <commander> <model>
"$CLAUDE_PLUGIN_ROOT/bin/consult-research-wait.sh" "$CONSULT_TOPIC" <commander> <model>
"$CLAUDE_PLUGIN_ROOT/bin/consult-diff.sh" "$CONSULT_TOPIC"
```

### Pattern 3: All-UNCERTAIN verify re-prompt

If `verify-<commander>.txt` verdicts are all UNCERTAIN:

```
/clone-wars:send <commander> "$CONSULT_TOPIC" "For each UNCERTAIN item,
   read the cited source at the file:line and re-grade. Write to
   <state-dir>/verify.md. END_OF_INSTRUCTION"
"$CLAUDE_PLUGIN_ROOT/bin/consult-offset-reset.sh" "$CONSULT_TOPIC" <commander> verify
"$CLAUDE_PLUGIN_ROOT/bin/consult-verify-send.sh" "$CONSULT_TOPIC" <commander> <model>
"$CLAUDE_PLUGIN_ROOT/bin/consult-verify-wait.sh" "$CONSULT_TOPIC" <commander> <model>
"$CLAUDE_PLUGIN_ROOT/bin/consult-adjudicate.sh" "$CONSULT_TOPIC"
cp "$TOPIC_DIR/_consult/adjudicated-draft.md" "$TOPIC_DIR/_consult/adjudicated.md"
# (or manually merge the new draft into adjudicated.md if you want to
# preserve specific prior PENDING resolutions — see spec Pattern 3.)
```
