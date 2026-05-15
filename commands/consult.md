---
description: Cross-verified multi-model research synthesized into a deploy-audit-passing design doc — Yoda fast-path or escalate to N troopers
argument-hint: [--use-force] [--targets a,b,c] <topic — what to research>
allowed-tools: Bash, Write, Read, Edit, AskUserQuestion, WebSearch, mcp__tavily__tavily-search, Skill
---

# /clone-wars:consult

Run a cross-verified multi-model investigation on `$ARGUMENTS`. Master
Yoda orchestrates the run via per-phase sub-scripts under `bin/`. Between
every step, Master Yoda regains control — if a trooper produces unexpected
output, Master Yoda can `cw_send` a clarifying prompt before the next
sub-script runs.

**When to use this command.** Invoke `/clone-wars:consult` when the user
asks to research, compare, evaluate, decide between, design, or brainstorm
anything that benefits from a written design doc. Phrases that should
route here include: "research X", "design how to do Y", "compare A vs B",
"second opinion on Z", "consult thoroughly on…", "verify rigorously",
"deeply investigate", "decide between options", "should we adopt X".

The trooper roster is **dynamic** (v0.15.0+): `bin/consult-init.sh` prefers
`$state_root/providers-active.txt` (selected by `/clone-wars:medic` v0.18.0)
and falls back to `providers-available.txt`. It writes `_consult/troopers.txt`
(TSV: `<provider>\t<commander>`). Supported counts: `N=2` (any 2 of
claude/codex/opencode) and `N=3` (all three). N=1 plain-exits with a
redirect to ask Claude directly. The directive below iterates the roster
— every "parallel block" issues `N` Bash tool calls in a single message.

All panes stay attached for the entire run — `tmux select-pane` to watch.

Spec:
- `docs/superpowers/specs/2026-05-08-consult-spec-merge-design.md` (v0.17.0 — current)
- `docs/superpowers/specs/2026-05-07-consult-3-trooper-design.md` (v0.15.0)
- `docs/superpowers/specs/2026-04-29-clone-wars-consult-v2-design.md` (v0.2 baseline)

## Task list (TaskCreate × 18 BEFORE Step 0)

Create the task list using `TaskCreate`. Update statuses at the
boundaries below — do NOT print a markdown checklist in chat. Per-trooper
rows are intentionally absent (N is variable); each `[troopers]` row
covers the whole roster in parallel.

| # | subject | activeForm |
|---|---|---|
| 0  | `0 Stage args-file [yoda]`                              | `Staging args-file` |
| 1  | `1 Phrasing trigger scan (skipped if --use-force) [yoda]` | `Checking phrasing` |
| 2  | `2 4-signal complexity check + route (fast-path or escalate) [yoda]` | `Checking complexity` |
| 3a | `3a Preflight pane allocation [yoda]`           | `Preflight pane allocation` |
| 3b | `3b Parallel spawn dispatch [yoda]`             | `Spawning troopers (parallel dispatch)` |
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

**Canonical N-aware examples** (referenced by Steps 4 / 7 / 8):

For N=3 (codex/rex, claude/cody, opencode/wolffe):

```
"$CLAUDE_PLUGIN_ROOT/bin/<verb>.sh" rex  codex    "$CONSULT_TOPIC"
"$CLAUDE_PLUGIN_ROOT/bin/<verb>.sh" cody claude   "$CONSULT_TOPIC"
"$CLAUDE_PLUGIN_ROOT/bin/<verb>.sh" wolffe  opencode "$CONSULT_TOPIC"
```

For N=2, issue 2 calls instead. Iterate `TROOPERS` to derive each call:

```
for entry in "${TROOPERS[@]}"; do
  IFS=$'\t' read -r prov cmdr <<<"$entry"
  # Issue: "$CLAUDE_PLUGIN_ROOT/bin/<verb>.sh" "$cmdr" "$prov" "$CONSULT_TOPIC"
  # — but as a PARALLEL Bash tool call, not a serial loop.
done
```

(The `for`-loop above is illustrative — Master Yoda emits N parallel
Bash tool calls in one message, NOT a sequential bash loop. The Bash
tool parallelism is what makes the spawns concurrent.)

### Step 0 — args-file + init + compute REPO_HASH

Set task `0` → `in_progress`.

**`--design-doc` flag parsing (BEFORE init):**
The flag was obsolete in v0.17.0 (silently ignored) and is fully
removed in v0.24.0; passing it will error from `bin/consult-init.sh`
downstream. Set `ARG_RAW="$ARGUMENTS"` directly — no flag parse
needed.

**v0.16.0 — `--use-force` flag parsing (BEFORE init):**

The `--use-force` flag escalates immediately to the trooper roster, skipping
the Yoda fast-path block (Step 2). Token-aware parse — only EXACT
`--use-force` tokens are stripped (not `--use-force-please`,
`--use-forced`, etc.).

```
PARSE_UF=$(cw_consult_parse_use_force_flag "$ARG_RAW")
USE_FORCE="${PARSE_UF%%	*}"
ARG_RAW="${PARSE_UF#*	}"
if [[ "$USE_FORCE" == "1" ]]; then
  log_info "--use-force: trooper escalation will skip Yoda fast-path"
fi
```

Continue using `$ARG_RAW` for the topic from this point.

1. Resolve a unique args path (v0.31.0: project-local + mktemp per invocation
   so parallel sessions don't collide on a stable filename):

   ```
   source "$CLAUDE_PLUGIN_ROOT/lib/state.sh"
   ARGS_DIR="$(cw_state_root)/_args"
   mkdir -p "$ARGS_DIR"
   ARGS_FILE=$(mktemp -p "$ARGS_DIR" -t 'consult.XXXXXX')
   echo "$ARGS_FILE" > /tmp/cw-consult-args-path.txt
   echo "$ARGS_FILE"
   ```

2. Write tool: `file_path` = the path printed (read from `/tmp/cw-consult-args-path.txt` in later Bash blocks); `content` = `$ARG_RAW`.

3. Initialize the consult topic AND compute the repo hash once:

   ```
   source "$CLAUDE_PLUGIN_ROOT/lib/state.sh"
   source "$CLAUDE_PLUGIN_ROOT/lib/consult.sh"
   ARGS_FILE=$(cat /tmp/cw-consult-args-path.txt)
   REPO_HASH=$(cw_repo_hash)
   CONSULT_TOPIC=$("$CLAUDE_PLUGIN_ROOT/bin/consult-init.sh" "$(cat "$ARGS_FILE")")
   TOPIC_DIR="$(cw_state_root)/state/$REPO_HASH/$CONSULT_TOPIC"
   echo "$CONSULT_TOPIC"   # for use in subsequent steps
   ```

   `$REPO_HASH` and `$TOPIC_DIR` are reused throughout the rest of the
   directive — DO NOT inline a `$(...)` containing a literal `<repo-hash>`
   redirect anywhere (bash interprets `$(< repo-hash )` as `cat repo-hash`,
   which would shell out to read a file named `repo-hash`). Always use the
   `$REPO_HASH` variable computed above.

4. **Load the trooper roster** that `consult-init.sh` just wrote.
   The roster drives every parallel block downstream (Steps 3, 4, 5, 7,
   8, and Step 13's optional drill rounds) — N is `2` or `3`.

   ```
   mapfile -t TROOPERS < <(cw_consult_load_troopers "$TOPIC_DIR/_consult/troopers.txt")
   N=${#TROOPERS[@]}
   log_info "trooper count: N=$N"
   # Each TROOPERS[i] is "<provider>\t<commander>" (TSV — provider first).
   # Example N=3: TROOPERS=("codex\trex" "claude\tcody" "opencode\twolffe").
   # Parse with: IFS=$'\t' read -r prov cmdr <<<"${TROOPERS[i]}"
   ```

Set task `0` → `completed`.

### Step 1 — Escalation phrasing-trigger detection

Set task `1` → `in_progress`.

If `USE_FORCE=1`, skip the trigger scan (already escalating).

Otherwise, scan the topic text for case-insensitive escalation keywords.
The keywords below indicate the user explicitly wants the multi-trooper
cross-verification (rather than Yoda's fast-path single-source answer).
If any match, set `ESCALATE_FROM_PHRASING=1`. Step 2's body branches on
this flag: when set, the 4-signal sub-block + fast-path emit are skipped
and control falls through directly to Step 3 (spawn).

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
from `/tmp/cw-fastpath-err`, map each via `cw_consult_audit_issue_to_section`,
re-draft the offending section(s) into `$DRAFT_DIR/<section>.md` (Write
tool, atomic), and **re-invoke `bin/consult-walk-assemble.sh`**. If the
re-invocation also exits non-zero (audit still fails after one re-draft),
surface the ISSUE list to the user and exit 1.

**Progress signaling during fast-path.** The fast-path emit can take
5–10 minutes (research + 6 drafts + audit). To keep the user informed
without splitting task `2` into two rows, log the sub-phase transitions
explicitly via `log_info`:

```
log_info "fast-path: research phase"      # before tool calls
log_info "fast-path: drafting sections"   # before Write tool calls
log_info "fast-path: assembling + audit"  # before walk-assemble
```

On audit PASS: print the design-doc path to the user, set all tasks
(`3`–`16`) to `completed` (the trooper-roster + walk tasks are skipped on
fast path), exit 0. No teardown call is needed — the only stateful
side-effects are `topic.txt`, `design-doc/.draft/*.md`, the assembled
`design-doc/<date>-<slug>-design.md`, and `audit.log`.

Set task `2` → `completed`.

### Step 3a — Preflight pane allocation

Set task `3a` → `in_progress`.

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

Initialize the retry counter ONCE before invoking preflight:

```
SPAWN_RETRY_COUNT=0
```

**Run preflight (single foreground bash call):**

```
"$CLAUDE_PLUGIN_ROOT/bin/preflight-layout.sh" "$CONSULT_TOPIC" "$N"
```

Expected behavior:

- On rc=0: `_consult/preflight-panes.txt` is now populated with N ordered
  TSV lines (`<commander>\t<pane_id>`). The user's tmux window now shows
  Yoda on the left + N evenly-sized sentinel panes on the right (via
  `tmux select-layout main-vertical`).
- On rc≠0: preflight rolled back any panes it created. Surface the error
  to the user. Retry semantics are handled in Step 3b's failure-tuple
  evaluation (Stage 1 retry-once + Stage 2 partial-success offer).

After preflight succeeds, load the pane assignments into a shell array:

```
declare -A PREFLIGHT_PANES
while IFS=$'\t' read -r cmdr pane; do
  [[ -n "$cmdr" && -n "$pane" ]] && PREFLIGHT_PANES["$cmdr"]="$pane"
done < "$TOPIC_DIR/_consult/preflight-panes.txt"
```

Set task `3a` → `completed`.

### Step 3b — Parallel spawn dispatch (N-aware, with Stage 1 retry + Stage 2 partial-success)

Set task `3b` → `in_progress`.

**Issue `N` parallel `Bash` tool calls in a single message** — one per
entry in `TROOPERS`. Each call invokes
`bin/spawn.sh <commander> <provider> "$CONSULT_TOPIC" --target-pane "${PREFLIGHT_PANES[$cmdr]}"`.
Capture each rc separately.

Canonical N=3 example (codex/rex, claude/cody, opencode/wolffe — order
matches `TROOPERS`):

```
"$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" rex  codex    "$CONSULT_TOPIC" --target-pane "${PREFLIGHT_PANES[rex]}"   # parallel 1
"$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" cody claude   "$CONSULT_TOPIC" --target-pane "${PREFLIGHT_PANES[cody]}"  # parallel 2
"$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" wolffe  opencode "$CONSULT_TOPIC" --target-pane "${PREFLIGHT_PANES[wolffe]}"   # parallel 3
```

For N=2 (any 2-provider subset selected via `/clone-wars:medic`), issue
2 calls. Iterate `TROOPERS` to derive each call:

```
for entry in "${TROOPERS[@]}"; do
  IFS=$'\t' read -r prov cmdr <<<"$entry"
  # Issue: "$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" "$cmdr" "$prov" "$CONSULT_TOPIC" --target-pane "${PREFLIGHT_PANES[$cmdr]}"
  # — but as a PARALLEL Bash tool call, not a serial loop.
done
```

(The `for`-loop above is illustrative — Master Yoda emits `N` parallel
Bash tool calls in one message, NOT a sequential bash loop. With
preflight-panes already allocated, the spawns are truly parallel — no
shared mutable state between the N processes.)

#### Failure handling — Stage 1 retry-once + Stage 2 partial-success

After all `N` parallel spawn calls return, evaluate the rc tuple.

- **All N succeed** → continue to Step 4. Set task `3b` → `completed`.

- **At least one fails AND `SPAWN_RETRY_COUNT == 0`** → **Stage 1 retry-once**:

  ```
  # Tear down everything (preflight panes + any spawned troopers); KEEP _consult/.
  "$CLAUDE_PLUGIN_ROOT/bin/consult-teardown.sh" "$CONSULT_TOPIC" 2>/dev/null || true
  SPAWN_RETRY_COUNT=1
  log_info "Stage 1: spawn failed (cold start?); retrying preflight + parallel spawn once"
  ```

  Then re-run Step 3a (preflight) and re-issue the N parallel spawn calls.
  Most cold-start failures (codex / opencode auth handshake on first call)
  are absorbed at Stage 1 invisibly.

- **At least one fails AND `SPAWN_RETRY_COUNT == 1`** → **Stage 2 partial-success offer**:

  Determine which troopers succeeded vs failed by checking each
  commander's state-dir:

  ```
  declare -a SUCCEEDED FAILED
  for entry in "${TROOPERS[@]}"; do
    IFS=$'\t' read -r prov cmdr <<<"$entry"
    if [[ -f "$TOPIC_DIR/$cmdr-$prov/pane.json" ]]; then
      SUCCEEDED+=( "$cmdr ($prov)" )
    else
      FAILED+=( "$cmdr ($prov)" )
    fi
  done
  ```

  If `${#SUCCEEDED[@]} -lt 2`, force abort: only one trooper alive, the
  protocol requires N≥2. Run teardown + `rm -rf "$TOPIC_DIR"` + exit 1
  with a message redirecting to ask Claude directly (matches the existing
  N=1 plain-exit semantics from `consult-init.sh`).

  Otherwise, ask the user:

  ```
  AskUserQuestion:
    question: "${#SUCCEEDED[@]}/$N troopers spawned after retry.
               Successes: ${SUCCEEDED[*]}. Failures: ${FAILED[*]}.
               Proceed degraded with N=${#SUCCEEDED[@]} or abort all?"
    options:  "Proceed degraded" / "Abort all"
  ```

  - **Proceed degraded** — rewrite `_consult/troopers.txt` to drop the
    failed entries (atomic tmp+mv), update the conductor's `$N` and
    `$TROOPERS` array to match the surviving roster, run
    `bin/consult-teardown.sh` to clean preflight orphan panes (the
    teardown extension from v0.19.0 handles this), then continue to
    Step 4 with N=${#SUCCEEDED[@]}.

    ```
    # Rewrite troopers.txt
    TMP=$(mktemp)
    for entry in "${TROOPERS[@]}"; do
      IFS=$'\t' read -r prov cmdr <<<"$entry"
      [[ -f "$TOPIC_DIR/$cmdr-$prov/pane.json" ]] && printf '%s\t%s\n' "$prov" "$cmdr" >> "$TMP"
    done
    mv "$TMP" "$TOPIC_DIR/_consult/troopers.txt"

    # Reload TROOPERS + N
    mapfile -t TROOPERS < <(cw_consult_load_troopers "$TOPIC_DIR/_consult/troopers.txt")
    N=${#TROOPERS[@]}
    log_info "Stage 2: proceeding degraded with N=$N"

    # consult-teardown's preflight-orphan extension cleans the failed sentinels
    "$CLAUDE_PLUGIN_ROOT/bin/consult-teardown.sh" "$CONSULT_TOPIC" 2>/dev/null || true
    ```

  - **Abort all** — full teardown + exit 1:

    ```
    "$CLAUDE_PLUGIN_ROOT/bin/consult-teardown.sh" "$CONSULT_TOPIC" 2>/dev/null || true
    rm -rf "$TOPIC_DIR"
    exit 1
    ```

  Set task `3b` → `completed` only on Stage 1 success or Stage 2
  "Proceed degraded" → continued to Step 4. Otherwise task `3b` stays
  `pending`.

### Step 4 — Parallel research dispatch (N-aware)

Set task `4` → `in_progress`.

Issue `N` parallel Bash tool calls in a single message — one per entry
in `TROOPERS`. Each call: `bin/consult-research-send.sh "$CONSULT_TOPIC"
<commander> <provider>`. Sends complete in <1s, so foreground is fine.
(See canonical N-aware examples in the "## Steps" preamble — substitute
`consult-research-send` for `<verb>`.)

Set task `4` → `completed`.

### Step 5 — Parallel research wait (N-aware, with question loop)

Set task `5` → `in_progress`.

Background-await protocol: wait-scripts run as background tasks so Master
Yoda's pane stays interactive while troopers work. Each wait-script writes
`FS=<state>` to its per-commander state file before exit and touches a
`.done` sentinel; the controller reads both on the harness's completion
notification.

If trooper questions storm the pane (e.g. mis-classified critical questions
that should have been auto-answered from findings), there is a kill switch:
see the Intervention patterns block at the end of this directive for
`CW_CONSULT_SKILL_OVERRIDE=none`.

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
  command='"$CLAUDE_PLUGIN_ROOT/bin/consult-research-wait.sh" "$CONSULT_TOPIC" wolffe  opencode',
  run_in_background: true,
  description='master yoda await commander wolffe research (background)'
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
   and consider the malformed-findings re-prompt recovery (see Intervention
   patterns) before proceeding.
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
c. Classify as critical / non-critical (same rules as the
   critical-question relay in Intervention patterns)
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
- Any `failed` / `timeout` / `malformed` → consider the
  malformed-findings re-prompt (see Intervention patterns) before
  proceeding; set task `5` → `completed` if accepting the degraded
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
<commander> <provider>`. (See canonical N-aware examples in the "## Steps"
preamble — substitute `consult-verify-send` for `<verb>`.)

Verify scope (v0.15.0): each trooper verifies the **union of bucket
files NOT containing this trooper** — i.e. claims nobody-else, the
other-trooper-only set, and any pair-overlaps that don't include this
trooper. `consult-verify-send.sh` computes the scope from
`_consult/troopers.txt` automatically.

### Step 8 — Parallel verify wait (N-aware, with question loop)

Set task `8` → `in_progress`.

This step reuses the **Step 5 wait-template wholesale** (background
dispatch, completion-notification loop, question-handling
critical-question relay re-arm). Apply these 4 verify-specific
differences:

1. **Script prefix:** invoke `bin/consult-verify-wait.sh` (not
   `consult-research-wait.sh`).
2. **State variable:** parse `^VS=` (not `^FS=`).
3. **State file:**
   `STATE_FILE="$TOPIC_DIR/_consult/verify-<commander>.txt"`.
4. **Question-loop findings source:** for `VS=question`, read
   `$TOPIC_DIR/<commander>-<model>/verify.md` (not `findings.md`) into
   `$FINDINGS_PATH` before invoking the critical-question relay
   (see Intervention patterns).

Description strings should embed `verify` instead of `research`
(e.g. `master yoda await captain rex verify (background)`).

If **all** troopers report all-UNCERTAIN verdicts, consider the
all-UNCERTAIN verify re-prompt (see Intervention patterns).
Otherwise set task `8` → `completed`.

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

**Resolve PENDING items in the intermediate artifact
`_consult/adjudicated.md`** (5-section: Consensus / Cross-verified /
Contested / Refuted / Pending). This is NOT the final design-doc —
Step 12 walk-assemble produces that from per-section drafts and the
6/8-section shape differs. Do not grep for `## Contested` in the
final design-doc; it only exists in the adjudicated intermediate.

**MANDATORY first step — `Read("$TOPIC_DIR/_consult/adjudicated.md")`.**
Bash `cat` does not satisfy the Edit tool's per-path read tracker;
Edit calls below will be rejected with "File has not been read yet"
without this Read first.

Then for every line beginning `- PENDING:`:

a. Note `[citation]` + claim.
b. Read the cited source (file or WebFetch URL). Reading other files
   does NOT invalidate adjudicated.md's edit tracker — that single
   Read above covers all step (d) Edit calls in this loop.
c. Decide CONFIRMED / REFUTED / CONTESTED.
d. Edit tool to rewrite (still inside `_consult/adjudicated.md`):
   - CONFIRMED / REFUTED: replace `- PENDING:` with the verdict + evidence.
   - CONTESTED: move under `## Contested`, drop the prefix.

When no `^- PENDING:` remains in `_consult/adjudicated.md`, set task `9`
→ `completed`. Step 11's per-section walk consumes the resolved
adjudicated.md (along with synthesis seed drafts) to populate design-doc
sections.

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
  # v0.30.0: corpus swap — use adjudicated.md (cross-verified findings) instead of
  # topic.txt (raw user input). Catches sub-repos that emerged during research.
  # Falls back to topic.txt if adjudicated.md is missing (defensive only; should
  # not happen in normal Step 9 → Step 10 sequencing).
  if [[ -f "$TOPIC_DIR/_consult/adjudicated.md" ]]; then
    HITS=$(cw_consult_detect_multi_repo "$PWD" "$(cat "$TOPIC_DIR/_consult/adjudicated.md")")
  else
    log_warn "[step 10] adjudicated.md missing; falling back to topic.txt"
    HITS=$(cw_consult_detect_multi_repo "$PWD" "$(cat "$TOPIC_DIR/_consult/topic.txt")")
  fi
fi
```

If `$HITS` is empty (no sibling matches OR --targets was set):
- single-repo path. Write `_consult/multi-repo.txt = single` if not already
  present. Skip the AskUserQuestion confirmation.

If `$HITS` has **exactly 1 line** (one sub-repo target — the common
"hub-with-one-affected-sub-repo" case):
- Issue `AskUserQuestion`:
  - Question: "Topic targets sub-project `<slug>` (detected from sibling
    repos). Use it as the single sub-repo target, or treat as hub-level
    work?"
  - Header: `Target`
  - Options: `Use <slug>` (recommended) / `Treat as hub-level`
- On `Use <slug>`: write `_consult/targets.txt` from `$HITS`
  + `_consult/multi-repo.txt = single-sub`. `bin/consult-walk-assemble.sh`
  will emit the singular `**Target Sub-Project:** <slug>` header so
  `/clone-wars:deploy` redirects target_cwd / branch / state into the
  sub-repo (v0.10.0 mechanism).
- On `Treat as hub-level`: write `_consult/multi-repo.txt = single`. No
  targets.txt.

If `$HITS` has **2+ lines** (multi-repo topic candidates):
- Issue `AskUserQuestion`:
  - Question: "Detected multi-repo topic candidates: <slug list>. Use
    these as targets, edit, or proceed single-repo?"
  - Options: `Use auto-detected list` / `Edit list` / `Proceed single-repo`
- On `Use auto-detected list`: write `_consult/targets.txt` from `$HITS`
  + `_consult/multi-repo.txt = multi`.
- On `Edit list`: AskUserQuestion (free-form) for the edited slug list
  (comma-separated). Validate each against `${CW_SLUG_REGEX_BASE}` and
  re-prompt on rejection. Write `targets.txt` + `multi-repo.txt = multi`
  for 2+ slugs, or `multi-repo.txt = single-sub` if the user edits down
  to exactly 1 slug.
- On `Proceed single-repo`: write `_consult/multi-repo.txt = single`. No
  targets.txt.

Set task `10` → `completed`.

### Step 11 — Per-section design walk

Set task `11` → `in_progress`.

**Setup.** Run `bin/consult-synthesize.sh` to produce SEED DRAFTS under
`$TOPIC_DIR/_consult/design-doc/.draft/<section>.md`. (Note: in v0.17.0
synthesize emits seeds, NOT a final design-doc — assembly happens in Step 12.)

Set the trust-label envs first (`CW_PATH_LABEL` was exported in Step 3;
`CW_SOURCE_LABEL` reflects the roster size). Both are consumed by
`bin/consult-synthesize.sh` to stamp seed drafts; the assembled
design-doc inherits the labels via Step 12.

```
case "$N" in
  2) export CW_SOURCE_LABEL="rex+cody cross-verified (N=2)" ;;
  3) export CW_SOURCE_LABEL="rex+cody+wolffe cross-verified (N=3)" ;;
  *) export CW_SOURCE_LABEL="cross-verified (N=$N)" ;;
esac

CW_SOURCE_LABEL="$CW_SOURCE_LABEL" CW_PATH_LABEL="$CW_PATH_LABEL" \
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
3. **Critical-section skip block.** If `$key` is `goal`, `architecture`,
   `testing`, or `success-criteria`, the AskUserQuestion options DO NOT
   include `Skip` (all four are required by `cw_deploy_audit_doc` —
   skipping any of them would force a Step 12 audit FAIL and bounce the
   user back into a walk↔audit retry loop). Banner: "This section is
   required by cw_deploy_audit_doc; Skip not available — pick Approve
   or Revise."
4. **Draft loop:**
   - REVISE_COUNT=0
   - Yoda reads `$TOPIC_DIR/_consult/adjudicated.md`,
     `$DRAFT_DIR/$key.md` (the seed from synthesize), and the matching
     trooper's `findings.md`/`verify.md`. **Use the Read tool** for
     `$DRAFT_DIR/$key.md` specifically (NOT `cat` via Bash) — the
     Approve step below uses the Write tool, which requires its target
     path to have been Read at least once in this session before
     overwriting an existing file. Synthesize already wrote the 6
     single-repo sections, so this Read is mandatory for those.
   - For multi-repo + `key=architecture`: also reads `targets.txt`; drafts
     `### <slug>` subsections (one per target).
   - For multi-repo + `key=execution-dag`: drafts a soft DAG using
     `cw_consult_emit_soft_dag` from a TSV that Yoda constructs based on
     trooper findings about cross-repo dependencies. (User can re-edit
     during Revise.)
   - Yoda presents the draft in chat (markdown formatting preserved).
   - `AskUserQuestion` (3 options for non-critical sections, 2 for critical):
     - **Approve** → use the **Write tool** to overwrite
       `$DRAFT_DIR/$key.md` with the approved draft body. (Step 4's
       Read tool call above satisfies the Write-tool's
       Read-before-overwrite prereq for the 6 single-repo sections that
       synthesize seeded; the 2 multi-repo extras
       `execution-dag` + `cross-repo-notes` don't have prior seeds, so
       Write creates them fresh.) Break draft loop, advance to next `i`.
     - **Revise** → AskUserQuestion: "What should change?" (free-form).
       Fold response into draft. REVISE_COUNT++. Re-loop to present.
       - If REVISE_COUNT == 4 (i.e., user picked Revise four times):
         AskUserQuestion: "Revise loop has hit the cap (3 revisions).
         Force-approve current draft / Skip (not available for goal,
         architecture, testing, success-criteria) / Abort consult."
         Force-approve writes the last presented draft.
     - **Skip** (non-critical only — i.e. NOT goal/architecture/testing/
       success-criteria) → write `_(skipped)_` to `$DRAFT_DIR/$key.md`,
       break draft loop, advance.

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
(slug = lowercased drill topic with spaces as hyphens). Drilldowns
persist in the archive as supplemental context for the user (Yoda may
also reference them when re-walking sections during Step 11).

```
DRILL_DIR="$TOPIC_DIR/_consult/drilldowns"
mkdir -p "$DRILL_DIR"

# v0.20.2: derive the design-doc path so each drilldown invocation can
# point its trooper at the right source. Same UTC-day session is the
# normal drill cadence; midnight-edge case errors with "no design-doc at"
# and is intentionally not glob-fallback'd (see spec risk assessment).
SLUG="${CONSULT_TOPIC#consult-}"
DESIGN_DOC=$(cw_consult_design_doc_canonical_path "$TOPIC_DIR/_consult" "$SLUG")
[[ -f "$DESIGN_DOC" ]] || { log_error "no design-doc at $DESIGN_DOC; cannot drill"; exit 1; }
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
     - For other 2-trooper rosters (e.g. claude+opencode → cody+wolffe), use
       the actual commanders from `TROOPERS` rather than the literal
       names above.

   - **N=3** (7 options): 3 singles + 3 pairs + 1 fan-out.
     - `rex (codex)` / `cody (claude)` / `wolffe (opencode)`
     - `rex + cody` / `rex + wolffe` / `cody + wolffe`
     - `all three (parallel)`

   → `$DRILL_TROOPER=<choice>`

4. Invoke the drill bin script. `bin/consult-drilldown.sh` accepts at
   most 2 trooper pairs per invocation (arg counts: 7 = single trooper,
   8 = single + sub-project, 9 = two troopers, 10 = two + sub-project).
   To fan out to 3 troopers, issue **multiple parallel** drill calls.

   Argument shape: 5 fixed args (`<topic> <drill-topic> <dd-dir>
   <focus> <design-doc-path>`) followed by `K ∈ {1, 2}` pairs of
   `<commander> <provider>`, optionally followed by a sub-project token.

   Single trooper (`K=1`, 7 args):
   ```
   "$CLAUDE_PLUGIN_ROOT/bin/consult-drilldown.sh" \
     "$CONSULT_TOPIC" "$DRILL_TOPIC" "$DRILL_DIR" "$DRILL_FOCUS" \
     "$DESIGN_DOC" \
     <commander> <provider>
   ```

   Two troopers in parallel (`K=2`, 9 args) — covers N=2 "both" or any
   N=3 pair (`rex + cody`, `rex + wolffe`, `cody + wolffe`):
   ```
   "$CLAUDE_PLUGIN_ROOT/bin/consult-drilldown.sh" \
     "$CONSULT_TOPIC" "$DRILL_TOPIC" "$DRILL_DIR" "$DRILL_FOCUS" \
     "$DESIGN_DOC" \
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
     "$DESIGN_DOC" \
     rex codex cody claude

   # Bash tool call 2 (parallel) — third trooper
   "$CLAUDE_PLUGIN_ROOT/bin/consult-drilldown.sh" \
     "$CONSULT_TOPIC" "$DRILL_TOPIC" "$DRILL_DIR" "$DRILL_FOCUS" \
     "$DESIGN_DOC" \
     wolffe opencode
   ```
   Treat the run as success if at least one of the two invocations
   returned `rc=0`. The 3 produced files share the same `<slug>` so
   they're recognizable as a single drill round in the archive.

5. Read the produced drilldown file(s) under `$DRILL_DIR/_scratch/` —
   filename pattern `drilldown-<slug>-<commander>.md` (slug = lowercased
   `$DRILL_TOPIC` with spaces as hyphens) — and print a brief summary of
   findings to the user. The script's exit codes:
   - `rc=0` if at least one trooper produced a non-empty drilldown
   - `rc=1` if all troopers timed out / errored / produced empty files
   - `rc=2` on bad args
6. If `rc=1` (all troopers timed out / errored), `AskUserQuestion`:
   "Drill returned no findings. Retry / Different trooper / Skip and continue?"
   - Retry: re-invoke with same args.
   - Different trooper: re-prompt step 3, then re-invoke.
   - Skip and continue: fall through to step 7.
7. `AskUserQuestion`: "Drill another aspect?" Options: `Yes` / `No — proceed to teardown`.

Drilldowns are part of the archive (`_consult/drilldowns/`) and remain
available to the user as supplemental context after teardown.

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
echoed by `bin/consult-walk-assemble.sh`).

Then point the user at the next step explicitly. The audit gate
guarantees the doc is deploy-ready:

- **Single-repo** (most cases): suggest
  `/clone-wars:deploy <path-to-design-doc>` to dispatch implementation
  to a trooper with plan/implement/self-verify + cross-verify loop.
- **Multi-repo** (`multi-repo.txt = multi`): suggest
  `/clone-wars:deploy <path-to-design-doc>` — `/clone-wars:deploy` v0.20+
  auto-detects multi-repo design docs via the `**Target Sub-Project(s):**`
  header + `## Execution DAG` section and dispatches per sub-repo
  through its DAG wave loop.

Set task `16` → `completed`.

## Intervention patterns

Reference for failure modes the conductor handles inline. Diagnose
first; don't generalize. Each item names the trigger and the recovery
shape; the conductor adapts the exact commander/model/sentinel paths.

### Pattern 1: Malformed findings re-prompt
When `research-<commander>.txt` shows `FS=malformed`: `cw_send` a
"reformat your findings with [citation] prefixes" prompt, reset the
offset (`bin/consult-offset-reset.sh`), re-arm the research-send +
background research-wait, then re-run `bin/consult-diff.sh`. Wait
mechanics mirror Step 5's notification handler.

### Pattern 2: All-UNCERTAIN verify re-prompt
When every verify verdict is UNCERTAIN: `cw_send` a "read the cited
source and re-grade" prompt, reset the offset, re-arm verify-send +
background verify-wait, then re-run `bin/consult-adjudicate.sh` and
overwrite (or merge) `adjudicated.md`.

### Pattern 3: Critical-question relay
When a wait reports `FS=question` or `VS=question`: read
`_consult/question-<commander>.txt`, classify (critical →
`AskUserQuestion`; non-critical → Yoda answers), `cw_send --from
master-yoda` the ANSWER line, remove the `.done` sentinel, and
re-arm the wait in background. N troopers may emit independently;
process notifications as they land.

**Kill switch:** set `CW_CONSULT_SKILL_OVERRIDE=none` to disable
autonomy hints if the question protocol misbehaves. Send-scripts then
append an empty hint and troopers use their default behavior.
