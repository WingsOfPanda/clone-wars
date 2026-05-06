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
| 3.1.5 | `3.1.5 Design-doc walk (optional) [yoda]` | `Walking design-doc sections` |
| 3.2 | `3.2 Teardown panes [yoda]`                | `Tearing down` |
| 3.3 | `3.3 Archive _consult/ [yoda]`             | `Archiving` |
| 4   | `4   Present final synthesis [yoda]`       | `Presenting synthesis` |

## Steps

The user's `$ARGUMENTS` may contain shell metacharacters. Write it via the
Write tool, then invoke sub-scripts with the resolved topic.

### Step 0 — args-file + init + compute REPO_HASH

Set task `0` → `in_progress`.

**Token-aware `--design-doc` flag parsing (BEFORE init):**

Use `cw_consult_parse_design_doc_flag` to remove ONLY exact `--design-doc`
tokens (not substrings like `--design-documentation` or
`--design-doc-please`).

```
source "$CLAUDE_PLUGIN_ROOT/lib/consult.sh"
PARSE=$(cw_consult_parse_design_doc_flag "$ARGUMENTS")
DESIGN_DOC="${PARSE%%	*}"
ARG_RAW="${PARSE#*	}"
```

Use `$ARG_RAW` (not `$ARGUMENTS`) for the topic text from this point.
Persist `$DESIGN_DOC` for Step 8.5.

1. Resolve args path:

   ```
   ARGS_DIR="${CLONE_WARS_HOME:-$HOME/.clone-wars}/_args"
   mkdir -p "$ARGS_DIR"; echo "$ARGS_DIR/consult.txt"
   ```

2. Write tool: `file_path` = the path printed; `content` = `$ARG_RAW`.

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
   redirect anywhere (bash interprets `$(< repo-hash )` as `cat repo-hash`,
   which would shell out to read a file named `repo-hash`). Always use the
   `$REPO_HASH` variable computed above.

Set task `0` → `completed`. Set tasks `1.1` and `1.2` → `in_progress`.

### Step 0.5 — Hub-mode classification

After `consult-init.sh` returns `$CONSULT_TOPIC`, the init script has already
persisted `_consult/hub-mode.txt`. Read it back and surface to the rest of
the directive:

```
HUB_MODE=$(cw_consult_hub_mode_load "$TOPIC_DIR/_consult")
log_info "hub mode: $HUB_MODE"
```

When `HUB_MODE != single-repo`, Step 1.5 (below) runs target selection
before research dispatch. When `HUB_MODE == single-repo`, the directive
proceeds to Step 1 unchanged from v0.10.

### Step 1.5 — Target selection (hub mode only)

Skip this step when `HUB_MODE == single-repo`. Otherwise the conductor
must let the user pick which leaf sub-projects this consultation should
cover, BEFORE research dispatch (the research prompt needs the list).

1. Re-run the detector to grab `LEAVES=` (and `HUBS=` for super-hub):

   ```
   HUB_OUT=$(cw_consult_detect_hub "$(pwd)")
   LEAVES=$(grep '^LEAVES=' <<< "$HUB_OUT" | cut -d= -f2 | tr ',' '\n')
   LEAVES_CSV=$(grep '^LEAVES=' <<< "$HUB_OUT" | cut -d= -f2)
   HUBS=$(grep '^HUBS='   <<< "$HUB_OUT" | cut -d= -f2 | tr ',' '\n' || true)
   ```

   **v0.11.1 auto-extract prelude** (runs BEFORE the legacy hub-subrepo /
   super-hub picker below). Parse the user's topic text for sub-project
   mentions; if any are inferred, offer a single confirm-or-edit gate
   instead of forcing the full picker:

   ```
   EXTRACT=$(cw_consult_extract_targets_from_topic "$ARG_RAW" "$LEAVES_CSV") && EX_RC=0 || EX_RC=$?
   INFERRED=$(grep '^INFERRED=' <<< "$EXTRACT" | cut -d= -f2)
   KEYWORD_ALL=$(grep '^KEYWORD_ALL=' <<< "$EXTRACT" | cut -d= -f2 || echo 0)
   ```

   Branch on `(EX_RC, KEYWORD_ALL)`:

   - **(0, 1) — KEYWORD_ALL hit:** `AskUserQuestion` with question
     `"All leaves auto-selected (KEYWORD_ALL keyword in topic). Continue
     or Edit selection?"` and options `[Continue: $LEAVES_CSV,
     Edit selection (open picker)]`. On **Continue**: set
     `CHOSEN_LEAVES=$LEAVES_CSV` and skip directly to the persist step
     (item 5). On **Edit selection**: fall through to the legacy picker
     (items 2-3 below).
   - **(0, 0) — Inferred ≥1 leaf:** `AskUserQuestion` with question
     `"Inferred targets from your topic: $INFERRED. Confirm or edit?"`
     and options `[Confirm: $INFERRED, Edit selection (open picker),
     Abort]`. On **Confirm**: set `CHOSEN_LEAVES=$INFERRED` and skip to
     persist (item 5). On **Edit selection**: fall through to the
     legacy picker (items 2-3). On **Abort**: teardown + archive + exit.
   - **(1, *) — No inference:** fall through to the legacy hub-subrepo /
     super-hub picker below (existing behavior unchanged).

2. **hub-subrepo mode:** single `AskUserQuestion` (multi-select), options =
   `LEAVES` (one option per `<self>/<leaf>`).

3. **super-hub mode:** two-step.
   - `AskUserQuestion` #1 (multi-select) over `HUBS`.
   - For each chosen hub, filter `LEAVES` to entries starting `<hub>/`.
   - `AskUserQuestion` #2 (multi-select) over the filtered leaf list.

4. **Empty-selection re-prompt:** if user selects nothing, re-prompt once.
   Second empty selection → `AskUserQuestion`: "No targets chosen. Continue
   as single-repo / Abort?". On Continue, overwrite `_consult/hub-mode.txt`
   with `single-repo` (re-export `HUB_MODE=single-repo` in this shell so
   downstream Step 8.5 picks it up) and skip persisting `targets.txt`. On
   Abort, teardown + archive + exit.

5. Persist the chosen targets via `cw_consult_targets_persist`. When
   `CHOSEN_LEAVES` is a bash array (legacy picker path):

   ```
   printf '%s\n' "${CHOSEN_LEAVES[@]}" \
     | cw_consult_targets_persist "$TOPIC_DIR/_consult"
   ```

   When `CHOSEN_LEAVES` is a comma-separated string (v0.11.1 prelude
   confirm path):

   ```
   printf '%s\n' "${CHOSEN_LEAVES//,/$'\n'}" \
     | cw_consult_targets_persist "$TOPIC_DIR/_consult"
   ```

### Step 1 — Parallel spawn (with auto-retry-once + rollback)

Initialize ONCE before invoking the parallel spawn calls:

```
SPAWN_RETRY_COUNT=0
```

Invoke BOTH spawn calls as PARALLEL Bash tool calls in a single message.
Capture each rc.

```
"$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" rex  codex  "$CONSULT_TOPIC"   # parallel 1
"$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" cody claude "$CONSULT_TOPIC"   # parallel 2
```

#### Spawn-rollback runbook (CRITICAL)

After both parallel spawn calls return, evaluate the rc pair. **The runbook
supports ONE automatic retry** because codex's first cold-start can blow the
spawn.sh budget (node-modules load + auth handshake); subsequent invocations
are warm and almost always succeed. The retry path costs ~30s in the rare
failure case and is invisible on the happy path.

- **Both succeed** → continue to Step 2. Set tasks `1.1` and `1.2` →
  `completed`.

- **At least one fails AND `SPAWN_RETRY_COUNT == 0`** → **auto-retry-once**:

  ```
  # Tear down any surviving pane(s), KEEP _consult/ for the retry.
  "$CLAUDE_PLUGIN_ROOT/bin/consult-teardown.sh" "$CONSULT_TOPIC" 2>/dev/null || true
  SPAWN_RETRY_COUNT=1
  log_info "spawn failed (cold start?); retrying parallel spawn once"
  ```

  Then re-issue the parallel spawn calls (back to the parallel block above).
  By this point codex's runtime is warm; second attempt almost always succeeds.

- **At least one fails AND `SPAWN_RETRY_COUNT == 1`** → **retry exhausted**:

  ```
  "$CLAUDE_PLUGIN_ROOT/bin/consult-teardown.sh" "$CONSULT_TOPIC" 2>/dev/null || true
  rm -rf "$TOPIC_DIR"
  exit 1
  ```

  Mark only any successful spawn task as `completed`; leave failed one(s)
  `pending`. Tell the user which side failed twice and why (capture stderr
  from both attempts for diagnostics — typically codex bootstrap timeout or
  binary-not-found).

### Step 2 — Parallel research dispatch

Set tasks `1.3` and `1.4` → `in_progress`.

Hub-mode threading: when `_consult/targets.txt` exists, pass the comma-list
to research-send via `CW_CONSULT_TARGETS=` env so the prompt builder emits
the per-sub-project structure block. Single-repo runs leave `TARGETS=""`
(builder strips the block).

PARALLEL Bash tool calls:

```
TARGETS=""
if [[ -s "$TOPIC_DIR/_consult/targets.txt" ]]; then
  TARGETS=$(cw_consult_targets_load "$TOPIC_DIR/_consult" | paste -sd, -)
fi
CW_CONSULT_TARGETS="$TARGETS" \
  "$CLAUDE_PLUGIN_ROOT/bin/consult-research-send.sh" "$CONSULT_TOPIC" rex  codex
CW_CONSULT_TARGETS="$TARGETS" \
  "$CLAUDE_PLUGIN_ROOT/bin/consult-research-send.sh" "$CONSULT_TOPIC" cody claude
```

### Step 3 — Parallel research wait (with question loop)

Background-await protocol: wait-scripts run as background tasks so Master
Yoda's pane stays interactive while troopers work. Each wait-script writes
`FS=<state>` to its per-commander state file before exit and touches a
`.done` sentinel; the controller reads both on the harness's completion
notification.

Dispatch BOTH waits as parallel background Bash calls:

```
Bash(
  command='"$CLAUDE_PLUGIN_ROOT/bin/consult-research-wait.sh" "$CONSULT_TOPIC" rex  codex',
  run_in_background: true,
  description='master yoda await captain rex research (background)'
)

Bash(
  command='"$CLAUDE_PLUGIN_ROOT/bin/consult-research-wait.sh" "$CONSULT_TOPIC" cody claude',
  run_in_background: true,
  description='master yoda await commander cody research (background)'
)
```

While the background tasks run, **Yoda's pane remains free** — the user can
chat, run `/clone-wars:list`, or interrupt with new instructions. You will
receive one harness completion notification per task.

On EACH notification, do:

1. Identify which commander finished (the bash task description names them).
2. Read the per-commander state file:
   ```
   STATE_FILE="$TOPIC_DIR/_consult/research-<commander>.txt"
   DONE_SENTINEL="${STATE_FILE%.txt}.done"
   ```
3. If `$DONE_SENTINEL` is missing, treat it as `FS=failed` (the wait-script
   crashed before writing terminal state). Surface the error to the user
   and consider Pattern 1 (re-prompt) before proceeding.
4. Otherwise, parse the last `FS=` line:
   ```
   FS=$(grep '^FS=' "$STATE_FILE" | tail -1 | cut -d= -f2)
   ```

For each commander whose `FS=question`:

a. Read the question payload — `_consult/question-<commander>.txt`. Use
   the Read tool, parse `TEXT=` and `OPTIONS=`. Decode any `%xx` you see.
b. Read `$TOPIC_DIR/<commander>-<model>/findings.md` (if it exists) for
   findings-so-far context.

   **v0.11.1 active-subproject context (hub mode only):**

   When `HUB_MODE != single-repo`, scope the answer-classification context
   to the trooper's currently-active sub-project before classifying:

   ```
   FINDINGS_PATH="$TOPIC_DIR/<commander>-<model>/findings.md"
   if [[ "$HUB_MODE" != "single-repo" ]]; then
     ACTIVE_SP=$(cw_consult_findings_active_subproject "$FINDINGS_PATH") || ACTIVE_SP=""
     if [[ -n "$ACTIVE_SP" ]]; then
       log_info "active sub-project for question: $ACTIVE_SP"
       CONTEXT_SLICE=$(awk -v leaf="$ACTIVE_SP" '
         /^### / && $0 ~ leaf { in_block=1; print; next }
         /^### / && in_block { in_block=0 }
         in_block { print }
       ' "$FINDINGS_PATH")
     else
       CONTEXT_SLICE=$(cat "$FINDINGS_PATH")
     fi
   else
     CONTEXT_SLICE=$(cat "$FINDINGS_PATH")
   fi
   ```

   Pass `$CONTEXT_SLICE` (NOT the full findings.md) into the
   answer-classification step that follows.
c. Classify as critical / non-critical (same rules as Pattern 4 below)
   using `$CONTEXT_SLICE` (active sub-project slice in hub mode, full
   findings otherwise).
d. Get an answer:
   - critical → `AskUserQuestion` with TEXT + OPTIONS.
   - non-critical → answer from topic + `$CONTEXT_SLICE` yourself.
e. Send the answer:
   ```
   /clone-wars:send --from master-yoda <commander> "$CONSULT_TOPIC" "ANSWER: <your answer>

   (end of question response — resume your skill loop)
   END_OF_INSTRUCTION"
   ```
f. **Re-arm by removing the `.done` sentinel and re-running the wait-script
   in BACKGROUND.** Do NOT call `consult-research-send.sh` and do NOT run
   the wait-script in foreground:
   ```
   rm -f "$DONE_SENTINEL"
   Bash(
     command='"$CLAUDE_PLUGIN_ROOT/bin/consult-research-wait.sh" "$CONSULT_TOPIC" <commander> <model>',
     run_in_background: true,
     description='master yoda await <commander> research re-arm (background)'
   )
   ```
   The new task will fire its own completion notification.

Continue handling notifications until both commanders' state files show
`FS ∈ {ok, empty, missing, failed, timeout, malformed}`. `FS=question` is a
transient state — only proceed to Step 4 when both have a terminal value.

- `ok` / `empty` / `missing` → set tasks `1.3` and `1.4` → `completed`.
- `failed` / `timeout` / `malformed` → consider Pattern 1 (re-prompt)
  before proceeding; set tasks → `completed` if accepting the degraded
  result.

### Step 4 — Diff

Set task `1.5` → `in_progress`.

```
"$CLAUDE_PLUGIN_ROOT/bin/consult-diff.sh" "$CONSULT_TOPIC"
```

Set task `1.5` → `completed`.

### Step 5 — Parallel verify dispatch + wait (with question loop)

Set tasks `1.6` and `1.7` → `in_progress`.

Send phase — keep parallel sends as foreground (sends complete in <1s).
Hub-mode threading mirrors Step 2: `CW_CONSULT_TARGETS=` env carries the
comma-list into verify-send so the verify prompt also embeds the
per-sub-project structure block.

```
TARGETS=""
if [[ -s "$TOPIC_DIR/_consult/targets.txt" ]]; then
  TARGETS=$(cw_consult_targets_load "$TOPIC_DIR/_consult" | paste -sd, -)
fi
CW_CONSULT_TARGETS="$TARGETS" \
  "$CLAUDE_PLUGIN_ROOT/bin/consult-verify-send.sh" "$CONSULT_TOPIC" rex  codex
CW_CONSULT_TARGETS="$TARGETS" \
  "$CLAUDE_PLUGIN_ROOT/bin/consult-verify-send.sh" "$CONSULT_TOPIC" cody claude
```

Wait phase — both wait-scripts run as background tasks (Yoda stays
interactive):

```
Bash(
  command='"$CLAUDE_PLUGIN_ROOT/bin/consult-verify-wait.sh" "$CONSULT_TOPIC" rex  codex',
  run_in_background: true,
  description='master yoda await captain rex verify (background)'
)

Bash(
  command='"$CLAUDE_PLUGIN_ROOT/bin/consult-verify-wait.sh" "$CONSULT_TOPIC" cody claude',
  run_in_background: true,
  description='master yoda await commander cody verify (background)'
)
```

On EACH completion notification, read the per-commander verify state file:

```
STATE_FILE="$TOPIC_DIR/_consult/verify-<commander>.txt"
DONE_SENTINEL="${STATE_FILE%.txt}.done"
```

Same 4-step parse as Step 3 (sentinel check + grep `^VS=`). Note that
verify uses `VS=` (not `FS=` — that's research). The verify phase's
question-loop semantics match Step 3's exactly — see Pattern 4 (updated
below) for the re-arm recipe.

For each commander whose `VS=question`, apply the **v0.11.1
active-subproject context (hub mode only)** recipe before classifying.
The verify phase's findings-so-far context source is the trooper's
`verify.md` (not `findings.md`); the slice logic is otherwise identical
to Step 3:

```
FINDINGS_PATH="$TOPIC_DIR/<commander>-<model>/verify.md"
if [[ "$HUB_MODE" != "single-repo" ]]; then
  ACTIVE_SP=$(cw_consult_findings_active_subproject "$FINDINGS_PATH") || ACTIVE_SP=""
  if [[ -n "$ACTIVE_SP" ]]; then
    log_info "active sub-project for verify question: $ACTIVE_SP"
    CONTEXT_SLICE=$(awk -v leaf="$ACTIVE_SP" '
      /^### / && $0 ~ leaf { in_block=1; print; next }
      /^### / && in_block { in_block=0 }
      in_block { print }
    ' "$FINDINGS_PATH")
  else
    CONTEXT_SLICE=$(cat "$FINDINGS_PATH")
  fi
else
  CONTEXT_SLICE=$(cat "$FINDINGS_PATH")
fi
```

Pass `$CONTEXT_SLICE` (NOT the full verify.md) into the
answer-classification prompt before invoking Pattern 4's relay.

If all-UNCERTAIN, consider Pattern 3 intervention. Else set `1.6` and
`1.7` → `completed`.

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

### Step 8.5 — Design-doc walk (optional)

**Entry conditions** (classifier is not the strict gate):

1. **Explicit flag.** `$DESIGN_DOC=1` → enter Step 8.5 with no prompt.
2. **Skip path.** Classifier returned `systematic-debugging` (clear non-design
   intent — auditing/triage). Skip Step 8.5 entirely.
3. **Default — always offer.** For `brainstorming` OR `none`, Yoda calls
   `AskUserQuestion`:

   > "Want me to walk through a design doc (Architecture / Components /
   > Data flow / Error handling / Testing) and write it to
   > `docs/clone-wars/specs/YYYY-MM-DD-<slug>-<hash>-design.md`?"
   > Options: `Yes — walk through design doc` / `No — synthesis is enough`.

   Yes sets `DESIGN_DOC=1`; No falls through to Step 9.

```
SKILL_TXT=$(cat "$TOPIC_DIR/_consult/skill.txt" 2>/dev/null || echo "none")
if [[ "$DESIGN_DOC" == "1" ]]; then
  : # explicit flag wins
elif [[ "$SKILL_TXT" == "systematic-debugging" ]]; then
  DESIGN_DOC=0  # skip — non-design intent
else
  # AskUserQuestion → set DESIGN_DOC based on user response
  :
fi
```

If `DESIGN_DOC=0` after the gate, skip to Step 9.

Set task `3.1.5` → `in_progress`.

**Hub-mode wiring (v0.11).** `HUB_MODE` is already loaded from
`_consult/hub-mode.txt` at Step 0.5. When `HUB_MODE != single-repo`, the
chosen leaf list lives in `_consult/targets.txt` (Step 1.5 persisted it).
The design-doc bin script (`bin/consult-design-doc.sh`) reads the
targets-dir directly to insert the `**Target Hub(s):**` /
`**Target Sub-Project(s):**` header pair into the assembled spec — no
`CW_CONSULT_TARGET_HEADER` env var needed.

For backward compatibility with v0.10 single-sub-repo flows, when
`HUB_MODE == single-repo` and the conductor's cwd happens to look like a
hub-subrepo repo, you MAY still ask which sub-project will implement and
export `CW_CONSULT_TARGET_HEADER="**Target Sub-Project:** <name>"`. v0.11
hub-mode runs ignore that env var (targets.txt wins).

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
  source "$CLAUDE_PLUGIN_ROOT/lib/consult.sh"
  cw_consult_design_doc_resume_state "$DD_DIR"
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
     "Section '$title' — Approve / Revise / Drill deeper / Skip?"
     - **Approve** →
       ```
       printf '%s\n' "<approved-draft-text>" > "$DD_DIR/$key.md"
       ```
       break draft loop, next `i`.
     - **Revise** → `AskUserQuestion`: "What should change?" (free-form).
       Fold response into draft. Re-loop to present.
     - **Drill deeper** → enter drill-down sub-loop (below). Fold
       drilldown content into draft. Re-loop to present.
     - **Skip** →
       ```
       printf '_(skipped)_\n' > "$DD_DIR/$key.md"
       ```
       break draft loop, next `i`.

**Drill-down sub-loop:**

Drill-down dispatch + await is delegated to `bin/consult-drilldown.sh` to
avoid the slash-command renderer's positional-arg substitution clobbering
inline bash function args (`$1` etc.) on multi-word topics. The bin script
handles 1- or 2-trooper drilldown in parallel and writes outputs to
`<dd-dir>/_scratch/drilldown-<section-slug>-<commander>.md` (the `_scratch/`
subdir keeps trooper outputs out of the user-facing design-doc directory,
which contains only the final assembled spec).

```
# AskUserQuestion: "Which trooper to drill into '<TITLE>'?"
#   Base options: rex (codex) / cody (claude) / both (parallel)
#   In hub mode (HUB_MODE != single-repo), expand the option list with a
#   per-sub-project axis so the user can scope a drill to one leaf:
TROOPER_OPTIONS=("rex (codex)" "cody (claude)" "both (parallel)")
if [[ "$HUB_MODE" != "single-repo" ]]; then
  while IFS= read -r leaf; do
    SP="${leaf#*/}"
    TROOPER_OPTIONS+=("rex on $SP" "cody on $SP" "both on $SP")
  done < "$TOPIC_DIR/_consult/targets.txt"
fi
TROOPER_CHOICE=<chosen from $TROOPER_OPTIONS>

# AskUserQuestion: "What's the focus? (e.g., 'trade-offs feel hand-wavy')"
FOCUS=<free-form>
```

Then invoke the drill script. The optional 6th positional arg is
`<subproject>` — pass it through ONLY when the user chose a per-sub-project
option (parse `SP` out of the option label). Single-trooper, no sub-project:

```
"$CLAUDE_PLUGIN_ROOT/bin/consult-drilldown.sh" \
  "$CONSULT_TOPIC" "<TITLE>" "$DD_DIR" "<FOCUS>" \
  rex codex                  # OR: cody claude
```

Both troopers (parallel), no sub-project:

```
"$CLAUDE_PLUGIN_ROOT/bin/consult-drilldown.sh" \
  "$CONSULT_TOPIC" "<TITLE>" "$DD_DIR" "<FOCUS>" \
  rex codex cody claude
```

Single-trooper, per-sub-project (`rex on $SP`):

```
"$CLAUDE_PLUGIN_ROOT/bin/consult-drilldown.sh" \
  "$CONSULT_TOPIC" "<TITLE>" "$DD_DIR" "<FOCUS>" \
  rex codex "$SP"
```

Both troopers (parallel) per-sub-project — the bin script accepts the
sub-project as the LAST positional after the second commander/model pair
(see `bin/consult-drilldown.sh` for the canonical arg-count rules).

Script emits `[drilldown] $commander: wrote …` per success, and exits:
- `rc=0` if at least one trooper produced a non-empty drilldown file
- `rc=1` if all troopers timed out / errored / produced empty files
- `rc=2` on bad args

After the script returns, Yoda reads the produced files (one or two of
`_scratch/drilldown-<section-slug>-rex.md` and
`_scratch/drilldown-<section-slug>-cody.md`) and folds the content into the
in-progress section draft, attributing each finding by commander when `both`
was used.

If `rc=1` (all drilldowns failed/empty), `AskUserQuestion`:
"Drill-down on '<TITLE>' returned nothing usable. Retry / Other trooper /
Skip drill / Continue with current draft?"

For unknown `TROOPER_CHOICE` values, re-prompt the AskUserQuestion above;
do not invoke the script with stale args.

**Finalize** (after all 5 sections processed):

```
"$CLAUDE_PLUGIN_ROOT/bin/consult-design-doc.sh" "$CONSULT_TOPIC"
```

The script assembles, self-reviews, and commits. Failure modes:

- **Output collision** (`docs/clone-wars/specs/<filename>` exists):
  script exits 1. Yoda asks via `AskUserQuestion`: "<path> exists.
  Overwrite (delete and rerun) / Append `-2` suffix / Abort?" Branch:
  - Overwrite → `rm` the file, re-invoke script.
  - Suffix → `mv` the assembled file (after re-run with patched
    helper, or use a manual `cp $DD_DIR + assemble + commit`); for v1
    keep it simple: re-run with `CW_TEST_DATE` containing a `-2` suffix
    workaround is NOT supported — instruct user to clean up manually.
  - Abort → leave artifacts, skip commit, fall through to Step 9.
- **Self-review found placeholders**: script's stderr lists
  `<file>:<lineno>: <line>`. Yoda parses, identifies which section
  contains the placeholder (by comparing against the assembled doc's
  section boundaries), and re-enters the per-section walk for the
  offending section ONLY. After fix, re-invoke `consult-design-doc.sh`.
  Loop until clean or user aborts.
- **Hub-mode validator failed**: when `targets.txt` exists, `consult-design-doc.sh`
  runs three validators sequentially before commit: `dag` → `xrepo-deps` →
  `acceptance-tests`. On failure the script exits 1 with stderr
  `validator <fn> rejected <section>.md (see stderr above)` followed by the
  validator's own `ERROR:` line(s). Yoda parses the rejected section name
  (`dag`, `xrepo-deps`, or `acceptance-tests`) and re-enters that section's
  per-section walk for revision (skip the other 7 sections). After the user
  re-approves the offending section, re-invoke `consult-design-doc.sh`. Loop
  until clean or user aborts. Section-to-validator mapping:
  - `dag.md` → `## Execution DAG` walk
  - `xrepo-deps.md` → `## Cross-Repo Dependencies` walk
  - `acceptance-tests.md` → `## Acceptance Tests` walk
- **Git commit failed**: script exits 1, design.md exists uncommitted.
  Yoda surfaces the git error verbatim and asks user to resolve.

**Tear down troopers BEFORE the user-review gate.**

Gate-then-teardown would keep two model TTYs idle through unbounded review
pauses with no keepalive or recovery path. After the design.md commits,
run teardown + archive immediately, THEN open the user-review gate. The
trade-off is that post-gate edits cannot drill troopers (they're gone) —
acceptable because drill-deeper is a during-walk affordance, not a
post-commit one. After commit, edits are git-tracked manual changes.

```
"$CLAUDE_PLUGIN_ROOT/bin/consult-teardown.sh" "$CONSULT_TOPIC"
"$CLAUDE_PLUGIN_ROOT/bin/consult-archive.sh"  "$CONSULT_TOPIC"
```

Set tasks `3.2` and `3.3` → `completed` (teardown + archive happened here,
not in Step 9 below — Step 9 becomes a no-op when Step 8.5 entered).

**User-review gate** (verbatim from `superpowers:brainstorming` SKILL):

> "Spec written and committed to `<path>`. Please review it and let me
> know if you want to make any changes before we start writing out the
> implementation plan."

Wait for user response. If they request changes, edit the file and amend
the commit (panes are already gone — manual edit only). Only proceed to
Step 10 (present) once user approves.

Set task `3.1.5` → `completed`.

### Step 9 — Teardown + archive

If Step 8.5 ran, teardown + archive already happened before the user-review
gate. Skip this step. Otherwise (no design-doc walk):

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

> The wait-script runs in background; read state file + `.done` sentinel
> from the controller's notification handler (see Step 3).

If `research-<commander>.txt` shows `FS=malformed`:

```
/clone-wars:send <commander> "$CONSULT_TOPIC" "Reformat your findings —
   every claim needs a [<citation>] prefix. Write to <state-dir>/findings.md.
   END_OF_INSTRUCTION"
"$CLAUDE_PLUGIN_ROOT/bin/consult-offset-reset.sh" "$CONSULT_TOPIC" <commander> research
"$CLAUDE_PLUGIN_ROOT/bin/consult-research-send.sh" "$CONSULT_TOPIC" <commander> <model>

Bash(
  command='"$CLAUDE_PLUGIN_ROOT/bin/consult-research-wait.sh" "$CONSULT_TOPIC" <commander> <model>',
  run_in_background: true,
  description='master yoda await <commander> research re-prompt (background)'
)
# Wait for completion notification, then read state file as in Step 3.

"$CLAUDE_PLUGIN_ROOT/bin/consult-diff.sh" "$CONSULT_TOPIC"
```

### Pattern 3: All-UNCERTAIN verify re-prompt

> The wait-script runs in background; read state file + `.done` sentinel
> from the controller's notification handler (see Step 3).

If `verify-<commander>.txt` verdicts are all UNCERTAIN:

```
/clone-wars:send <commander> "$CONSULT_TOPIC" "For each UNCERTAIN item,
   read the cited source at the file:line and re-grade. Write to
   <state-dir>/verify.md. END_OF_INSTRUCTION"
"$CLAUDE_PLUGIN_ROOT/bin/consult-offset-reset.sh" "$CONSULT_TOPIC" <commander> verify
"$CLAUDE_PLUGIN_ROOT/bin/consult-verify-send.sh" "$CONSULT_TOPIC" <commander> <model>

Bash(
  command='"$CLAUDE_PLUGIN_ROOT/bin/consult-verify-wait.sh" "$CONSULT_TOPIC" <commander> <model>',
  run_in_background: true,
  description='master yoda await <commander> verify re-prompt (background)'
)
# Wait for completion notification, then read state file as in Step 3.

"$CLAUDE_PLUGIN_ROOT/bin/consult-adjudicate.sh" "$CONSULT_TOPIC"
cp "$TOPIC_DIR/_consult/adjudicated-draft.md" "$TOPIC_DIR/_consult/adjudicated.md"
# (or manually merge the new draft into adjudicated.md if you want to
# preserve specific prior PENDING resolutions — see spec Pattern 3.)
```

### Pattern 4: Critical-question relay

When a wait-script reports `FS=question` (research) or `VS=question`
(verify):

1. Read `_consult/question-<commander>.txt` — note `TEXT` and `OPTIONS`.
2. Read `$TROOPER_DIR/findings.md` (or `verify.md`) for findings-so-far.
3. Classify:
   - critical → `AskUserQuestion(TEXT, OPTIONS)`.
   - non-critical → answer from topic + findings yourself.
4. Send the answer (the new `--from` flag carries Yoda's identity):
   ```
   /clone-wars:send --from master-yoda <commander> "$CONSULT_TOPIC" "ANSWER: <answer>

   (end of question response — resume your skill loop)
   END_OF_INSTRUCTION"
   ```
5. Re-arm by removing the `.done` sentinel and re-running the wait-script
   in BACKGROUND (no send-script, no offset-reset — the wait-script's
   prior pass already advanced OFFSET past the question):
   ```
   rm -f "$TOPIC_DIR/_consult/research-<commander>.done"   # research
   # or:
   rm -f "$TOPIC_DIR/_consult/verify-<commander>.done"     # verify

   Bash(
     command='"$CLAUDE_PLUGIN_ROOT/bin/consult-research-wait.sh" "$CONSULT_TOPIC" <commander> <model>',
     run_in_background: true,
     description='master yoda await <commander> research re-arm (background)'
   )
   # or the verify-wait equivalent.
   ```
6. The new background task will fire a completion notification when the
   trooper either re-emits FS=question (loop), produces a terminal event,
   or times out.

Both troopers may emit questions independently. Notifications can arrive
in any order; process each as it lands.

**Kill switch:** if the question protocol misbehaves (storming,
mis-classification), set `CW_CONSULT_SKILL_OVERRIDE=none` in the
directive's environment. Send-scripts will append an empty hint
(no autonomy contract); troopers will use their default behavior.
