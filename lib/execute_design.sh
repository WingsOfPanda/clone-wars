# lib/execute_design.sh — /clone-wars:execute-design helpers.
# Sourced. Depends on lib/state.sh, lib/consult.sh (for slug regex re-use).

cw_execute_design_topic_dir() {
  printf '%s/state/%s/%s\n' "$(cw_state_root)" "$(cw_repo_hash)" "$1"
}

cw_execute_design_art_dir() {
  printf '%s/state/%s/%s/_execute\n' "$(cw_state_root)" "$(cw_repo_hash)" "$1"
}

# cw_execute_design_assert_topic <topic>
# Stricter than cw_consult_topic_validate's regex; execute-design topics are strict kebab-only.
cw_execute_design_assert_topic() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] \
    || { log_error "invalid topic slug: '$1' (must match ^[a-z0-9][a-z0-9-]{0,31}\$)"; exit 2; }
}

# cw_execute_design_derive_topic <design-path>
# Strip leading YYYY-MM-DD- and trailing -design.md (or .md). Print slug.
cw_execute_design_derive_topic() {
  local p="$1" base
  [[ -n "$p" ]] || { printf ''; return 0; }
  base="${p##*/}"                       # basename
  base="${base#????-??-??-}"            # strip YYYY-MM-DD-
  base="${base%-design.md}"             # strip -design.md
  base="${base%.md}"                    # strip .md if -design.md missed
  printf '%s\n' "$base"
}

# cw_execute_design_audit_doc <design-path>
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
cw_execute_design_audit_doc() {
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

# cw_execute_design_branch_create <topic> [<branch-name-override>]
# Refuses on dirty tree or pre-existing branch. Prints created branch name.
cw_execute_design_branch_create() {
  local topic="$1" override="${2:-}" branch
  branch="${override:-feat/exec-$topic}"
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

# Phase prompt builders. Each prints a self-contained inbox-prompt body
# terminating in END_OF_INSTRUCTION. The slash directive writes the body
# to inbox.md via bin/send.sh.

cw_execute_design_build_plan_prompt() {
  local design="$1" plan_out="$2"
  cat <<EOF
You are entering the PLAN phase of /clone-wars:execute-design.

Use the superpowers:writing-plans skill. Read the design doc at:
  $design

Produce a comprehensive implementation plan and write it to:
  $plan_out

Follow the writing-plans skill's task-decomposition conventions
(bite-sized steps, exact file paths, complete code, frequent commits).

When the plan file is written, emit a {"event":"done"} line to your
outbox.

END_OF_INSTRUCTION
EOF
}

cw_execute_design_build_implement_prompt() {
  local plan="$1"
  cat <<EOF
You are entering the IMPLEMENT phase of /clone-wars:execute-design.

Use the superpowers:subagent-driven-development skill. Read the plan at:
  $plan

Implement every task in order. For each task: write failing tests, make
them pass, commit per task, run the full test suite after each task and
confirm it stays green. Do not skip tasks. Do not declare done before all
tasks are implemented and all tests pass.

When all tasks are complete and the full test suite is green, emit a
{"event":"done"} line to your outbox.

END_OF_INSTRUCTION
EOF
}

cw_execute_design_build_verify_prompt() {
  local design="$1" round="$2" report="$3" test_log="$4"
  cat <<EOF
You are entering the SELF-VERIFY phase (round $round) of /clone-wars:execute-design.

Use the superpowers:verification-before-completion skill. Verify your
implementation against the design doc at:
  $design

Write your verification report to:
  $report

The report must include:
  - top-line VERDICT: PASS | PARTIAL | FAIL
  - per-requirement verdicts (PASS / PARTIAL / FAIL) with evidence
    (file:line or commit SHA references)

Also run the full test suite and write the raw output to:
  $test_log

When both files are written, emit a {"event":"done"} line to your outbox.

END_OF_INSTRUCTION
EOF
}

cw_execute_design_build_fix_prompt() {
  local fix_prompt="$1"
  cat <<EOF
You are entering the FIX phase of /clone-wars:execute-design.

Cross-verification flagged issues. Read the fix-prompt at:
  $fix_prompt

The file's preamble names the superpowers skill you must use
(systematic-debugging for bugs/regressions, writing-plans for spec gaps).
Resolve every issue listed. Make one commit per fix. Re-run the full
test suite after each fix. Do NOT skip any issue.

When every issue is resolved and the full test suite is green, emit a
{"event":"done"} line to your outbox.

END_OF_INSTRUCTION
EOF
}
