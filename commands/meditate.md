---
description: Deep multi-aspect exploration of hard topics — SOTA surveys, multi-angle thinking, adversary-tested landscape doc that feeds /clone-wars:consult
argument-hint: <topic>
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, AskUserQuestion, Skill, WebSearch, WebFetch
---

# /clone-wars:meditate

Deep multi-aspect exploration of `$ARGUMENTS`. Master Yoda orchestrates an
N-trooper research pass — classifying the topic up front to tell each
trooper how much to weight academic-paper retrieval — synthesizes a
preliminary landscape doc, runs a 5-signal confidence gate, dispatches
all N troopers as adversaries against the synthesis if the gate doesn't
let the user skip, and writes a final landscape doc with tradeoff matrix
+ adversary critiques + directional Conclusion intended as a hand-off
seed for `/clone-wars:consult`. **Yoda itself never runs retrieval skills
— troopers are the only retrievers.**

**When to use this command.** Invoke `/clone-wars:meditate` when the user
wants to explore, think deeply, find SOTA architectures, survey a
landscape, or research from multiple angles WITHOUT committing to a
buildable plan. Phrases that should route here:

- "explore SOTA …", "find new architectures for …"
- "deep think about …", "think through tradeoffs of …"
- "research from multiple aspects …"
- "deep reference research on …", "survey the landscape of …"
- "meditate on …"

Phrases that route to `/clone-wars:consult` instead (because they
require a buildable spec):

- "design X", "build X"
- "compare A vs B for decision", "should we adopt …"

The line is fuzzy; the intended workflow is `meditate → consult →
deploy`. Meditate's Conclusion feeds consult's next research round.

Spec: `docs/superpowers/specs/2026-05-11-v0.25.0-meditate-command-design.md`.

## Task list (TaskCreate × 12 BEFORE Step 0)

Create the task list using `TaskCreate`. Update statuses at the
boundaries below. Per-trooper rows are intentionally absent (N varies
2 or 3); each `[troopers]` row covers the whole roster in parallel.

| # | subject | activeForm |
|---|---|---|
| 0   | `0 Args + init + roster load [yoda]`        | `Staging args` |
| 1   | `1 Literature auto-detect [yoda]`           | `Classifying topic` |
| 2   | `2 Parallel spawn [yoda]`                   | `Spawning troopers` |
| 3   | `3 Research dispatch [troopers + lit]`      | `Dispatching research` |
| 4   | `4 Research wait [troopers]`                | `Troopers researching` |
| 5   | `5 Preliminary synthesis [yoda]`            | `Synthesizing draft` |
| 5.5 | `5.5 Confidence gate [yoda + user]`         | `Evaluating confidence` |
| 6   | `6 Adversary dispatch [troopers]`           | `Dispatching adversary` |
| 7   | `7 Adversary wait [troopers]`               | `Troopers attacking synthesis` |
| 8   | `8 Final synthesis [yoda]`                  | `Writing final landscape` |
| 9   | `9 Teardown + archive [yoda]`               | `Tearing down` |
| 10  | `10 Present final doc + next step [yoda]`   | `Presenting landscape` |

## Steps

The user's `$ARGUMENTS` may contain shell metacharacters. To avoid shell
injection, write it via the Write tool, then invoke sub-scripts.

### Step 0 — Args + init + roster load

Set task `0` → `in_progress`.

1. Resolve a unique args path (v0.31.0: project-local + mktemp per
   invocation so parallel sessions don't collide) and a per-invocation
   `RUN_DIR` (v0.36.0: project-local pointer dir; replaces session-global
   pointer files that collided across parallel runs):

   ```
   source "$CLAUDE_PLUGIN_ROOT/lib/log.sh"
   source "$CLAUDE_PLUGIN_ROOT/lib/state.sh"
   RUN_DIR=$(cw_run_dir meditate)
   ARGS_DIR="$(cw_state_root)/_args"
   mkdir -p "$ARGS_DIR"
   ARGS_FILE=$(mktemp -p "$ARGS_DIR" -t 'meditate.XXXXXX')
   printf '%s' "$ARGS_FILE" > "$RUN_DIR/args-path.txt"
   echo "$ARGS_FILE"
   ```

2. Write tool: `file_path` = the path printed; `content` = `$ARGUMENTS`.

3. Initialize the topic + compute repo hash:

   ```
   source "$CLAUDE_PLUGIN_ROOT/lib/state.sh"
   source "$CLAUDE_PLUGIN_ROOT/lib/consult.sh"
   RUN_DIR=$(cw_run_dir_last)
   ARGS_FILE=$(cat "$RUN_DIR/args-path.txt")
   REPO_HASH=$(cw_repo_hash)
   MEDITATE_TOPIC=$("$CLAUDE_PLUGIN_ROOT/bin/meditate-init.sh" "$(cat "$ARGS_FILE")")
   TOPIC_DIR="$(cw_state_root)/state/$REPO_HASH/$MEDITATE_TOPIC"
   ART_DIR="$TOPIC_DIR/_meditate"
   ```

4. **Load the trooper roster:**

   ```
   mapfile -t TROOPERS < <(cw_consult_load_troopers "$ART_DIR/troopers.txt")
   N=${#TROOPERS[@]}
   log_info "trooper count: N=$N"
   ```

Set task `0` → `completed`.

### Step 1 — Literature auto-detect

Set task `1` → `in_progress`.

Yoda classifies the topic via keyword scan and writes
`_meditate/lit-track.txt`. The result is consumed by Step 2's per-trooper
send-script via `{{LIT_GUIDANCE}}` — Yoda itself never runs retrieval.

```
source "$CLAUDE_PLUGIN_ROOT/lib/meditate.sh"
TOPIC_TEXT=$(cat "$ART_DIR/topic.txt")
LIT_FINAL=$(cw_meditate_classify_topic "$TOPIC_TEXT")
{
  printf '%s\n' "$LIT_FINAL"
  printf 'reason: auto-detect via keyword scan\n'
} > "$ART_DIR/lit-track.txt"
log_info "literature track: $LIT_FINAL (auto-detect via keyword scan)"
```

Set task `1` → `completed`.

### Step 2 — Parallel spawn (consult-style with rollback)

Set task `2` → `in_progress`.

Allocate panes via the preflight helper (reuse from v0.20.0):

```
"$CLAUDE_PLUGIN_ROOT/bin/preflight-layout.sh" "$MEDITATE_TOPIC" "$N"
```

This writes `_meditate/preflight-panes.txt` with ordered pane IDs.

Initialize retry counter ONCE before the parallel spawn block:

```
SPAWN_RETRY_COUNT=0
```

**Issue N parallel `Bash` tool calls in a single message** — one per
`TROOPERS` entry. Each call:

```
"$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" \
  <commander> <provider> "$MEDITATE_TOPIC" \
  --target-pane <pane_id_from_preflight> \
  --preflight-art-dir "$ART_DIR"
```

Evaluate the rc tuple after the parallel block:

- **All N succeed** → continue to Step 3. Task `2` → `completed`.
- **Any failed AND `SPAWN_RETRY_COUNT == 0`** → retry once:

  ```
  "$CLAUDE_PLUGIN_ROOT/bin/meditate-teardown.sh" "$MEDITATE_TOPIC" 2>/dev/null || true
  SPAWN_RETRY_COUNT=1
  log_info "spawn failed (cold start?); retrying parallel spawn once"
  ```

  Then re-issue the same N parallel spawn calls.

- **Any failed AND `SPAWN_RETRY_COUNT == 1`** → retry exhausted:

  ```
  "$CLAUDE_PLUGIN_ROOT/bin/meditate-teardown.sh" "$MEDITATE_TOPIC" 2>/dev/null || true
  rm -rf "$TOPIC_DIR"
  exit 1
  ```

  Surface specific provider failures to the user.

### Step 3 — Parallel research dispatch

Set task `3` → `in_progress`.

Issue N parallel Bash tool calls (one per trooper):

```
"$CLAUDE_PLUGIN_ROOT/bin/meditate-research-send.sh" "$MEDITATE_TOPIC" <cmdr> <provider>
```

Each trooper's research prompt has already been pre-rendered with the
`{{LIT_GUIDANCE}}` block appropriate to `_meditate/lit-track.txt`
(handled by `bin/meditate-research-send.sh` reading the lit-track value
written by Step 1) — no separate conductor-side literature-retrieval
call is needed. Yoda's role is to orchestrate and synthesize; troopers
do all retrieval.

Set task `3` → `completed`.

### Step 4 — Parallel research wait

Set task `4` → `in_progress`.

For each trooper, dispatch a background-await Bash call:

```
"$CLAUDE_PLUGIN_ROOT/bin/consult-research-wait.sh" "$MEDITATE_TOPIC" <cmdr> <provider>
```

`bin/consult-research-wait.sh` dispatches to `cw_consult_wait research`
which reads state files from `cw_consult_art_dir "$TOPIC"`. Since
v0.25.0, `cw_consult_art_dir` is prefix-aware: when topic starts with
`meditate-`, it returns `_meditate/` (where meditate-research-send wrote
the state file). No additional fix needed — the path resolution is
automatic.

Wait — follow them via background-await (mirror consult Step 5's
pattern: issue N background Bash calls in parallel in one message). On
the notification handler firing for each, check the corresponding
`.done` sentinel file. When all N have completed, proceed.

If a trooper emits `question`, handle via Pattern 1 (intervention
section below) before proceeding.

Set task `4` → `completed`.

### Step 5 — Preliminary synthesis (Yoda)

Set task `5` → `in_progress`.

Run input validator:

```
OUT_DRAFT=$("$CLAUDE_PLUGIN_ROOT/bin/meditate-synth-preliminary.sh" "$MEDITATE_TOPIC") \
  || { log_error "preliminary synth blocked — inputs missing"; exit 1; }
```

`$OUT_DRAFT` is the path Yoda Writes to: `_meditate/landscape-draft.md`.

**Yoda's synthesis work:** Read all `findings-<cmdr>.md` files (and
`literature-review.md` if present), then use the Write tool to author
`landscape-draft.md` with this EXACT section structure (Phase-5 set):

```markdown
## Topic
<verbatim from topic.txt>

## Approaches
1. <approach name> — <one-line summary, cluster across findings>
2. ...

## Tradeoff matrix
| Priority    | Best fit | Reason (with citation) |
|-------------|----------|------------------------|
| ...         | ...      | ...                    |

## Findings by trooper
### <Commander Rank> Rex (codex)
<digest of findings-rex.md>

### <Commander Rank> Cody (claude)
<digest of findings-cody.md>

### <Commander Rank> Wolffe (opencode)  ← only if present
<digest of findings-wolffe.md>

## Open questions
- ...

## Citations
- ...
```

When digesting findings, label CONTESTED claims explicitly (signal S3).
When citing in the matrix, every Reason cell must contain at least one
file path, URL, or paper-id reference (signal S4).

Set task `5` → `completed`.

### Step 5.5 — Confidence gate

Set task `5.5` → `in_progress`.

Evaluate 5 signals against `landscape-draft.md` + findings:

```bash
# S1: top-approach convergence (≥ N-1 troopers cite it)
TOP_APPROACH=$(grep -m1 -oE '^[0-9]+\. [^—]+' "$ART_DIR/landscape-draft.md" \
  | head -n1 | sed 's/^[0-9]*\. //; s/ —.*//; s/ *$//')
HITS=0
for f in "$ART_DIR"/findings-*.md; do
  grep -qiF "$TOP_APPROACH" "$f" && HITS=$((HITS+1))
done
[[ $HITS -ge $((N-1)) ]] && S1=true || S1=false

# S2: every citation in draft appears in ≥2 troopers' findings
SOLO_CITED=0
while IFS= read -r citation; do
  CITER_COUNT=0
  for f in "$ART_DIR"/findings-*.md; do
    grep -qF "$citation" "$f" && CITER_COUNT=$((CITER_COUNT+1))
  done
  (( CITER_COUNT < 2 )) && SOLO_CITED=$((SOLO_CITED+1))
done < <(grep -oE '[a-zA-Z_./-]+\.[a-z]+(:[0-9]+)?|https?://[^ )"\\]+' \
         "$ART_DIR/landscape-draft.md" | sort -u)
[[ $SOLO_CITED -eq 0 ]] && S2=true || S2=false

# S3: zero CONTESTED markers
grep -qi 'CONTESTED' "$ART_DIR/landscape-draft.md" && S3=false || S3=true

# S4: every matrix Reason cell has file/URL/paper backing.
# Heuristic: matrix rows where the Reason column lacks :// or / or paper: → bad.
MATRIX_BAD_COUNT=$(sed -n '/^## Tradeoff matrix/,/^## /p' "$ART_DIR/landscape-draft.md" \
  | grep -cE '^\| [^|]+\| [^|]+\| [^/:][^|]*\|$' || true)
[[ $MATRIX_BAD_COUNT -eq 0 ]] && S4=true || S4=false

# S5: at least one trooper acknowledged uncertainty
S5=false
for f in "$ART_DIR"/findings-*.md; do
  if grep -qiE 'uncertain|unclear|depends on|could not determine|not sure|gap in evidence' "$f"; then
    S5=true; break
  fi
done

# All 5 must hold to OFFER skip
ALL_HOLD=false
if [[ "$S1" == true && "$S2" == true && "$S3" == true && "$S4" == true && "$S5" == true ]]; then
  ALL_HOLD=true
fi
log_info "confidence signals: S1=$S1 S2=$S2 S3=$S3 S4=$S4 S5=$S5 — all-hold=$ALL_HOLD"
```

**Branch on `ALL_HOLD`:**

- **If `ALL_HOLD=false`** (any signal failed) → no prompt. Record the
  audit log and fall through to Step 6:

  ```bash
  {
    printf 'timestamp: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'signals_passed: S1=%s S2=%s S3=%s S4=%s S5=%s\n' "$S1" "$S2" "$S3" "$S4" "$S5"
    printf 'user_decision: not-offered\n'
  } > "$ART_DIR/adversary-skip.txt"
  ```

- **If `ALL_HOLD=true`** → fire `AskUserQuestion`:

  ```
  question: "Yoda is confident in the preliminary findings (all 5 signals hold). Skip adversary and write Conclusion now?"
  header:   "Adversary"
  options:
    1. (recommended) "Run adversary (default — safer)"
       description: "Re-dispatch all N troopers in parallel to challenge
                     the synthesis. Catches blind spots the confidence
                     gate may have missed. ~5-8 min."
    2. "Skip adversary, write Conclusion now"
       description: "Trust the preliminary synthesis; jump straight to
                     final landscape doc with Conclusion. Saves ~5-8 min."
  ```

  Then record the audit log with the user's decision:

  ```bash
  USER_DECISION=skip   # or "continue" based on the answer
  {
    printf 'timestamp: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'signals_passed: S1=true S2=true S3=true S4=true S5=true\n'
    printf 'user_decision: %s\n' "$USER_DECISION"
  } > "$ART_DIR/adversary-skip.txt"
  ```

- If `USER_DECISION=skip` → jump to Step 8.
- If `USER_DECISION=continue` (or no prompt fired) → proceed to Step 6.

Set task `5.5` → `completed`.

### Step 6 — Adversary dispatch (skipped if user accepted skip)

Set task `6` → `in_progress` (or `completed` immediately if skipped).

Issue N parallel Bash calls:

```
"$CLAUDE_PLUGIN_ROOT/bin/meditate-adversary-send.sh" "$MEDITATE_TOPIC" <cmdr> <provider>
```

Set task `6` → `completed`.

### Step 7 — Adversary wait (skipped if Step 6 skipped)

Set task `7` → `in_progress`.

Issue N background-await Bash calls (mirror Step 4):

```
"$CLAUDE_PLUGIN_ROOT/bin/meditate-adversary-wait.sh" "$MEDITATE_TOPIC" <cmdr> <provider>
```

This shim dispatches to `cw_consult_wait adversary`. Same notification
handling + question-event protocol as Step 4.

When all N complete, proceed.

Set task `7` → `completed`.

### Step 8 — Final synthesis (Yoda)

Set task `8` → `in_progress`.

Run input validator:

```
OUT_FINAL=$("$CLAUDE_PLUGIN_ROOT/bin/meditate-synth-final.sh" "$MEDITATE_TOPIC") \
  || { log_error "final synth blocked"; exit 1; }
```

`$OUT_FINAL` is the canonical output path: `_meditate/landscape-<date>-<slug>.md`.

**Yoda's synthesis work (Phase-8 sections):** Read `landscape-draft.md`
and all `adversary-<cmdr>.md` (if adversary ran). Write the final doc:

```markdown
## Topic
<from topic.txt>

## Approaches
<carried from draft, possibly revised per adversary critiques>

## Tradeoff matrix
<carried from draft, possibly revised per adversary critiques>

## Adversary critiques
- **<Rank> Rex (codex):** <one-paragraph summary of adversary-rex.md>
- **<Rank> Cody (claude):** ...
- **<Rank> Wolffe (opencode):** ...

(If adversary was skipped:)
> _Adversary phase skipped after Yoda's confidence gate passed (signals:
> S1,S2,S3,S4,S5 all true) and user accepted skip. Findings are
> single-pass — no post-synthesis challenge was performed._

## Open questions
<merged from draft + new questions from adversary critiques>

## Conclusion (for /clone-wars:consult hand-off)
<Yoda's directional take. Body should:>

- Name the strongest approach + state explicit caveats
- List adversary-surfaced weaknesses the design phase must address
- Suggest a concrete /clone-wars:consult invocation:

  /clone-wars:consult Design <X> using approach <A>, with mitigations for
  <adversary-flagged-issue>

- If user priorities shift, point to the matrix row that would change
  the answer.

## Citations
- (collected from all findings + literature-review + adversary)
```

Set task `8` → `completed`.

### Step 9 — Teardown panes + archive

Set task `9` → `in_progress`.

```
"$CLAUDE_PLUGIN_ROOT/bin/meditate-teardown.sh" "$MEDITATE_TOPIC"
```

Then move the topic state dir to archive:

```
source "$CLAUDE_PLUGIN_ROOT/lib/state.sh"
ARCHIVE_DIR="$(cw_global_state_root)/archive/$REPO_HASH/$MEDITATE_TOPIC-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$(dirname "$ARCHIVE_DIR")"
mv "$TOPIC_DIR" "$ARCHIVE_DIR"
log_info "archived to: $ARCHIVE_DIR"
```

The final landscape doc lives at `$ARCHIVE_DIR/_meditate/landscape-<date>-<slug>.md`.

Set task `9` → `completed`.

### Step 10 — Present final doc + suggested next step

Set task `10` → `in_progress`.

Print to the user:

```
Meditation complete.

Landscape doc:
  $ARCHIVE_DIR/_meditate/landscape-<date>-<slug>.md

Suggested next step (from Conclusion section):
  /clone-wars:consult <suggested topic from Conclusion>

Or hand-edit the topic to investigate a different angle.
```

Set task `10` → `completed`.

## Intervention patterns

Master Yoda regains control between every step (file-IPC, not in-process
SendMessage). If a trooper produces unexpected output, intervene before
the next sub-script runs. Three patterns:

### Pattern 1: Trooper question event

A trooper emits `{"event": "question", ...}`. The wait shim sets
`AS=question` (or `FS=question` for research). Read
`_meditate/question-<cmdr>.txt`, answer via `cw_send`, advance the
offset, then re-wait. Same flow as consult Pattern 1.

### Pattern 2: Malformed adversary output

A trooper's `adversary-<cmdr>.md` is empty or doesn't have a `## Verdict`
line. Re-dispatch one trooper with a clarifying inbox payload pointing
at the missing structure. If a second attempt still fails, mark that
trooper's critique as `(unavailable)` in the final doc.

### Pattern 3: Stuck spawn / cold start failure

Already absorbed by Step 2's auto-retry-once mechanism. If retry also
fails, Step 2 hard-exits with state cleanup. No further intervention.
