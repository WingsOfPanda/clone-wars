---
description: Spawn N consult-eligible troopers (claude, codex, opencode) on a topic; cross-verify their findings; synthesize a final report
argument-hint: <topic — what to research>
---

# /clone-wars:consult

Run a cross-verified multi-model investigation on `$ARGUMENTS`. Master
Yoda orchestrates the run via per-phase sub-scripts under `bin/`. Between
every step, Master Yoda regains control — if a trooper produces unexpected
output, Master Yoda can `cw_send` a clarifying prompt before the next
sub-script runs.

The trooper roster is **dynamic** in v0.15.0: `bin/consult-init.sh` reads
`$state_root/providers-available.txt` (written by `/clone-wars:medic`) and
writes `_consult/troopers.txt` (TSV: `<provider>\t<commander>`). Supported
counts: `N=2` (any 2 of claude/codex/opencode) and `N=3` (all three). N=1
plain-exits with a redirect to ask Claude directly. The directive below
iterates the roster — every "parallel block" issues `N` Bash tool calls in
a single message.

All panes stay attached for the entire run — `tmux select-pane` to watch.

Spec: `docs/superpowers/specs/2026-05-07-consult-3-trooper-design.md`
(v0.15.0); `docs/superpowers/specs/2026-04-29-clone-wars-consult-v2-design.md`
(v0.2 baseline).

## Task list (TaskCreate × 17 BEFORE step 1)

Create the task list using `TaskCreate`. Update statuses at the
boundaries below — do NOT print a markdown checklist in chat. Per-trooper
rows are intentionally absent (N is variable); each `[troopers]` row
covers the whole roster in parallel.

| # | subject | activeForm |
|---|---|---|
| 0  | `0 Stage args-file [yoda]`                      | `Staging args-file` |
| 1  | `1 Phrasing trigger check [yoda]`               | `Checking phrasing` |
| 2  | `2 4-signal complexity check + route [yoda]`    | `Checking complexity` |
| 3  | `3 Spawn troopers (parallel) [yoda]`            | `Spawning troopers` |
| 4  | `4 Research dispatch [troopers]`                | `Dispatching research` |
| 5  | `5 Research wait [troopers]`                    | `Troopers researching` |
| 6  | `6 Diff findings [yoda]`                        | `Diffing findings` |
| 7  | `7 Verify dispatch [troopers]`                  | `Dispatching verify` |
| 8  | `8 Verify wait [troopers]`                      | `Troopers verifying` |
| 9  | `9 Adjudicate + resolve PENDING [yoda]`         | `Adjudicating` |
| 10 | `10 Multi-repo detect [yoda]`                   | `Detecting multi-repo` |
| 11 | `11 Per-section design walk [yoda + user]`      | `Walking design sections` |
| 12 | `12 Assemble + audit gate [yoda]`               | `Assembling + auditing` |
| 13 | `13 Drill deeper (optional) [yoda + troopers]`  | `Drilling deeper` |
| 14 | `14 Teardown panes [yoda]`                      | `Tearing down` |
| 15 | `15 Archive _consult/ [yoda]`                   | `Archiving` |
| 16 | `16 Present final design doc [yoda]`            | `Presenting design-doc` |

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
if [[ "$DESIGN_DOC" == "1" ]]; then
  log_warn "--design-doc is deprecated as of v0.12.0. Run /clone-wars:spec separately after consult finishes."
fi
```

Use `$ARG_RAW` (not `$ARGUMENTS`) for the topic text from this point.
The flag is parsed only for back-compat — a deprecation warning fires
above and `$DESIGN_DOC` is otherwise unused. Run `/clone-wars:spec`
separately to walk a design doc.

**v0.16.0 — `--use-force` flag parsing (after `--design-doc` parse, BEFORE init):**

The `--use-force` flag escalates immediately to the trooper roster, skipping
the Yoda fast-path block (Step 2). Mirrors `cw_consult_parse_design_doc_flag`'s
token-aware semantics — only EXACT `--use-force` tokens are stripped (not
`--use-force-please`, `--use-forced`, etc.).

```
PARSE_UF=$(cw_consult_parse_use_force_flag "$ARG_RAW")
USE_FORCE="${PARSE_UF%%	*}"
ARG_RAW="${PARSE_UF#*	}"
if [[ "$USE_FORCE" == "1" ]]; then
  log_info "--use-force: trooper escalation will skip Yoda fast-path"
fi
```

Continue using `$ARG_RAW` for the topic from this point. Both flags can
coexist (legal but unusual): the `--design-doc` deprecation warning fires
and `--use-force` still escalates.

1. Resolve args path:

   ```
   ARGS_DIR="${CLONE_WARS_HOME:-$HOME/.clone-wars}/_args"
   mkdir -p "$ARGS_DIR"; echo "$ARGS_DIR/consult.txt"
   ```

2. Write tool: `file_path` = the path printed; `content` = `$ARG_RAW`.

3. Initialize the consult topic AND compute the repo hash once:

   ```
   source "$CLAUDE_PLUGIN_ROOT/lib/state.sh"
   source "$CLAUDE_PLUGIN_ROOT/lib/consult.sh"
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

4. **v0.15.0: load the trooper roster** that `consult-init.sh` just wrote.
   The roster drives every parallel block downstream (Steps 1, 2, 3, 5,
   8.4) — N is `2` or `3`.

   ```
   mapfile -t TROOPERS < <(cw_consult_load_troopers "$TOPIC_DIR/_consult/troopers.txt")
   N=${#TROOPERS[@]}
   log_info "trooper count: N=$N"
   # Each TROOPERS[i] is "<provider>\t<commander>" (TSV — provider first).
   # Example N=3: TROOPERS=("codex\trex" "claude\tcody" "opencode\tbly").
   # Parse with: IFS=$'\t' read -r prov cmdr <<<"${TROOPERS[i]}"
   ```

Set task `0` → `completed`.

### Step 1 — Escalation phrasing-trigger detection

Set task `1` → `in_progress`.

If `USE_FORCE=1`, skip the trigger scan (already escalating).

Otherwise, scan the topic text for case-insensitive escalation keywords.
The keywords below indicate the user explicitly wants the multi-trooper
cross-verification (rather than Yoda's fast-path single-source answer).
If any match, set `ESCALATE_FROM_PHRASING=1` and skip Step 2 (fast-path).

```
ESCALATE_FROM_PHRASING=0
if [[ "$USE_FORCE" != "1" ]]; then
  PHRASING_TRIGGERS=(
    "deeply"
    "verify"               # also matches "verify rigorously", "cross-verify"
    "compare carefully"
    "second opinion"
    "consult thoroughly"
  )
  TOPIC_LOWER=$(printf '%s' "$ARG_RAW" | tr '[:upper:]' '[:lower:]')
  for trigger in "${PHRASING_TRIGGERS[@]}"; do
    if [[ "$TOPIC_LOWER" == *"$trigger"* ]]; then
      ESCALATE_FROM_PHRASING=1
      log_info "phrasing trigger '$trigger' fired; escalating to troopers"
      break
    fi
  done
fi
```

Set task `1` → `completed`.

### Step 2 — 4-signal complexity check + ROUTE

Set task `2` → `in_progress`.

**Routing rules** (any one triggers escalated path):
- `--use-force` flag present
- Phrasing trigger fires (Step 1)
- Any 4-signal fires (below)
- `--targets a,b,c` was passed (treated as explicit escalation signal — even
  on trivial topics, an explicit multi-repo declaration deserves the full
  pipeline)

If none of the above → fast path.

If `USE_FORCE=1` or `ESCALATE_FROM_PHRASING=1` or `--targets` was supplied
(detect by `[[ -f "$TOPIC_DIR/_consult/targets.txt" ]]`), skip the 4-signal
check entirely and proceed to Step 3 (parallel spawn).

Otherwise, Master Yoda performs a fast-path research pass to determine
whether the topic warrants spawning the trooper roster. The goal is to
answer the user as a single source if (and only if) the topic is
sufficiently bounded; on any sign of complexity, escalate.

**1. Research the topic** using the full toolkit:

- `Read` / `Grep` / `Bash` for code-side research in this repository.
- `WebSearch` + `mcp__tavily__tavily-search` (paired per the global
  dual-search rule — issue both in a single tool-call block).
- Any `superpowers:*` skills that fit the topic
  (e.g. `superpowers:systematic-debugging`, `superpowers:brainstorming`).
- `mcp__claude_ai_*` MCP tools when external services are relevant
  (Drive, Calendar, Gmail, Notion, etc.).

Time-box research roughly equivalent to what one trooper would spend
in Step 5 (a few minutes of focused investigation, not an open-ended
deep dive).

**2. Run the 4-signal complexity check.** Favor rigor — **any 1+ signal
fires** → escalate to troopers. The signals are:

- **Conflicting evidence** — Yoda's research surfaced sources that
  disagreed with each other on a key claim (e.g. one doc says X is
  required, another says X is forbidden).
- **Significant assumptions** — answer required Yoda to assume facts
  not in evidence (e.g. "I think the user means Y, but the topic
  doesn't say").
- **High-stakes decision** — topic implicates architecture / security /
  irreversibility / production data (e.g. choice of auth model, schema
  migration direction, retention policy).
- **Subjective tradeoffs** — no objective right answer ("compare A vs B",
  "should we adopt X", "which approach is better for Z") — these benefit
  from cross-verified perspectives.

**3. If any signal fires:** set `ESCALATE_FROM_SIGNALS=1`, log the firing
signal name, and proceed to Step 3 (parallel spawn).

```
ESCALATE_FROM_SIGNALS=1
log_info "fast-path: signal '<which-fired>' fired; escalating to troopers"
```

**4. If no signal fires:** FAST PATH. Yoda writes a deploy-audit-passing
6-section design-doc by drafting each section inline, staging the drafts
under `.draft/<section>.md`, and invoking
`bin/consult-walk-assemble.sh` to assemble + audit. Then exit.

```
DRAFT_DIR="$TOPIC_DIR/_consult/design-doc/.draft"
mkdir -p "$DRAFT_DIR"
```

Use the **Write tool** to draft each of the 6 sections to its draft file
(atomic single-shot writes, not appends). Section file mapping:

- `$DRAFT_DIR/problem.md`         — `## Problem` heading + 1-3 sentences
  on the current state being addressed.
- `$DRAFT_DIR/goal.md`            — `## Goal` heading + 1 paragraph on
  what the world looks like after this is done.
- `$DRAFT_DIR/architecture.md`    — `## Architecture` heading + Yoda's
  recommended approach, the bulk of the doc.
- `$DRAFT_DIR/components.md`      — `## Components` heading + bullets
  for files / functions / classes touched.
- `$DRAFT_DIR/testing.md`         — `## Testing` heading + bullets for
  what tests cover the change.
- `$DRAFT_DIR/success-criteria.md` — `## Success Criteria` heading +
  measurable bullets (e.g. `- [ ] p99 latency < 50ms`).

Each draft body should cite sources inline where applicable
(`path/to/file:line`, URLs, runtime observations). Goal / Architecture /
Testing / Success Criteria are deploy-audit-required — do NOT emit them
empty. If a section truly doesn't apply (e.g. pure-research topic with
no testing implications), still emit the heading with a one-line
explanation rather than `_(skipped)_`.

After all 6 drafts are written, invoke walk-assemble:

```
DD_PATH=$("$CLAUDE_PLUGIN_ROOT/bin/consult-walk-assemble.sh" "$CONSULT_TOPIC" 2>/tmp/cw-fastpath-err) || {
  log_error "fast-path: walk-assemble FAILED — see /tmp/cw-fastpath-err"
  exit 1
}
log_ok "fast-path: design-doc at $DD_PATH"
```

If `walk-assemble.sh` exits non-zero (audit FAIL), parse `ISSUE=` lines
from `/tmp/cw-fastpath-err` and re-draft the offending section once via
`cw_consult_audit_issue_to_section`. If audit still fails after one
re-draft, surface the ISSUE list to the user and exit 1.

On audit PASS: print the design-doc path to the user, set all tasks
(`3`–`16`) to `completed` (the trooper-roster + walk tasks are skipped on
fast path), exit 0. No teardown call is needed — the only stateful
side-effects are `topic.txt`, `design-doc/.draft/*.md`, the assembled
`design-doc/<date>-<slug>-design.md`, and `audit.log`.

Set task `2` → `completed`.

### Step 3 — Parallel spawn (N-aware, with auto-retry-once + rollback)

Set task `3` → `in_progress`.

**Reached from one of three escalation paths:** `--use-force` flag,
phrasing trigger, or 4-signal escalation from Step 2. Set
`CW_PATH_LABEL` accordingly — it is consumed by Step 11 (synthesize)
to stamp the design-doc trust header:

```
case "$USE_FORCE,$ESCALATE_FROM_PHRASING,${ESCALATE_FROM_SIGNALS:-0}" in
  1,*,*) export CW_PATH_LABEL="escalated-from-flag" ;;
  *,1,*) export CW_PATH_LABEL="escalated-from-phrasing" ;;
  *,*,1) export CW_PATH_LABEL="escalated-from-signals" ;;
  *)     export CW_PATH_LABEL="escalated-from-signals" ;;  # defensive default
esac
log_info "trooper escalation path: $CW_PATH_LABEL"
```

Initialize ONCE before invoking the parallel spawn calls:

```
SPAWN_RETRY_COUNT=0
```

**Issue `N` parallel `Bash` tool calls in a single message** — one per
entry in `TROOPERS`. Each call invokes `bin/spawn.sh <commander>
<provider> "$CONSULT_TOPIC"`. Capture each rc separately.

Canonical N=3 example (codex/rex, claude/cody, opencode/bly — order
matches `TROOPERS`):

```
"$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" rex  codex    "$CONSULT_TOPIC"   # parallel 1
"$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" cody claude   "$CONSULT_TOPIC"   # parallel 2
"$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" bly  opencode "$CONSULT_TOPIC"   # parallel 3
```

For N=2 (the v0.14.0 default — claude+codex), issue 2 calls instead. The
shape per call is identical; only the count varies. Iterate `TROOPERS` to
emit the right `<commander> <provider>` pair on each call:

```
for entry in "${TROOPERS[@]}"; do
  IFS=$'\t' read -r prov cmdr <<<"$entry"
  # Issue: "$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" "$cmdr" "$prov" "$CONSULT_TOPIC"
  # — but as a PARALLEL Bash tool call, not a serial loop.
done
```

(The `for`-loop above is illustrative — Master Yoda emits `N` parallel
Bash tool calls in one message, NOT a sequential bash loop. The Bash tool
parallelism is what makes spawns concurrent.)

#### Spawn-rollback runbook (CRITICAL — N-aware)

After all `N` parallel spawn calls return, evaluate the rc tuple. **The
runbook supports ONE automatic retry** because codex's first cold-start
can blow the spawn.sh budget (node-modules load + auth handshake);
subsequent invocations are warm and almost always succeed. The retry path
costs ~30s in the rare failure case and is invisible on the happy path.
Same semantics for opencode (DeepSeek V4 Pro auth handshake on first
call).

- **All N succeed** → continue to Step 4. Set task `3` → `completed`.

- **At least one of the N fails AND `SPAWN_RETRY_COUNT == 0`** →
  **auto-retry-once**:

  ```
  # Tear down any surviving pane(s), KEEP _consult/ for the retry.
  "$CLAUDE_PLUGIN_ROOT/bin/consult-teardown.sh" "$CONSULT_TOPIC" 2>/dev/null || true
  SPAWN_RETRY_COUNT=1
  log_info "spawn failed (cold start?); retrying parallel spawn once"
  ```

  Then re-issue the same N parallel spawn calls (back to the block above).
  By this point each provider's runtime is warm; second attempt almost
  always succeeds.

- **At least one of the N fails AND `SPAWN_RETRY_COUNT == 1`** →
  **retry exhausted**:

  ```
  "$CLAUDE_PLUGIN_ROOT/bin/consult-teardown.sh" "$CONSULT_TOPIC" 2>/dev/null || true
  rm -rf "$TOPIC_DIR"
  exit 1
  ```

  Tell the user which provider(s) failed twice and why (capture stderr
  from both attempts for diagnostics — typically codex/opencode bootstrap
  timeout or binary-not-found). Task `3` stays `pending`.

### Step 4 — Parallel research dispatch (N-aware)

Set task `4` → `in_progress`.

Issue `N` parallel Bash tool calls in a single message — one per entry
in `TROOPERS`. Each call: `bin/consult-research-send.sh "$CONSULT_TOPIC"
<commander> <provider>`. Sends complete in <1s, so foreground is fine.

Canonical N=3 example:

```
"$CLAUDE_PLUGIN_ROOT/bin/consult-research-send.sh" "$CONSULT_TOPIC" rex  codex
"$CLAUDE_PLUGIN_ROOT/bin/consult-research-send.sh" "$CONSULT_TOPIC" cody claude
"$CLAUDE_PLUGIN_ROOT/bin/consult-research-send.sh" "$CONSULT_TOPIC" bly  opencode
```

For N=2, issue 2 calls instead. Use the same `TROOPERS` iteration pattern
(`IFS=$'\t' read -r prov cmdr <<<"$entry"`) to derive each call.

Set task `4` → `completed`.

### Step 5 — Parallel research wait (N-aware, with question loop)

Set task `5` → `in_progress`.

Background-await protocol: wait-scripts run as background tasks so Master
Yoda's pane stays interactive while troopers work. Each wait-script writes
`FS=<state>` to its per-commander state file before exit and touches a
`.done` sentinel; the controller reads both on the harness's completion
notification.

Dispatch `N` parallel **background** Bash tool calls in a single message
— one per entry in `TROOPERS`. Use the rank-prefixed trooper name in
the description so Yoda can identify which task fired the notification.

Canonical N=3 example:

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

Bash(
  command='"$CLAUDE_PLUGIN_ROOT/bin/consult-research-wait.sh" "$CONSULT_TOPIC" bly  opencode',
  run_in_background: true,
  description='master yoda await commander bly research (background)'
)
```

For N=2, issue 2 background calls. Iterate `TROOPERS` to derive the
`<commander> <provider>` pair for each call; the description string
should embed the trooper name so notifications are self-identifying.

While the background tasks run, **Yoda's pane remains free** — the user can
chat, run `/clone-wars:list`, or interrupt with new instructions. You will
receive one harness completion notification per task (`N` notifications
total — one per trooper).

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

   ```
   FINDINGS_PATH="$TOPIC_DIR/<commander>-<model>/findings.md"
   ```
c. Classify as critical / non-critical (same rules as Pattern 4 below)
   using the contents of `$FINDINGS_PATH`.
d. Get an answer:
   - critical → `AskUserQuestion` with TEXT + OPTIONS.
   - non-critical → answer from topic + `$FINDINGS_PATH` yourself.
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

Continue handling notifications until **all `N` commanders'** state files show
`FS ∈ {ok, empty, missing, failed, timeout, malformed}`. `FS=question` is a
transient state — only proceed to Step 6 when every trooper has a
terminal value.

- All `ok` / `empty` / `missing` → set task `5` → `completed`.
- Any `failed` / `timeout` / `malformed` → consider Pattern 1 (re-prompt)
  before proceeding; set task `5` → `completed` if accepting the degraded
  result.

### Step 6 — Diff (N-way Venn)

Set task `6` → `in_progress`.

```
"$CLAUDE_PLUGIN_ROOT/bin/consult-diff.sh" "$CONSULT_TOPIC"
```

`consult-diff.sh` reads `_consult/troopers.txt` and produces an N-way
Venn — for N=2 the legacy `rex_only_items.txt` / `cody_only_items.txt` /
`overlap_items.txt`; for N=3 a `<cmdr>_only_items.txt` per commander
plus pair-overlaps and a 3-way `consensus.txt`. Set task `6` →
`completed`.

### Step 7 — Parallel verify dispatch (N-aware)

Set task `7` → `in_progress`.

Send phase — issue `N` parallel Bash tool calls (foreground; sends
complete in <1s). Each: `bin/consult-verify-send.sh "$CONSULT_TOPIC"
<commander> <provider>`. Iterate `TROOPERS` to derive each call.

Canonical N=3 example:

```
"$CLAUDE_PLUGIN_ROOT/bin/consult-verify-send.sh" "$CONSULT_TOPIC" rex  codex
"$CLAUDE_PLUGIN_ROOT/bin/consult-verify-send.sh" "$CONSULT_TOPIC" cody claude
"$CLAUDE_PLUGIN_ROOT/bin/consult-verify-send.sh" "$CONSULT_TOPIC" bly  opencode
```

For N=2 issue 2 calls. Verify scope (v0.15.0): each trooper verifies
the **union of bucket files NOT containing this trooper** — i.e. claims
nobody-else, the other-trooper-only set, and any pair-overlaps that
don't include this trooper. `consult-verify-send.sh` computes the scope
from `_consult/troopers.txt` automatically.

### Step 8 — Parallel verify wait (N-aware, with question loop)

Set task `8` → `in_progress`.

Wait phase — issue `N` parallel **background** Bash tool calls (Yoda
stays interactive):

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

Bash(
  command='"$CLAUDE_PLUGIN_ROOT/bin/consult-verify-wait.sh" "$CONSULT_TOPIC" bly  opencode',
  run_in_background: true,
  description='master yoda await commander bly verify (background)'
)
```

For N=2, issue 2 background calls. Iterate `TROOPERS` to derive each
call. You will receive `N` completion notifications.

On EACH completion notification, read the per-commander verify state file:

```
STATE_FILE="$TOPIC_DIR/_consult/verify-<commander>.txt"
DONE_SENTINEL="${STATE_FILE%.txt}.done"
```

Same 4-step parse as Step 5 (sentinel check + grep `^VS=`). Note that
verify uses `VS=` (not `FS=` — that's research). The verify phase's
question-loop semantics match Step 5's exactly — see Pattern 4 (updated
below) for the re-arm recipe.

For each commander whose `VS=question`, the verify phase's findings-so-far
context source is the trooper's `verify.md` (not `findings.md`):

```
FINDINGS_PATH="$TOPIC_DIR/<commander>-<model>/verify.md"
```

Pass the contents of `$FINDINGS_PATH` into the answer-classification
prompt before invoking Pattern 4's relay.

If **all** troopers report all-UNCERTAIN verdicts, consider Pattern 3
intervention. Otherwise set task `8` → `completed`.

### Step 9 — Adjudicate + Yoda resolves PENDING

Set task `9` → `in_progress`.

```
"$CLAUDE_PLUGIN_ROOT/bin/consult-adjudicate.sh" "$CONSULT_TOPIC"
```

This writes `_consult/adjudicated-draft.md`. v0.15.0 emits 5 sections:
**Consensus** (all troopers agree), **Cross-verified** (verified across
the roster), **Contested**, **Refuted**, and **Pending**. For N=2 the
Consensus + Cross-verified sections collapse onto the legacy 2-trooper
shape; the structure is byte-equal-or-superset.

Copy the draft to Master Yoda's resolution surface:

```
cp "$TOPIC_DIR/_consult/adjudicated-draft.md" "$TOPIC_DIR/_consult/adjudicated.md"
```

**Resolve PENDING items.** Open `_consult/adjudicated.md` with the Read
tool. For every line beginning `- PENDING:`:

a. Note `[citation]` + claim.
b. Read the cited source (file or WebFetch URL).
c. Decide CONFIRMED / REFUTED / CONTESTED.
d. Edit tool to rewrite:
   - CONFIRMED / REFUTED: replace `- PENDING:` with the verdict + evidence.
   - CONTESTED: move under `## Contested`, drop the prefix.

When no `^- PENDING:` remains, set task `9` → `completed`.

### Step 10 — Multi-repo detection

Set task `10` → `in_progress`.

If `--targets a,b,c` was passed on the command line, `bin/consult-init.sh`
already wrote `_consult/targets.txt` and `_consult/multi-repo.txt=multi`.
Skip auto-detection in that case.

```
if [[ -f "$TOPIC_DIR/_consult/multi-repo.txt" && -f "$TOPIC_DIR/_consult/targets.txt" ]]; then
  log_info "[step 10] multi-repo set by --targets; skipping auto-detect"
else
  source "$CLAUDE_PLUGIN_ROOT/lib/consult-walk.sh"
  HITS=$(cw_consult_detect_multi_repo "$PWD" "$(cat "$TOPIC_DIR/_consult/topic.txt")")
fi
```

If `$HITS` is empty (no sibling matches OR --targets was set):
- single-repo path. Write `_consult/multi-repo.txt = single` if not already
  present. Skip the AskUserQuestion confirmation.

If `$HITS` is non-empty (auto-detect found candidate slugs):
- Issue `AskUserQuestion`:
  - Question: "Detected multi-repo topic candidates: <slug list>. Use
    these as targets, edit, or proceed single-repo?"
  - Options: `Use auto-detected list` / `Edit list` / `Proceed single-repo`
- On `Use auto-detected list`: write `_consult/targets.txt` from `$HITS`
  + `_consult/multi-repo.txt = multi`.
- On `Edit list`: AskUserQuestion (free-form) for the edited slug list
  (comma-separated). Validate each against `${CW_SLUG_REGEX_BASE}` and
  re-prompt on rejection. Write `targets.txt` + `multi-repo.txt = multi`.
- On `Proceed single-repo`: write `_consult/multi-repo.txt = single`. No
  targets.txt.

Set task `10` → `completed`.

### Step 11 — Per-section design walk

Set task `11` → `in_progress`.

**Setup.** Run `bin/consult-synthesize.sh` to produce SEED DRAFTS under
`$TOPIC_DIR/_consult/design-doc/.draft/<section>.md`. (Note: in v0.17.0
synthesize emits seeds, NOT a final design-doc — assembly happens in Step 12.)

```
"$CLAUDE_PLUGIN_ROOT/bin/consult-synthesize.sh" "$CONSULT_TOPIC"
```

Determine section list based on multi-repo flag:

```
MULTI_REPO=$(tr -d '[:space:]' < "$TOPIC_DIR/_consult/multi-repo.txt" 2>/dev/null || echo "single")
if [[ "$MULTI_REPO" == "multi" ]]; then
  SECTIONS=(problem goal architecture components execution-dag cross-repo-notes testing success-criteria)
  SECTION_TITLES=(Problem Goal Architecture Components "Execution DAG" "Cross-Repo Notes" Testing "Success Criteria")
else
  SECTIONS=(problem goal architecture components testing success-criteria)
  SECTION_TITLES=(Problem Goal Architecture Components Testing "Success Criteria")
fi
DRAFT_DIR="$TOPIC_DIR/_consult/design-doc/.draft"
mkdir -p "$DRAFT_DIR"
```

Load resume state (sections approved on prior runs):

```
mapfile -t APPROVED < <(cw_consult_walk_section_state "$DRAFT_DIR")
```

**Per-section loop.** For each `i` in `0..${#SECTIONS[@]}-1`:

1. `key=${SECTIONS[$i]}; title=${SECTION_TITLES[$i]}`.
2. **Resume check.** If `$key` appears in `${APPROVED[@]}` AND the existing
   `$DRAFT_DIR/$key.md` is approved (not `_(skipped)_`):
   - `AskUserQuestion`: "Section '$title' already approved on a prior run.
     Reuse / Redo / Skip?"
   - Reuse → continue to next `i`.
   - Redo → `rm "$DRAFT_DIR/$key.md"`, fall through to draft loop.
   - Skip → `printf '_(skipped)_\n' > "$DRAFT_DIR/$key.md"`, next `i`.
3. **Critical-section skip block.** If `$key` is `goal` or `architecture`,
   the AskUserQuestion options DO NOT include `Skip` (they're required by
   `cw_deploy_audit_doc`). Banner: "This section is required by
   cw_deploy_audit_doc; Skip not available — pick Approve or Revise."
4. **Draft loop:**
   - REVISE_COUNT=0
   - Yoda reads `$TOPIC_DIR/_consult/adjudicated.md`,
     `$DRAFT_DIR/$key.md` (the seed from synthesize), and the matching
     trooper's `findings.md`/`verify.md`.
   - For multi-repo + `key=architecture`: also reads `targets.txt`; drafts
     `### <slug>` subsections (one per target).
   - For multi-repo + `key=execution-dag`: drafts a soft DAG using
     `cw_consult_emit_soft_dag` from a TSV that Yoda constructs based on
     trooper findings about cross-repo dependencies. (User can re-edit
     during Revise.)
   - Yoda presents the draft in chat (markdown formatting preserved).
   - `AskUserQuestion` (3 options for non-critical sections, 2 for critical):
     - **Approve** → write the approved draft to `$DRAFT_DIR/$key.md` (atomic
       tmp+mv), break draft loop, advance to next `i`.
     - **Revise** → AskUserQuestion: "What should change?" (free-form).
       Fold response into draft. REVISE_COUNT++. Re-loop to present.
       - If REVISE_COUNT == 4 (i.e., user picked Revise four times):
         AskUserQuestion: "Revise loop has hit the cap (3 revisions).
         Force-approve current draft / Skip (not available for goal/architecture) /
         Abort consult." Force-approve writes the last presented draft.
     - **Skip** (non-critical only) → write `_(skipped)_` to
       `$DRAFT_DIR/$key.md`, break draft loop, advance.

Set task `11` → `completed`.

### Step 12 — Assemble + deploy-audit gate

Set task `12` → `in_progress`.

```
ATTEMPT=1
MAX_ATTEMPT_PER_SECTION=2
while :; do
  if DD_PATH=$("$CLAUDE_PLUGIN_ROOT/bin/consult-walk-assemble.sh" "$CONSULT_TOPIC" 2>/tmp/cw-walk-err); then
    log_ok "[step 12] design-doc assembled + audit PASS: $DD_PATH"
    break
  fi
  # Audit FAILED. Parse ISSUE= lines and re-walk the offending section(s).
  mapfile -t ISSUE_LINES < <(grep '^ISSUE=' /tmp/cw-walk-err || true)
  [[ ${#ISSUE_LINES[@]} -gt 0 ]] || { log_error "[step 12] audit FAIL but no ISSUE= lines parsed"; exit 1; }

  source "$CLAUDE_PLUGIN_ROOT/lib/consult-walk.sh"
  for line in "${ISSUE_LINES[@]}"; do
    KEY="${line#ISSUE=}"
    TARGET=$(cw_consult_audit_issue_to_section "$KEY")
    case "$TARGET" in
      goal|architecture|components|testing|success-criteria|execution-dag|cross-repo-notes|problem)
        log_info "[step 12] re-walking $TARGET (ISSUE=$KEY)"
        rm -f "$TOPIC_DIR/_consult/design-doc/.draft/$TARGET.md"
        # Re-enter Step 11's per-section walk for this section ONLY.
        # (Walk only this one key; other approved sections preserved.)
        ;;
      ASK)
        # Marker issue (TBD/TODO/etc.) — Yoda must locate the section.
        # AskUserQuestion: which section contains the marker? Options derived
        # from sections that have non-skipped drafts. Then re-walk that one.
        log_info "[step 12] marker issue $KEY; asking user to identify section"
        ;;
      header)
        # Target Sub-Project slug invalid. Re-prompt for targets in Step 10.
        log_error "[step 12] target_subproject_when_invalid; re-running Step 10 multi-repo detect"
        rm -f "$TOPIC_DIR/_consult/multi-repo.txt" "$TOPIC_DIR/_consult/targets.txt"
        # (Directive falls back to Step 10 by goto-style logic; in practice,
        # surface the error to user and ask to abort or retry.)
        ;;
      *)
        log_error "[step 12] unknown ISSUE=$KEY (no mapping)"
        # AskUserQuestion: "Audit emitted unknown ISSUE=$KEY. Commit failing doc / Abort?"
        ;;
    esac
  done

  ATTEMPT=$((ATTEMPT+1))
  if (( ATTEMPT > MAX_ATTEMPT_PER_SECTION )); then
    # AskUserQuestion: "Audit retry budget exhausted. Commit failing doc with banner / Abort?"
    # On "Commit failing doc with banner": re-run walk-assemble one more time
    # to write doc despite audit FAIL; banner appended to top of doc by Yoda
    # using Edit tool. Then break.
    log_error "[step 12] aborting"; exit 1
  fi
done
```

Set task `12` → `completed`.

### Step 13 — Drill deeper (optional, N-aware)

Set task `13` → `in_progress`.

Before teardown, offer one or more free-form drill-deeper rounds while
troopers are still alive. Each round writes to
`$TOPIC_DIR/_consult/drilldowns/_scratch/drilldown-<slug>-<commander>.md`
(slug = lowercased drill topic with spaces as hyphens) and becomes part
of the archive that `/clone-wars:spec` consumes.

```
DRILL_DIR="$TOPIC_DIR/_consult/drilldowns"
mkdir -p "$DRILL_DIR"
```

`AskUserQuestion`: "Any aspect to drill deeper before tearing down? (panes still live)"
Options: `Yes — drill` / `No — proceed to teardown`.

Loop while user picks "Yes":

1. `AskUserQuestion`: "Drill subject?" — free-form text response. → `$DRILL_TOPIC=<response>`
2. `AskUserQuestion`: "Focus angle? (e.g., 'tradeoffs feel hand-wavy')" — free-form. → `$DRILL_FOCUS=<response>`
3. `AskUserQuestion`: "Which trooper(s)?" — option list **depends on `N`**:

   - **N=2** (3 options): the 2 singles + parallel-all.
     - For roster `(rex/codex, cody/claude)`:
       `rex (codex)` / `cody (claude)` / `both (parallel)`
     - For other 2-trooper rosters (e.g. claude+opencode → cody+bly), use
       the actual commanders from `TROOPERS` rather than the literal
       names above.

   - **N=3** (7 options): 3 singles + 3 pairs + 1 fan-out.
     - `rex (codex)` / `cody (claude)` / `bly (opencode)`
     - `rex + cody` / `rex + bly` / `cody + bly`
     - `all three (parallel)`

   → `$DRILL_TROOPER=<choice>`

4. Invoke the drill bin script. `bin/consult-drilldown.sh` accepts at
   most 2 trooper pairs per invocation (arg counts: 6 = single trooper,
   7 = single + sub-project, 8 = two troopers, 9 = two + sub-project).
   To fan out to 3 troopers, issue **multiple parallel** drill calls.

   Argument shape: 4 fixed args (`<topic> <drill-topic> <dd-dir>
   <focus>`) followed by `K ∈ {1, 2}` pairs of `<commander> <provider>`,
   optionally followed by a sub-project token.

   Single trooper (`K=1`, 6 args):
   ```
   "$CLAUDE_PLUGIN_ROOT/bin/consult-drilldown.sh" \
     "$CONSULT_TOPIC" "$DRILL_TOPIC" "$DRILL_DIR" "$DRILL_FOCUS" \
     <commander> <provider>
   ```

   Two troopers in parallel (`K=2`, 8 args) — covers N=2 "both" or any
   N=3 pair (`rex + cody`, `rex + bly`, `cody + bly`):
   ```
   "$CLAUDE_PLUGIN_ROOT/bin/consult-drilldown.sh" \
     "$CONSULT_TOPIC" "$DRILL_TOPIC" "$DRILL_DIR" "$DRILL_FOCUS" \
     rex codex cody claude
   ```

   Three troopers (N=3 "all three (parallel)") — issue **two parallel
   Bash tool calls in a single message**: one K=2 pair + one K=1 single.
   The two calls share `$DRILL_TOPIC` and `$DRILL_DIR` so all three
   produced files land in `$DRILL_DIR/_scratch/` under the same slug:
   ```
   # Bash tool call 1 (parallel) — first 2 troopers
   "$CLAUDE_PLUGIN_ROOT/bin/consult-drilldown.sh" \
     "$CONSULT_TOPIC" "$DRILL_TOPIC" "$DRILL_DIR" "$DRILL_FOCUS" \
     rex codex cody claude

   # Bash tool call 2 (parallel) — third trooper
   "$CLAUDE_PLUGIN_ROOT/bin/consult-drilldown.sh" \
     "$CONSULT_TOPIC" "$DRILL_TOPIC" "$DRILL_DIR" "$DRILL_FOCUS" \
     bly opencode
   ```
   Treat the run as success if at least one of the two invocations
   returned `rc=0`. The 3 produced files share the same `<slug>` so
   `/clone-wars:spec` consumes them as a single drill round.

5. Read the produced drilldown file(s) under `$DRILL_DIR/_scratch/` —
   filename pattern `drilldown-<slug>-<commander>.md` (slug = lowercased
   `$DRILL_TOPIC` with spaces as hyphens) — and print a brief summary of
   findings to the user. The script's exit codes:
   - `rc=0` if at least one trooper produced a non-empty drilldown
   - `rc=1` if all troopers timed out / errored / produced empty files
   - `rc=2` on bad args
5b. If `rc=1` (all troopers timed out / errored), `AskUserQuestion`:
    "Drill returned no findings. Retry / Different trooper / Skip and continue?"
    - Retry: re-invoke with same args.
    - Different trooper: re-prompt step 3, then re-invoke.
    - Skip and continue: fall through to step 6.
6. `AskUserQuestion`: "Drill another aspect?" Options: `Yes` / `No — proceed to teardown`.

Drilldowns are part of the archive (`_consult/drilldowns/`) and become
available to `/clone-wars:spec` as supplemental context for the
design-doc walk.

Set task `13` → `completed`.

### Step 14 — Teardown panes

Set task `14` → `in_progress`.

```
"$CLAUDE_PLUGIN_ROOT/bin/consult-teardown.sh" "$CONSULT_TOPIC"
```

`consult-teardown.sh` reads `_consult/troopers.txt` and tears down every
listed trooper (no hardcoded pair). Set task `14` → `completed`.

### Step 15 — Archive _consult/

Set task `15` → `in_progress`.

```
"$CLAUDE_PLUGIN_ROOT/bin/consult-archive.sh" "$CONSULT_TOPIC"
```

Set task `15` → `completed`. Set task `16` → `in_progress`.

### Step 16 — Present final design-doc

Show the user the final design-doc assembled in Step 12 at
`$TOPIC_DIR/_consult/design-doc/<date>-<slug>-design.md` (path also
echoed by `bin/consult-walk-assemble.sh`). Set task `16` → `completed`.

## Intervention patterns

### Pattern 1: Malformed findings re-prompt

> The wait-script runs in background; read state file + `.done` sentinel
> from the controller's notification handler (see Step 5).

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
# Wait for completion notification, then read state file as in Step 5.

"$CLAUDE_PLUGIN_ROOT/bin/consult-diff.sh" "$CONSULT_TOPIC"
```

### Pattern 3: All-UNCERTAIN verify re-prompt

> The wait-script runs in background; read state file + `.done` sentinel
> from the controller's notification handler (see Step 5).

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
# Wait for completion notification, then read state file as in Step 5.

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

Any of the `N` troopers may emit questions independently. Notifications
can arrive in any order; process each as it lands.

**Kill switch:** if the question protocol misbehaves (storming,
mis-classification), set `CW_CONSULT_SKILL_OVERRIDE=none` in the
directive's environment. Send-scripts will append an empty hint
(no autonomy contract); troopers will use their default behavior.
