# Clone Wars Hardening — Design Spec

**Date:** 2026-04-26
**Author:** Conductor session, post-v0.0.3
**Scope:** 14 fixes derived from a full audit of `bin/*`, `lib/*`, `config/*`. Three of the original 17 audit findings (cwd-disappears edge case, 1s polling latency, `--all` non-interactive TTY) were dropped as low-impact nits.

## Goal

Harden Clone Wars from "works in a controlled tracer-bullet flow" to "robust against real-world edge cases" without expanding the surface area. Every fix targets a concrete failure mode observed during testing, audit, or a hypothetical-but-plausible misuse path.

## Non-goals

- New features (no MCP server, no worktree integration, no tier routing)
- Provider expansion (still claude/codex/gemini)
- API/CLI breaking changes (existing slash command syntax stays compatible)

## Architecture: phased rollout

Three phased PRs. Each phase ends in a version bump, codex adversarial review of the implementation plan, smoke test, and `/plugin update`. Stopping after any phase still leaves the runtime in a strictly-better state than before.

| Phase | Version | Items | Theme |
|---|---|---|---|
| 1 | `v0.0.4` | #1 #2 #3 #4 #5 | Critical correctness + safety |
| 2 | `v0.0.5` | #6 #7 #8 #9 #10 #11 | IPC correctness + DRY |
| 3 | `v0.0.6` | #12 #13 #17 | Polish |

Per-phase budget: tests included where the regression cost is high (per-fix discretion, not exhaustive coverage). Tests are added to `tests/` and registered via `tests/run.sh`.

---

## Phase 1 — `v0.0.4`: Critical correctness + safety

### #1 — Spawn rolls back state dir on bootstrap failure

**Problem.** `bin/spawn.sh:154` kills the failed pane but leaves the state directory in place. Next spawn for the same `<commander, topic>` is blocked by `cw_commander_in_use`, forcing a manual teardown. Observed in production: rex's first spawn timed out and required `teardown rex triple-test` before retry succeeded.

**Fix.** On the FAIL branch in `bin/spawn.sh`, after `cw_pane_kill_now`, archive the state dir to `archive/<repo-hash>/<topic>/<commander>-<model>-<ts>-FAILED/`. The `-FAILED` suffix is the signal: distinguishes from clean teardown archives, preserves outbox + identity for forensics, frees the state-dir slot.

**Files.** `bin/spawn.sh` (FAIL path), `lib/ipc.sh` (extend `cw_state_archive` to accept an optional suffix).

**Tests.** `tests/test_spawn_rollback.sh`: simulate a spawn failure (e.g., spawn against a model whose binary doesn't exist), assert state dir is gone from `state/`, assert archive entry exists with `-FAILED` suffix, assert immediate respawn succeeds.

### #2 — Commander-name validation

**Problem.** `bin/spawn.sh:65` validates topic against `^[a-z0-9-]+$` but commander is unchecked. Any string is accepted. Consequences: shell-special chars (`|`, `;`, `$`, ` `) inject into `cw_identity_write`'s sed call (`s|{{commander}}|...|g` breaks if name contains `|`), into log messages, into state-dir paths.

**Fix.** Add identical regex check for commander: `^[a-z0-9-]{1,32}$`, performed before any state mutation. Pool membership stays advisory — custom names allowed, just must be syntactically clean.

**Files.** `bin/spawn.sh` (validation block alongside topic check).

**Tests.** `tests/test_spawn_validation.sh`: assert rejection of `evil|payload`, empty string, 33-char string, `name with spaces`. Assert acceptance of `rex`, `dual-saber`, `cody123`.

### #3 — Persist model in `pane.json` (replace dir-name parser)

**Problem.** `bin/send.sh:37`, `bin/list.sh:42`, `bin/collect.sh:39`, `bin/teardown.sh:60,116` all parse `<commander>-<model>` from the directory name with `${name##*-}`. Implicit constraint: model keys must be hyphen-free. Codex/claude/gemini are dashless today; the day someone adds `claude-haiku` or `codex-mini`, every parse breaks.

**Fix.** Persist `"model"` field in `pane.json` (written by `cw_pane_meta_write` at spawn). All consumers read model from pane.json. Parser fallback retained for backward-compat: if `pane.json` lacks `model`, fall back to dir-name parse and emit `log_warn` once per script invocation (cached in a guard variable) so the user gets one heads-up message per command, not one per trooper iterated.

**Files.** `lib/ipc.sh` (`cw_pane_meta_write` adds the field, new `cw_pane_meta_model` reader), `bin/send.sh` `bin/list.sh` `bin/collect.sh` `bin/teardown.sh` (replace dir-parse with reader call, fallback path retained).

**Tests.** `tests/test_pane_meta.sh`: write pane.json with hyphenated model key, assert `cw_pane_meta_model` returns it correctly. Backward-compat: pane.json without `model` field returns dir-parsed value.

### #4 — Medic checks `pane-border-status`

**Problem.** `bin/medic.sh:54-66` warns if `pane-border-format` is missing the `@cw_label` reference but doesn't check whether `pane-border-status` is set to `top` or `bottom`. User can have format set with status=off and see zero labels while medic prints OK. The warning's fix message mentions both lines, but the test is single-sided.

**Fix.** Add a sibling check: read `pane-border-status`. WARN if not in `{top, bottom}`, sharing the same fix message that already mentions `set -g pane-border-status top`.

**Files.** `bin/medic.sh` (one new check block).

**Tests.** `tests/test_medic.sh` covers medic flows; extend with a fake tmux that returns `pane-border-status off`, assert WARN.

### #5 — Shell-injection fence on `$ARGUMENTS`

**Problem.** Every `commands/*.md` directs Claude to run `"${CLAUDE_PLUGIN_ROOT}/bin/spawn.sh" $ARGUMENTS` with `$ARGUMENTS` unquoted. If a user types `/clone-wars:spawn rex codex foo; rm -rf /`, the conductor expands `$ARGUMENTS` and bash sees the chained command before our regex validation runs. The conductor IS the user, so risk is low — but it's a real footgun if a malicious file/PR gets pasted into the prompt.

**Fix.** Each `commands/*.md` writes `$ARGUMENTS` to a temp file (`mktemp -t cw-args-XXXXXX`), then invokes `bin/<verb>.sh --args-file <temp_path>`. The bin script reads the file with `read -ra TOKENS < "$args_file"` (which shell-tokenizes one line into a bash array, respecting quotes) and reassigns `set -- "${TOKENS[@]}"` so the rest of the existing arg parser is unchanged. Temp file is `rm -f`'d at the end of the bin script via trap. Existing direct-CLI usage (`bin/spawn.sh rex codex foo`) keeps working — `--args-file` is purely additive.

Choice rationale: temp file over stdin because (a) debuggable (`cat` after failure), (b) no conflict with the conductor's tty, (c) no risk of stdin getting eaten by the spawned TUI.

**Files.** All six `commands/*.md`. All six `bin/*.sh` (add `--args-file` parsing block at top of arg parser).

**Tests.** `tests/test_args_file.sh`: write a temp file with `rex codex foo`, invoke `bin/spawn.sh --args-file <path>`, assert it resolves the same way as `bin/spawn.sh rex codex foo`. Adversarial: write `rex; rm -rf /` to a temp file, assert validation rejects (#2 catches it) AND no shell expansion occurs.

---

## Phase 2 — `v0.0.5`: IPC correctness + DRY

### #6 — `cw_outbox_wait` short-circuits on terminal events

**Problem.** `lib/ipc.sh:107-119` polls for a single named event. If the trooper emits `{event:"error"}` while the conductor is waiting for `ready`, the conductor still waits the full timeout (30s codex / 60s claude) before failing.

**Fix.** Extend `cw_outbox_wait` signature: accepts a list of events. Returns 0 with the matched line on first hit. Existing callers pass `ready` only; `bin/spawn.sh` updated to also watch for `error`, branches differently on which arrived.

**Files.** `lib/ipc.sh`, `bin/spawn.sh`.

**Tests.** `tests/test_outbox_wait.sh`: pre-write `error` line to outbox, assert `cw_outbox_wait commander model topic ready error 30` returns within 1s with the error line.

### #7 — JSON-strict event matching

**Problem.** `bin/collect.sh:51` and `bin/list.sh:48` use substring `grep '"event":"done"'`. A `progress` event whose `note` field contains the literal text `"event":"done"` (e.g., `note: "almost done with the work — event:done"`) would false-match.

**Fix.** Replace with anchored regex: `grep -E '^\{"event":"<name>"[,}]'`. The `^\{"event":"` anchor + the `[,}]` lookbehind for the next character (separator or close-brace for empty payload) is enough JSON-strictness without pulling in `jq` as a dependency.

**Files.** `bin/collect.sh`, `bin/list.sh`, `lib/ipc.sh` (`cw_outbox_wait`'s grep).

**Tests.** `tests/test_event_match.sh`: outbox containing `{"event":"progress","note":"\"event\":\"done\""}` followed by a real `done` line — assert collect's matcher picks the real one and ignores the noisy progress line.

### #8 — Atomic inbox write

**Problem.** `lib/ipc.sh:88-102` does `cat > "$inbox"`, which truncates first then writes. The trooper's `END_OF_INSTRUCTION` sentinel makes single-cycle write-and-read safe, but two `send` calls in quick succession can interleave.

**Fix.** Write to `inbox.md.tmp` then `mv -f` (POSIX rename is atomic when source and dest are on the same filesystem; same dir guarantees this).

**Files.** `lib/ipc.sh` (`cw_inbox_write`).

**Tests.** `tests/test_inbox_atomic.sh`: spawn two background `cw_inbox_write` calls in tight loop, assert reader (running `tail -F` parsed for `END_OF_INSTRUCTION`) never sees a partial file.

### #9 — Archive timestamp collisions

**Problem.** `lib/ipc.sh:42` uses `%Y%m%dT%H%M%SZ` (1s granularity). A teardown→spawn→teardown cycle within one second produces nested archives (because `mv src dst/` semantics when `dst` exists as a directory).

**Fix.** Compute the base archive path with `%Y%m%dT%H%M%SZ` as today, then run a collision-resolution loop: if the path exists, append `-2`, `-3`, ... until unique. Pure-bash, no GNU-date dependency, handles arbitrary collision frequency. (Nanoseconds via `%N` was considered but skipped — macOS doesn't support `%N`, and the counter loop is the safety net regardless.)

**Files.** `lib/ipc.sh` (`cw_state_archive`).

**Tests.** `tests/test_archive_collision.sh`: call `cw_state_archive` twice for the same trooper within the same second; assert both succeed and produce distinct archive paths.

### #10 — Contract-driven bootstrap sleep

**Problem.** `bin/spawn.sh:135-138` hardcodes `claude=12s, *=8s`. The contract abstraction otherwise carries `binary`, `modes`, `ready_timeout_s` per provider. Adding a new provider with slow startup means editing spawn.sh, not contracts.yaml.

**Fix.** Add `bootstrap_sleep_s:` field to each provider in `contracts.yaml` (default 8 if missing). `bin/spawn.sh` reads via new `cw_contract_bootstrap_sleep`. Remove the hardcoded case statement.

**Files.** `config/contracts.yaml` (and the user's installed copy at `~/.clone-wars/contracts.yaml` — flag this in PR description as a manual sync needed for existing installs), `lib/contracts.sh` (new reader function), `bin/spawn.sh` (replace hardcoded case).

**Tests.** Extend `tests/test_contracts.sh`: contract with `bootstrap_sleep_s: 5` returns 5; contract without the field returns the default.

### #11 — Dedup teardown logic

**Problem.** `bin/teardown.sh:49-80` (topic mode) and `:108-132` (commander+topic mode) both implement "find panes → archive → sleep 9 → hard kill" with subtly different conditions. DRY violation; bug-fixing both copies in lockstep is fragile.

**Fix.** Internal helper `_teardown_panes_in_topic <topic> <name1> <name2> ...` where each `nameN` is `<commander>-<model>`. Helper handles the snapshot+banner+sleep+kill flow. Topic mode passes all troopers; 2-arg mode passes one. Ten-line shrink, easier to read.

**Files.** `bin/teardown.sh`.

**Tests.** None new — existing teardown smoke tests (run as part of triple-test cycles) cover the refactor.

---

## Phase 3 — `v0.0.6`: Polish

### #12 — Ready event timestamp at emit time

**Problem.** `lib/ipc.sh:77` bakes `$(date -u +...)` into the identity template at write time, so the trooper's `ready` event reflects spawn-prep time, not actual emit time. Off by 8-30 seconds.

**Fix.** Identity template's "first action" tells the trooper to use `date -u +"%Y-%m-%dT%H:%M:%SZ"` (literal, in their shell command) at echo time. The conductor's substituted text becomes a template-with-placeholder rather than baked-in.

**Files.** `lib/ipc.sh` (one-line heredoc edit).

**Tests.** None — visual inspection of outbox `ts` field.

### #13 — Residual test coverage

**Problem.** After Phase 1/2, most of `lib/ipc.sh`, `lib/contracts.sh`, `lib/state.sh` are exercised. `lib/colors.sh` and `lib/commanders.sh` remain untested.

**Fix.** Add `tests/test_colors.sh` (palette stability for known commanders, default fallback for unknowns) and `tests/test_commanders.sh` (pool parsing skips comments/empties, random-pick excludes globally-used names then falls back to topic-unused).

**Files.** Two new test files. Register in `tests/run.sh`.

### #17 — Palette tweak

**Problem.** `fives` (colour103, steel-blue) and `wolffe` (colour104, periwinkle) are one shade apart in the 256-color terminal palette. Adjacent panes look near-identical.

**Fix.** Move `fives` from colour103 → colour67 (mid-slate, currently used by `dogma`). Move `dogma` from colour67 → colour103 (steel-blue). Net: fives is now slate, dogma is steel-blue, neither adjacent to wolffe. Both retain Morandi character.

**Files.** `lib/colors.sh` (two-line edit).

**Tests.** `tests/test_colors.sh` (added in #13) covers stability.

---

## Codex adversarial review

After `superpowers:writing-plans` produces a phase's plan markdown, dispatch `codex:adversarial-review` against that plan file. The review challenges design decisions and surfaces hidden risks. Findings are addressed inline (or explicitly dismissed with rationale) before implementation begins.

Three reviews total — one per phase. Each review is run in foreground; the conductor decides which findings to action.

## Rollout per phase

1. Branch from `main`: `chore/v0.0.{4,5,6}-{theme-slug}`
2. `superpowers:writing-plans` produces `docs/superpowers/plans/2026-04-26-clone-wars-hardening-phase-{N}.md`
3. `codex:adversarial-review` against that plan
4. Address findings; commit a plan-update if substantive
5. Implement via `superpowers:subagent-driven-development` (per-task subagent + two-stage review)
6. Push branch, open PR
7. User merges
8. Local main sync
9. Tag `v0.0.{N}`, push tag
10. User runs `/plugin update` + `/reload-plugins`
11. Smoke test on `phase{N}-smoke` topic (spawn, send, collect, teardown)
12. Move to next phase

Stopping after any phase leaves the runtime strictly-better than the prior version.

## Out of scope (deferred or rejected)

- **#14 cwd-disappears edge case** — vanishingly rare; conductor working dir disappearing mid-session is "you have bigger problems."
- **#15 1s polling latency** — purely cosmetic; up to 1s extra wait per nudge is invisible to humans.
- **#16 `--all` requires interactive TTY** — only a problem if someone scripts `teardown --all` non-interactively; the slash command is always interactive.

Reopen if real-world usage surfaces them.

## Risks

- **Phase 2's #10 (contract-driven bootstrap)** changes a config schema. Existing installs have `~/.clone-wars/contracts.yaml` from the user-owned copy; the new field `bootstrap_sleep_s:` won't auto-apply. Mitigation: spec defaults to 8s when the field is missing, so existing installs continue working but lose the customizability until they sync their copy. Surface this in the v0.0.5 PR description.
- **Phase 1's #5 (shell-injection fence)** changes the contract between slash-command markdown and bin scripts. If a user has any custom command markdown that calls these scripts, they'd need updating. Mitigation: bin scripts retain backward-compat positional-arg parsing alongside `--args-file`.
- **Phase 1's #3 (model in pane.json)** changes the schema of pane.json. Existing in-flight troopers spawned on v0.0.3 don't have the field. Mitigation: backward-compat dir-name parser fallback with one-time warning.
- **Phase 3's #17 (palette tweak)** is cosmetic but visible — anyone who has come to associate fives with colour103 will see colour67 instead. Acceptable for a polish-tier change.
