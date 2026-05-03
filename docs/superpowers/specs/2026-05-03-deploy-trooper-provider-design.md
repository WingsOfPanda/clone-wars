# Deploy Trooper Provider Auto-Detect Design

## Goal

Let `/clone-wars:deploy` pick the trooper provider (codex vs claude) automatically based on whether the repo is a Claude Code plugin, with an asymmetric confirmation pattern: codex auto-goes (cheap default); claude requires explicit user consent (token-aware).

## Success Criteria

- `bin/deploy-init.sh` writes `_deploy/auto_provider.txt` containing `claude` if `<repo-root>/.claude-plugin/plugin.json` exists, else `codex`.
- `commands/deploy.md` Step 0 reads `auto_provider.txt`; on `codex` it proceeds without prompting; on `claude` it raises an `AskUserQuestion` (Use claude / Fall back to codex), then writes the chosen value to `_deploy/provider.txt`.
- Step 1.1 spawns `bin/spawn.sh cody "$PROVIDER" "$TOPIC"` (no hard-coded `codex`).
- All downstream steps (turn-send, turn-wait, cross-verify, fix-loop, teardown, archive) work transparently for both providers.
- `lib/deploy.sh` exposes `cw_deploy_detect_provider <repo-root>` returning `claude` or `codex` to stdout.
- `bin/medic.sh`'s deploy-helpers-load probe exercises the new detector helper so refactor breakage surfaces immediately.
- New unit tests in `tests/test_deploy_helpers.sh` cover the detector's positive / negative / no-arg / missing-dir cases.
- Extended `tests/test_deploy_init.sh` covers the auto_provider.txt write for both provider outcomes.
- New static-wiring test `tests/test_deploy_directive_provider.sh` confirms the directive references both state files and uses `$PROVIDER` for the spawn line.
- `tests/run.sh` stays green (existing pre-existing failure unchanged).
- No CLI flag added — the only override is the AskUserQuestion's "Fall back to codex" option.

## Architecture

`/clone-wars:deploy` auto-detects the trooper provider from a single binary signal — presence of `.claude-plugin/plugin.json` at the repo root — and surfaces an asymmetric confirmation: **codex auto-goes (cheap default); claude requires user consent (token-aware)**.

**Three load-bearing principles:**

1. **Single signal, binary decision.** The detector reads exactly one file: `.claude-plugin/plugin.json` at the conductor's `git rev-parse --show-toplevel`. Present → `claude`. Absent → `codex`. No fallback ladder, no other heuristics. Simple, fast, fully auditable.

2. **Asymmetric confirmation = token guard rail.** When auto-detect picks `codex`, the directive proceeds without prompting (cheap; user explicitly chose this design pattern). When it picks `claude`, the directive raises an `AskUserQuestion` with two options: *Use claude (recommended for plugin testing)* / *Fall back to codex (cheaper)*. The user is the only thing standing between an accidental claude-token bill and a deliberate one.

3. **No CLI flag escape hatch.** Per the user's design choice, the only override is the AskUserQuestion's "Fall back to codex" option. Forcing claude on a non-plugin repo (or forcing gemini at all from deploy) is intentionally not supported in v0.9 — it would expand the surface area for negligible benefit. Users who want gemini for deploy can spawn manually via `/clone-wars:spawn cody gemini …` (out of scope for this feature; that's a future enhancement).

**What stays the same:** the spawn flow (`bin/spawn.sh cody <provider> <topic>`), the turn-send / turn-wait / cross-verify / fix-loop machinery (just shipped in v0.8.0), the audit gates, the teardown+archive flow, the per-round state files.

**What's new:** a `cw_deploy_detect_provider` helper in `lib/deploy.sh`, an integration point in `bin/deploy-init.sh` that writes `_deploy/auto_provider.txt`, a confirmation step in `commands/deploy.md` Step 0 that resolves the final `_deploy/provider.txt`, and propagation of `$PROVIDER` through Step 1.1's spawn line.

**Out of scope:** multi-trooper deploys (still 1 trooper), gemini support in auto-detect, configurable detection rules (e.g. user-supplied glob list), per-design-doc provider hints inside the spec.

## Components

**1. New helper `cw_deploy_detect_provider <repo-root>`** in `lib/deploy.sh`:

```bash
# cw_deploy_detect_provider <repo-root>
# Returns "claude" if <repo-root>/.claude-plugin/plugin.json exists;
# else "codex". Single binary signal; no fallback ladder.
cw_deploy_detect_provider() {
  local repo_root="$1"
  [[ -n "$repo_root" ]] || { log_error "cw_deploy_detect_provider: missing repo-root arg"; return 2; }
  if [[ -f "$repo_root/.claude-plugin/plugin.json" ]]; then
    printf 'claude\n'
  else
    printf 'codex\n'
  fi
}
```

**2. `bin/deploy-init.sh` integration:** after the existing audit/branch-create logic completes, call `cw_deploy_detect_provider` against `git rev-parse --show-toplevel` (or `$PWD` if `--no-branch` mode meant we're not in a git repo) and atomically write the result to `$ART_DIR/auto_provider.txt`. The file contains a single line: `claude` or `codex`. The init script's stdout payload (currently the topic name) is unchanged — backward-compatible.

**3. `_deploy/auto_provider.txt`:** what the detector chose. Persisted for audit + dogfood test assertions. Single line, slug-only.

**4. `_deploy/provider.txt`:** what was actually USED (after any user override via the confirmation prompt). The directive writes this in Step 0 after resolving the AskUserQuestion. Read by Step 1.1 to drive the spawn line. Two files (auto vs final) so a future debugger can see both "what we detected" and "what the user picked" without inferring from `git log`.

**5. `commands/deploy.md` Step 0 changes:** after `deploy-init.sh` returns, read `auto_provider.txt`. If `codex` → write `codex` to `provider.txt` and proceed. If `claude` → AskUserQuestion (Use claude / Fall back to codex) → write the chosen value to `provider.txt`.

**6. `commands/deploy.md` Step 1.1 changes:** read `$ART_DIR/provider.txt` into `$PROVIDER`; replace `bin/spawn.sh cody codex "$TOPIC"` with `bin/spawn.sh cody "$PROVIDER" "$TOPIC"`. The TaskCreate row for 1.1 should display the resolved provider in its `activeForm` (`Spawning cody-claude` or `Spawning cody-codex`).

**7. `commands/deploy.md` cross-references:** any prose/comments that say "cody-codex" specifically should switch to "cody-$PROVIDER" or just "the cody trooper" where the provider is irrelevant. Most references already use the latter form (e.g. "the cody pane stays attached"); a sweep confirms no hard-coded "codex" leak.

**8. `bin/medic.sh` deploy-helpers-load probe:** extend the existing probe to also call `cw_deploy_detect_provider /tmp` (which doesn't have `.claude-plugin/plugin.json`, so will return `codex`) — this catches refactor breakage in the new helper.

**9. `tests/test_deploy_helpers.sh` extension:** add 5 assertions for the new helper:
- Returns `claude` when `<repo-root>/.claude-plugin/plugin.json` exists.
- Returns `codex` when it doesn't.
- Returns `codex` when `.claude-plugin/` exists as an empty dir (presence test must be on the file).
- Returns `codex` when `<repo-root>` doesn't exist as a directory.
- Returns rc=2 with clear error when no arg passed.

**10. `tests/test_deploy_init.sh` extension:** add assertions that after init:
- `_deploy/auto_provider.txt` exists with `codex\n` content for a fixture without `.claude-plugin/plugin.json`.
- `_deploy/auto_provider.txt` exists with `claude\n` content for a fixture WITH `.claude-plugin/plugin.json` (touch the file before init).
- File is written via tmp+rename (no partial reads).

## Data Flow

**1. Conductor invokes `/clone-wars:deploy <design-path>`** (Step 0):

```
commands/deploy.md Step 0
  → write args to /tmp/.../deploy.txt
  → bin/deploy-init.sh --args-file /tmp/.../deploy.txt
       └─ existing: derive topic, copy design, create branch
       └─ NEW: REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
       └─ NEW: cw_deploy_detect_provider "$REPO_ROOT" → 'claude' or 'codex'
       └─ NEW: atomic write → $ART_DIR/auto_provider.txt
  → captures topic from stdout (unchanged)
```

**2. Provider confirmation** (Step 0 continues):

```
AUTO=$(cat "$ART_DIR/auto_provider.txt")

case "$AUTO" in
  codex)
    PROVIDER=codex
    log_info "auto-detected provider: codex (default)"
    ;;
  claude)
    AskUserQuestion(
      "This repo has .claude-plugin/plugin.json — Claude is the recommended trooper for plugin testing (it can load slash commands, run hooks, exercise the Claude Code surface natively). It will use claude tokens. Use claude or fall back to codex?",
      options: [
        "Use claude (recommended for plugin testing)",
        "Fall back to codex (cheaper)"
      ]
    )
    PROVIDER=<chosen>
    ;;
  *)
    log_warn "unexpected auto_provider value '$AUTO'; defaulting to codex"
    PROVIDER=codex
    ;;
esac

# Atomic write of the FINAL choice.
printf '%s\n' "$PROVIDER" > "$ART_DIR/provider.txt.tmp"
mv "$ART_DIR/provider.txt.tmp" "$ART_DIR/provider.txt"
```

**3. Spawn** (Step 1.1):

```
PROVIDER=$(cat "$ART_DIR/provider.txt")
"$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" cody "$PROVIDER" "$TOPIC"
```

The spawned trooper is `cody-claude-<topic>` or `cody-codex-<topic>`. Everything downstream (turn-send, turn-wait, cross-verify, fix-loop, teardown, archive) refers to the trooper as "cody" — the per-pane state dir is at `<topic-state>/cody-<provider>/`, so the existing `cw_trooper_dir cody <provider> <topic>` calls still resolve correctly.

**4. Re-invocation on the same topic** (e.g. user runs deploy twice on the same spec):

`bin/deploy-init.sh` currently refuses if `_deploy/` already exists. That gate runs BEFORE provider detection — so the user gets a clear "topic already exists" error and never re-detects. No need to handle "what if auto-detect picked codex on attempt 1 but claude on attempt 2"; the second attempt is blocked entirely.

**5. Auto-retry path** (Step 1, fix-round dispatches): provider is fixed for the duration of the topic — read once from `provider.txt` at Step 1.1 spawn time. Auto-retry doesn't re-detect or re-spawn; it just re-dispatches the same prompt to the existing trooper pane. So `provider.txt` is effectively immutable after Step 0.

**6. Teardown + archive:** `provider.txt` and `auto_provider.txt` move to archive alongside the rest of `_deploy/`. No special cleanup.

## Error Handling

**1. `git rev-parse --show-toplevel` fails** (deploy invoked outside a git repo) — `bin/deploy-init.sh` already errors out earlier via `cw_deploy_branch_create`'s "not inside a git repository" gate (unless `--no-branch` was passed). With `--no-branch`, we still want detection to work; fall back to `$PWD` as the repo root in that case. Detector remains correct: it just checks whether `$PWD/.claude-plugin/plugin.json` exists.

**2. `auto_provider.txt` write fails** (read-only state dir, etc.) — `bin/deploy-init.sh` exits non-zero with `log_error "failed to persist auto_provider.txt"`; the directive surfaces the error to the user. No silent fallback — the artifact-dir is the source of truth for downstream steps.

**3. `auto_provider.txt` contains an unexpected value** (e.g. an old run with stale content, or a manual-edit typo) — Step 0 validates the read against the closed set `{claude, codex}`. On invalid value: log warning, default to `codex`, write the corrected value to `provider.txt`. Defensive but not paranoid; the file is plugin-managed, so corruption is unlikely.

**4. User picks "Fall back to codex"** in the confirmation dialog but codex isn't installed — `bin/spawn.sh` already has the provider-binary check; it'll fail loudly with `cody-codex spawn failed: codex binary not on PATH`. That error surfaces in Step 1.1; the directive offers Abort. We do NOT pre-validate codex availability in Step 0 because:
- Pre-validation would duplicate spawn.sh's check.
- The user would be redirected to medic to fix it anyway.
- Failing at spawn time gives the actual error message in context.

**5. User picks "Use claude" but claude isn't installed** — same shape as #4: spawn.sh fails. Acceptable behavior; user installs claude (`/plugin install claude` or whatever) and re-runs deploy.

**6. `.claude-plugin/plugin.json` exists but is malformed JSON** — irrelevant to detection. We only check file presence, not content. Future detection rules might parse the JSON (e.g. to read a `provider:` hint from the plugin manifest), but v0.9 is presence-only.

**7. Detection happens once per topic; not invalidated on retry** — if a user creates a `.claude-plugin/plugin.json` mid-deploy, it doesn't affect the active run. Provider is locked at Step 0. This is intentional — re-detecting mid-flight would require killing+respawning the trooper, which is out of scope.

**8. Backward compatibility** — existing `_deploy/` directories from before this feature ships have no `auto_provider.txt` or `provider.txt`. Step 0 runs from scratch on each new deploy (init.sh refuses if `_deploy/` exists), so backward-compat is automatic — pre-existing `_deploy/` dirs are either teardown'd or live in the archive, neither of which is reentered.

**9. Medic warns if `.claude-plugin/plugin.json` is malformed** — out of scope. Could be a future medic enhancement (e.g. validate plugin.json shape against the schema) but not for v0.9.

## Testing

**1. New `cw_deploy_detect_provider` assertions in `tests/test_deploy_helpers.sh`:**

- Returns `claude` when `<repo-root>/.claude-plugin/plugin.json` exists (use a temp dir + touch the file).
- Returns `codex` when the file does not exist (clean temp dir).
- Returns `codex` when `<repo-root>/.claude-plugin/` exists as an empty dir (presence test must be on the file, not the parent dir).
- Returns rc=2 with clear error when called with no arg.
- Returns `codex` (not error) when `<repo-root>` doesn't exist as a directory (graceful no-signal case — the auto-detect rule is "file present" not "repo exists").

**2. New `tests/test_deploy_init.sh` assertions** — extend the existing fixture:

- After `bin/deploy-init.sh` runs against a fixture WITHOUT `.claude-plugin/plugin.json`, assert `_deploy/auto_provider.txt` exists with content `codex\n`.
- After `bin/deploy-init.sh` runs against a fixture WITH `.claude-plugin/plugin.json` (touch the file before init), assert content `claude\n`.
- Assert the file is single-line, no trailing whitespace beyond the newline (catch off-by-one in the writer).

**3. Atomic-write verification** — assert that `auto_provider.txt` is written via tmp+rename (no partial reads). Mirror the pattern used by other state-file tests in the suite (`test_deploy_archive.sh` race tests).

**4. Directive-flow integration coverage** — out of automated scope (the directive's AskUserQuestion can't be exercised without a Claude session). But add a static-wiring assertion in a new `tests/test_deploy_directive_provider.sh`:

- `grep -q 'auto_provider.txt' commands/deploy.md` — directive references the auto file.
- `grep -q 'provider.txt' commands/deploy.md` — directive references the final file.
- `grep -q 'AskUserQuestion' commands/deploy.md` near the provider block — directive asks for confirmation when claude.
- `grep -qE 'spawn.sh.*cody.*"\$PROVIDER"|spawn.sh.*cody.*\$PROVIDER' commands/deploy.md` — Step 1.1 uses the variable, not a hard-coded `codex`.
- `! grep -qE 'spawn.sh cody codex ' commands/deploy.md` — no leftover hardcoded `codex` spawn line (allowing matches inside code-comment examples).

**5. Manual dogfood gate update** — extend `tests/test_deploy_v07_dogfood.sh` (or create `tests/test_deploy_v09_dogfood.sh` if you prefer separation per-version) to document a new scenario:

- Run `/clone-wars:deploy <design>` in a non-plugin repo (no `.claude-plugin/plugin.json`); confirm Step 0 picks codex without prompting.
- Run `/clone-wars:deploy <design>` in a plugin repo (clone-wars itself); confirm Step 0 raises the AskUserQuestion. Pick "Use claude" → confirm `cody-claude` pane spawns. Re-run with the same fixture → pick "Fall back to codex" → confirm `cody-codex` pane spawns instead.

**6. `bin/medic.sh` regression** — extend `tests/test_medic.sh` to assert the medic output now includes a clean line for the new probe (`cw_deploy_detect_provider` smoke call). Suggested assertion: `grep -q 'deploy helpers load clean' <medic output>` already passes, but the probe now exercises one more helper — add a comment in the test noting the implicit coverage.

**7. Test-suite invariant** — `tests/run.sh` discovers `test_*.sh`; new test file uses the same `set -euo pipefail` discipline + `cw_assert_*` helpers as existing tests. No new test framework or dependency.
