# Deploy Single-Turn Trooper Design

## Goal

Collapse `/clone-wars:deploy`'s plan / implement / self-verify trooper hand-offs into one trooper turn per round. Yoda's only re-engagement points are Step 0 (audit + spawn), Step 2.2 (cross-verify), and Step 4 (teardown + archive). Give the trooper a long timeout (default 4hr) so a single autonomous run can plan + implement + self-verify without Yoda's polling tearing it out of flow.

## Success Criteria

- Round 1 of `/clone-wars:deploy` is dispatched as ONE inbox prompt; the trooper writes `plan.md`, makes implementation commits, runs the test suite, and writes `verify-report-1.md` before emitting `done`.
- Fix rounds (2..N) are also single-turn: the trooper addresses each issue in `fix-prompt-N.md`, runs tests, writes `verify-report-N.md`, then emits `done`.
- A single `CW_DEPLOY_TURN_TIMEOUT` env var (default 14400s / 4hr) replaces three legacy timeouts (`CW_DEPLOY_PLAN_TIMEOUT`, `CW_DEPLOY_IMPLEMENT_TIMEOUT`, `CW_DEPLOY_VERIFY_TIMEOUT`) and the inter-bundle `CW_DEPLOY_FIX_TIMEOUT`.
- One state file per round (`turn-cody-N.txt` with `TS=ok|failed|timeout`) replaces the three legacy per-phase state files.
- On `TS=failed` or `TS=timeout`, Yoda silently auto-retries the same prompt once before asking the user. The trooper's prompt encodes resume-awareness so the retry continues from disk state rather than restarting.
- `bin/medic.sh` warns when any of the four deleted env vars are set in the user's environment.
- All cross-verify reads, fix-bundle authoring, the 5-round + 1 exhaustion ceiling, the `[bug]/[regression]/[spec-gap]` taxonomy, the teardown+archive flow, and the spec-audit gates are unchanged.
- Six bin scripts and four lib helpers are deleted; two of each are added in their place. `tests/run.sh` stays green.

## Architecture

Collapse `/clone-wars:deploy`'s per-phase trooper hand-offs (plan / implement / self-verify) into **one trooper turn per round**. Yoda's only re-engagement points are Step 0 (audit + spawn), Step 2.2 (cross-verify), and Step 4 (teardown + archive).

**Three load-bearing principles:**

1. **One inbox per round.** Round 1's inbox tells codex to (a) write `plan.md` via `superpowers:writing-plans`, (b) implement via `superpowers:subagent-driven-development` with commits per task, (c) run full test suite + write `verify-report-1.md` via `superpowers:verification-before-completion`, then emit `done`. Fix-round inboxes tell codex to (a) address each cross-verify issue with commits, (b) re-run full suite + write `verify-report-N.md`, then emit `done`.

2. **Resume-aware prompt template.** The prompt itself encodes resume logic: *"If `plan.md` exists, skip planning. If commits since the last fix bundle indicate partial progress, continue from the next pending task. If `verify-report-N.md` already exists, just re-run the suite and update it."* On auto-retry, Yoda re-dispatches the same prompt — the trooper figures out where it stopped from disk state. No `--resume` flag, no resume-state machinery in Yoda.

3. **Long timeout, single per-round state file.** New env var `CW_DEPLOY_TURN_TIMEOUT=14400` (4hr default; user-overridable). Replaces three separate timeouts (plan=600s, implement=7200s, verify=1200s). Per-round state file `turn-cody-N.txt` carries a single `TS=ok|failed|timeout` line, replacing `plan-cody.txt`, `implement-cody.txt`, and `verify-cody-N.txt`.

**What stays the same:** Yoda's audit step, the spawn flow, the cross-verify reads (`verify-report-N.md` + `test-output-N.log` + `git diff/log` + spot-checks), fix-bundle authoring, `[bug]/[regression]/[spec-gap]` taxonomy, 5-round + 1 exhaustion ceiling, teardown+archive flow.

**What's new:** two new scripts (`deploy-turn-send.sh`, `deploy-turn-wait.sh`), the unified turn prompt-template (round-1 + fix-round variants), an auto-retry-once pattern in the directive, and the resume-on-restart contract for the trooper.

**Out of scope:** changing cross-verify shape, expanding fix-bundle taxonomy, adding audit gates, parallel troopers, worktree isolation.

## Components

**1. Two new bin scripts** (replace six existing ones):

- `bin/deploy-turn-send.sh <topic> <round>` — assembles the per-round inbox prompt, captures pre-send byte offset, calls `bin/send.sh`. For `round=1`, uses `cw_deploy_build_turn_prompt_round1`. For `round>=2`, reads `$ART_DIR/fix-prompt-<round>.md` from disk and wraps it with the fix-turn preamble via `cw_deploy_build_turn_prompt_fix`.
- `bin/deploy-turn-wait.sh <topic> <round>` — sources `lib/ipc.sh`, calls `cw_outbox_wait_since cody codex <topic> <offset> done error $CW_DEPLOY_TURN_TIMEOUT`. Writes `TS=ok|failed|timeout` to `$ART_DIR/turn-cody-<round>.txt` and touches `.done` sentinel.

**2. Six deleted bin scripts:**

- `bin/deploy-plan-send.sh`, `bin/deploy-plan-wait.sh`
- `bin/deploy-implement-send.sh`, `bin/deploy-implement-wait.sh`
- `bin/deploy-verify-send.sh`, `bin/deploy-verify-wait.sh`
- `bin/deploy-fix-send.sh` (folded into `deploy-turn-send.sh` round>=2)

**3. Two new helpers in `lib/deploy.sh`:**

- `cw_deploy_build_turn_prompt_round1 <design> <plan_out> <verify_out>` — emits the round-1 prompt body. Names three skills (`writing-plans`, `subagent-driven-development`, `verification-before-completion`). Includes the resume-aware preamble (*"If `plan.md` exists, skip planning. If commits past the design-doc commit indicate partial progress, continue from the next pending task. If `verify-report-1.md` already exists, just re-run the suite and update it"*).
- `cw_deploy_build_turn_prompt_fix <fix_bundle_path> <verify_out> <round>` — reads the user-authored fix-prompt content from disk, wraps it with: (a) preamble naming `systematic-debugging` for `[bug]/[regression]` items + `writing-plans` for `[spec-gap]` items, (b) "commit per fix" + "re-run full suite" + "write `verify-report-<round>.md`" instructions, (c) the same resume-aware preamble pattern, (d) the `done` event contract.

**4. Four deleted helpers in `lib/deploy.sh`:**

- `cw_deploy_build_plan_prompt`
- `cw_deploy_build_implement_prompt`
- `cw_deploy_build_verify_prompt`
- `cw_deploy_build_fix_prompt`

**5. Single fix-bundle file per round** — `fix-prompt-<round>.md` (no more `-debug` / `-gap` split). The turn-prompt preamble routes issues to the appropriate skill by tag. This kills the inter-bundle wait and `CW_DEPLOY_FIX_TIMEOUT`.

**6. State-file rename** — `plan-cody.txt`, `implement-cody.txt`, `verify-cody-<N>.txt` → single `turn-cody-<N>.txt` with `TS=ok|failed|timeout`. Same `tmp + rename` write pattern.

**7. New env var** — `CW_DEPLOY_TURN_TIMEOUT=14400` (4hr default). Documented in `bin/deploy-turn-wait.sh` header comment + the medic helper-load probe + `commands/deploy.md` env-var section.

**8. `bin/medic.sh` deploy-helpers-load probe** — update the smoke check to call `cw_deploy_build_turn_prompt_round1` instead of the deleted builders, so refactor-breakage surfaces immediately.

**9. `commands/deploy.md` directive** — Steps 1.2 + 1.3 + 2.1 collapse into one new "Step 1 — Run trooper turn" block. Step 3 (fix dispatch) simplifies to "write fix-prompt-N.md, increment ROUND, loop back to turn-send/wait." Auto-retry-once logic added to the turn-wait failure branches.

## Data Flow

**1. Round 1 dispatch** (after audit + spawn):

```
commands/deploy.md Step 1
  → bin/deploy-turn-send.sh $TOPIC 1
       └─ cw_deploy_build_turn_prompt_round1 design.md plan.md verify-report-1.md
       └─ capture pre-send byte offset → turn-cody-1.txt (OFFSET=N line)
       └─ bin/send.sh cody $TOPIC @inbox-prompt
  → bin/deploy-turn-wait.sh $TOPIC 1   (background)
       └─ cw_outbox_wait_since done|error  CW_DEPLOY_TURN_TIMEOUT (default 14400)
       └─ write TS=ok|failed|timeout to turn-cody-1.txt
       └─ touch turn-cody-1.done
  → harness completion notification → directive reads TS=
```

Trooper, inside its pane, runs: resume-check → write `plan.md` (if missing) → implement (commits per task) → run `tests/run.sh` (tee to `test-output-1.log`) → write `verify-report-1.md` → emit `{"event":"done"}`.

**2. Auto-retry-once on TS ∈ {failed, timeout}:**

```
if RETRY_COUNT == 0:
  log "auto-retry round=$ROUND attempt=2"
  rm -f turn-cody-$ROUND.txt turn-cody-$ROUND.done
  re-dispatch turn-send + turn-wait   (same prompt — trooper sees disk, resumes)
  RETRY_COUNT = 1
else:
  AskUserQuestion (Hand-off / Abort / Try-again)
```

**3. TS=ok → Step 2.2 cross-verify** (Yoda's reads unchanged):

Yoda reads `verify-report-$ROUND.md`, `test-output-$ROUND.log`, `git log/diff $BRANCH_BASE..HEAD`, spot-checks ≤3 hunks. Writes `cross-verify-$ROUND.md` with `VERDICT: PASS|FAIL`.

**4. PASS → Step 4 teardown + archive.**

**5. FAIL, `ROUND <= MAX_ROUNDS`:**

Yoda authors `$ART_DIR/fix-prompt-$((ROUND+1)).md` from `cross-verify-$ROUND.md` issues (user-authored, single file — no `-debug`/`-gap` split). Then:

```
ROUND=$((ROUND + 1))
RETRY_COUNT=0
loop back to bin/deploy-turn-send.sh $TOPIC $ROUND
```

**6. Fix-round dispatch:**

```
bin/deploy-turn-send.sh $TOPIC $ROUND   (ROUND >= 2)
  └─ reads fix-prompt-$ROUND.md
  └─ cw_deploy_build_turn_prompt_fix wraps with:
       • "Use systematic-debugging for [bug]/[regression], writing-plans for [spec-gap]"
       • "Commit per fix; re-run full suite; write verify-report-$ROUND.md"
       • Resume-aware preamble
       • done-event contract
  → inbox.md → bin/send.sh → wait → notification → cross-verify
```

**7. Trooper resume contract** (lives in the prompt template, not Yoda):

> *Round 1*: "Check whether `<art-dir>/plan.md` exists; if yes, skip planning. Check `git log <branch-base>..HEAD` for commits past the design-doc commit; if any, identify the next pending task from `plan.md`'s checkbox state. If `verify-report-1.md` exists, re-run tests and update it."
>
> *Fix rounds*: "Check `git log` for commits since the prior round; if some issues from `fix-prompt-$ROUND.md` already have addressing commits, identify which remain. If `verify-report-$ROUND.md` exists, re-run tests and update it."

The trooper makes the resume decision inside its own pane; Yoda doesn't probe disk state on retry.

**8. Step 4 teardown + archive** unchanged.

## Error Handling

**1. `bin/send.sh` failure during dispatch** — `deploy-turn-send.sh` exits non-zero, leaving the state file with only `OFFSET=`. The directive treats no `TS=` line as `TS=failed` (consistent with current per-phase scripts) and triggers the auto-retry-once path.

**2. Trooper crashes mid-turn (no `done` event before timeout)** — wait-script writes `TS=timeout`. Auto-retry kicks in. Trooper's resume contract handles partial state on retry. If the second attempt also times out, `AskUserQuestion (Hand-off / Abort / Try-again)`.

**3. Trooper emits `error` event** — wait-script writes `TS=failed`. Auto-retry kicks in. The `error` event's `message` field is left in the outbox for Yoda to surface in the AskUserQuestion if the second attempt fails too.

**4. `verify-report-N.md` missing after `TS=ok`** — trooper emitted `done` but didn't write the verify report. Treat as `TS=failed` (the spec contract is "emit done only after writing verify-report-N.md"). Auto-retry; the resume contract tells the trooper to re-run tests + write verify-report-N.md.

**5. `plan.md` missing in round 1 after `TS=ok`** — same shape: treat as `TS=failed` and retry.

**6. Resume-on-retry races** — if the trooper is mid-write when the retry fires, the new inbox.md write could land while codex is still processing the previous turn. Mitigation: `bin/deploy-turn-send.sh` checks whether `cody-codex/status.json` shows `state != idle` and refuses with a clear error ("trooper not idle; previous turn still in flight"). The directive surfaces this as `AskUserQuestion (Wait 60s and retry / Force-retry / Abort)`.

**7. Auto-retry exhaustion (2 attempts failed)** — `AskUserQuestion`:
- *Hand off* — write `RESUME.md` with topic dir + branch + last cross-verify; preserve the cody pane (don't teardown). User attaches manually.
- *Abort* — `bin/deploy-teardown.sh` + `bin/deploy-archive.sh`, exit.
- *Try again* — reset `RETRY_COUNT=0`, dispatch one more attempt; if that fails, ask again.

**8. Backward compatibility** — existing `_deploy/` directories with `plan-cody.txt` / `implement-cody.txt` / `verify-cody-N.txt` from prior runs are pre-archive; they don't get re-read. The new directive only looks for `turn-cody-N.txt`. No migration needed; `deploy-archive.sh` archives whatever's in `_deploy/`.

**9. `CW_DEPLOY_FIX_TIMEOUT` removal** — env var is gone (the inter-bundle wait it gated no longer exists). If any user has it set, it's silently ignored — log a warning in medic when detected so users can clean up their env.

**10. `CW_DEPLOY_PLAN_TIMEOUT` / `CW_DEPLOY_IMPLEMENT_TIMEOUT` / `CW_DEPLOY_VERIFY_TIMEOUT` removal** — same treatment: medic warns if any of the three legacy env vars is set, instructing the user to use `CW_DEPLOY_TURN_TIMEOUT` instead.

## Testing

**1. New `tests/test_deploy_turn_send.sh`** — unit coverage for `bin/deploy-turn-send.sh`:

- Round 1 happy path — calls round-1 prompt builder, writes `OFFSET=N` to `turn-cody-1.txt`, calls `bin/send.sh` (stub).
- Round >=2 reads `fix-prompt-N.md` from disk and wraps with fix-turn preamble; missing `fix-prompt-N.md` → exit non-zero with clear error.
- `status.json` not idle → refuses with the "trooper not idle" error.
- Bad args (missing topic, non-numeric round) → exit 2.

**2. New `tests/test_deploy_turn_wait.sh`** — parameterized integration test (mirrors current `tests/test_deploy_wait_scripts.sh` shape):

- Synthetic outbox with a `done` event past `OFFSET` → `TS=ok` written + `.done` sentinel touched.
- Synthetic outbox with `error` → `TS=failed`.
- No event before timeout → `TS=timeout` (use `CW_DEPLOY_TURN_TIMEOUT=2` for fast test).
- Sentinel + state file are atomic (tmp + rename).

**3. New `tests/test_deploy_turn_helpers.sh`** — unit coverage for new lib helpers:

- `cw_deploy_build_turn_prompt_round1` — emits END_OF_INSTRUCTION; mentions all three skills; includes the resume preamble; references the design/plan/verify paths.
- `cw_deploy_build_turn_prompt_fix` — reads a sample `fix-prompt-N.md`, wraps it correctly; mentions both routing skills + commit/test/verify-report instructions; includes resume preamble.

**4. Delete obsolete tests:**

- `tests/test_deploy_plan_send.sh`, `tests/test_deploy_implement_send.sh`, `tests/test_deploy_verify_send.sh`, `tests/test_deploy_fix_send.sh`
- `tests/test_deploy_wait_scripts.sh` (parameterized over plan/implement/verify — replaced by `test_deploy_turn_wait.sh`)

**5. Update `tests/test_deploy_helpers.sh`** — replace assertions on the four deleted prompt builders with assertions on the two new ones. Branch override / git-repo gate / audit / branch-create tests are unchanged.

**6. Update `tests/test_deploy_init.sh`** — unchanged; init.sh's argv parsing isn't affected.

**7. Update `tests/test_deploy_archive.sh`** — unchanged; archive logic is unaffected.

**8. New `tests/test_deploy_v07_dogfood.sh`** — manual gate (skipped from `tests/run.sh`, mirrors current `tests/test_deploy_v070_dogfood.sh`):

- Spawn cody, dispatch round 1 turn against a small fixture spec, confirm `plan.md` + commits + `verify-report-1.md` all land before `done`.
- Force a `TS=timeout` mid-implement (kill the codex pane manually), confirm auto-retry fires, confirm trooper resumes from `git log` rather than re-planning.
- Cross-verify FAIL → fix-prompt-2.md → second turn → confirm fix-round resume contract works (commits past last fix bundle are skipped).

**9. `bin/medic.sh` deploy-helpers-load probe** — already updated to call `cw_deploy_build_turn_prompt_round1`. Add a smoke test in `tests/test_medic.sh` that asserts the medic output mentions "deploy helpers load clean" after the refactor.

**10. Test suite invariant** — `tests/run.sh` discovers `test_*.sh`; new test files use the same `set -euo pipefail` discipline + `cw_assert_*` helpers. No new test framework.
