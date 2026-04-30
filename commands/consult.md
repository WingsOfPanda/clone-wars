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

**v0.4.2 — `--design-doc` token-aware flag parsing (BEFORE init):**

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

### Step 3 — Parallel research wait (with question loop)

v0.3 protocol: troopers may emit `{"event":"question","text":"...","options":["A","B"]}`
events while running `superpowers:brainstorming` or `superpowers:systematic-debugging`.
Master Yoda catches those, classifies critical vs non-critical, and either
answers from topic context or escalates to the user via `AskUserQuestion`.

Both calls in PARALLEL:

```
"$CLAUDE_PLUGIN_ROOT/bin/consult-research-wait.sh" "$CONSULT_TOPIC" rex  codex
"$CLAUDE_PLUGIN_ROOT/bin/consult-research-wait.sh" "$CONSULT_TOPIC" cody claude
```

After both return, read each commander's `FS=` (last line wins):

```
grep '^FS=' "$TOPIC_DIR/_consult/research-rex.txt"  | tail -1
grep '^FS=' "$TOPIC_DIR/_consult/research-cody.txt" | tail -1
```

For each commander whose `FS=question`:

1. Read the question payload — `_consult/question-<commander>.txt`. Use
   the Read tool, parse `TEXT=` and `OPTIONS=`. Decode any `%xx` you see.
2. Read `$TOPIC_DIR/<commander>-<model>/findings.md` (if it exists) for
   findings-so-far context. Required for non-critical answers.
3. Classify the question as **critical** or **non-critical**:
   - critical = answer would change topic interpretation (scope expansion,
     contradiction with explicit user constraint, binary fork with no
     clear default given findings-so-far).
   - non-critical = clarifying question, defaulting choice, language
     convention answerable from topic + findings.
4. Get an answer:
   - critical → `AskUserQuestion` with TEXT as question, OPTIONS as
     multiple-choice (or free-form if OPTIONS is empty).
   - non-critical → answer from topic + findings yourself.
5. Send the answer (writes inbox.md + nudges trooper):
   ```
   /clone-wars:send <commander> "$CONSULT_TOPIC" "ANSWER: <your answer>

   (end of question response — resume your skill loop)
   END_OF_INSTRUCTION"
   ```
6. **Re-arm by re-running the wait-script ONLY**. Do NOT call
   `consult-research-send.sh` — it would overwrite inbox.md (clobbering
   ANSWER). The wait-script's `source $STATE_FILE` picks up the
   post-question OFFSET (last-wins) the previous wait appended.
   ```
   "$CLAUDE_PLUGIN_ROOT/bin/consult-research-wait.sh" "$CONSULT_TOPIC" \
      <commander> <model>
   ```
7. Loop back to the top of Step 3 if any trooper still has `FS=question`
   pending. Both troopers may emit questions independently — process in
   iteration order (rex first, then cody). The user sees critical prompts
   sequentially.

Stop the loop when both are FS ∈ {ok, empty, missing, failed, timeout, malformed}.

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

```
# Parallel send
"$CLAUDE_PLUGIN_ROOT/bin/consult-verify-send.sh" "$CONSULT_TOPIC" rex  codex
"$CLAUDE_PLUGIN_ROOT/bin/consult-verify-send.sh" "$CONSULT_TOPIC" cody claude

# Parallel wait
"$CLAUDE_PLUGIN_ROOT/bin/consult-verify-wait.sh" "$CONSULT_TOPIC" rex  codex
"$CLAUDE_PLUGIN_ROOT/bin/consult-verify-wait.sh" "$CONSULT_TOPIC" cody claude
```

Read `verify-{rex,cody}.txt` for `VS=` status (last-wins).

The verify phase has the same question loop as Step 3 — if `VS=question`
for either trooper, follow Pattern 4 (Critical-question relay) below:
read payload + verify.md, classify, AskUserQuestion or answer, cw_send,
re-run consult-verify-wait.sh. NO send-script re-call.

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

### Step 8.5 — Design-doc walk (v0.4.0, optional)

**Entry conditions** (v0.4.2 — classifier no longer the strict gate):

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

**Setup:**

```
DD_DIR="$TOPIC_DIR/_consult/design-doc"
mkdir -p "$DD_DIR"
SECTIONS=(architecture components data-flow error-handling testing)
SECTION_TITLES=(Architecture Components "Data Flow" "Error Handling" Testing)
mapfile -t APPROVED < <(
  source "$CLAUDE_PLUGIN_ROOT/lib/consult.sh"
  cw_consult_design_doc_resume_state "$DD_DIR"
)
```

**Per-section loop** (5 iterations — one per section):

For each `i` in `0..4`:

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

v0.4.2: drill-down accepts `rex` / `cody` / `both`. For `both`, Yoda dispatches
the same focused prompt to BOTH troopers in parallel; outputs land at
`drilldown-<section>-rex.md` and `drilldown-<section>-cody.md`; both fold into
the section draft, attributing each finding by commander.

```
# AskUserQuestion: "Which trooper to drill into '$title'?"
#   options: rex (codex) / cody (claude) / both (parallel)
TROOPER_CHOICE=<chosen>

# AskUserQuestion: "What's the focus? (e.g., 'trade-offs feel hand-wavy')"
FOCUS=<free-form>

source "$CLAUDE_PLUGIN_ROOT/lib/consult.sh"
TIMEOUT=$(awk -F: '/findings_timeout_s/{gsub(/[^0-9]/,"",$2); print $2; exit}' \
  "${CLONE_WARS_HOME:-$HOME/.clone-wars}/contracts.yaml")
TIMEOUT=${TIMEOUT:-90}

dispatch_drill() {
  local commander="$1" model="$2"
  local trooper_dir offset prompt
  trooper_dir=$(cw_trooper_dir "$commander" "$model" "$CONSULT_TOPIC")
  offset=$(wc -c < "$trooper_dir/outbox.jsonl" 2>/dev/null || echo 0)
  prompt=$(cw_consult_design_doc_drilldown_prompt \
    "$title" "$TOPIC_DIR/_consult/synthesis.md" "$commander" "$DD_DIR" "$FOCUS")
  "$CLAUDE_PLUGIN_ROOT/bin/send.sh" "$commander" "$CONSULT_TOPIC" "$prompt"
  printf '%s\n' "$offset"  # caller captures pre-send offset
}

await_drill() {
  local commander="$1" model="$2" offset="$3"
  cw_outbox_wait_since "$commander" "$model" "$CONSULT_TOPIC" \
    "$offset" done error "$TIMEOUT" >/dev/null
}

SECTION_SLUG=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

case "$TROOPER_CHOICE" in
  rex)
    OFF_REX=$(dispatch_drill rex codex)
    if await_drill rex codex "$OFF_REX"; then
      DRILL="$DD_DIR/drilldown-${SECTION_SLUG}-rex.md"
      [[ -s "$DRILL" ]] && log_info "[design-doc] folded $DRILL into $title draft"
    fi
    ;;
  cody)
    OFF_CODY=$(dispatch_drill cody claude)
    if await_drill cody claude "$OFF_CODY"; then
      DRILL="$DD_DIR/drilldown-${SECTION_SLUG}-cody.md"
      [[ -s "$DRILL" ]] && log_info "[design-doc] folded $DRILL into $title draft"
    fi
    ;;
  both)
    OFF_REX=$(dispatch_drill rex codex)   # parallel — these run in tmux panes
    OFF_CODY=$(dispatch_drill cody claude)
    REX_OK=0; CODY_OK=0
    await_drill rex  codex  "$OFF_REX"  && REX_OK=1
    await_drill cody claude "$OFF_CODY" && CODY_OK=1
    DRILL_REX="$DD_DIR/drilldown-${SECTION_SLUG}-rex.md"
    DRILL_CODY="$DD_DIR/drilldown-${SECTION_SLUG}-cody.md"
    if (( REX_OK || CODY_OK )); then
      [[ -s "$DRILL_REX" ]]  && log_info "[design-doc] folded $DRILL_REX into $title draft"
      [[ -s "$DRILL_CODY" ]] && log_info "[design-doc] folded $DRILL_CODY into $title draft"
      # Yoda reads both files (when present) and incorporates findings,
      # attributing each by commander in the section text.
    else
      # AskUserQuestion: "Both drill-downs failed/timed out. Retry / Skip drill?"
      :
    fi
    ;;
  *)
    log_error "drill-down: unknown choice '$TROOPER_CHOICE' — re-prompting"
    # Re-enter the AskUserQuestion above; do not proceed with stale MODEL.
    ;;
esac

# Single-trooper empty-drilldown handling (rex/cody branches above).
DRILL_PATH="$DD_DIR/drilldown-${SECTION_SLUG}-${TROOPER_CHOICE}.md"
if [[ "$TROOPER_CHOICE" != "both" && ! -s "$DRILL_PATH" ]]; then
  # AskUserQuestion: "Drill-down completed but $DRILL_PATH is empty.
  #   Continue / Retry / Other trooper / Skip?"
  :
fi
else
  # AskUserQuestion: "Drill-down on $title timed out. Retry / Other
  #   trooper / Skip drill / Continue with current draft?"
  :
fi
```

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
- **Git commit failed**: script exits 1, design.md exists uncommitted.
  Yoda surfaces the git error verbatim and asks user to resolve.

**v0.4.2 — tear down troopers BEFORE the user-review gate.**

Codex's adversarial review flagged the v0.4.0 ordering (gate-then-teardown)
as keeping two model TTYs idle through unbounded review pauses with no
keepalive or recovery path. v0.4.2 reorders: after the design.md commits,
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

**v0.4.2:** if Step 8.5 ran, teardown + archive already happened before the
user-review gate. Skip this step. Otherwise (no design-doc walk):

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

### Pattern 4: Critical-question relay (v0.3)

When a wait-script reports `FS=question` (research) or `VS=question`
(verify):

1. Read `_consult/question-<commander>.txt` — note `TEXT` and `OPTIONS`.
2. Read `$TROOPER_DIR/findings.md` (or `verify.md`) for findings-so-far.
3. Classify:
   - critical → `AskUserQuestion(TEXT, OPTIONS)`.
   - non-critical → answer from topic + findings yourself.
4. Send the answer:
   ```
   /clone-wars:send <commander> "$CONSULT_TOPIC" "ANSWER: <answer>

   (end of question response — resume your skill loop)
   END_OF_INSTRUCTION"
   ```
5. Re-run the wait-script ONLY (no send-script, no offset-reset — the
   wait-script already advanced OFFSET past the question on first match):
   ```
   "$CLAUDE_PLUGIN_ROOT/bin/consult-research-wait.sh" "$CONSULT_TOPIC" \
      <commander> <model>          # research
   # or:
   "$CLAUDE_PLUGIN_ROOT/bin/consult-verify-wait.sh" "$CONSULT_TOPIC" \
      <commander> <model>          # verify
   ```
6. Loop until the trooper reports `FS=ok` / `VS=ok`.

Both troopers may emit questions independently. Process in iteration
order; the user sees critical prompts sequentially.

**Kill switch:** if the question protocol misbehaves (storming,
mis-classification), set `CW_CONSULT_SKILL_OVERRIDE=none` in the
directive's environment. Send-scripts will append an empty hint
(no autonomy contract); troopers will use their default behavior.
