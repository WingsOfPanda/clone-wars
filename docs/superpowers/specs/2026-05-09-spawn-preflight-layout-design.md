# Spawn Preflight Layout — Design Doc (v0.19.0)

**Status:** approved 2026-05-09. Implementation pending.

## Problem

`/clone-wars:consult` currently spawns N=2 or N=3 troopers via N parallel
`bin/spawn.sh` invocations, each of which calls `tmux split-window`. Two
linked bugs surface from this design:

1. **Sequential spawn despite parallel calls.** `bin/spawn.sh:156-165` reads
   `_consult/<topic>/.last_pane` to decide which pane to split, then writes
   its own pane back. The N parallel processes race-and-serialize on this
   shared file: trooper 1 splits Yoda's pane, writes `.last_pane`; trooper
   2 reads `.last_pane`, down-splits trooper 1; trooper 3 reads
   `.last_pane`, down-splits trooper 2. The user observes panes appearing
   one-at-a-time even though the conductor emitted them in parallel.

2. **Uneven pane heights.** `cw_pane_spawn_down` calls `tmux split-window
   -v -t <prior>`, which splits the prior pane in half. After T1
   (right-split Yoda), Yoda has 50% width. After T2 (down-split T1), T1
   has 25% height. After T3 (down-split T2), T2 has 12.5% height. Each
   trooper gets a smaller pane than its predecessor.

The user reported both symptoms during dogfood: "tmux pane is split into
one, and into two, and into three, this cause the split tmux panes not
evenly large too."

## Goal

Replace the prior-pane chaining mechanism in the consult spawn path with
a two-phase **pre-allocate, then dispatch** architecture:

- Preflight phase splits N panes upfront in a single bash process,
  applies `tmux select-layout main-vertical` (Yoda left, troopers stacked
  right with even heights), and writes deterministic
  `<commander>↔<pane_id>` mappings.
- Dispatch phase fires N truly-independent `bin/spawn.sh --target-pane`
  calls in parallel; each respawns into its pre-assigned pane via
  `tmux respawn-pane`. No shared mutable state between spawn processes.

`/clone-wars:deploy`'s single-trooper spawn path is unchanged
(backwards compat).

## Architecture

```
[Phase 1: preflight — single bash process]
conductor calls bin/preflight-layout.sh <topic> <N>
       │
       ▼
   tmux split × N (off Yoda's pane)
   tmux select-layout main-vertical
   sentinel banner per pane (colored, identifies commander)
       │
       ▼
   _consult/preflight-panes.txt   (ordered: <commander>\t<pane_id> per line)

[Phase 2: dispatch — N parallel processes]
conductor issues N parallel bin/spawn.sh --target-pane <id> calls
       │
       ▼
   tmux respawn-pane × N (each into its pre-assigned pane)
       │
       ▼
   sentinel banners replaced by trooper TUIs
   troopers boot in parallel; cw_outbox_wait per trooper
```

Key properties:

- **No `.last_pane` reads/writes on the preflight path** — the new code
  path is independent of legacy state. Legacy path (deploy) continues to
  use `.last_pane` byte-equal to today.
- **Deterministic commander↔pane ordering** — preflight writes
  `preflight-panes.txt` in roster order; the visual layout maps left→top→
  bottom in the same order.
- **True parallel dispatch** — each `bin/spawn.sh --target-pane` process
  reads its target pane from preflight-panes.txt (read-only) and calls
  `tmux respawn-pane`. No file the spawn processes share is written
  during dispatch.

## Components

### NEW `bin/preflight-layout.sh`

Signature: `preflight-layout.sh <topic> <N>` (rc=0 on success, rc≠0 on
failure with full rollback).

Behavior:

1. Read `_consult/troopers.txt` (TSV `<provider>\t<commander>` per line);
   verify line count matches `<N>` (defensive — guards against
   troopers.txt drift between init and preflight).
2. Capture Master Yoda's pane ID via
   `tmux display-message -p '#{pane_id}'` (the pane the conductor is
   running in).
3. Source `lib/colors.sh` and `lib/tmux.sh` for `cw_color_for` /
   `cw_label_fmt` / `cw_pane_label_set`.
4. For each trooper in roster order (1-indexed):
   - Compute the sentinel command — a colored banner script that prints
     `<rank>-<commander>:<provider>:<topic> — preflight pane reserved,
     awaiting trooper spawn…` using `cw_label_fmt` formatting, then
     `sleep infinity`.
   - First iteration: `tmux split-window -P -F '#{pane_id}' -h -t
     <yoda_pane> <sentinel_cmd>` (right-split Yoda).
   - Subsequent iterations: `tmux split-window -P -F '#{pane_id}' -v -t
     <prev_pane> <sentinel_cmd>` (down-split the previous trooper pane).
   - Capture the new pane ID; stamp `@cw_label` / `@cw_color` /
     `@cw_label_fmt` via `cw_pane_label_set`.
   - Append `<commander>\t<pane_id>` to a temp file
     `preflight-panes.txt.tmp`.
5. After all N panes are created, run `tmux select-layout -t <yoda_pane>
   main-vertical` to redistribute the right column to even heights.
   `main-pane-width` is left at tmux's default unless an env override
   `CW_PREFLIGHT_MAIN_WIDTH` is set (e.g. `60`).
6. Atomic rename: `mv preflight-panes.txt.tmp _consult/preflight-panes.txt`.
7. Print the pane IDs (one per line) to stdout for the conductor's logs.

Rollback (atomic):

- Maintain a list of created pane IDs in shell-local memory.
- Trap `ERR` and `EXIT` (when rc≠0): for each created pane, run
  `tmux kill-pane -t <pane_id> 2>/dev/null || true`; remove
  `preflight-panes.txt.tmp` if present; do not write
  `preflight-panes.txt`.

Why split-then-relayout instead of pre-computing geometry: tmux's
`select-layout main-vertical` produces correct even-height columns
regardless of the split order, and is one line. Pre-computed custom
layout strings exist (`tmux select-layout <layout-string>`) but are
fragile to terminal-size changes.

### `bin/spawn.sh` gains `--target-pane <id>`

New flag, additive. When set:

1. Validate strictly: `<id>` must appear in
   `_consult/preflight-panes.txt` for `<topic>`. If not, exit 1 with
   `log_error "--target-pane <id> not in preflight-panes.txt for topic
   <topic>"`. The validation enforces the preflight-then-spawn discipline
   and prevents accidental respawn into Yoda's pane or another topic's
   trooper pane.
2. Verify `<id>` is alive (`cw_pane_alive`); if not, exit 1.
3. Skip the entire `.last_pane` read/write block (lines 156-165 of
   today's `bin/spawn.sh`).
4. Use a new helper `cw_pane_respawn <id> <commander> <model> <topic>
   <launch> [<cwd>]` from `lib/tmux.sh` instead of
   `cw_pane_spawn_right` / `cw_pane_spawn_down`.
5. Continue with the existing bootstrap-sleep, identity-write,
   pane-send, and outbox-wait flow.

Without `--target-pane`, behavior is byte-equal to today (legacy
split-window + `.last_pane` flow preserved for /clone-wars:deploy and
any future single-trooper callers).

### NEW `cw_pane_respawn` in `lib/tmux.sh`

```sh
# cw_pane_respawn <pane_id> <commander> <model> <topic> <launch_cmd> [<cwd>]
# Replaces the sentinel banner in <pane_id> with <launch_cmd>; re-stamps
# @cw_label / @cw_color / @cw_label_fmt. Honors <cwd> via tmux respawn-pane's
# current-working-directory inheritance — caller is responsible for ensuring
# the respawn-pane runs `cd <cwd>` if a custom cwd is needed (the launch_cmd
# string can wrap with `cd <cwd> && exec <binary>` if necessary).
cw_pane_respawn() {
  local pane="$1" commander="$2" model="$3" topic="$4" launch="$5" cwd="${6:-}"
  local cmd="$launch"
  if [[ -n "$cwd" ]]; then
    cmd="cd '$cwd' && exec $launch"
  fi
  tmux respawn-pane -k -t "$pane" "$cmd"
  cw_pane_label_set "$pane" "$commander" "$model" "$topic"
  printf '%s\n' "$pane"
}
```

`tmux respawn-pane -k` kills the running command (the sentinel
`sleep infinity`) and starts a new one in the same pane geometry. The
existing `cw_pane_label_set` re-stamps user-options.

### `commands/consult.md` Step 3 rewrite

Today's Step 3 emits N parallel `bin/spawn.sh <commander> <provider>
<topic>` calls in one message, then handles `SPAWN_RETRY_COUNT` rollback.

The rewrite splits Step 3 into two sub-phases:

- **Step 3a — preflight:** single foreground bash call to
  `bin/preflight-layout.sh "$CONSULT_TOPIC" "$N"`. On rc=0 the conductor
  reads `_consult/preflight-panes.txt` into a `PREFLIGHT_PANES`
  associative array (commander → pane_id). On rc≠0 → Stage 1 retry
  (preflight is part of the retry budget; full teardown + re-run).
- **Step 3b — parallel dispatch:** N parallel `bin/spawn.sh` calls, each
  with `--target-pane "${PREFLIGHT_PANES[$cmdr]}"`. Same retry semantics:
  if any rc≠0 → Stage 1 (rollback all + retry preflight + retry N
  spawns); if retry fails → Stage 2 partial-success AskUserQuestion.

The directive's existing illustration of "issue N parallel Bash tool
calls in a single message" is preserved; only the per-call argument
shape changes (additional `--target-pane` flag).

### Stage 2 partial-success handling

When `SPAWN_RETRY_COUNT == 1` AND the second attempt also has at least
one failure:

1. Determine which troopers succeeded vs failed by checking each
   commander's state-dir (`<commander>-<model>/pane.json` exists +
   bootstrap completed).
2. AskUserQuestion: "M/N troopers spawned. Successes: <list>. Failures:
   <list> (<reason>). Options: Proceed degraded with N=M / Abort all?"
3. On "Proceed degraded":
   - Rewrite `_consult/troopers.txt` to drop failed entries (atomic
     `mv` via temp file).
   - Update conductor's `$N` and `$TROOPERS` array to match.
   - Tear down only the failed troopers' panes (preflight panes that
     never received a successful respawn).
   - Continue to Step 4 with the reduced roster.
   - If `M < 2` (only one trooper succeeded), force "Abort all" — N=1
     plain-exits with redirect to ask Claude directly per existing
     consult-init.sh contract.
4. On "Abort all": teardown surviving troopers via
   `bin/consult-teardown.sh`, `rm -rf "$TOPIC_DIR"`, exit 1.

### `bin/consult-teardown.sh` extension

Today: reads `troopers.txt` and tears down each listed trooper's pane.

v0.19.0 extension: also reads `preflight-panes.txt` (if present) and
kills any pane in it that is NOT in `troopers.txt`. This handles two
cases:

- Stage 2 partial-success aborted with surviving preflight sentinels
- Preflight succeeded but spawn never started (e.g. user Ctrl-C between
  Step 3a and Step 3b)

Implementation: 5-10 lines added to teardown.sh. No contract change for
callers.

## Data flow

| File | Writer | Readers | Lifetime |
|---|---|---|---|
| `_consult/troopers.txt` | `consult-init.sh` (today) + Stage 2 partial-success rewrite (new) | conductor, preflight-layout.sh, every step's roster iteration, consult-teardown.sh | full consult |
| `_consult/preflight-panes.txt` | `bin/preflight-layout.sh` (NEW) | conductor (Step 3b dispatch), `bin/spawn.sh --target-pane` validation, `bin/consult-teardown.sh` orphan cleanup | full consult |
| `<topic>/.last_pane` | `bin/spawn.sh` legacy path | `bin/spawn.sh` legacy path | unchanged from today; not touched on preflight path |

## Backwards compatibility

- `bin/spawn.sh` without `--target-pane` is **byte-equal** to today
  (the entire `.last_pane` block remains in place for that codepath).
  All existing tests for spawn.sh's legacy behavior pass unchanged.
- `/clone-wars:deploy`'s single-trooper spawn keeps the legacy path
  (no preflight, no `--target-pane`).
- Pre-v0.19 archived consult dirs lack `preflight-panes.txt`; the
  consult-teardown extension is a no-op when the file is absent.
- No migration script needed.

## Failure modes

| Stage | Failure | Behavior |
|---|---|---|
| Preflight | tmux split fails midway | Trap-driven rollback kills any panes created; preflight-panes.txt not written; rc=1 |
| Preflight | Yoda pane discovery fails (`tmux display-message` empty) | Exit 1 immediately, no panes created |
| Preflight | troopers.txt absent or wrong line count | Exit 1 immediately, no panes created |
| Stage 1 retry | Preflight fails second time | Treat as Stage 2 trigger (preflight-panes.txt writes failed; surviving conductor state may include partial pane creation — teardown via consult-teardown.sh which now handles preflight orphans) |
| Stage 2 | Spawn fails on M of N (M<N) after retry | AskUserQuestion: degrade or abort |
| Stage 2 degraded | M < 2 succeeded | Force abort (degrades to N=1 which the protocol rejects) |
| consult-teardown | preflight-panes.txt exists, troopers.txt does not | Kill all preflight panes, rm preflight-panes.txt |
| Spawn | `--target-pane <id>` not in preflight-panes.txt | Strict reject, rc=1 |
| Spawn | `--target-pane <id>` is dead (killed externally) | Strict reject, rc=1 (do NOT fall back to split-window — that violates the deterministic mapping contract) |

## Testing

Five new tests under `tests/`:

1. **`test_preflight_layout.sh`** — happy paths for N=2 and N=3:
   - Stub tmux session via `tmux new-session -d -s preflight-test`
   - Call preflight-layout.sh with a fake troopers.txt
   - Assert: rc=0, preflight-panes.txt has N lines in commander order,
     each pane_id is alive (`cw_pane_alive`), pane heights are roughly
     even (use `tmux display-message -p '#{pane_height}'` per pane;
     allow ±2 row tolerance for borders), sentinel banners contain
     commander names (capture with `tmux capture-pane -p -t <id>`)

2. **`test_preflight_layout_rollback.sh`** — failure rollback:
   - Inject failure mid-preflight (e.g. by writing a stub tmux that
     fails on the 2nd `split-window` call), verify all created panes
     are killed and preflight-panes.txt is not written

3. **`test_spawn_target_pane_strict.sh`** — flag validation:
   - With valid `<id>` from preflight-panes.txt: respawn succeeds,
     `@cw_label` is set, pane is alive
   - With Yoda's pane ID: rc=1, error message mentions
     "not in preflight-panes.txt"
   - With pane ID from another topic: rc=1
   - With `--target-pane` absent: legacy split-window flow runs
     (regression guard for backwards compat)

4. **`test_consult_teardown_preflight_orphans.sh`** — extended teardown:
   - Set up preflight-panes.txt with 3 entries; troopers.txt with 2
     entries (one preflight orphan)
   - Run consult-teardown.sh; verify the orphan pane is killed and
     preflight-panes.txt is removed

5. **`test_consult_directive_v019_static_wiring.sh`** — directive prose:
   - References `bin/preflight-layout.sh`
   - References `--target-pane`
   - Step 3a + Step 3b headings present
   - Stage 1 / Stage 2 wording present
   - Negative-assert: no `.last_pane` references in consult.md (legacy
     state file should not appear in the consult flow)

Existing tests must remain green:
- All `test_spawn_*.sh` (legacy spawn behavior)
- `test_consult_init_*.sh` (roster precedence)
- `test_medic_*.sh` (no medic surface change)
- `test_deploy_*.sh` (deploy uses legacy spawn flow)
- `test_consult_directive_v017_static_wiring.sh` (will need v0.19.0
  amendment — drop `.last_pane` negative-assert if present, add
  preflight references)

## Success criteria

- [ ] `/clone-wars:consult --use-force` on a 3-trooper run produces
  three evenly-sized trooper panes that all appear within ~2s of the
  preflight call (visually atomic — no "1, then 2, then 3" appearance)
- [ ] All N spawn processes start in parallel; the only serialization
  is at the tmux server's command socket (~50-150ms per respawn-pane,
  not per-bootstrap)
- [ ] Yoda's pane stays at the configured `main-pane-width` (default
  ~50%) — does not shrink as troopers spawn
- [ ] `/clone-wars:deploy` (single-trooper) is byte-equal to v0.18.3 in
  behavior and pane shape
- [ ] All v0.18.3 tests pass without modification
- [ ] Five new v0.19.0 tests pass
- [ ] Stage 2 partial-success path tested manually via dogfood (kill one
  trooper's binary mid-cold-start to force the failure)

## Out of scope

- True per-process parallelism at the tmux server layer (the server
  itself serializes its command socket; this is a tmux fundamental,
  not a Clone Wars design choice). Our parallelism gain is at the
  spawn-process layer.
- Custom pane geometry (`CW_PREFLIGHT_MAIN_WIDTH` env var is mentioned
  but defaulting only; no per-topic config or AskUserQuestion for
  layout).
- Multi-conductor coordination (still out of scope per `docs/DESIGN.md`).
- `/clone-wars:deploy` migration to preflight (single-trooper case
  doesn't benefit from preflight; legacy split-window flow is fine).
- Re-spawn of a dead trooper into its existing pane (would be a v0.20+
  feature — preflight-panes.txt makes it possible but is not required
  for v0.19.0).

## Versioning

- Plugin version: 0.18.3 → **0.19.0** (minor bump)
  - New `bin/preflight-layout.sh` script (additive)
  - New `bin/spawn.sh --target-pane` flag (additive)
  - `commands/consult.md` Step 3 contract changes (visible to anyone
    reading the directive; not a runtime contract change for
    /consult invokers)
  - `bin/consult-teardown.sh` gains a small extension (no caller
    contract change)

- Spec doc: `docs/superpowers/specs/2026-05-09-spawn-preflight-layout-design.md`
- CLAUDE.md status: add v0.19.0 row + strict-dogfood release gate

## Implementation outline (for writing-plans skill)

Approximate task breakdown (the writing-plans skill will produce the
authoritative TDD plan):

1. New `cw_pane_respawn` helper in `lib/tmux.sh` + unit test
2. New `bin/preflight-layout.sh` (happy path) + unit test
3. Preflight rollback (trap-driven) + rollback test
4. `bin/spawn.sh --target-pane` flag with strict validation + flag test
5. `bin/consult-teardown.sh` preflight-orphan extension + test
6. `commands/consult.md` Step 3a + 3b rewrite
7. `commands/consult.md` Stage 2 AskUserQuestion block
8. Static-wiring test for the new directive prose
9. Plugin version bump 0.18.3 → 0.19.0; CLAUDE.md status entry
10. Strict dogfood pass on a real machine (release gate)
