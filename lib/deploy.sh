# lib/deploy.sh — /clone-wars:deploy helpers.
# Sourced. Depends on lib/state.sh, lib/consult.sh (for slug regex re-use).

cw_deploy_topic_dir() {
  printf '%s/state/%s/%s\n' "$(cw_state_root)" "$(cw_repo_hash)" "$1"
}

cw_deploy_art_dir() {
  printf '%s/state/%s/%s/_deploy\n' "$(cw_state_root)" "$(cw_repo_hash)" "$1"
}

# cw_deploy_assert_topic <topic>
# Stricter than cw_consult_topic_validate's regex; deploy topics are strict kebab-only.
cw_deploy_assert_topic() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] \
    || { log_error "invalid topic slug: '$1' (must match ^[a-z0-9][a-z0-9-]{0,31}\$)"; exit 2; }
}

# cw_deploy_derive_topic <design-path>
# Strip leading YYYY-MM-DD- and trailing -design.md (or .md). Print slug.
cw_deploy_derive_topic() {
  local p="$1" base
  [[ -n "$p" ]] || { printf ''; return 0; }
  base="${p##*/}"                       # basename
  base="${base#????-??-??-}"            # strip YYYY-MM-DD-
  base="${base%-design.md}"             # strip -design.md
  base="${base%.md}"                    # strip .md if -design.md missed
  printf '%s\n' "$base"
}

# cw_deploy_audit_doc <design-path>
# Heuristic checklist for design-doc readiness. Prints one VERDICT= line plus
# one ISSUE= line per detected issue. Returns 0 on PASS, 1 on FAIL, 2 on
# missing/unreadable file.
#
# Heuristic gates (each ISSUE= prints only if the gate fails):
#   no_goal_section       — no '^## Goal' heading
#   no_arch_section       — no '^## Architecture' or '^## Approach' heading
#   no_testing_section    — no heading containing 'Test' or 'test'
#   no_success_section    — no heading containing 'Success' or 'success'
#   tbd_marker            — file contains 'TBD' as a word
#   todo_marker           — file contains 'TODO' as a word (case-sensitive; lowercase
#                           'todo' is allowed since it commonly appears in field names)
#   fill_in_later_marker  — file matches /fill in later/i
#   to_be_determined_marker — file matches /to be determined/i
cw_deploy_audit_doc() {
  local doc="$1"
  [[ -f "$doc" && -r "$doc" ]] || { log_error "design-doc unreadable: $doc"; return 2; }
  local fail=0
  local -a issues=()
  grep -qE '^##\s+Goal\b'                       "$doc" || { issues+=("no_goal_section"); fail=1; }
  grep -qE '^##\s+(Architecture|Approach)\b'    "$doc" || { issues+=("no_arch_section"); fail=1; }
  grep -qE '^##\s+.*[Tt]est'                    "$doc" || { issues+=("no_testing_section"); fail=1; }
  grep -qE '^##\s+.*[Ss]uccess'                 "$doc" || { issues+=("no_success_section"); fail=1; }
  grep -qE '\bTBD\b'                            "$doc" && { issues+=("tbd_marker"); fail=1; }
  grep -qE '\bTODO\b'                           "$doc" && { issues+=("todo_marker"); fail=1; }
  grep -qiE 'fill in later'                     "$doc" && { issues+=("fill_in_later_marker"); fail=1; }
  grep -qiE 'to be determined'                  "$doc" && { issues+=("to_be_determined_marker"); fail=1; }
  if (( fail == 0 )); then
    printf 'VERDICT=PASS\n'
    return 0
  fi
  printf 'VERDICT=FAIL\n'
  local i
  for i in "${issues[@]}"; do
    printf 'ISSUE=%s\n' "$i"
  done
  return 1
}

# cw_deploy_branch_create <topic> [<branch-name-override>]
# Refuses on dirty tree or pre-existing branch. Prints created branch name.
cw_deploy_branch_create() {
  local topic="$1" override="${2:-}" branch
  branch="${override:-feat/deploy-$topic}"
  # Not-in-a-git-repo gate (prevents misleading "dirty" message + 70-line git usage spew)
  git rev-parse --git-dir >/dev/null 2>&1 \
    || { log_error "not inside a git repository"; return 1; }
  # Dirty-tree check
  if ! git diff --quiet || ! git diff --cached --quiet; then
    log_error "working tree is dirty (uncommitted changes); commit/stash or pass --no-branch"
    return 1
  fi
  # Untracked-files check (ls-files -o exit code is unreliable; count instead)
  if [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
    log_error "working tree is dirty (untracked files); commit/stash or pass --no-branch"
    return 1
  fi
  # Pre-existing branch check
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    log_error "branch '$branch' already exists; pass --branch <name> to override"
    return 1
  fi
  local err
  if ! err=$(git checkout -b "$branch" 2>&1 >/dev/null); then
    log_error "git checkout -b failed: $err"
    return 1
  fi
  printf '%s\n' "$branch"
}

# Turn prompt builders. Each prints a self-contained inbox-prompt body
# terminating in END_OF_INSTRUCTION. The slash directive writes the body
# to inbox.md via bin/send.sh.

# cw_deploy_build_turn_prompt_round1 <design> <plan_out> <verify_out>
# Emits the round-1 inbox prompt for the collapsed plan+implement+verify
# trooper turn. Bound to writing-plans + subagent-driven-development +
# verification-before-completion skills. Includes resume-aware preamble so
# auto-retry on the same prompt picks up from disk state.
cw_deploy_build_turn_prompt_round1() {
  local design="$1" plan_out="$2" verify_out="$3"
  cat <<EOF
You are entering ROUND 1 of /clone-wars:deploy.

This is a single-turn workflow: you will write the implementation plan,
implement it, run the test suite, and write the verify report — all in
one autonomous run. The conductor will only re-engage when you emit done.

RESUME CHECK (do this BEFORE starting):
- If $plan_out already exists, skip the planning phase — read the
  existing plan and proceed to implementation.
- If \`git log --oneline\` shows commits past the design-doc commit on
  this branch, identify the next pending task from $plan_out's checkbox
  state and continue from there. Do not redo already-committed tasks.
- If $verify_out already exists, you previously completed implementation
  — re-run the test suite and update $verify_out if test outcomes changed.

PHASE 1: Plan (skip if $plan_out exists)
  Use the superpowers:writing-plans skill. Read the design doc at:
    $design
  Produce a comprehensive implementation plan and write it to:
    $plan_out

PHASE 2: Implement
  Use the superpowers:subagent-driven-development skill. Walk $plan_out
  task-by-task. Commit per task (Conventional Commits prefix). Run the
  full test suite (\`bash tests/run.sh\`) after each task and confirm green.

PHASE 3: Self-verify
  Use the superpowers:verification-before-completion skill. Run the full
  test suite, tee output to:
    ${verify_out%/*}/test-output-1.log
  Write a structured verify report to:
    $verify_out

  The report MUST start with \`VERDICT: PASS|PARTIAL|FAIL\` on the first
  line, followed by per-requirement evidence (file:line citations) and a
  short summary.

When all three phases are done AND the test suite is green AND
$verify_out exists with a VERDICT line, emit:
  {"event":"done","summary":"Round 1 complete","ts":"<iso>"}

END_OF_INSTRUCTION
EOF
}

# cw_deploy_build_turn_prompt_fix <fix_bundle_path> <verify_out> <round>
# Emits the fix-round inbox prompt for the collapsed fix+verify trooper
# turn. Reads the user-authored fix bundle from disk, wraps it with
# routing instructions (systematic-debugging for [bug]/[regression],
# writing-plans for [spec-gap]) and the resume-aware preamble.
# Returns 1 on missing/unreadable bundle.
cw_deploy_build_turn_prompt_fix() {
  local bundle="$1" verify_out="$2" round="$3"
  [[ -f "$bundle" && -r "$bundle" ]] \
    || { log_error "fix bundle not found or unreadable: $bundle"; return 1; }
  local issues
  issues=$(cat "$bundle")
  cat <<EOF
You are entering ROUND $round of /clone-wars:deploy (fix loop).

This is a single-turn workflow: address each issue below, re-run the test
suite, and write the verify report — all in one autonomous run.

RESUME CHECK (do this BEFORE starting):
- Check \`git log --oneline\` for commits since the previous round's
  verify report was written. If some issues already have addressing
  commits, identify which remain unaddressed and start from those.
- If $verify_out already exists, re-run tests and update it if outcomes
  changed.

ISSUES TO ADDRESS:

$issues

ROUTING:
- For each issue tagged [bug] or [regression]: use the
  superpowers:systematic-debugging skill.
- For each issue tagged [spec-gap]: use the superpowers:writing-plans
  skill (re-plan the gap, then implement).
- After EACH fix commit: dispatch a superpowers:code-reviewer subagent
  via the superpowers:requesting-code-review skill with the fix commit's
  SHA as scope. Address Critical and Important findings before moving to
  the next issue. Round 1's subagent-driven-development walks code review
  per-task automatically; fix rounds need this explicit invocation.

For EACH issue: implement the fix, commit per fix (Conventional Commits
prefix \`fix:\`, \`feat:\`, or \`test:\` as appropriate), run the
code-review subagent on the new commit, then re-run the full test suite.
Do NOT skip any listed issue.

After all issues are addressed AND the test suite is green:
  Run the full test suite, tee output to:
    ${verify_out%/*}/test-output-$round.log
  Write the verify report to:
    $verify_out
  The report MUST start with \`VERDICT: PASS|PARTIAL|FAIL\`.

When done, emit:
  {"event":"done","summary":"Round $round complete","ts":"<iso>"}

END_OF_INSTRUCTION
EOF
}

