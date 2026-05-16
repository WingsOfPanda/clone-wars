# /clone-wars:deep-research — resume handler (3.b)

> **Do not invoke directly.** This file is referenced by
> `hooks/user-prompt-submit-active-session.sh` when an active session
> is detected. Yoda reads it via the Read tool to load the handler
> logic on each chat-triggered turn.

You are mid-session as the deep-research advisor. An active-<session-id>.txt exists
in some `_deep-research/` state dir under `$CLONE_WARS_HOME/state/`.
Before responding to the user, run the steps below in order.

## Handler 3.b steps

### Step 1 — Read state baseline

Use the Bash tool with the lib helpers preloaded:

```bash
source ${CLAUDE_PLUGIN_ROOT}/lib/log.sh
source ${CLAUDE_PLUGIN_ROOT}/lib/state.sh
source ${CLAUDE_PLUGIN_ROOT}/lib/consult.sh
source ${CLAUDE_PLUGIN_ROOT}/lib/deep-research.sh
```

Resolve ART_DIR by reading the active-<session-id>.txt that the hook surfaced:
- Topic slug: from the hook's `topic:` field.
- ART_DIR: from the hook's `Active state:` field.

Read:
- `$ART_DIR/scoreboard.md`
- For each commander in `$ART_DIR/troopers.txt`: `$ART_DIR/troopers/<cmdr>/state.txt` (via `cw_deep_research_trooper_state_read`)
- `$ART_DIR/halt.flag` (existence check)
- `$ART_DIR/time-budget.txt`, `$ART_DIR/session-start.txt`
- Recent `<task-notification>` messages in this turn's context

### Step 2 — Hard-cap check

If `$ART_DIR/halt.flag` exists OR `cw_deep_research_check_time_budget` returns true:

1. Invoke `bin/deep-research-finalize.sh "$TOPIC_SLUG"`.
2. Call `TaskStop` on each task ID in `$ART_DIR/monitor-tasks.txt`.
3. Jump to Phase 5 synthesis (use `bin/deep-research-teardown.sh` to archive after synthesis).
4. End turn.

### Step 3.a — Process queued notifications

For each `<task-notification>` in this turn's context, route by event type. Initialize `RAN_SCORE=0` and `LAST_CMDR=`/`LAST_EXP=` accumulators before the loop; Step 3.b reads them.

- **done | error** → run `bin/deep-research-score.sh "$TOPIC"`. This iterates all per-trooper experiments, appends scoreboard rows, and sets state.txt `phase=idle` for each commander whose `current_exp_id` has a `result.json` on disk (v0.28.1 fix). If the exit code is 0, set `RAN_SCORE=1`; record `LAST_CMDR=<cmdr>` and `LAST_EXP=<exp-id>` from the `<task-notification>` event JSON (`trooper` field + `summary`-derived `exp-NNN`). Do NOT render the status brief here — Step 3.b handles that once.
- **question** → surface the trooper's question to user in chat; set `cw_deep_research_trooper_state_write "$ART_DIR" "<cmdr>" phase=blocked`. Do NOT auto-dispatch — wait for user direction.
- **stale** → send `status?` probe via `bin/send.sh "<cmdr>" "$TOPIC" "status? brief update on current experiment please"`. Set `phase=stale, probe_sent_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)`. Debounce: skip if `probe_sent_ts` was already set within `LIVENESS_STUCK_S` window.
- **stuck** → use Yoda judgment. Either abort (Ctrl-C trooper pane via tmux, set `phase=failed`) or extend (clear `probe_sent_ts`, give more time).
- **heartbeat** → just update `last_event_ts` via `cw_deep_research_trooper_state_write`. No further action.

### Step 3.b — Render status brief once (v0.28.2)

If `RAN_SCORE=1` (at least one done/error event was successfully scored in Step 3.a), render the status brief exactly once before continuing to Step 4:

```bash
cw_deep_research_render_status_brief "$ART_DIR" "$LAST_CMDR" "$LAST_EXP"
```

Print the helper's output verbatim to chat as your next message. Skip this step if `RAN_SCORE=0` (e.g. only heartbeat/question/stale events fired) — there's no new structured state worth surfacing. If `score.sh` exited non-zero in Step 3.a, `RAN_SCORE` stays 0 and the brief is skipped (no half-baked status).

When multiple done events queue in the same turn, the brief still fires only once — the loop in Step 3.a calls `score.sh` per event, but `LAST_CMDR`/`LAST_EXP` are overwritten by each so the final values name the most-recently-processed event. Single status snapshot per turn, not N×.

### Step 4 — Completion check

```bash
cw_deep_research_check_completion "$ART_DIR/scoreboard.md" "$ART_DIR/metric.md"
```

Read the TSV signal block:

```
floor_met=yes|no
target_met=yes|no
K_so_far=<int>
K_required=<int>
plateau=yes|no
```

Apply Yoda's decision policy:

**Hard rules (no judgment):**
- `floor_met=no` AND no hard cap → keep going.
- `hard_cap=yes` OR `halt.flag` present → stop (go to Step 2).

**Soft rules (Yoda judgment):**
- All floor + target + K satisfied → **default stop**. Override if variance suspicious or user asked to keep exploring.
- Floor met + plateau detected + target not met → **default stop**. Override to pivot direction or request user input.

If decision = stop, touch halt.flag with reason text, jump to Step 2.

### Step 5 — Dispatch round

For each trooper where `phase=idle` AND halt.flag absent:

1. Compose a 1-2 sentence direction (~50 tokens max) informed by:
   - `$ART_DIR/session-summary.md` (Recent decisions, Current direction)
   - `$ART_DIR/scoreboard.md` recent rows
   - Topic + metric
   This is "direction not plan" — see Section 1 architectural principle.
2. Compute next EXP_ID: read current `exp_counter` from state.txt, increment, format `exp-NNN`.
3. Dispatch:
   ```bash
   ${CLAUDE_PLUGIN_ROOT}/bin/deep-research-experiment-send.sh \
     "$TOPIC" "<cmdr>" "$EXP_ID" "<approach-label>" "<short direction>"
   ```
4. The dispatch script updates state.txt to `phase=working, current_exp_id, exp_counter+1`.

### Step 6 — Handle user message

If this turn was triggered by a user message (not solely a notification):

- **Halt intent** ("stop", "halt", "we're done", "end research", "call it"):
  ```bash
  echo "user-halted at $(date -u +%H:%M:%SZ)" > "$ART_DIR/halt.flag"
  ```
  Jump to Step 2.
- **Direction-change intent** ("focus on Y for rex", "stop exploring X"):
  Record in `session-summary.md` Recent decisions section. Factor into Step 5's next direction.
- **Extension intent** ("extend by 2 hours"):
  Update `$ART_DIR/time-budget.txt` (add seconds) + `$ART_DIR/session-start.txt` (refresh).
- **False-positive guard**: if halt phrase appears with negation ("don't stop"), ignore. When uncertain, ask: "Halt now? (yes/no)".
- **Other**: respond conversationally with status awareness (mention current state from session-summary).

### Step 7 — Update session-summary.md

```bash
cw_deep_research_render_summary "$ART_DIR" > "$ART_DIR/session-summary.md.tmp"
# Yoda manually appends/edits "Current direction" + "Recent decisions" sections via Write tool.
mv "$ART_DIR/session-summary.md.tmp" "$ART_DIR/session-summary.md"
```

The mechanical sections (Status, Scoreboard top 5, Completion check, Recent events) are rendered by the helper. Yoda fills in "Current direction" (1-3 sentence strategy note) and "Recent decisions" (last 5 dispatches with one-line rationale each) via Write tool atomic replacement.

### Step 8 — End turn

Emit a chat message summarizing what just happened (one paragraph max), then stop. Future trooper events fire fresh turns; future user messages also fire fresh turns and re-enter at Step 1.

## End of handler
