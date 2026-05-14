---
description: Audit a design doc, dispatch to codex troopers (claude on plugin repos) for plan/implement/self-verify, then cross-verify and fix-loop. Multi-repo DAG-aware (v0.20.0).
argument-hint: [--no-branch] [--branch <n>] [--topic <slug>] [--provider codex|claude] [--max-rounds 5] [<design-doc-path>]
allowed-tools: Bash, Write, Read, Edit, AskUserQuestion, Skill
---

# /clone-wars:deploy

Run a trooper-implements / Yoda-verifies pipeline on `$ARGUMENTS`.

**When to use this command.** Invoke `/clone-wars:deploy` when the user
asks to implement, ship, or execute a design doc produced by
`/clone-wars:consult`. Trigger phrases: "deploy this design", "implement
the spec at <path>", "ship <design-path>", "execute the design-doc",
"spawn troopers for <design>". Single-repo design docs run today's
single-trooper flow; multi-repo design docs (`**Target Sub-Project(s):**`
header + `## Execution DAG` section) automatically route through the
v0.20.0 multi-repo DAG flow.

The cody pane stays attached for the entire run — `tmux select-pane` to watch.

Spec: `docs/superpowers/specs/2026-05-09-deploy-multi-repo-dag-design.md` (v0.20.0 — current);
`docs/superpowers/specs/2026-05-02-clone-wars-execute-design.md` (v0.6 baseline).

## Task list (TaskCreate × N BEFORE step 0)

Create the task list using `TaskCreate`. Single-repo runs uses tasks
0/1.1/1/2/3/4 (N=6, like v0.19.0). Multi-repo runs use tasks
0/3a/3c/3d/4 (N=5 upfront; the 1.1/1/2/3 single-repo tasks are skipped).
Pick one set after Step 0's routing branch decides.

For multi-repo runs, `3b` is intentionally absent from the upfront
table — Step 3b creates one task PER (wave, repo) tuple at runtime
once `dag-waves.txt` is known (v0.23.1+). See Step 3b for the
TaskCreate prose.

| # | subject | activeForm |
|---|---|---|
| 0   | `0   Audit + routing detect [yoda]`               | `Auditing design doc + routing` |
| 1.1 | `1.1 Spawn cody (single-repo)  [yoda]`            | `Spawning cody-${PROVIDER}` |
| 1   | `1   Run trooper turn (round N) [cody]`           | `Cody running turn (round N)` |
| 2   | `2   Cross-verify (round N) [yoda]`               | `Yoda cross-verifying (round N)` |
| 3   | `3   Author fix bundle (if needed) [yoda]`        | `Authoring fix bundle` |
| 3a  | `3a  Preflight pane allocation (multi-repo) [yoda]` | `Multi-repo preflight` |
| 3c  | `3c  Final verification (multi-repo) [yoda]`      | `Multi-repo final verify` |
| 3d  | `3d  Fix-loop (multi-repo) [yoda+troopers]`       | `Multi-repo fix-loop` |
| 4   | `4   Teardown + archive [yoda]`                   | `Tearing down` |

## Steps

The user's `$ARGUMENTS` may contain shell metacharacters. Write it via the
Write tool, then invoke sub-scripts with the resolved values.

### Step 0 — Audit design doc

Set task `0` → `in_progress`.

1. Resolve args path:
   ```
   ARGS_DIR="${CLONE_WARS_HOME:-$HOME/.clone-wars}/_args"
   mkdir -p "$ARGS_DIR"; echo "$ARGS_DIR/deploy.txt"
   ```
2. Parse `--max-rounds <N>` out of `$ARGUMENTS` BEFORE writing the args file.
   The init script rejects unknown flags, so this flag must never reach it.
   Scan `$ARGUMENTS` token-by-token: when you see `--max-rounds`, capture the
   NEXT token into `MAX_ROUNDS_OVERRIDE` (export it for Step 2's loop init)
   and drop both tokens. Write the REMAINING tokens (space-joined) to the
   args file via the Write tool — not `$ARGUMENTS` verbatim.

   Example transformation:
   - `$ARGUMENTS` = `path/to/spec.md --topic foo --max-rounds 3 --no-branch`
   - `MAX_ROUNDS_OVERRIDE` = `3`
   - args-file contents = `path/to/spec.md --topic foo --no-branch`

   If `--max-rounds` is absent, leave `MAX_ROUNDS_OVERRIDE` unset (Step 2
   defaults to 5) and write `$ARGUMENTS` unchanged.
3. Write tool: `file_path` = the path printed in step 1; `content` = the
   filtered argument string from step 2 (or `$ARGUMENTS` verbatim if no
   `--max-rounds` was found).
4. Inspect the args file to detect "no positional .md arg given". If so,
   apply source defaulting (v0.20.0: only the modern audit-passing
   design-doc shape is considered; pre-v0.12 `--design-doc` flag and
   `synthesis.md` fallback are gone):
   ```
   source "$CLAUDE_PLUGIN_ROOT/lib/state.sh"
   REPO_HASH=$(cw_repo_hash)
   STATE_ROOT="${CLONE_WARS_HOME:-$HOME/.clone-wars}"
   CANDIDATE=$(find "$STATE_ROOT/state/$REPO_HASH" \
                 -path '*/_consult/design-doc/*-design.md' \
                 -type f -printf '%T@ %p\n' 2>/dev/null \
                 | sort -n | tail -1 | cut -d' ' -f2-)
   ```
   - If `CANDIDATE` is non-empty, `AskUserQuestion` (options: "Use this",
     "Cancel"). On "Use this", append the path to the args file (so init.sh
     receives it as the positional argument). On "Cancel", exit 0.
   - If `CANDIDATE` is empty and no `.md` path is in the args file, refuse
     with a usage hint and exit 1.
5. Init (init.sh consumes the args file directly — its argv parser handles
   `--no-branch` / `--branch` / `--topic` / `<design-path>`). Capture rc so
   sub-step 5b can intercept multi-repo DAG-parse failures from
   human-authored docs:
   ```
   source "$CLAUDE_PLUGIN_ROOT/lib/state.sh"
   source "$CLAUDE_PLUGIN_ROOT/lib/deploy.sh"
   REPO_HASH=$(cw_repo_hash)
   TOPIC=$("$CLAUDE_PLUGIN_ROOT/bin/deploy-init.sh" \
              --args-file "$ARGS_DIR/deploy.txt" 2>/tmp/cw-init-err) \
              && INIT_RC=0 || INIT_RC=$?
   ```
   When `INIT_RC=0`, jump straight to the post-init block below (TOPIC_DIR /
   ART_DIR / TARGET_CWD lines).

   When `INIT_RC == 7`, run sub-step 5a (dirty-tree intercept, v0.30.0
   item 3) before re-invoking init.sh.

   When `INIT_RC != 0` and `INIT_RC != 7`, run sub-step 5b (DAG rescue
   intercept) before continuing.

5a. **Dirty-tree intercept (v0.30.0).** `bin/deploy-init.sh` exits 7
    when the working tree is dirty (uncommitted changes or untracked
    files in `$TARGET_CWD`). Don't auto-clean — the user's WIP may be
    intentional and unrelated. Fire AskUserQuestion to let them choose:

    ```
    AskUserQuestion:
      Question: "Working tree in <TARGET_CWD> is dirty. Pick a path forward."
      Header:   "Dirty tree"
      Options:
        - "Stash and continue" (Recommended) — git stash push -u; deploy
          proceeds; Step 4 attempts stash pop on success
        - "Commit first as chore: WIP" — git commit -am with chore: WIP
          message; commit lives on feat branch alongside deploy work
        - "Abort" — exit deploy, leave working tree as-is
    ```

    On `Stash and continue`:

    ```
    TARGET_CWD=$(pwd)
    git -C "$TARGET_CWD" stash push -u -m "deploy ${TOPIC:-pending} WIP"
    STASH_SHA=$(git -C "$TARGET_CWD" stash list -1 --format=%H)
    [[ -n "$STASH_SHA" ]] || { log_error "stash push reported success but no stash on list"; exit 1; }
    TOPIC=$("$CLAUDE_PLUGIN_ROOT/bin/deploy-init.sh" \
               --args-file "$ARGS_DIR/deploy.txt" 2>/tmp/cw-init-err) || {
      log_error "init.sh failed on second attempt after stash; popping stash and aborting"
      git -C "$TARGET_CWD" stash pop "$STASH_SHA" 2>/dev/null || \
        log_warn "stash pop failed; SHA $STASH_SHA still in stash list"
      exit 1
    }
    REPO_HASH=$(cw_repo_hash)
    ART_DIR="${CLONE_WARS_HOME:-$HOME/.clone-wars}/state/$REPO_HASH/$TOPIC/_deploy"
    printf 'sha=%s\nmessage=%s\n' "$STASH_SHA" "deploy $TOPIC WIP" \
      | cw_atomic_write "$ART_DIR/pre-deploy-stash.txt"
    log_ok "stashed pre-deploy WIP as $STASH_SHA; will attempt pop in Step 4"
    ```

    On `Commit first as chore: WIP`:

    ```
    TARGET_CWD=$(pwd)
    git -C "$TARGET_CWD" add -A
    git -C "$TARGET_CWD" commit -m "chore: WIP before deploy ${TOPIC:-pending}"
    COMMIT_SHA=$(git -C "$TARGET_CWD" rev-parse HEAD)
    TOPIC=$("$CLAUDE_PLUGIN_ROOT/bin/deploy-init.sh" \
               --args-file "$ARGS_DIR/deploy.txt" 2>/tmp/cw-init-err) || {
      log_error "init.sh failed on second attempt after WIP commit"
      exit 1
    }
    REPO_HASH=$(cw_repo_hash)
    ART_DIR="${CLONE_WARS_HOME:-$HOME/.clone-wars}/state/$REPO_HASH/$TOPIC/_deploy"
    printf 'sha=%s\n' "$COMMIT_SHA" \
      | cw_atomic_write "$ART_DIR/pre-deploy-commit.txt"
    log_ok "committed pre-deploy WIP as $COMMIT_SHA; commit lives on feat branch"
    ```

    On `Abort`:

    ```
    log_error "deploy aborted by user; working tree left dirty"
    exit 0
    ```

5b. **DAG auto-extract (multi-repo, hand-authored docs).** v0.21.0
    introduced this feature; v0.23.0 made it auto-proceed silently when
    the extraction is verifiable. If `bin/deploy-init.sh` exited non-zero
    because the `## Execution DAG` section uses a non-parser-conforming
    prose format (Unicode box diagrams `┌──┐`, narrative wave
    descriptions, etc.) instead of the parser-conforming
    `N. <slug> [(<abs-path>)] — <desc>` lines, Yoda extracts the implicit
    DAG, verifies each line against the on-disk repo layout, writes
    parser-conforming lines into the local copy of the design doc, then
    re-runs the parse + multi-init steps. The auto-proceed path runs
    without confirmation when verification passes; the AskUserQuestion
    safety net fires only when verification fails OR the user opted in
    via `CW_DEPLOY_FORCE_RESCUE_PROMPT=1`. /consult is unchanged — this
    auto-extract path is for human-authored docs only.

    **Sub-step 5b.1 — re-derive TOPIC + ART_DIR.** Init failed before
    printing the topic slug to stdout, so re-derive it from the design
    doc path embedded in the args file:

    ```
    DESIGN_PATH=$(awk '{
      for (i=1; i<=NF; i++) {
        if ($i !~ /^--/ && (i==1 || $(i-1) !~ /^--(branch|topic|provider)$/)) {
          print $i; exit
        }
      }
    }' "$ARGS_DIR/deploy.txt")
    [[ -n "$DESIGN_PATH" ]] || { log_error "rescue: cannot find design path in args file"; cat /tmp/cw-init-err >&2; exit 1; }
    TOPIC=$(cw_deploy_derive_topic "$DESIGN_PATH")
    TARGET_CWD=$(cw_deploy_resolve_target "$DESIGN_PATH" "$(cw_repo_root)") || { log_error "rescue: resolve_target failed"; exit 1; }
    export CW_TOPIC_REPO_CWD="$TARGET_CWD"
    TOPIC_DIR=$(cw_deploy_topic_dir "$TOPIC")
    ART_DIR=$(cw_deploy_art_dir "$TOPIC")
    ```

    **Sub-step 5b.2 — check rescue applicability.** Rescue only fires
    when init failed at DAG parse on a multi-repo doc:

    ```
    if [[ ! -f "$ART_DIR/design.md" ]] \
       || ! grep -qE '^## Execution DAG\b' "$ART_DIR/design.md" \
       || [[ -f "$ART_DIR/dag-waves.txt" ]]; then
      log_error "init failed for a non-DAG-parse reason; rescue does not apply"
      cat /tmp/cw-init-err >&2
      "$CLAUDE_PLUGIN_ROOT/bin/deploy-archive.sh" "$TOPIC" 2>/dev/null || true
      exit 1
    fi
    log_info "DAG section is prose; auto-extracting parser-conforming lines"
    ```

    **Sub-step 5b.3 — Yoda extracts implicit DAG.** Read
    `$ART_DIR/design.md`'s `## Execution DAG` section. Use Yoda's
    judgment to identify wave boundaries (box rows, separator markers
    like `▼`/`then`/`after`/numbered "Wave N" headings), parallel groups
    within a wave (multiple boxes side-by-side), and dependencies
    (sequential waves depend on the previous wave's steps). Cross-
    reference the `## Components` section for absolute paths when the
    DAG section names repos by short label only.

    Format the extracted DAG as parser-conforming lines:

    ```
    1. <SlugA> (/abs/path/to/SlugA) — short description
    2. <SlugB> (/abs/path/to/SlugB) — short description (depends on 1)
    3. <SlugC> (/abs/path/to/SlugC) — short description (depends on 1)
    ```

    Use absolute paths in parens when the sub-repo is nested deeper
    than one level under the conductor's cwd, or when its name has
    CapWords/underscore (which differ from the slug). Omit the parens
    for flat-monorepo siblings of the conductor's cwd.

    **Sub-step 5b.3.5 — verify each extracted line against on-disk repo
    layout (v0.23.0).** Yoda runs three checks per line, accumulating
    failures into an array. If any check fails, the AskUserQuestion in
    5b.4 fires with the specific failure messages cited inline (no
    guessing). If all pass, 5b.4 auto-proceeds without prompting.

    ```
    # EXTRACTED_LINES is the array Yoda built in 5b.3 (one parser-conforming
    # line per element, e.g. "1. ARS-TaskServe (/abs/path) — desc").
    declare -a EXTRACTED_LINES=( … )
    NUM_EXTRACTED_LINES=${#EXTRACTED_LINES[@]}
    declare -a VERIFY_FAILED=()

    for i in "${!EXTRACTED_LINES[@]}"; do
      line_no=$(( i + 1 ))
      line="${EXTRACTED_LINES[$i]}"
      # Parse: "N. <slug> [(<abs-path>)] — <desc>" using the same regex shape
      # as cw_deploy_dag_parse_line (lib/deploy-dag.sh).
      # v0.24.0: parse via cw_deploy_dag_parse_line (single source of truth
      # for the slug regex in lib/deploy-dag.sh). Returns 5-field TSV
      # step\tslug\tabs_path\tdesc\tdeps; map "none" sentinel back to empty.
      if parsed=$(cw_deploy_dag_parse_line "$line" 2>/dev/null); then
        IFS=$'\t' read -r _step slug abs_path _desc _deps <<<"$parsed"
        [[ "$abs_path" == "none" ]] && abs_path=""
      else
        VERIFY_FAILED+=( "line $line_no: regex parse failed: '$line'" )
        continue
      fi
      # 1. slug regex (already passed by the outer parse but assert explicitly).
      if ! [[ "$slug" =~ ^[A-Za-z0-9_-]+$ ]]; then
        VERIFY_FAILED+=( "line $line_no: slug '$slug' invalid (must match [A-Za-z0-9_-]+)" )
        continue
      fi
      # 2. directory exists (use abs_path if given, else flat-sibling fallback).
      if [[ -n "$abs_path" ]]; then
        repo_cwd="$abs_path"
      else
        repo_cwd="$TARGET_CWD/$slug"
      fi
      if [[ ! -d "$repo_cwd" ]]; then
        VERIFY_FAILED+=( "line $line_no: directory not found: $repo_cwd" )
        continue
      fi
      # 3. CLAUDE.md or AGENTS.md present (sub-repo marker file).
      if [[ ! -f "$repo_cwd/CLAUDE.md" && ! -f "$repo_cwd/AGENTS.md" ]]; then
        VERIFY_FAILED+=( "line $line_no: $repo_cwd missing CLAUDE.md/AGENTS.md" )
        continue
      fi
    done

    # Determine status for the audit log + confirm gate.
    if (( ${#VERIFY_FAILED[@]} == 0 )); then
      VERIFY_STATUS="auto-passed"
    else
      VERIFY_STATUS="verification-failed-${#VERIFY_FAILED[@]}"
    fi
    ```

    **Sub-step 5b.4 — auto-proceed OR conditional confirm (v0.23.0).**
    Default behavior is to auto-proceed silently when verification
    (5b.3.5) passed AND the user did not opt into the explicit confirm
    gate via `CW_DEPLOY_FORCE_RESCUE_PROMPT=1`. The AskUserQuestion
    safety net fires only when verification failed OR the FORCE env
    var is set.

    ```
    USER_CHOICE=""
    if (( ${#VERIFY_FAILED[@]} == 0 )) && [[ "${CW_DEPLOY_FORCE_RESCUE_PROMPT:-}" != "1" ]]; then
      # Auto-proceed path — no AskUserQuestion. One log line summarizing
      # which slugs were extracted, so the user has visible confirmation
      # of what's about to run without an interactive stop.
      slug_summary=$(printf '%s\n' "${EXTRACTED_LINES[@]}" | grep -oE '^[0-9]+\. [A-Za-z0-9_-]+' | tr '\n' ' ')
      log_ok "DAG auto-extract: $NUM_EXTRACTED_LINES lines verified ($slug_summary)"
      USER_CHOICE="auto-verified"
    fi
    ```

    If `USER_CHOICE` is still empty after the auto-proceed gate
    (verification failed OR force-prompt env var set), fire
    `AskUserQuestion`. Build the question body so the user sees exactly
    WHAT failed verification (no guessing what to review):

    - When `CW_DEPLOY_FORCE_RESCUE_PROMPT=1` AND verification PASSED:
      prefix the body with `"Force-prompt env var set; verification PASSED.\n\n"`
      and set `VERIFY_STATUS="forced-prompt"`.
    - When verification FAILED: prefix the body with
      `"Auto-extracted DAG from prose section. Verification failed:\n"`
      followed by each `VERIFY_FAILED[i]` entry on its own line, then
      `"\n\n"`.
    - Append `"Lines:\n"` + each `EXTRACTED_LINES[i]` entry on its own line.

    ```
    question: <built per the rules above>
    options:
      - "Looks right — write & retry" (recommended)
      - "Let me edit"
      - "Abort deploy"
    USER_CHOICE = answer  # one of: "Looks right — write & retry" | "Let me edit" | "Abort deploy"
    ```

    On `"Let me edit"`: wait for the user to provide corrected DAG-lines
    via the next chat message; rebuild `EXTRACTED_LINES` from the new
    lines; re-run sub-step 5b.3.5 verification on the corrected lines;
    if those pass, auto-proceed (`USER_CHOICE="edited-passed"`); else
    re-fire `AskUserQuestion` with the new `VERIFY_FAILED` list.

    On `"Abort deploy"`: run `bin/deploy-archive.sh "$TOPIC"` and exit 0.

    **Sub-step 5b.5 — write into design-doc copy.** Use the `Edit` tool
    to insert the confirmed DAG-lines as a new `### DAG Lines`
    subsection under the `## Execution DAG` heading in
    `$ART_DIR/design.md` (the local copy under
    `_deploy/<topic>/`, NOT the user's original source file). Place the
    subsection at the very top of the section (before the prose) so
    `bin/deploy-dag-parse.sh`'s "first lines that match the DAG-line
    regex" loop picks it up. Then write a one-line audit log (extended
    in v0.23.0 with the verification status field):

    ```
    printf 'rescued at %s; choice: %s; lines extracted: %d; verification: %s\n' \
      "$(date -u +%FT%TZ)" "$USER_CHOICE" "$NUM_EXTRACTED_LINES" "$VERIFY_STATUS" \
      > "$ART_DIR/dag-rescue.log"
    ```

    `$VERIFY_STATUS` is one of: `auto-passed` (auto-proceed path,
    verification clean), `forced-prompt` (verification clean but
    `CW_DEPLOY_FORCE_RESCUE_PROMPT=1`), `verification-failed-N`
    (N failures cited in the prompt body).

    **Sub-step 5b.6 — re-invoke parse + multi-init + replay tail.**
    init.sh's tail (target_cwd.txt write, branch-create, auto_provider
    write) must be replayed inline since init.sh aborted before
    reaching them:

    ```
    "$CLAUDE_PLUGIN_ROOT/bin/deploy-dag-parse.sh" "$ART_DIR/design.md" "$ART_DIR" \
      || { log_error "rescue: dag-parse still failed; surfacing parser stderr"; exit 1; }
    "$CLAUDE_PLUGIN_ROOT/bin/deploy-multi-init.sh" "$TOPIC" "$TARGET_CWD" \
      || { log_error "rescue: multi-init failed"; exit 1; }
    printf '%s\n' "$TARGET_CWD" | cw_atomic_write "$ART_DIR/target_cwd.txt"
    ( cd "$TARGET_CWD" && cw_deploy_branch_create "$TOPIC" "" ) \
      || { log_error "rescue: branch-create failed"; exit 1; }
    AUTO_PROVIDER=$(cw_deploy_detect_provider "$TARGET_CWD" "")
    printf '%s\n' "$AUTO_PROVIDER" | cw_atomic_write "$ART_DIR/auto_provider.txt"
    log_ok "DAG auto-extract complete; resuming Step 0 sub-step 6"
    ```

    The rescue is **one-shot per deploy**. If sub-step 5b.6's re-parse
    or multi-init still fails, the directive surfaces the error and
    exits without retry — Yoda's extraction was wrong and a fresh
    `/clone-wars:deploy` invocation is needed (with the user editing
    the design doc by hand to add a `### DAG Lines` subsection).

5c. (post-init) Set TOPIC_DIR / ART_DIR / TARGET_CWD / branch-base for
    downstream steps. Whether init succeeded directly (5) or via the
    rescue (5b), `$ART_DIR` and `$TARGET_CWD` are now valid:
   ```
   TOPIC_DIR=$(cw_deploy_topic_dir "$TOPIC")
   ART_DIR="$TOPIC_DIR/_deploy"
   # Pull TARGET_CWD up here so the branch-base rev-parse below runs in the
   # right working tree. Sub-step 9 logs/re-reads it for downstream steps;
   # this early read is harmless because deploy-init.sh has already written
   # target_cwd.txt by the time it returns.
   TARGET_CWD=$(cat "$ART_DIR/target_cwd.txt")
   # CRITICAL: export so EVERY downstream bin script invocation in this
   # directive (deploy-turn-send, deploy-turn-wait, deploy-archive,
   # deploy-teardown, spawn) inherits it. lib/state.sh's cw_topic_repo_hash
   # honors this var when computing topic-state paths so reads agree with
   # what bin/deploy-init.sh wrote (under the SUB-repo hash, not the HUB).
   export CW_TOPIC_REPO_CWD="$TARGET_CWD"
   # Record branch base for cross-verify diff range (used in Step 2 + Step 4).
   # init.sh creates feat/deploy-<topic> from HEAD on the *trooper's* working
   # tree, so HEAD inside $TARGET_CWD right now IS the commit the new branch
   # was created from — exactly the diff base we want.
   # Do NOT use `git merge-base HEAD main` here: when invoked from a topic
   # branch that already diverged from main, merge-base returns the prior
   # branch's divergence point (over-counting unrelated commits).
   git -C "$TARGET_CWD" rev-parse HEAD > "$ART_DIR/branch-base.sha"
   BRANCH_BASE=$(cat "$ART_DIR/branch-base.sha")
   ```
6. Run audit and persist verdict:
   ```
   source "$CLAUDE_PLUGIN_ROOT/lib/deploy.sh"
   AUDIT=$(cw_deploy_audit_doc "$ART_DIR/design.md" 2>&1) && AUDIT_RC=0 || AUDIT_RC=$?
   printf '%s\n' "$AUDIT" > "$ART_DIR/design-audit.md"
   ```
7. Branch on `AUDIT_RC` — distinguish unreadable doc from FAIL verdict:
   ```
   if (( AUDIT_RC == 2 )); then
     log_error "design-doc unreadable; aborting."
     "$CLAUDE_PLUGIN_ROOT/bin/deploy-archive.sh" "$TOPIC"
     exit 1
   elif (( AUDIT_RC == 1 )); then
     # Audit FAIL — read the design doc yourself, weigh the flagged issues, then:
     # AskUserQuestion (options: "Proceed anyway", "Abort and edit doc").
     # Abort → bin/deploy-archive.sh "$TOPIC" + exit 1
     # Proceed → continue.
     :
   fi
   ```

8. Resolve trooper provider (auto-detect → confirm if claude):

   ```
   AUTO_PROVIDER=$(cat "$ART_DIR/auto_provider.txt")
   ```

   Branch on `$AUTO_PROVIDER`:

   - `codex` → no prompt, just persist:
     ```
     PROVIDER=codex
     log_info "trooper provider: codex (auto-go)"
     ```
   - any other unexpected value (e.g. stale-file corruption) → log warning,
     default to codex without prompting:
     ```
     log_warn "unexpected auto_provider value '$AUTO_PROVIDER'; defaulting to codex"
     PROVIDER=codex
     ```
   - `claude` → AskUserQuestion (the cheap default isn't appropriate for
     plugin repos; ask the user before spending claude tokens):
     ```
     question: "This repo has .claude-plugin/plugin.json — Claude is the
       recommended trooper for plugin testing (it can load slash commands,
       run hooks, exercise the Claude Code surface natively). It will use
       claude tokens. Use claude or fall back to codex?"
     options:
       - "Use claude (recommended for plugin testing)"
       - "Fall back to codex (cheaper)"
     ```
     Set `PROVIDER` to `claude` if user picked "Use claude"; else `codex`.

   Atomically persist the final choice:
   ```
   printf '%s\n' "$PROVIDER" | cw_atomic_write "$ART_DIR/provider.txt"
   ```

9. Re-confirm the target cwd resolved by `deploy-init.sh` and ensure it is
   exported for downstream bin scripts:

   ```
   TARGET_CWD=$(cat "$ART_DIR/target_cwd.txt")
   export CW_TOPIC_REPO_CWD="$TARGET_CWD"
   log_info "trooper target cwd: $TARGET_CWD"
   ```

   Every downstream bin script (`bin/deploy-turn-send.sh`, `bin/deploy-turn-wait.sh`,
   `bin/deploy-archive.sh`, `bin/spawn.sh`, `bin/teardown.sh`) reads
   `$CW_TOPIC_REPO_CWD` (via `lib/state.sh`'s `cw_topic_repo_hash`) to compute
   topic-state paths against the sub-repo's hash — without this export they
   would key off the conductor's `$PWD` (the HUB) and miss the artifacts that
   `deploy-init.sh` wrote under the SUB-repo hash.

   For single-repo deploys (no `Target Sub-Project` header in the design doc),
   `$TARGET_CWD` equals the conductor's cwd — the env var still gets exported
   but resolves to the same hash, so behavior is unchanged. For hub deploys
   with a header, `$TARGET_CWD` is the absolute path to the named sub-repo.
   Step 1.1 passes this to `spawn.sh --cwd`, and Step 2's cross-verify uses
   it as the `git -C` working tree.

**Sub-step 0.X — Capture sibling baseline (v0.30.0 item 2).**

Capture HEAD SHAs of every sibling git repo of the hub that isn't a
declared deploy target. Step 4 will re-read these and surface any
commits that landed on those siblings' main branches during the
deploy (rogue commits — the trooper edited a sub-repo we didn't
create a feature branch in).

```
source "$CLAUDE_PLUGIN_ROOT/lib/deploy.sh"
HUB_CWD=$(cw_deploy_resolve_hub "$ART_DIR/design.md" "$(cw_repo_root)")
TARGETS_CSV=""
if [[ -f "$ART_DIR/multi-repo-targets.txt" ]]; then
  TARGETS_CSV=$(tr '\n' ',' < "$ART_DIR/multi-repo-targets.txt" | sed 's/,$//')
fi
"$CLAUDE_PLUGIN_ROOT/bin/deploy-sibling-baseline.sh" "$ART_DIR" "$HUB_CWD" "$TARGETS_CSV" \
  || log_warn "sibling-baseline.sh failed; Step 4 verify will be skipped"
```

`cw_deploy_resolve_hub` returns the parent dir of all sub-repo targets
for multi-repo OR the repo-root for single-repo (in v0.30.0 both
resolve to repo-root — see lib/deploy.sh). `multi-repo-targets.txt` is
only written by `bin/deploy-multi-init.sh` in the multi-repo path;
single-repo deploys pass an empty CSV. Sibling enumeration produces an
empty baseline file when the hub has no qualifying siblings, in which
case Step 4's verify is a cheap no-op.

Set task `0` → `completed`.

**Routing branch (v0.20.0).** After audit PASS + provider resolution,
read the routing decision written by `bin/deploy-init.sh`:

```
ROUTING=$(cat "$ART_DIR/routing.txt")
log_info "deploy routing: $ROUTING"
```

- If `$ROUTING == "single-repo"`: continue with Steps 1.1, 1, 2, 3, 4
  exactly as v0.19.0 (single-trooper flow, no multi-repo ceremony).
- If `$ROUTING == "multi-repo"`: SKIP Steps 1.1, 1, 2, 3 entirely;
  jump to NEW Step 3a (multi-repo preflight) → Step 3b (DAG wave
  dispatch) → Step 3c (final verification) → Step 3d (fix-loop) →
  Step 4 (teardown, common to both paths).

### Step 1.1 — Spawn cody-$PROVIDER

**Active only when `$ROUTING == "single-repo"`.**

Set task `1.1` → `in_progress`.
```
PROVIDER=$(cat "$ART_DIR/provider.txt")
TARGET_CWD=$(cat "$ART_DIR/target_cwd.txt")
"$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" cody "$PROVIDER" "$TOPIC" --cwd "$TARGET_CWD"
```
Set task `1.1` → `completed`. If spawn fails, archive `_deploy/` and exit.

The `--cwd "$TARGET_CWD"` flag tells `spawn.sh` to launch the trooper TUI
inside `$TARGET_CWD` (via `tmux split-window -c`). For single-repo deploys
this is the conductor's cwd; for hub deploys with a `Target Sub-Project`
header it is the sub-repo path resolved by `deploy-init.sh`.

### Step 1 — Run trooper turn (round-aware, auto-retry-once)

Set task `1` → `in_progress`. Use the same task across rounds; only the
activeForm reflects the round number (e.g. `Cody running turn (round 2)`).

Initialize (only on first entry, NOT on retry):

```
ROUND=1
RETRY_COUNT=0
MAX_ROUNDS="${MAX_ROUNDS_OVERRIDE:-5}"
```

**Dispatch:**

```
"$CLAUDE_PLUGIN_ROOT/bin/deploy-turn-send.sh" "$TOPIC" "$ROUND"
```

If round 1, the script generates the round-1 prompt (plan + implement +
self-verify in one turn). If round >= 2, the script reads
`$ART_DIR/fix-prompt-$ROUND.md` (which Step 3 wrote on the previous round)
and wraps it with the fix-round preamble. **Yoda authors fix-prompt-$ROUND.md
in Step 3 BEFORE incrementing ROUND and re-entering Step 1.**

**Wait (background — Yoda's pane stays interactive):**

```
Bash(
  command='"$CLAUDE_PLUGIN_ROOT/bin/deploy-turn-wait.sh" "$TOPIC" "$ROUND"',
  run_in_background: true,
  description="master yoda await cody round=$ROUND turn (background)"
)
```

Default timeout is 4 hours (`CW_DEPLOY_TURN_TIMEOUT=14400`). Override
with the env var if your topic is unusually large.

**On harness completion notification:**

Read `TS=` from `$ART_DIR/turn-cody-$ROUND.txt`:

```
TS=$(grep '^TS=' "$ART_DIR/turn-cody-$ROUND.txt" | tail -1 | cut -d= -f2)
```

Branch on TS:

- `TS=ok` → set task `1` → `completed` for this round; jump to Step 2.
- `TS=failed` or `TS=timeout` → auto-retry path:

  ```
  if (( RETRY_COUNT == 0 )); then
    log "auto-retry round=$ROUND attempt=2"
    rm -f "$ART_DIR/turn-cody-$ROUND.txt" "$ART_DIR/turn-cody-$ROUND.done"
    rm -f "$ART_DIR/cody_turn_prompt_$ROUND.md"
    RETRY_COUNT=1
    # re-dispatch turn-send + turn-wait (loop back to top of Step 1)
  else
    # Two attempts failed.
    AskUserQuestion (Hand-off / Abort / Try-again).
    Hand-off: write $ART_DIR/RESUME.md with topic dir + branch + last
      cross-verify summary; preserve cody pane (do NOT teardown); exit.
    Abort: bin/deploy-teardown.sh + bin/deploy-archive.sh; exit.
    Try-again: RETRY_COUNT=0; loop back to top of Step 1.
  fi
  ```

  **Trooper-not-idle case on retry.** `bin/deploy-turn-send.sh` reads
  `cody-$PROVIDER/status.json` and refuses with `trooper not idle (state=...)`
  when the previous turn never reset to idle (most common after
  `TS=timeout` — the trooper is still mid-work). On that error,
  AskUserQuestion (Wait 60s and retry / Force-retry / Abort):
  - *Wait 60s and retry* — sleep 60, re-attempt `deploy-turn-send.sh`
    (do NOT clear state files first; the previous attempt already cleared
    them).
  - *Force-retry* — atomically reset `status.json` to idle via Bash
    (NOT the Write/Edit tool — that file already exists with non-idle
    state and the tool's Read-before-overwrite rule will reject it):
    ```
    STATUS_FILE="$TOPIC_DIR/cody-$PROVIDER/status.json"
    printf '{"state":"idle","updated":"%s","last_event":"force-reset"}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | cw_atomic_write "$STATUS_FILE"
    ```
    Then re-attempt `deploy-turn-send.sh`. The trooper's next inbox.md
    write will overlap its previous read but the END_OF_INSTRUCTION
    sentinel keeps the new payload safe.
  - *Abort* — `bin/deploy-teardown.sh` + `bin/deploy-archive.sh`; exit.

### Step 2 — Cross-verify (per round)

Set task `2` → `in_progress`.

**Skill:** invoke `superpowers:verification-before-completion`.

Yoda's reads (capped):
- `$ART_DIR/verify-report-$ROUND.md`
- `$ART_DIR/test-output-$ROUND.log` (grep tail for pass/fail counts)
- `git -C "$TARGET_CWD" log --oneline "$BRANCH_BASE"..HEAD`
- `git -C "$TARGET_CWD" diff --stat "$BRANCH_BASE"..HEAD`
- Up to 3 spot-checks: pick the highest-stakes diff hunk per critical
  requirement and Read just that hunk. File paths reported by
  `git -C "$TARGET_CWD" diff` are RELATIVE to `$TARGET_CWD`; the Read tool
  needs absolute paths, so prefix with `$TARGET_CWD/<path>` (e.g.
  `$TARGET_CWD/lib/foo.sh`).

(`$BRANCH_BASE` was captured into `$ART_DIR/branch-base.sha` in Step 0,
and `$TARGET_CWD` was loaded alongside it from `$ART_DIR/target_cwd.txt`.)

Write the verdict to `$ART_DIR/cross-verify-$ROUND.md`:
- Top-line `VERDICT: PASS` or `VERDICT: FAIL`.
- If FAIL: bullet list of issues, each tagged `[bug]`, `[regression]`, or
  `[spec-gap]`, with (a) requirement reference, (b) evidence (file:line or
  commit), (c) suggested fix direction.

If `VERDICT: PASS` → set task `2` → `completed`, exit the loop, jump to
Step 4.

If `VERDICT: FAIL` and `ROUND > MAX_ROUNDS`:
- Write `$ART_DIR/RESUME.md` with the topic dir, branch name, latest
  cross-verify summary, and instructions for manual takeover.
- AskUserQuestion: "5 fix rounds exhausted. Continue (1 more round) /
  Hand off (preserve state) / Abort (teardown + archive)." Default: hand off.
- Hand off: log the topic dir + RESUME.md path, exit (do not teardown). Set
  task `3` → `completed` and task `4` → `completed` with note.
- Abort: teardown + archive, exit.
- Continue: increment `MAX_ROUNDS` by 1 and continue the loop.

If `VERDICT: FAIL` and `ROUND <= MAX_ROUNDS` → continue to Step 3.

### Step 3 — Author fix bundle

Set task `3` → `in_progress`.

Read `cross-verify-$ROUND.md`. For every issue listed under `## Issues`,
preserve its tag (`[bug]`, `[regression]`, `[spec-gap]`) and its
`(file:line)` evidence. Group all issues into a single fix bundle file:

```
$ART_DIR/fix-prompt-$((ROUND + 1)).md
```

The fix bundle is a markdown body — NO preamble, NO skill mention, NO
END_OF_INSTRUCTION sentinel. The turn-send script wraps it with all of
those when it dispatches. Just list the issues, one per markdown bullet,
each starting with the tag:

```markdown
- [bug] <evidence> — <suggested fix direction>
- [spec-gap] <evidence> — <suggested fix direction>
```

After writing the bundle:

```
ROUND=$((ROUND + 1))
RETRY_COUNT=0
```

Set task `3` → `completed`; loop back to Step 1.

### Step 3a — Preflight pane allocation (multi-repo)

**Active only when `$ROUTING == "multi-repo"`.**

Set task `3a` → `in_progress`.

`bin/deploy-init.sh` already invoked `bin/deploy-dag-parse.sh`
(NEW v0.20.0) to produce `_deploy/<topic>/dag-waves.txt` +
`dag-edges.txt`, and `bin/deploy-multi-init.sh` to produce
`_deploy/<topic>/troopers.txt`. Defensive check:

```
[[ -f "$ART_DIR/dag-waves.txt"  ]] || { log_error "dag-waves.txt missing — re-run deploy-init"; exit 1; }
[[ -f "$ART_DIR/dag-edges.txt"  ]] || { log_error "dag-edges.txt missing — re-run deploy-init"; exit 1; }
[[ -f "$ART_DIR/troopers.txt"   ]] || { log_error "troopers.txt missing — re-run deploy-init"; exit 1; }
```

Initialize the spawn retry counter:

```
SPAWN_RETRY_COUNT=0
```

Count troopers and run preflight:

```
N=$(wc -l < "$ART_DIR/troopers.txt")
"$CLAUDE_PLUGIN_ROOT/bin/preflight-layout.sh" \
  --art-dir "$ART_DIR" \
  --cwd-from "$ART_DIR/cmdr-cwd-map.txt" \
  --troopers-from "$ART_DIR/troopers-preflight.txt" \
  "$TOPIC" "$N"
```

The `--art-dir` flag points preflight at the deploy art-dir
(preflight-layout.sh accepts this flag as of v0.20.0). The `--cwd-from`
flag (v0.20.3) points preflight at deploy-multi-init's per-commander
cwd map, so each preflight pane is allocated already-rooted in its
sub-repo cwd via `tmux split-window -c` — no transient hub-cwd, no
`cd` later. The `--troopers-from` flag (v0.22.0) points preflight at
deploy's consult-shaped 2-col sidecar (`troopers-preflight.txt`,
written by `bin/deploy-multi-init.sh`); without it, preflight would
mis-parse deploy's 3-col `troopers.txt` as consult's 2-col and end up
with absolute paths in the commander column (BUG #2/3/4 in the v0.22.0
spec).

Load pane assignments:

```
declare -A PREFLIGHT_PANES
while IFS=$'\t' read -r cmdr pane; do
  [[ -n "$cmdr" && -n "$pane" ]] && PREFLIGHT_PANES["$cmdr"]="$pane"
done < "$ART_DIR/preflight-panes.txt"
```

Set task `3a` → `completed`.

### Step 3b — DAG wave dispatch (multi-repo)

**Active only when `$ROUTING == "multi-repo"`.**

Step 3b does NOT pre-create a single `3b` task at upfront — instead,
once `dag-waves.txt` is parsed below, fire one `TaskCreate` per
`(wave, repo)` tuple so the conductor display surfaces each trooper's
sub-repo. See "Per-trooper sub-row creation" block below.

A **wave** is a set of sub-repos with no remaining unsatisfied
dependencies that can run in parallel. `bin/deploy-dag-parse.sh`
computes wave grouping via Kahn's topological sort and writes one row
per `(wave, step, repo, desc)` to `_deploy/dag-waves.txt`.

Walk `_deploy/<topic>/dag-waves.txt` wave-by-wave. For each wave:
issue K parallel `bin/spawn.sh --target-pane <pane> --cwd <sub-repo-cwd>`
calls (one per sub-repo in the wave); send the DAG-unit prompt to each
trooper's inbox via the `cw_deploy_build_dag_unit_prompt` helper;
background-await for K done events via `bin/deploy-wave-wait.sh`.

**Build the per-repo lookup tables + wave groups:**

```
mapfile -t WAVES < "$ART_DIR/dag-waves.txt"
declare -A REPO_TO_CMDR
declare -A REPO_TO_CWD
declare -A REPO_TO_PROVIDER
declare -A REPO_TO_STEP
declare -A REPO_TO_UPSTREAM_CSV
while IFS=$'\t' read -r cmdr cwd provider; do
  repo=$(basename "$cwd")
  REPO_TO_CMDR["$repo"]="$cmdr"
  REPO_TO_CWD["$repo"]="$cwd"
  REPO_TO_PROVIDER["$repo"]="$provider"
done < "$ART_DIR/troopers.txt"

# Build per-repo step + upstream lookup from dag-waves + dag-edges
while IFS=$'\t' read -r wave step repo desc; do
  REPO_TO_STEP["$repo"]="$step"
done < "$ART_DIR/dag-waves.txt"

declare -A STEP_TO_REPO
while IFS=$'\t' read -r wave step repo desc; do
  STEP_TO_REPO["$step"]="$repo"
done < "$ART_DIR/dag-waves.txt"

declare -A REPO_UPSTREAM_STEPS
while IFS=$'\t' read -r from to; do
  REPO_UPSTREAM_STEPS["${STEP_TO_REPO[$to]}"]="${REPO_UPSTREAM_STEPS["${STEP_TO_REPO[$to]}"]} $from"
done < "$ART_DIR/dag-edges.txt"

for repo in "${!REPO_TO_CMDR[@]}"; do
  upstream_csv=""
  for u_step in ${REPO_UPSTREAM_STEPS["$repo"]:-}; do
    [[ -z "$upstream_csv" ]] && upstream_csv="${STEP_TO_REPO[$u_step]}" || upstream_csv="${upstream_csv},${STEP_TO_REPO[$u_step]}"
  done
  REPO_TO_UPSTREAM_CSV["$repo"]="$upstream_csv"
done

# Group rows by wave number
declare -a WAVE_GROUPS=()
current_wave=""
group_buf=""
for line in "${WAVES[@]}"; do
  IFS=$'\t' read -r wave step repo desc <<<"$line"
  if [[ "$wave" != "$current_wave" ]]; then
    [[ -n "$group_buf" ]] && WAVE_GROUPS+=( "$group_buf" )
    group_buf="$repo"
    current_wave="$wave"
  else
    group_buf="$group_buf,$repo"
  fi
done
[[ -n "$group_buf" ]] && WAVE_GROUPS+=( "$group_buf" )

WAVE_COUNT=${#WAVE_GROUPS[@]}
TOTAL_REPOS=${#REPO_TO_CMDR[@]}
log_info "[step 3b] DAG: $WAVE_COUNT wave(s) across $TOTAL_REPOS sub-repo(s)"
```

**Per-trooper sub-row creation (v0.23.1+):**

Source `lib/commanders.sh` for `cw_cmdr_rank`, then walk
`dag-waves.txt` and fire one `TaskCreate` per row. Capture each
returned task ID into `REPO_TO_TASK_ID["<repo>"]` for the wave loop's
`in_progress` / `completed` transitions below.

```
source "$CLAUDE_PLUGIN_ROOT/lib/commanders.sh"

declare -A REPO_TO_TASK_ID

# For each (wave, step, repo, desc) row in dag-waves.txt: ISSUE one
# TaskCreate tool call with:
#   subject="3b.$step $rank ${cmdr^} on $repo [wave $wave]"
#   description="Plan + implement + self-verify $repo DAG unit (${REPO_TO_PROVIDER[$repo]})"
#   activeForm="$rank ${cmdr^} implementing $repo"
# where $rank is $(cw_cmdr_rank "$cmdr") and ${cmdr^} capitalizes the
# first letter (e.g. "rex" → "Rex"). CAPTURE the returned task ID
# into REPO_TO_TASK_ID["$repo"].
#
# Example for a 3-row dag-waves.txt:
#   1<TAB>1<TAB>auth-svc<TAB>plan + implement auth
#   1<TAB>2<TAB>data-plane<TAB>plan + implement data
#   2<TAB>3<TAB>api-gw<TAB>plan + implement gateway
# Three TaskCreate calls fire (parallel is fine, order doesn't matter):
#   TaskCreate(subject="3b.1 Captain Rex on auth-svc [wave 1]",
#              activeForm="Captain Rex implementing auth-svc", …)
#   TaskCreate(subject="3b.2 Commander Bly on data-plane [wave 1]",
#              activeForm="Commander Bly implementing data-plane", …)
#   TaskCreate(subject="3b.3 Commander Cody on api-gw [wave 2]",
#              activeForm="Commander Cody implementing api-gw", …)
```

**Walk waves with explicit outer loop:**

```
for ((w=1; w<=WAVE_COUNT; w++)); do
  IFS=, read -ra REPOS <<<"${WAVE_GROUPS[w-1]}"
  log_info "[step 3b] wave $w of $WAVE_COUNT: dispatching ${#REPOS[@]} trooper(s) — ${REPOS[*]}"

  # ISSUE ${#REPOS[@]} PARALLEL Bash tool calls in a SINGLE message —
  # one per repo. Each call: spawn.sh + cw_inbox_write (DAG-unit prompt
  # built via cw_deploy_build_dag_unit_prompt). Then ISSUE another
  # ${#REPOS[@]} PARALLEL background Bash tool calls — one per trooper —
  # for bin/deploy-wave-wait.sh.
  #
  # Wait until ALL K notifications arrive AND all K wave-<cmdr>.txt
  # files show TS=ok. Then continue to the next wave.

  # Per-repo dispatch shape (each runs in parallel):
  #
  #   "$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" "${REPO_TO_CMDR[$repo]}" \
  #     "${REPO_TO_PROVIDER[$repo]}" "$TOPIC" \
  #     --target-pane "${PREFLIGHT_PANES[${REPO_TO_CMDR[$repo]}]}" \
  #     --preflight-art-dir "$ART_DIR" \
  #     --cwd "${REPO_TO_CWD[$repo]}"
  #
  #   PROMPT=$(cw_deploy_build_dag_unit_prompt \
  #     "$repo" "$ART_DIR/design.md" \
  #     "${REPO_TO_STEP[$repo]}" "$TOTAL_REPOS" \
  #     "${REPO_TO_UPSTREAM_CSV[$repo]}")
  #   PROMPT_FILE="$ART_DIR/${REPO_TO_CMDR[$repo]}_dag_unit_prompt.md"
  #   printf '%s' "$PROMPT" > "$PROMPT_FILE"
  #   "$CLAUDE_PLUGIN_ROOT/bin/send.sh" "${REPO_TO_CMDR[$repo]}" "$TOPIC" "@$PROMPT_FILE"
  #
  # When the per-repo dispatch returns rc=0, ISSUE:
  #   TaskUpdate(taskId=${REPO_TO_TASK_ID[$repo]}, status="in_progress")
  # so the conductor display shows "<Rank> <Cmdr> implementing <repo>"
  # in the spinner row for that trooper (v0.23.1+).
  #
  # NOTE: dispatch uses `bin/send.sh @file` (NOT bare `cw_inbox_write`)
  # because `bin/send.sh` writes inbox.md AND nudges the trooper's pane
  # via `cw_pane_send` — the canonical write+nudge convention that every
  # working dispatch in the codebase pairs (consult-research-send.sh,
  # deploy-turn-send.sh, spawn.sh's initial-prompt path). Bare
  # `cw_inbox_write` writes the file but the trooper TUI never receives a
  # tmux signal — it sits idle at "Ready event emitted" forever (BUG #5
  # in the v0.22.0 spec).
  #
  # Per-repo wave-wait shape (each runs in BACKGROUND parallel):
  #
  #   Bash(
  #     command='"$CLAUDE_PLUGIN_ROOT/bin/deploy-wave-wait.sh" "$TOPIC" "${REPO_TO_CMDR[$repo]}" "${REPO_TO_PROVIDER[$repo]}"',
  #     run_in_background: true,
  #     description="master yoda await ${REPO_TO_CMDR[$repo]} wave $w (background)"
  #   )

  # Process notifications as they arrive. For each notification:
  #   1. Read $ART_DIR/wave-<cmdr>.txt
  #   2. Parse TS= line:
  #        TS=ok      → trooper succeeded; ISSUE
  #                     TaskUpdate(taskId=${REPO_TO_TASK_ID[$repo]},
  #                                status="completed")
  #                     to flip that trooper's sub-row from spinner →
  #                     ✓ in the conductor display (v0.23.1+).
  #        TS=failed  → enter Stage 1/2 failure handling (below)
  #        TS=timeout → enter Stage 1/2 failure handling (below)
  #
  # When ALL K wave-<cmdr>.txt files show TS=ok: log "wave $w
  # completed; ${#REPOS[@]} succeeded" and continue to the next wave.

  log_info "[step 3b] wave $w completed"
done
```

#### Failure handling — Stage 1 retry-once + Stage 2 partial-success (multi-repo)

After a wave's K spawns + wave-waits return:

- **All K succeed** → continue to next wave. Per-trooper sub-rows for
  succeeded repos are already flipped to `completed` from the wave-loop
  notification handler above; no additional task transition needed.

- **At least one fails AND `SPAWN_RETRY_COUNT == 0`** → **Stage 1
  retry-once**: full teardown + re-preflight + re-dispatch the entire
  wave (mirrors v0.19.0 consult Step 3b). Per-trooper sub-rows for the
  in-flight repos remain `in_progress` across the retry — the work IS
  in progress, just on attempt #2.

- **At least one fails AND `SPAWN_RETRY_COUNT == 1`** → **Stage 2
  partial-success offer**: AskUserQuestion ("M/K spawned in this wave
  after retry. Proceed degraded with N=M / Abort all?"). On "Proceed
  degraded": rewrite `_deploy/troopers.txt` to drop the failed entry +
  flip the dropped repo's sub-row to `completed` via
  `TaskUpdate(taskId=${REPO_TO_TASK_ID[$repo]}, status="completed",
  description="skipped per user choice")` so the conductor display
  doesn't leave an orphan spinner. On "Abort all": archive state +
  exit 1 (preserves diagnostic context):

  ```
  "$CLAUDE_PLUGIN_ROOT/bin/deploy-teardown.sh" "$TOPIC" 2>/dev/null || true
  "$CLAUDE_PLUGIN_ROOT/bin/deploy-archive.sh"  "$TOPIC"
  exit 1
  ```

The wave loop exits after the last wave's per-trooper sub-rows have
all been flipped to `completed` by the notification handler — no
further task transition needed at the Step 3b boundary (v0.23.1+
replaces the old single `Set task 3b → completed`).

### Step 3c — Final verification (multi-repo)

**Active only when `$ROUTING == "multi-repo"`.**

Set task `3c` → `in_progress`.

After all waves complete, the conductor (Yoda) does its own verification.
Default = cross-repo invariants only. Escalate to full check (all tests
+ Success Criteria diff review) on any of three "feels unsafe" triggers.

**Compute the unsafe signal:**

```
source "$CLAUDE_PLUGIN_ROOT/lib/deploy-dag.sh"
WAVE_COUNT=$(awk -F$'\t' '{print $1}' "$ART_DIR/dag-waves.txt" | sort -u | wc -l)
FAN_IN_REPOS=$(cw_deploy_dag_fan_in_repos "$ART_DIR/dag-edges.txt" "$ART_DIR/dag-waves.txt")
SHARED_PATHS=""
declare -A PATH_COUNT
while IFS=$'\t' read -r cmdr cwd provider; do
  branch_base=$(cat "$ART_DIR/$cmdr-branch-base.sha" 2>/dev/null) || continue
  while IFS= read -r p; do
    PATH_COUNT["$p"]=$(( ${PATH_COUNT["$p"]:-0} + 1 ))
  done < <(git -C "$cwd" diff --name-only "${branch_base}..HEAD" 2>/dev/null)
done < "$ART_DIR/troopers.txt"
for p in "${!PATH_COUNT[@]}"; do
  (( ${PATH_COUNT[$p]} >= 2 )) && SHARED_PATHS="$SHARED_PATHS $p"
done

UNSAFE=0
[[ "$WAVE_COUNT" -ge 3 ]] && { UNSAFE=1; log_warn "feels unsafe: wave count $WAVE_COUNT >= 3"; }
[[ -n "$FAN_IN_REPOS" ]]   && { UNSAFE=1; log_warn "feels unsafe: fan-in repos: $FAN_IN_REPOS"; }
[[ -n "$SHARED_PATHS" ]]   && { UNSAFE=1; log_warn "feels unsafe: shared filesystem paths: $SHARED_PATHS"; }
```

**Default verification (UNSAFE=0):** cross-repo invariants only.
Yoda reads the design-doc's `## Architecture` section and verifies
that any cross-repo interface declared there is implemented
consistently across sub-repos. If no cross-repo interfaces are
declared, default verification is a no-op.

**Escalated verification (UNSAFE=1):** run full check.
- Per sub-repo: `git -C "<cwd>" status --short` (no uncommitted leftovers)
- Per sub-repo: `bash <cwd>/tests/run.sh` if present, else `<cwd>/Makefile test` if present, else skip
- Yoda reads the design-doc's `## Success Criteria` checklist and
  evaluates each `- [ ]` bullet against the diffs

**Bugs collection contract.** When verification finds bugs, write them
to `_deploy/multi-verify-bugs.txt` (TSV: `<repo>\t<bug-description>`,
one line per bug). Step 3d consumes this file to drive its fix-loop.
The file is truncated each verify pass.

```
# Truncate any prior verify pass output
> "$ART_DIR/multi-verify-bugs.txt"

# For each bug found by cross-repo invariants check OR escalated full
# check, append a TSV row:
#   printf '%s\t%s\n' "<offending-repo>" "<bug-description-one-line>" \
#     >> "$ART_DIR/multi-verify-bugs.txt"
#
# When the verify pass is done, multi-verify-bugs.txt is the
# authoritative bugs list for Step 3d.
```

If `multi-verify-bugs.txt` is non-empty after the verify pass, proceed
to Step 3d fix-loop. If empty (all green), set task `3c` → `completed`
and proceed to Step 4.

### Step 3d — Fix-loop (multi-repo)

**Active only when `$ROUTING == "multi-repo"` AND Step 3c found bugs.**

Set task `3d` → `in_progress`.

**Bugs source.** Step 3c wrote `_deploy/multi-verify-bugs.txt` (TSV:
`<repo>\t<bug-description>`). Step 3d reads it to drive the fix-loop.
An empty / absent file means "no bugs — skip Step 3d entirely":

```
[[ -f "$ART_DIR/multi-verify-bugs.txt" && -s "$ART_DIR/multi-verify-bugs.txt" ]] || {
  log_info "[step 3d] no bugs in multi-verify-bugs.txt; skipping fix-loop"
  # Set task 3d → completed and proceed to Step 4 (teardown)
}

declare -A FIX_ROUNDS
MAX_FIX_ROUNDS=3
```

For each `(REPO, BUG)` row in `multi-verify-bugs.txt`:

```
while IFS=$'\t' read -r REPO BUG; do
  [[ -n "$REPO" && -n "$BUG" ]] || continue

  # Look up the trooper that owns this sub-repo
  CMDR=$(awk -F$'\t' -v r="$REPO" '$2 ~ ("/" r "$") { print $1 }' "$ART_DIR/troopers.txt")
  PROVIDER=$(awk -F$'\t' -v r="$REPO" '$2 ~ ("/" r "$") { print $3 }' "$ART_DIR/troopers.txt")
  [[ -n "$CMDR" ]] || { log_warn "[step 3d] no trooper found for repo '$REPO'; skipping"; continue; }

  FIX_ROUNDS["$REPO"]="${FIX_ROUNDS[$REPO]:-1}"
  log_info "[step 3d] fix-loop round ${FIX_ROUNDS[$REPO]}/$MAX_FIX_ROUNDS for $REPO (trooper $CMDR)"

  # 1. Send fix-prompt via the trooper's inbox
  FIX_PROMPT=$(cat <<EOFP
FIX REQUEST (round ${FIX_ROUNDS[$REPO]} of $MAX_FIX_ROUNDS):

I detected the following issue in your sub-repo:

$BUG

Please fix it using the same superpowers ceremony (writing-plans for
the fix → subagent-driven-development → verification-before-completion).
Report done via outbox when verified.
END_OF_INSTRUCTION
EOFP
)
  # v0.22.0: dispatch via bin/send.sh @file (canonical write+nudge), NOT bare
  # cw_inbox_write — same Bug 5 fix as Step 3b's dispatch shape. The trooper
  # TUI does not poll inbox.md; without cw_pane_send, the fix-prompt sits on
  # disk while the trooper waits forever for a signal.
  FIX_PROMPT_FILE="$ART_DIR/${CMDR}_fix_prompt_round_${FIX_ROUNDS[$REPO]}.md"
  printf '%s' "$FIX_PROMPT" > "$FIX_PROMPT_FILE"
  "$CLAUDE_PLUGIN_ROOT/bin/send.sh" "$CMDR" "$TOPIC" "@$FIX_PROMPT_FILE"

  # 2. Background-await via deploy-wave-wait (mirror Step 3b)
  Bash(
    command='"$CLAUDE_PLUGIN_ROOT/bin/deploy-wave-wait.sh" "$TOPIC" "$CMDR" "$PROVIDER"',
    run_in_background: true,
    description="master yoda await $CMDR fix-round ${FIX_ROUNDS[$REPO]} (background)"
  )

  # 3. On notification: read wave-<cmdr>.txt; if TS=ok, re-run Step 3c
  #    verification for THIS sub-repo. If still buggy AND
  #    FIX_ROUNDS[$REPO] < MAX_FIX_ROUNDS: bump FIX_ROUNDS[$REPO] and
  #    re-loop to step 1.
  #
  # 4. If still buggy AND FIX_ROUNDS[$REPO] >= MAX_FIX_ROUNDS:
  #    AskUserQuestion (give up / continue / escalate to different commander).
  #    "Give up on this sub-repo": log $REPO as FAILED in _deploy/results.txt;
  #    continue verification for other sub-repos.
  #    "Continue more rounds": bump FIX_ROUNDS[$REPO] and re-loop.
  #    "Escalate to different commander": pick next available commander
  #    from the pool, spawn fresh trooper with same --cwd, reset
  #    FIX_ROUNDS[$REPO]=0.
done < "$ART_DIR/multi-verify-bugs.txt"
```

After all bugs resolved (or given up on), set task `3d` → `completed`.

### Step 4 — Teardown + archive

Set task `4` → `in_progress`.

**Sub-step 4.0 — Pre-deploy stash unwind (v0.30.0 item 3).**

If a `pre-deploy-stash.txt` exists from Step 0's intercept, attempt to
restore the stashed WIP onto the user's working tree:

```
TARGET_CWD=$(cat "$ART_DIR/target_cwd.txt")
if [[ -f "$ART_DIR/pre-deploy-stash.txt" ]]; then
  STASH_SHA=$(awk -F= '/^sha=/{print $2; exit}' "$ART_DIR/pre-deploy-stash.txt")
  if [[ -n "$STASH_SHA" ]]; then
    if git -C "$TARGET_CWD" stash pop "$STASH_SHA" 2>/tmp/cw-stashpop-err; then
      log_ok "popped pre-deploy stash $STASH_SHA back onto working tree"
      printf 'status=popped\nsha=%s\n' "$STASH_SHA" \
        | cw_atomic_write "$ART_DIR/post-deploy-stash-pop.txt"
    else
      log_warn "stash pop conflict; stash $STASH_SHA preserved for manual recovery"
      log_warn "  recovery: cd $TARGET_CWD && git stash apply $STASH_SHA"
      log_warn "  conflict detail in /tmp/cw-stashpop-err"
      printf 'status=conflict\nsha=%s\n' "$STASH_SHA" \
        | cw_atomic_write "$ART_DIR/post-deploy-stash-pop.txt"
    fi
  fi
fi

# Note: pre-deploy-commit.txt has no special unwind — the WIP commit lives
# on the feature branch alongside deploy work. User can `git rebase -i`
# post-merge.
```

**Sub-step 4.1 — Verify sibling baseline (v0.30.0 item 2).**

Re-read each sibling's HEAD vs the baseline captured in Step 0.
Surfaces any rogue commits on undeclared siblings' main branches.

```
source "$CLAUDE_PLUGIN_ROOT/lib/deploy.sh"
HUB_CWD=$(cw_deploy_resolve_hub "$ART_DIR/design.md" "$(cw_repo_root)")
if [[ -f "$ART_DIR/sibling-baseline.txt" ]]; then
  "$CLAUDE_PLUGIN_ROOT/bin/deploy-sibling-verify.sh" "$ART_DIR" "$HUB_CWD" \
    || log_warn "sibling-verify.sh failed; skipping rogue-commit intercept"
fi
```

If `_deploy/sibling-rogue.txt` exists and is non-empty, fire
AskUserQuestion offering one of three recovery paths.

```
AskUserQuestion (Yoda formats sibling-rogue.txt as inline markdown table):
  Question: "Rogue commits detected on undeclared sibling main branches. Pick a recovery path."
  Header:   "Rogue commits"
  Options:
    - "Revert + replay on feat branch" (Recommended) — calls
      cw_deploy_revert_and_replay per affected sibling; leaves
      feat/deploy-<topic>-rescue branch in each rescued sibling
    - "Keep on main (accept the data)" — appends the entire
      sibling-rogue.txt contents to _deploy/sibling-rogue-accepted.txt
      for audit; no git action
    - "Send back to trooper as fix-loop bug" — appends entries to
      _deploy/bugs.txt and triggers fix-round (re-enters Step 2 with
      the bug list)
```

On `Revert + replay on feat branch`:

```
source "$CLAUDE_PLUGIN_ROOT/lib/deploy-sibling.sh"
TOPIC=$(cat "$ART_DIR/topic.txt")
declare -A ROGUE_BY_SLUG=()
while IFS=$'\t' read -r slug sha subject; do
  [[ -n "$slug" ]] || continue
  ROGUE_BY_SLUG["$slug"]+="$sha "
done < "$ART_DIR/sibling-rogue.txt"
for slug in "${!ROGUE_BY_SLUG[@]}"; do
  base_sha=$(awk -F$'\t' -v s="$slug" '$1==s{print $2; exit}' "$ART_DIR/sibling-baseline.txt")
  branch=$(awk -F$'\t' -v s="$slug" '$1==s{print $3; exit}' "$ART_DIR/sibling-baseline.txt")
  ordered_shas="${ROGUE_BY_SLUG["$slug"]% }"   # trim trailing space; oldest-first as captured
  if cw_deploy_revert_and_replay "$HUB_CWD/$slug" "$TOPIC" "$base_sha" "$branch" "$ordered_shas"; then
    log_ok "rescued $slug: feat/deploy-${TOPIC}-rescue created with replayed work"
    printf '%s\trescued\n' "$slug" >> "$ART_DIR/sibling-rescue.txt"
  else
    log_warn "rescue failed for $slug — manual intervention needed (see git status in $HUB_CWD/$slug)"
    printf '%s\trescue-failed\n' "$slug" >> "$ART_DIR/sibling-rescue.txt"
  fi
done
```

On `Keep on main (accept the data)`:

```
cat "$ART_DIR/sibling-rogue.txt" >> "$ART_DIR/sibling-rogue-accepted.txt"
log_info "rogue commits accepted: see $ART_DIR/sibling-rogue-accepted.txt"
```

On `Send back to trooper as fix-loop bug`:

```
{
  echo "## Rogue commits on undeclared siblings"
  echo ""
  echo "The following commits landed on sibling sub-repo main branches"
  echo "that weren't declared in the design's Target Sub-Project(s):"
  echo ""
  awk -F$'\t' '{ printf "- %s: %s — %s\n", $1, $2, $3 }' "$ART_DIR/sibling-rogue.txt"
  echo ""
  echo "Action required: revert these commits and either redeclare the"
  echo "design as multi-repo OR confine the implementation to declared"
  echo "targets only."
} >> "$ART_DIR/bugs.txt"
log_info "rogue commits added as fix-loop bug; re-entering Step 2"
# Directive jumps back to Step 2 (fix round) — no more code in this branch.
```

**Sub-step 4.2 — Scope conformance check (v0.30.0 item 4).**

Compare the trooper's git diff against the design doc's Components
table. Surface any files the trooper added/modified that aren't covered
by a listed path (or its prefix).

```
source "$CLAUDE_PLUGIN_ROOT/lib/deploy-scope.sh"
TARGET_CWD=$(cat "$ART_DIR/target_cwd.txt")
BASE=$(cat "$ART_DIR/branch-base.sha")

DIFF_PATHS="$ART_DIR/diff-paths.txt"
: > "$DIFF_PATHS"
git -C "$TARGET_CWD" diff --name-only "$BASE..HEAD" >> "$DIFF_PATHS"

# Multi-repo: also collect diffs from each declared sub-repo.
if [[ -f "$ART_DIR/multi-repo-targets.txt" ]]; then
  while IFS= read -r slug; do
    [[ -n "$slug" ]] || continue
    sub_base=$(awk -F$'\t' -v s="$slug" '$1==s{print $2; exit}' "$ART_DIR/cmdr-branch-base.sha" 2>/dev/null)
    [[ -n "$sub_base" ]] || continue
    git -C "$TARGET_CWD/$slug" diff --name-only "$sub_base..HEAD" 2>/dev/null \
      | while IFS= read -r p; do echo "$slug/$p"; done >> "$DIFF_PATHS"
  done < "$ART_DIR/multi-repo-targets.txt"
fi

COMP_PATHS="$ART_DIR/components-paths.txt"
cw_deploy_extract_components_paths "$ART_DIR/design.md" > "$COMP_PATHS"

OOS="$ART_DIR/scope-out-of-scope.txt"
cw_deploy_match_diff_against_components "$DIFF_PATHS" "$COMP_PATHS" > "$OOS"

if [[ -s "$OOS" ]]; then
  log_warn "scope conformance: $(wc -l < "$OOS") out-of-scope path(s) detected"
fi
```

If `$OOS` is non-empty, fire AskUserQuestion offering one of three
paths.

```
AskUserQuestion (Yoda renders inline body from $OOS as a bulleted list):
  Question: "Out-of-scope files in trooper's diff. Pick a path."
  Header:   "Scope drift"
  Options:
    - "Accept and amend design retroactively" — Yoda offers a draft
      amendment to the Components table; user reviews via Edit tool;
      design.md updated in place; recorded to
      _deploy/scope-amended.txt for audit
    - "Send back to trooper to remove" — append entries to
      _deploy/bugs.txt; re-enter Step 2 fix round
    - "Force-keep without amending" — append $OOS contents to
      _deploy/scope-overrides.txt for audit; deploy proceeds unchanged
```

On `Accept and amend design retroactively`:

```
printf 'amended-rows=%s\nat-time=%s\n' \
  "$(wc -l < "$OOS")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  | cw_atomic_write "$ART_DIR/scope-amended.txt"
# Yoda reads $OOS, drafts new Components rows, presents them in chat
# for user review, uses Edit tool on $ART_DIR/design.md to insert the
# new rows into the Components table.
```

On `Send back to trooper to remove`:

```
{
  echo "## Out-of-scope files"
  echo ""
  echo "These files are in your diff but not declared in the design's"
  echo "Components/Files-edited table:"
  echo ""
  awk '{print "- `" $0 "`"}' "$OOS"
  echo ""
  echo "Either remove them OR raise an amendment request via Yoda."
} >> "$ART_DIR/bugs.txt"
log_info "scope drift added as fix-loop bug; re-entering Step 2"
```

On `Force-keep without amending`:

```
cat "$OOS" >> "$ART_DIR/scope-overrides.txt"
log_warn "scope drift accepted without amendment: see $ART_DIR/scope-overrides.txt"
```

```
"$CLAUDE_PLUGIN_ROOT/bin/deploy-teardown.sh" "$TOPIC"
"$CLAUDE_PLUGIN_ROOT/bin/deploy-archive.sh" "$TOPIC"
```

**Final summary.** Output depends on `$ROUTING`:

```
if [[ "$ROUTING" == "multi-repo" ]]; then
  echo "=== multi-repo final summary ==="
  while IFS=$'\t' read -r CMDR CWD PROVIDER; do
    BB="$ART_DIR/${CMDR}-branch-base.sha"
    if [[ -f "$BB" ]]; then
      base=$(cat "$BB")
      n=$(git -C "$CWD" log --oneline "${base}..HEAD" 2>/dev/null | wc -l)
      echo "  $CMDR ($PROVIDER) → $CWD: $n commit(s) on top of branch base"
    else
      echo "  $CMDR ($PROVIDER) → $CWD: branch base unknown"
    fi
  done < "$ART_DIR/troopers.txt"
  echo "Final cross-verify verdict: see _deploy/multi-verify-bugs.txt (empty = PASS)."
  echo "Archive path: $(cat $ART_DIR/archive_path.txt 2>/dev/null || echo unknown)"
else
  # Single-repo (v0.19.0 byte-equal) summary:
  echo "Branch: $(git -C "$TARGET_CWD" branch --show-current) ($(git -C "$TARGET_CWD" log --oneline "$BRANCH_BASE..HEAD" | wc -l) commit(s))"
  echo "Final cross-verify verdict: PASS or hand-off note"
  echo "Archive path: $(cat $ART_DIR/archive_path.txt 2>/dev/null || echo unknown)"
fi
```

Set task `4` → `completed`.

## Environment variables

- `CW_DEPLOY_TURN_TIMEOUT` (default `14400` / 4hr) — max wall time for one
  trooper turn (plan+implement+verify in round 1; fix+verify in fix
  rounds). Set to a larger value for very long-running specs; reduce
  only for testing.
- `MAX_ROUNDS_OVERRIDE` (default `5`) — fix-round ceiling before
  exhaustion AskUserQuestion fires.

The following legacy env vars are **deprecated and ignored** (medic warns
when set):
- `CW_DEPLOY_PLAN_TIMEOUT`
- `CW_DEPLOY_IMPLEMENT_TIMEOUT`
- `CW_DEPLOY_VERIFY_TIMEOUT`
- `CW_DEPLOY_FIX_TIMEOUT`

## State files (per topic)

Files written under `$ART_DIR` (= `$TOPIC_DIR/_deploy/`):

- `_deploy/target_cwd.txt` — absolute path to the trooper's working dir. Equal to the
  conductor's cwd in single-repo mode; equal to `<conductor-cwd>/<sub-repo>` when the
  design doc declares `**Target Sub-Project:** <sub-repo>`. Set by `bin/deploy-init.sh`,
  read by Step 0 + Step 1.1 + Step 2.
- `_deploy/auto_provider.txt` — what `cw_deploy_detect_provider` chose (codex/claude).
- `_deploy/provider.txt` — what was actually used (after any user override).
- `_deploy/branch-base.sha` — the commit SHA the deploy branch was created from
  (captured by Step 0; consumed by Step 2 + Step 4 as the diff range base).
- `_deploy/design.md` — the design doc init.sh copied into place.
- `_deploy/design-audit.md` — verdict from `cw_deploy_audit_doc`.
- `_deploy/turn-cody-N.txt` — per-round trooper-turn status (TS=ok/failed/timeout).
- `_deploy/verify-report-N.md` — trooper's own verification report for round N.
- `_deploy/cross-verify-N.md` — Yoda's verdict for round N (PASS / FAIL + issues).
- `_deploy/fix-prompt-N.md` — fix bundle Yoda authored for round N (Step 3 output;
  Step 1 input on the next round).
- `_deploy/RESUME.md` — written on hand-off (5 rounds exhausted or auto-retry
  abandoned); documents how to take over manually.

## Intervention patterns

### Abandoned run cleanup
If a previous run wedged (panes alive, state intact), tear down explicitly:
```
"$CLAUDE_PLUGIN_ROOT/bin/deploy-teardown.sh" <topic>
"$CLAUDE_PLUGIN_ROOT/bin/deploy-archive.sh" <topic>
```

### Manual takeover (after hand-off)
The cody pane stays alive after a 5-round hand-off. Attach:
```
tmux select-pane -t <pane_id>   # printed by spawn.sh
```
Use the cody session directly. RESUME.md in `$ART_DIR/` documents context.

### Auto-created branch survives audit-FAIL and spawn-FAIL
If the audit or spawn fails, the directive aborts and archives `_deploy/`
but the auto-created `feat/deploy-<topic>` branch is left in place. Clean up
manually if undesired (run inside the trooper's working tree — the conductor's
cwd for single-repo deploys, the sub-repo path for hub deploys):
```
git -C "$TARGET_CWD" checkout - \
  && git -C "$TARGET_CWD" branch -D feat/deploy-<topic>
```
