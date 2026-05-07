---
description: Walk a design doc from a consult synthesis (or any seed) — conductor-only, no troopers spawned
argument-hint: [<seed-path-to-synthesis.md>]
allowed-tools: Bash, Write
---

# /clone-wars:spec

Walk a design doc from a consult synthesis (or any seed). Conductor-only —
no troopers spawned. Reads archived findings + verify + drilldowns and
produces `docs/clone-wars/specs/<date>-<slug>-<hash>-design.md`.

Spec: `docs/superpowers/specs/2026-05-06-consult-spec-split-design.md`

## Task list (TaskCreate × 7 BEFORE step 0)

| # | subject | activeForm |
|---|---|---|
| 0 | `0 Resolve seed [yoda]`              | `Resolving seed` |
| 1 | `1 Detect mode (single/hub) [yoda]`  | `Detecting mode` |
| 2 | `2 Walk sections [yoda]`             | `Walking sections` |
| 3 | `3 Assemble + self-review [yoda]`    | `Assembling` |
| 4 | `4 Commit [yoda]`                    | `Committing` |
| 5 | `5 User-review gate [yoda]`          | `Awaiting user review` |
| 6 | `6 Done [yoda]`                      | `Done` |

## Steps

The user's `<seed-path>` may contain shell metacharacters. Write it via the
Write tool, then invoke sub-scripts with the resolved path.

### Step 0 — Resolve seed

Set task `0` → `in_progress`.

1. If a positional `.md` path was passed, write it via Write tool to:
   ```
   ARGS_DIR="${CLONE_WARS_HOME:-$HOME/.clone-wars}/_args"
   mkdir -p "$ARGS_DIR"; echo "$ARGS_DIR/spec.txt"
   ```
   then read it back and pass as the positional arg to spec-init.sh.
   If no arg, invoke spec-init.sh with no positional.

   After the Write tool writes the seed to `$ARGS_DIR/spec.txt`, read it
   back into a shell variable and immediately clear the stale-state file
   so the next no-arg run cannot accidentally reuse it:
   ```
   ARGS_DIR="${CLONE_WARS_HOME:-$HOME/.clone-wars}/_args"
   mkdir -p "$ARGS_DIR"
   # (Write tool writes the seed to $ARGS_DIR/spec.txt)
   SEED_PATH=$(cat "$ARGS_DIR/spec.txt" 2>/dev/null || true)
   # Clear stale state immediately after read so next no-arg run doesn't reuse it.
   rm -f "$ARGS_DIR/spec.txt"
   ```

2. Resolve seed and topic:
   ```
   eval "$("$CLAUDE_PLUGIN_ROOT/bin/spec-init.sh" "${SEED_PATH:-}")"
   # Sets TOPIC=<x> and SEED=<absolute-path-to-synthesis.md> from stdout.
   ```

3. Compute REPO_HASH and topic dir paths (the consult parent of the seed):
   ```
   source "$CLAUDE_PLUGIN_ROOT/lib/state.sh"
   REPO_HASH=$(cw_repo_hash)
   STATE_ROOT=$(cw_state_root)
   # SEED is at <root>/<topic>/_consult/synthesis.md → topic-dir is two-up:
   TOPIC_DIR=$(dirname "$(dirname "$SEED")")
   CONSULT_TOPIC="$TOPIC"   # for compatibility with lifted Step 8.5 code
   ```

4. AskUserQuestion to confirm: "Use this synthesis as seed? <SEED>" Options:
   `Use this` / `Cancel`. Cancel → exit 0.

Set task `0` → `completed`.

### Step 1 — Detect mode (single-repo / hub-subrepo / super-hub)

Set task `1` → `in_progress`.

```
HUB_MODE=$(cat "$TOPIC_DIR/_consult/hub-mode.txt" 2>/dev/null || echo "single-repo")
```

Set task `1` → `completed`. Log the detected mode.

### Step 2 — Walk sections

Set task `2` → `in_progress`.

**Setup:**

```
DD_DIR="$TOPIC_DIR/_consult/design-doc"
mkdir -p "$DD_DIR"
if [[ "$HUB_MODE" == "single-repo" ]]; then
  SECTIONS=(architecture components data-flow error-handling testing)
  SECTION_TITLES=(Architecture Components "Data Flow" "Error Handling" Testing)
else
  SECTIONS=(architecture components data-flow error-handling acceptance-tests dag xrepo-deps)
  SECTION_TITLES=(Architecture Components "Data Flow" "Error Handling" \
                  "Acceptance Tests" "Execution DAG" "Cross-Repo Dependencies")
fi
mapfile -t APPROVED < <(
  source "$CLAUDE_PLUGIN_ROOT/lib/spec.sh"
  cw_spec_resume_state "$DD_DIR"
)
```

**Per-section loop** (5 iterations in single-repo mode, 7 in hub modes —
one per section):

For each `i` in `0..$((${#SECTIONS[@]}-1))`:

1. `key=${SECTIONS[$i]}; title=${SECTION_TITLES[$i]}`.
2. **Resume check.** If `$key` appears in `${APPROVED[@]}`:
   `AskUserQuestion`: "Section '$title' already approved on a prior run.
   Reuse / Redo / Skip?"
   - Reuse → continue to next `i`.
   - Redo → `rm "$DD_DIR/$key.md"`, fall through to draft loop.
   - Skip → `printf '_(skipped on resume)_\n' > "$DD_DIR/$key.md"`, next `i`.
3. **Draft loop:**
   - Yoda reads `$TOPIC_DIR/_consult/synthesis.md`,
     `$TOPIC_DIR/_consult/adjudicated.md`, both troopers'
     `findings.md` and `verify.md`. Drafts the section text inline,
     scaled to complexity.
   - Yoda presents the draft in chat (markdown formatting preserved).
   - `AskUserQuestion`:
     "Section '$title' — Approve / Revise / Skip?"
     - **Approve** →
       ```
       printf '%s\n' "<approved-draft-text>" > "$DD_DIR/$key.md"
       ```
       break draft loop, next `i`.
     - **Revise** → `AskUserQuestion`: "What should change?" (free-form).
       Fold response into draft. Re-loop to present.
     - **Skip** →
       ```
       printf '_(skipped)_\n' > "$DD_DIR/$key.md"
       ```
       break draft loop, next `i`.

Set task `2` → `completed`.

### Step 3 — Assemble + self-review

Set task `3` → `in_progress`.

**Finalize** (after all sections processed):

```
"$CLAUDE_PLUGIN_ROOT/bin/spec-assemble.sh" "$CONSULT_TOPIC"
```

The script assembles, self-reviews, and commits. Failure modes:

- **Output collision** (`docs/clone-wars/specs/<filename>` exists):
  script exits 1. Yoda asks via `AskUserQuestion`: "<path> exists.
  Overwrite (delete and rerun) / Abort?" Branch:
  - Overwrite → `rm` the file, re-invoke script.
  - Abort → leave artifacts, skip commit, fall through to Step 5.
- **Self-review found placeholders**: script's stderr lists
  `<file>:<lineno>: <line>`. Yoda parses, identifies which section
  contains the placeholder (by comparing against the assembled doc's
  section boundaries), and re-enters the per-section walk for the
  offending section ONLY. After fix, re-invoke `spec-assemble.sh`.
  Loop until clean or user aborts.
- **Hub-mode validator failed**: when `targets.txt` exists, `spec-assemble.sh`
  runs three validators sequentially before commit: `dag` → `xrepo-deps` →
  `acceptance-tests`. On failure the script exits 1 with stderr
  `validator <fn> rejected <section>.md (see stderr above)` followed by the
  validator's own `ERROR:` line(s). Yoda parses the rejected section name
  (`dag`, `xrepo-deps`, or `acceptance-tests`) and re-enters that section's
  per-section walk for revision (skip the other 6 sections). After the user
  re-approves the offending section, re-invoke `spec-assemble.sh`. Loop
  until clean or user aborts. Section-to-validator mapping:
  - `dag.md` → `## Execution DAG` walk
  - `xrepo-deps.md` → `## Cross-Repo Dependencies` walk
  - `acceptance-tests.md` → `## Acceptance Tests` walk
- **Git commit failed**: script exits 1, design.md exists uncommitted.
  Yoda surfaces the git error verbatim and asks user to resolve.

Set task `3` → `completed`.

### Step 4 — Commit

Commit happens inside `bin/spec-assemble.sh` (idempotent — re-invoked on
each retry). Set task `4` → `completed` after Step 3 returns successfully.

### Step 5 — User-review gate

Set task `5` → `in_progress`.

Verbatim from `superpowers:brainstorming` SKILL:

> "Spec written and committed to `<path>`. Please review it and let me
> know if you want to make any changes before we start writing out the
> implementation plan."

Wait for user response. If they request changes, edit the file and amend
the commit. Only proceed to Step 6 once user approves.

Set task `5` → `completed`.

### Step 6 — Done

Print final committed path. Set task `6` → `completed`.
