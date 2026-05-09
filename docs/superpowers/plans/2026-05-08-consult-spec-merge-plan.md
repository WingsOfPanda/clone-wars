# v0.17.0 Consult-Spec Merge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge `/clone-wars:spec` into `/clone-wars:consult` so a single command produces a deploy-audit-passing design doc; add auto-detection of multi-repo topics + a per-section design walk + an audit gate.

**Architecture:** Three new lib helpers in a new `lib/consult-walk.sh` module + one new tail script `bin/consult-walk-assemble.sh` + a major directive rewrite that renumbers `commands/consult.md` to clean integers (0–16) and adds three new steps (10 multi-repo detect, 11 walk, 12 audit gate). `/spec` and its supporting files are deleted entirely. Multi-repo docs route to external multi-agent dispatch (out of plugin at v0.17 — later restored in-plugin via /deploy v0.20.0+); /deploy stays single-repo-only at v0.17.

**Tech Stack:** Bash 4.2+, tmux, file IPC under `~/.clone-wars/`. No Node/Python. Tests use `tests/lib/assert.sh` (`assert_file_exists`, `assert_contains`, `pass`) and run via `bash tests/run.sh`.

---

## Existing-codebase orientation (read before Task 1)

Before starting, the implementer should read these files to internalize conventions:

- `CLAUDE.md` — project overview + conventions
- `docs/superpowers/specs/2026-05-08-consult-spec-merge-design.md` — this plan's spec
- `lib/log.sh` — `log_info`, `log_warn`, `log_error`, `log_ok` to stderr
- `lib/state.sh` — `cw_repo_hash`, `cw_state_root`
- `lib/consult.sh` — sourcing pattern, naming pattern (`cw_consult_*`), atomic-write idiom
- `lib/deploy.sh` — `cw_deploy_audit_doc` (constraint surface), `cw_deploy_extract_target`, `CW_SLUG_REGEX_BASE`
- `tests/lib/assert.sh` — assertion helpers
- `tests/run.sh` — test runner
- `tests/test_consult_directive_v016_static_wiring.sh` — pattern for directive static tests
- `commands/consult.md` — current v0.16 directive (the rewrite target)
- `commands/spec.md` — current v0.14 directive (being deleted; copy useful walk patterns)
- `bin/consult-init.sh` — current arg parsing (extending with `--targets`)
- `bin/consult-synthesize.sh` — current synthesize logic (refactoring to emit per-section drafts)

**Convention reminders:**
- All bash scripts start with `#!/usr/bin/env bash` + `set -euo pipefail`
- All lib helpers prefixed `cw_consult_*` or `cw_deploy_*` etc.
- Atomic writes use `printf '%s\n' "$content" > "$tmp" && mv "$tmp" "$final"`
- Tests run from `tests/` dir with `cd "$(dirname "$0")"` + `source lib/assert.sh`
- Each test isolates state via `TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; export CLONE_WARS_HOME="$TMP/cw"`
- No emojis in output. No backwards-compat hacks. Commit after each task.

---

## Task 1: Setup — feature branch + spec/plan link in CLAUDE.md

**Files:**
- Modify: `CLAUDE.md` (add v0.17.0 placeholder line under Status)

- [ ] **Step 1: Create feature branch off main**

```bash
cd /home/liupan/CC/clone-wars
git checkout main && git pull --ff-only origin main
git checkout -b feat/v0.17.0-consult-spec-merge
```

Expected: switched to new branch, clean tree.

- [ ] **Step 2: Add v0.17.0 placeholder to CLAUDE.md status**

Open `CLAUDE.md`, find the `## Status` block (last status entries reference v0.16.0). Add this line at the bottom of the checklist:

```markdown
- [ ] v0.17.0: consult-spec merge — single command from topic to deploy-audit-passing design doc; /spec deleted; multi-repo auto-detect + soft DAG section
```

- [ ] **Step 3: Verify the spec is committed and visible**

```bash
git log --oneline -1 -- docs/superpowers/specs/2026-05-08-consult-spec-merge-design.md
ls docs/superpowers/specs/2026-05-08-consult-spec-merge-design.md
```

Expected: shows commit `b7de2c1 docs(spec): v0.17.0 consult-spec merge design`, file exists.

- [ ] **Step 4: Smoke-test current suite is green on this branch**

```bash
bash tests/run.sh 2>&1 | tail -5
```

Expected: `PASS=N FAIL=0` line. Record N for end-of-plan comparison.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "$(cat <<'EOF'
chore(release): mark v0.17.0 placeholder in CLAUDE.md status

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: lib/consult-walk.sh — `cw_consult_audit_issue_to_section` (pure mapping)

**Files:**
- Create: `lib/consult-walk.sh`
- Test: `tests/test_consult_audit_issue_mapping.sh`

The first helper is the simplest: a pure-bash lookup that maps `cw_deploy_audit_doc`'s `ISSUE=...` keys to draft section file names. Used by Step 12's audit-retry routing.

- [ ] **Step 1: Write the failing test**

Create `tests/test_consult_audit_issue_mapping.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_audit_issue_mapping.sh
#
# cw_consult_audit_issue_to_section maps cw_deploy_audit_doc ISSUE= keys
# to the draft section file (under _consult/design-doc/.draft/) that the
# directive should re-walk. Pure lookup; no I/O.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

source ../lib/consult-walk.sh

# Hard mappings (from spec Error Handling table).
got=$(cw_consult_audit_issue_to_section no_goal_section);     [[ "$got" == "goal" ]]            || { echo "FAIL: no_goal_section -> $got" >&2; exit 1; }
got=$(cw_consult_audit_issue_to_section no_arch_section);     [[ "$got" == "architecture" ]]    || { echo "FAIL: no_arch_section -> $got" >&2; exit 1; }
got=$(cw_consult_audit_issue_to_section no_testing_section);  [[ "$got" == "testing" ]]         || { echo "FAIL: no_testing_section -> $got" >&2; exit 1; }
got=$(cw_consult_audit_issue_to_section no_success_section);  [[ "$got" == "success-criteria" ]] || { echo "FAIL: no_success_section -> $got" >&2; exit 1; }

# Marker issues — caller must AskUserQuestion to identify section, so map to ASK.
for marker in tbd_marker todo_marker fill_in_later_marker to_be_determined_marker; do
  got=$(cw_consult_audit_issue_to_section "$marker")
  [[ "$got" == "ASK" ]] || { echo "FAIL: $marker -> $got (expected ASK)" >&2; exit 1; }
done

# Target Sub-Project slug error → header re-emit, not section walk.
got=$(cw_consult_audit_issue_to_section target_subproject_when_invalid)
[[ "$got" == "header" ]] || { echo "FAIL: target_subproject_when_invalid -> $got (expected header)" >&2; exit 1; }

# Unknown issue → empty (caller treats as fatal).
got=$(cw_consult_audit_issue_to_section bogus_unknown_issue)
[[ -z "$got" ]] || { echo "FAIL: unknown issue -> $got (expected empty)" >&2; exit 1; }

# Missing arg → rc=2.
cw_consult_audit_issue_to_section >/dev/null 2>&1 && { echo "FAIL: empty arg should error" >&2; exit 1; } || rc=$?
[[ "$rc" -eq 2 ]] || { echo "FAIL: empty arg rc=$rc (expected 2)" >&2; exit 1; }

pass "cw_consult_audit_issue_to_section maps all 8 known ISSUE= keys"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
bash tests/test_consult_audit_issue_mapping.sh
```

Expected: fails because `lib/consult-walk.sh` doesn't exist (`No such file or directory`).

- [ ] **Step 3: Create lib/consult-walk.sh with the helper**

Create `lib/consult-walk.sh`:

```bash
#!/usr/bin/env bash
# lib/consult-walk.sh
#
# Helpers for the v0.17.0 design-walk phase of /clone-wars:consult:
#   - cw_consult_audit_issue_to_section: map cw_deploy_audit_doc ISSUE= → section file
#   - cw_consult_emit_soft_dag:          format soft DAG section text from TSV
#   - cw_consult_detect_multi_repo:      cwd siblings + topic prose grep
#   - cw_consult_walk_section_state:     resume state for re-walked sections
#
# Sourcing-only file. No top-level side effects.

# cw_consult_audit_issue_to_section <issue-key>
# Echoes the draft-section name (without .md) that should be re-walked, OR
# the literal string "ASK" when the directive must AskUserQuestion to identify
# the offending section, OR "header" when the issue is in the assembled header
# (not a walked section), OR empty when the issue is unknown.
# rc=0 always on a non-empty arg; rc=2 on missing arg.
cw_consult_audit_issue_to_section() {
  local key="${1:-}"
  [[ -n "$key" ]] || { echo "cw_consult_audit_issue_to_section: issue-key required" >&2; return 2; }
  case "$key" in
    no_goal_section)               printf 'goal\n' ;;
    no_arch_section)               printf 'architecture\n' ;;
    no_testing_section)            printf 'testing\n' ;;
    no_success_section)            printf 'success-criteria\n' ;;
    tbd_marker|todo_marker|fill_in_later_marker|to_be_determined_marker)
                                   printf 'ASK\n' ;;
    target_subproject_when_invalid) printf 'header\n' ;;
    *)                             printf '\n' ;;
  esac
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
bash tests/test_consult_audit_issue_mapping.sh
```

Expected: `PASS: cw_consult_audit_issue_to_section maps all 8 known ISSUE= keys`.

- [ ] **Step 5: Commit**

```bash
git add lib/consult-walk.sh tests/test_consult_audit_issue_mapping.sh
git commit -m "$(cat <<'EOF'
feat(consult-walk): add cw_consult_audit_issue_to_section mapper

Pure lookup that maps cw_deploy_audit_doc ISSUE= keys to draft section
file names (or "ASK" for marker issues that need user input, or "header"
for Target Sub-Project slug errors). First helper in the new
lib/consult-walk.sh module.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: lib/consult-walk.sh — `cw_consult_emit_soft_dag` (formatter)

**Files:**
- Modify: `lib/consult-walk.sh`
- Test: `tests/test_consult_emit_soft_dag.sh`

Format a soft DAG section from a TSV input with columns `<step-num>\t<repo>\t<description>\t<deps-csv|none>`. Output is a numbered list with `(depends on N)` annotations.

- [ ] **Step 1: Write the failing test**

Create `tests/test_consult_emit_soft_dag.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_emit_soft_dag.sh
#
# cw_consult_emit_soft_dag formats a numbered prose DAG from TSV input.
# Each row: <step>\t<repo>\t<description>\t<deps-csv|none>
# Output:    "<step>. <repo> Part X — <description>" + "(depends on N)" if any.
# Soft format — human-readable, copy-pastable into strict grammar by hand.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

source ../lib/consult-walk.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
TSV="$TMP/dag.tsv"

# Single step, no deps.
cat > "$TSV" <<EOF
1	ARS-TaskServe	add registry.yaml field	none
EOF
got=$(cw_consult_emit_soft_dag "$TSV")
expected="1. ARS-TaskServe — add registry.yaml field"
[[ "$got" == "$expected" ]] || { echo "FAIL single-no-deps: got=[$got] expected=[$expected]" >&2; exit 1; }

# Three interleaved steps with chain deps.
cat > "$TSV" <<EOF
1	ARS-TaskServe	add registry.yaml field	none
2	ARS-LVMGateway	consume new field in dispatcher	1
3	ARS-TaskServe	switch dispatcher callers to new field	2
EOF
got=$(cw_consult_emit_soft_dag "$TSV")
expected=$(cat <<EOF
1. ARS-TaskServe — add registry.yaml field
2. ARS-LVMGateway — consume new field in dispatcher (depends on 1)
3. ARS-TaskServe — switch dispatcher callers to new field (depends on 2)
EOF
)
[[ "$got" == "$expected" ]] || { echo "FAIL chain: got=[$got] expected=[$expected]" >&2; exit 1; }

# Multi-dep step.
cat > "$TSV" <<EOF
1	repo-a	produce A	none
2	repo-b	produce B	none
3	repo-c	consume A and B	1,2
EOF
got=$(cw_consult_emit_soft_dag "$TSV")
assert_contains "$got" "3. repo-c — consume A and B (depends on 1, 2)" "multi-dep formatted with comma+space"

# Empty file → empty output, rc=0.
: > "$TSV"
got=$(cw_consult_emit_soft_dag "$TSV")
[[ -z "$got" ]] || { echo "FAIL empty TSV: got=[$got]" >&2; exit 1; }

# Missing arg → rc=2.
cw_consult_emit_soft_dag >/dev/null 2>&1 && { echo "FAIL: empty arg should error" >&2; exit 1; } || rc=$?
[[ "$rc" -eq 2 ]] || { echo "FAIL: empty arg rc=$rc (expected 2)" >&2; exit 1; }

# Missing file → rc=1.
cw_consult_emit_soft_dag "$TMP/nonexistent.tsv" >/dev/null 2>&1 && { echo "FAIL: nonexistent file" >&2; exit 1; } || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: nonexistent rc=$rc (expected 1)" >&2; exit 1; }

pass "cw_consult_emit_soft_dag formats numbered prose with comma-list deps"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
bash tests/test_consult_emit_soft_dag.sh
```

Expected: fails with "command not found: cw_consult_emit_soft_dag" or similar.

- [ ] **Step 3: Implement helper in lib/consult-walk.sh**

Append to `lib/consult-walk.sh`:

```bash
# cw_consult_emit_soft_dag <tsv-path>
# Formats a numbered prose DAG from a TSV file with columns:
#   <step-num>\t<repo>\t<description>\t<deps-csv|none>
# Each output line: "<n>. <repo> — <description>" optionally followed by
# " (depends on M, N, ...)" when deps != "none".
# Empty input → empty output. Missing file → rc=1. Missing arg → rc=2.
cw_consult_emit_soft_dag() {
  local tsv="${1:-}"
  [[ -n "$tsv" ]] || { echo "cw_consult_emit_soft_dag: tsv-path required" >&2; return 2; }
  [[ -f "$tsv" ]] || { echo "cw_consult_emit_soft_dag: file not found: $tsv" >&2; return 1; }
  local step repo desc deps
  while IFS=$'\t' read -r step repo desc deps; do
    [[ -n "$step" ]] || continue
    if [[ "$deps" == "none" || -z "$deps" ]]; then
      printf '%s. %s — %s\n' "$step" "$repo" "$desc"
    else
      # Reformat "1,2" → "1, 2" for readability.
      local pretty_deps
      pretty_deps=$(printf '%s' "$deps" | sed 's/,/, /g')
      printf '%s. %s — %s (depends on %s)\n' "$step" "$repo" "$desc" "$pretty_deps"
    fi
  done < "$tsv"
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
bash tests/test_consult_emit_soft_dag.sh
```

Expected: `PASS: cw_consult_emit_soft_dag formats numbered prose with comma-list deps`.

- [ ] **Step 5: Commit**

```bash
git add lib/consult-walk.sh tests/test_consult_emit_soft_dag.sh
git commit -m "$(cat <<'EOF'
feat(consult-walk): add cw_consult_emit_soft_dag formatter

Reads a TSV (step\trepo\tdescription\tdeps) and emits a numbered prose
DAG with "(depends on N, M)" annotations. Soft format; humans hand-
translate to strict Step <N>: grammar for external multi-agent dispatch.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: lib/consult-walk.sh — `cw_consult_detect_multi_repo`

**Files:**
- Modify: `lib/consult-walk.sh`
- Test: `tests/test_consult_detect_multi_repo.sh`

Walk cwd's siblings looking for `*/CLAUDE.md` and `*/AGENTS.md`. Filter against topic-prose mentions of those slugs. Emit TSV `<slug>\t<absolute-path>` for hits, empty stream when no hits.

- [ ] **Step 1: Write the failing test**

Create `tests/test_consult_detect_multi_repo.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_detect_multi_repo.sh
#
# cw_consult_detect_multi_repo <cwd> <topic-prose>
# Walks $cwd's first-level siblings for CLAUDE.md or AGENTS.md, intersects
# the directory basenames against words in $topic-prose. Emits TSV lines
# "<slug>\t<absolute-path-to-CLAUDE-or-AGENTS-file>" to stdout.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

source ../lib/consult-walk.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Build a fake hub layout:
#   $TMP/hub/api-server/CLAUDE.md       (mentioned in topic)
#   $TMP/hub/auth-service/AGENTS.md     (mentioned in topic)
#   $TMP/hub/billing-stub/CLAUDE.md     (NOT mentioned in topic)
#   $TMP/hub/.hidden/CLAUDE.md          (hidden, skipped)
#   $TMP/hub/no-marker/                  (no marker file, skipped)
mkdir -p "$TMP/hub/api-server" "$TMP/hub/auth-service" "$TMP/hub/billing-stub" \
         "$TMP/hub/.hidden" "$TMP/hub/no-marker"
touch "$TMP/hub/api-server/CLAUDE.md" "$TMP/hub/auth-service/AGENTS.md" \
      "$TMP/hub/billing-stub/CLAUDE.md" "$TMP/hub/.hidden/CLAUDE.md"

TOPIC="plan migration of session storage between api-server and auth-service repos"

got=$(cw_consult_detect_multi_repo "$TMP/hub" "$TOPIC")

# Two hits expected (api-server, auth-service); billing-stub filtered out.
echo "$got" | grep -qE "^api-server\b"    || { echo "FAIL: missing api-server in [$got]" >&2; exit 1; }
echo "$got" | grep -qE "^auth-service\b"  || { echo "FAIL: missing auth-service in [$got]" >&2; exit 1; }
echo "$got" | grep -qE "billing-stub" && { echo "FAIL: billing-stub should be filtered" >&2; exit 1; } || true
echo "$got" | grep -qE "\.hidden"     && { echo "FAIL: .hidden should be skipped" >&2; exit 1; } || true

# Each emitted line is TSV with absolute path.
echo "$got" | while IFS=$'\t' read -r slug path; do
  [[ -f "$path" ]] || { echo "FAIL: emitted path doesn't exist: $path" >&2; exit 1; }
  [[ "$path" = /* ]] || { echo "FAIL: path is not absolute: $path" >&2; exit 1; }
done

# Topic with NO matches → empty stdout, rc=0.
got=$(cw_consult_detect_multi_repo "$TMP/hub" "completely unrelated topic")
[[ -z "$got" ]] || { echo "FAIL: unrelated topic should produce no output, got=[$got]" >&2; exit 1; }

# CWD with no children → empty stdout, rc=0.
mkdir -p "$TMP/empty"
got=$(cw_consult_detect_multi_repo "$TMP/empty" "anything")
[[ -z "$got" ]] || { echo "FAIL: empty cwd should produce no output, got=[$got]" >&2; exit 1; }

# Missing args.
cw_consult_detect_multi_repo "" "topic" >/dev/null 2>&1 && { echo "FAIL: empty cwd should rc=2" >&2; exit 1; } || rc=$?
[[ "$rc" -eq 2 ]] || { echo "FAIL: empty cwd rc=$rc" >&2; exit 1; }
cw_consult_detect_multi_repo "$TMP/hub" "" >/dev/null 2>&1 && { echo "FAIL: empty topic should rc=2" >&2; exit 1; } || rc=$?
[[ "$rc" -eq 2 ]] || { echo "FAIL: empty topic rc=$rc" >&2; exit 1; }

# Non-existent cwd → rc=1.
cw_consult_detect_multi_repo "$TMP/nonexistent" "topic" >/dev/null 2>&1 && { echo "FAIL: missing cwd should rc=1" >&2; exit 1; } || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: missing cwd rc=$rc" >&2; exit 1; }

pass "cw_consult_detect_multi_repo: filters siblings by topic-prose mentions"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
bash tests/test_consult_detect_multi_repo.sh
```

Expected: fails with "command not found: cw_consult_detect_multi_repo".

- [ ] **Step 3: Implement helper in lib/consult-walk.sh**

Append to `lib/consult-walk.sh`:

```bash
# cw_consult_detect_multi_repo <cwd> <topic-prose>
# Walks $cwd's first-level subdirs (skipping dotfiles), keeps those that
# contain a CLAUDE.md or AGENTS.md, and filters them by case-insensitive
# substring match against $topic-prose.
# Emits TSV "<slug>\t<absolute-path>" to stdout, one match per line.
# rc=0 always on valid args (zero hits prints nothing).
# rc=1 if $cwd doesn't exist; rc=2 if either arg empty.
cw_consult_detect_multi_repo() {
  local cwd="${1:-}" topic="${2:-}"
  [[ -n "$cwd"   ]] || { echo "cw_consult_detect_multi_repo: cwd required"   >&2; return 2; }
  [[ -n "$topic" ]] || { echo "cw_consult_detect_multi_repo: topic required" >&2; return 2; }
  [[ -d "$cwd"   ]] || { echo "cw_consult_detect_multi_repo: not a directory: $cwd" >&2; return 1; }
  local topic_lower
  topic_lower=$(printf '%s' "$topic" | tr '[:upper:]' '[:lower:]')
  local entry slug abs marker
  for entry in "$cwd"/*/; do
    [[ -d "$entry" ]] || continue
    slug=$(basename "$entry")
    [[ "$slug" != .* ]] || continue   # skip hidden
    if   [[ -f "$entry/CLAUDE.md" ]]; then marker="$entry/CLAUDE.md"
    elif [[ -f "$entry/AGENTS.md" ]]; then marker="$entry/AGENTS.md"
    else continue
    fi
    # Case-insensitive substring match (slug → topic-lower).
    local slug_lower
    slug_lower=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')
    [[ "$topic_lower" == *"$slug_lower"* ]] || continue
    abs=$(cd "$entry" && pwd)/$(basename "$marker")
    printf '%s\t%s\n' "$slug" "$abs"
  done
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
bash tests/test_consult_detect_multi_repo.sh
```

Expected: `PASS: cw_consult_detect_multi_repo: filters siblings by topic-prose mentions`.

- [ ] **Step 5: Commit**

```bash
git add lib/consult-walk.sh tests/test_consult_detect_multi_repo.sh
git commit -m "$(cat <<'EOF'
feat(consult-walk): add cw_consult_detect_multi_repo

Walks cwd siblings for CLAUDE.md/AGENTS.md, intersects with topic-prose
slug mentions (case-insensitive substring), emits TSV slug\tpath. Skips
hidden dirs. v0.11 auto-detect resurrected (without v0.11's classifier
picker friction).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: lib/consult-walk.sh — `cw_consult_walk_section_state` (resume helper)

**Files:**
- Modify: `lib/consult-walk.sh`
- Test: `tests/test_consult_walk_section_state.sh`

Mirrors the deleted `cw_spec_resume_state`. Reads `$DD_DIR/.draft/` for existing section files; emits one approved-section name per line on stdout.

- [ ] **Step 1: Write the failing test**

Create `tests/test_consult_walk_section_state.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_walk_section_state.sh
#
# cw_consult_walk_section_state <draft-dir>
# Lists the approved (non-skipped) section names that already exist as
# draft files. Used to resume a partial walk after a conductor restart.
# A section file containing only "_(skipped)_" still counts as "decided"
# but emits with a "skipped:" prefix so the directive can re-offer it.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

source ../lib/consult-walk.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
DD="$TMP/.draft"
mkdir -p "$DD"

# Empty dir → empty stdout, rc=0.
got=$(cw_consult_walk_section_state "$DD")
[[ -z "$got" ]] || { echo "FAIL: empty draft dir should produce no output, got=[$got]" >&2; exit 1; }

# Stage three sections: goal approved, architecture skipped, components approved.
printf '## Goal\n\nDescribe the world after this lands.\n' > "$DD/goal.md"
printf '_(skipped)_\n' > "$DD/architecture.md"
printf '## Components\n\n- file A\n- file B\n' > "$DD/components.md"

got=$(cw_consult_walk_section_state "$DD")

# Order is alphabetical (find -name | sort).
echo "$got" | head -1 | grep -qE '^architecture$'        && \
echo "$got" | sed -n '2p' | grep -qE '^components$'      && \
echo "$got" | sed -n '3p' | grep -qE '^goal$'            || {
  echo "FAIL: state order or membership; got=[$got]" >&2
  exit 1
}

# Also assert: the helper must distinguish skipped from approved when the
# caller calls with a "--with-status" flag.
got=$(cw_consult_walk_section_state --with-status "$DD")
echo "$got" | grep -qE '^architecture\tskipped$' || { echo "FAIL: missing skipped tag for architecture; got=[$got]" >&2; exit 1; }
echo "$got" | grep -qE '^goal\tapproved$'        || { echo "FAIL: missing approved tag for goal; got=[$got]" >&2; exit 1; }

# Missing arg → rc=2.
cw_consult_walk_section_state >/dev/null 2>&1 && { echo "FAIL: empty arg should rc=2" >&2; exit 1; } || rc=$?
[[ "$rc" -eq 2 ]] || { echo "FAIL: empty arg rc=$rc" >&2; exit 1; }

# Nonexistent dir → rc=1.
cw_consult_walk_section_state "$TMP/nonexistent" >/dev/null 2>&1 && { echo "FAIL: nonexistent dir should rc=1" >&2; exit 1; } || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: nonexistent dir rc=$rc" >&2; exit 1; }

pass "cw_consult_walk_section_state: lists approved/skipped sections from draft dir"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
bash tests/test_consult_walk_section_state.sh
```

Expected: `command not found: cw_consult_walk_section_state`.

- [ ] **Step 3: Implement helper in lib/consult-walk.sh**

Append to `lib/consult-walk.sh`:

```bash
# cw_consult_walk_section_state [--with-status] <draft-dir>
# Lists section names that already have draft files in $draft-dir, sorted
# alphabetically. With --with-status, emits TSV "<name>\t<approved|skipped>".
# A draft file whose contents are exactly "_(skipped)_" (one line, with or
# without trailing newline) is "skipped"; anything else is "approved".
# rc=0 on success; rc=1 if dir missing; rc=2 if arg missing.
cw_consult_walk_section_state() {
  local with_status=0
  if [[ "${1:-}" == "--with-status" ]]; then
    with_status=1; shift
  fi
  local dir="${1:-}"
  [[ -n "$dir" ]] || { echo "cw_consult_walk_section_state: draft-dir required" >&2; return 2; }
  [[ -d "$dir" ]] || { echo "cw_consult_walk_section_state: not a directory: $dir" >&2; return 1; }
  local f name body
  for f in "$dir"/*.md; do
    [[ -f "$f" ]] || continue
    name=$(basename "$f" .md)
    if (( with_status )); then
      body=$(tr -d '[:space:]' < "$f")
      if [[ "$body" == "_(skipped)_" ]]; then
        printf '%s\tskipped\n' "$name"
      else
        printf '%s\tapproved\n' "$name"
      fi
    else
      printf '%s\n' "$name"
    fi
  done | sort
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
bash tests/test_consult_walk_section_state.sh
```

Expected: `PASS: cw_consult_walk_section_state: lists approved/skipped sections from draft dir`.

- [ ] **Step 5: Commit**

```bash
git add lib/consult-walk.sh tests/test_consult_walk_section_state.sh
git commit -m "$(cat <<'EOF'
feat(consult-walk): add cw_consult_walk_section_state resume helper

Mirrors deleted cw_spec_resume_state. Emits names of section files that
already exist in .draft/, alphabetically sorted; --with-status appends
\tapproved or \tskipped per file body. Lets the directive resume a
partial walk without re-presenting already-approved sections.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: bin/consult-init.sh — `--targets` flag parsing

**Files:**
- Modify: `bin/consult-init.sh`
- Test: `tests/test_consult_targets_flag_parse.sh`

Add an opt-in `--targets a,b,c` flag that bypasses Step 10's auto-detection. The flag is parsed, validated against `CW_SLUG_REGEX_BASE`, and written to `_consult/targets.txt` plus `_consult/multi-repo.txt = multi`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_consult_targets_flag_parse.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_targets_flag_parse.sh
#
# bin/consult-init.sh --targets a,b,c <topic>
# Parses comma-separated slugs, validates each against CW_SLUG_REGEX_BASE,
# writes _consult/targets.txt (TSV slug\tabsolute-CLAUDE.md-path) and
# _consult/multi-repo.txt (single line: "multi"). Auto-detect (Step 10)
# is skipped on subsequent runs because targets.txt exists.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
mkdir -p "$TMP/hub/api-server" "$TMP/hub/auth-service"
touch "$TMP/hub/api-server/CLAUDE.md" "$TMP/hub/auth-service/CLAUDE.md"

# Run from a fake cwd so detect would be relative; init normalizes paths.
cd "$TMP/hub"

# Happy path: two valid slugs.
TOPIC=$(../init_helper.sh 2>/dev/null || echo "session storage migration")
TOPIC_OUT=$(../../bin/consult-init.sh --targets api-server,auth-service "session storage migration")
RH=$(bash -c 'source ../../lib/state.sh; cw_repo_hash')
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC_OUT"
assert_file_exists "$TD/_consult/targets.txt"     "targets.txt written"
assert_file_exists "$TD/_consult/multi-repo.txt"  "multi-repo.txt written"
mode=$(cat "$TD/_consult/multi-repo.txt")
[[ "$mode" == "multi" ]] || { echo "FAIL: multi-repo.txt = [$mode] (expected multi)" >&2; exit 1; }
grep -qE "^api-server\t.*api-server/CLAUDE\.md$"    "$TD/_consult/targets.txt" || { echo "FAIL: api-server row missing or wrong path" >&2; exit 1; }
grep -qE "^auth-service\t.*auth-service/CLAUDE\.md$" "$TD/_consult/targets.txt" || { echo "FAIL: auth-service row missing or wrong path" >&2; exit 1; }

# Invalid slug (uppercase) → rc=1.
rm -rf "$TD"
"../../bin/consult-init.sh" --targets API-SERVER,auth-service "topic-2" 2>/dev/null && { echo "FAIL: uppercase slug should reject" >&2; exit 1; } || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: uppercase rc=$rc (expected 1)" >&2; exit 1; }

# Slug pointing at non-existent dir → rc=1 with clear error.
rm -rf "$TD"
err=$("../../bin/consult-init.sh" --targets api-server,nonexistent "topic-3" 2>&1 1>/dev/null) || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: missing-dir rc=$rc" >&2; exit 1; }
echo "$err" | grep -qE "nonexistent" || { echo "FAIL: error didn't name the missing slug" >&2; exit 1; }

# Empty targets list (--targets with no value or empty value) → rc=1.
"../../bin/consult-init.sh" --targets "" "topic-4" 2>/dev/null && { echo "FAIL: empty targets should reject" >&2; exit 1; } || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: empty rc=$rc" >&2; exit 1; }

# Duplicate slugs → rc=1.
"../../bin/consult-init.sh" --targets api-server,api-server "topic-5" 2>/dev/null && { echo "FAIL: duplicate slugs should reject" >&2; exit 1; } || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: duplicate rc=$rc" >&2; exit 1; }

# Without --targets, behavior is unchanged (no targets.txt, no multi-repo.txt).
TOPIC_OUT=$("../../bin/consult-init.sh" "single-repo topic" 2>/dev/null)
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC_OUT"
[[ ! -f "$TD/_consult/targets.txt" ]]    || { echo "FAIL: targets.txt should not exist without --targets flag" >&2; exit 1; }
[[ ! -f "$TD/_consult/multi-repo.txt" ]] || { echo "FAIL: multi-repo.txt should not exist without --targets flag" >&2; exit 1; }

pass "bin/consult-init.sh --targets parsing + validation works"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
bash tests/test_consult_targets_flag_parse.sh
```

Expected: fails — `--targets` flag is not recognized by current init.sh.

- [ ] **Step 3: Add `--targets` parsing to bin/consult-init.sh**

Open `bin/consult-init.sh`. Find the existing argv-parsing section (it currently accepts only the topic positional arg). Add this block BEFORE topic resolution (replace the existing simple positional-arg handling — the engineer must read the current file first to find the right insertion point):

```bash
# --targets a,b,c parsing (BEFORE topic resolution).
TARGETS_RAW=""
NEW_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --targets)
      shift
      [[ $# -gt 0 ]] || { log_error "--targets: missing value"; exit 1; }
      TARGETS_RAW="$1"
      shift
      ;;
    --targets=*)
      TARGETS_RAW="${1#--targets=}"
      shift
      ;;
    *)
      NEW_ARGS+=("$1")
      shift
      ;;
  esac
done
set -- "${NEW_ARGS[@]:-}"

# Validate + materialize targets BEFORE creating topic dir, so a bad slug
# fails fast.
if [[ -n "$TARGETS_RAW" ]]; then
  source "$(dirname "$0")/../lib/deploy.sh"   # for CW_SLUG_REGEX_BASE
  IFS=',' read -ra TARGET_SLUGS <<< "$TARGETS_RAW"
  [[ ${#TARGET_SLUGS[@]} -gt 0 ]] || { log_error "--targets: empty list"; exit 1; }
  declare -A SEEN
  for s in "${TARGET_SLUGS[@]}"; do
    [[ -n "$s" ]] || { log_error "--targets: empty slug in list"; exit 1; }
    [[ "$s" =~ ^${CW_SLUG_REGEX_BASE}$ ]] || { log_error "--targets: invalid slug '$s' (must match ${CW_SLUG_REGEX_BASE})"; exit 1; }
    [[ -z "${SEEN[$s]:-}" ]] || { log_error "--targets: duplicate slug '$s'"; exit 1; }
    SEEN[$s]=1
    [[ -d "$PWD/$s" ]] || { log_error "--targets: directory not found: $PWD/$s"; exit 1; }
    [[ -f "$PWD/$s/CLAUDE.md" || -f "$PWD/$s/AGENTS.md" ]] \
      || { log_error "--targets: $PWD/$s lacks CLAUDE.md or AGENTS.md"; exit 1; }
  done
fi
```

Then, AFTER the topic dir is created (existing code), append the materialization:

```bash
# Materialize --targets if provided. Auto-detection (Step 10 in directive)
# is skipped when these files already exist.
if [[ -n "$TARGETS_RAW" ]]; then
  TARGETS_FILE="$ARTIFACTS_DIR/targets.txt"
  TMPF=$(mktemp); trap 'rm -f "$TMPF"' EXIT
  printf '# generated %s by bin/consult-init.sh --targets\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TMPF"
  for s in "${TARGET_SLUGS[@]}"; do
    if   [[ -f "$PWD/$s/CLAUDE.md" ]]; then marker="$PWD/$s/CLAUDE.md"
    elif [[ -f "$PWD/$s/AGENTS.md" ]]; then marker="$PWD/$s/AGENTS.md"
    fi
    abs=$(cd "$PWD/$s" && pwd)/$(basename "$marker")
    printf '%s\t%s\n' "$s" "$abs" >> "$TMPF"
  done
  mv "$TMPF" "$TARGETS_FILE"
  printf 'multi\n' > "$ARTIFACTS_DIR/multi-repo.txt"
  log_info "--targets: wrote $TARGETS_FILE (${#TARGET_SLUGS[@]} slugs)"
fi
```

(The exact variable name for the topic's `_consult/` dir in the existing script may be `ARTIFACTS_DIR` or similar — read the existing file to confirm and use the local variable.)

- [ ] **Step 4: Run test to verify it passes**

```bash
bash tests/test_consult_targets_flag_parse.sh
```

Expected: `PASS: bin/consult-init.sh --targets parsing + validation works`.

- [ ] **Step 5: Run full suite to confirm no regressions**

```bash
bash tests/run.sh 2>&1 | tail -5
```

Expected: `FAIL=0`. PASS count grew by 4 (new tests from Tasks 2-5 + this Task 6).

- [ ] **Step 6: Commit**

```bash
git add bin/consult-init.sh tests/test_consult_targets_flag_parse.sh
git commit -m "$(cat <<'EOF'
feat(consult-init): add --targets a,b,c flag for explicit multi-repo

Parses comma-separated slugs, validates each against CW_SLUG_REGEX_BASE,
checks directory existence + CLAUDE.md/AGENTS.md presence, writes
_consult/targets.txt and _consult/multi-repo.txt=multi. When --targets
is provided, the directive's Step 10 auto-detect is bypassed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: bin/consult-synthesize.sh — refactor to per-section seed drafts

**Files:**
- Modify: `bin/consult-synthesize.sh`
- Test: `tests/test_consult_synthesize_per_section_drafts.sh`

Currently `consult-synthesize.sh` writes the single 6-section design-doc directly. Refactor: produce SEED drafts per section under `$DD_DIR/.draft/<section>.md`, NOT the final assembled doc. The directive's Step 11 walk consumes these as starting points for Yoda's per-section drafts.

This is a behavior change for the synthesize script. The final doc is no longer its responsibility — that moves to `bin/consult-walk-assemble.sh` (Task 8).

- [ ] **Step 1: Write the failing test**

Create `tests/test_consult_synthesize_per_section_drafts.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_synthesize_per_section_drafts.sh
#
# v0.17.0: bin/consult-synthesize.sh produces seed drafts under
# _consult/design-doc/.draft/{problem,goal,architecture,components,testing,success-criteria}.md
# from the adjudicated.md content. It does NOT emit a final design doc;
# that's bin/consult-walk-assemble.sh's job.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=consult-fixture-syn-v17
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_consult/design-doc/.draft"

echo "v0.17 seed-draft synthesis test" > "$TD/_consult/topic.txt"
cat > "$TD/_consult/troopers.txt" <<EOF
codex	rex
claude	cody
EOF

# Stage minimum prerequisites: stage status files for both research and verify.
for stage in research verify; do
  for cmdr in rex cody; do
    cat > "$TD/_consult/$stage-$cmdr.txt" <<EOF
OFFSET=0
$( [[ "$stage" == research ]] && echo FS=ok || echo VS=ok )
EOF
  done
done

# Stage adjudicated.md with cross-verified content covering each section
# topic (synthesize uses heuristics to map content to sections).
cat > "$TD/_consult/adjudicated.md" <<'MD'
## Cross-verified
- [src/auth.py:42] Session storage uses postgres `sessions` table currently. — verified
- [Goal] Migrate to redis-backed session storage with TTL = 24h. — both agree
- [Architecture] Use redis-py with connection pool sized to 20. — both agree
- [Components] auth-service/middleware.py + api-server/session_loader.py. — both agree
- [Testing] redis-py mock in unit tests, real redis in integration. — both agree
- [Success Criteria] p99 session-read latency < 5ms. — both agree

## Adjudicated

## Contested

## Not-verified
MD

# Stage diff.md with an Agreed section.
cat > "$TD/_consult/diff.md" <<'MD'
## Agreed
- [overlap] postgres → redis migration is the goal
## Rex-only
## Cody-only
MD

# Run synthesize.
../bin/consult-synthesize.sh "$TOPIC" >/dev/null

# Each of the 6 single-repo sections must have a seed draft file.
for section in problem goal architecture components testing success-criteria; do
  assert_file_exists "$TD/_consult/design-doc/.draft/$section.md" "$section seed draft exists"
  body=$(cat "$TD/_consult/design-doc/.draft/$section.md")
  [[ -n "$body" ]] || { echo "FAIL: $section seed draft is empty" >&2; exit 1; }
done

# v0.17 negative: NO final design-doc emitted by synthesize. (walk-assemble
# is responsible for that.)
DD=$(find "$TD/_consult/design-doc" -maxdepth 1 -name '*-design.md' 2>/dev/null | head -1)
[[ -z "$DD" ]] || { echo "FAIL: synthesize emitted final design doc $DD (should be walk-assemble's job)" >&2; exit 1; }

# v0.17 negative: NO synthesis.md (legacy v0.12 file).
[[ ! -f "$TD/_consult/synthesis.md" ]] || { echo "FAIL: legacy synthesis.md still emitted" >&2; exit 1; }

pass "v0.17.0 consult-synthesize.sh emits per-section seed drafts only"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
bash tests/test_consult_synthesize_per_section_drafts.sh
```

Expected: fails because synthesize still emits a final `*-design.md` instead of per-section seeds.

- [ ] **Step 3: Refactor bin/consult-synthesize.sh**

Open `bin/consult-synthesize.sh`. Read the current file fully. The existing logic constructs a single design-doc from `adjudicated.md` + headers. Replace the "write final doc" block with a per-section split:

Replace the block that currently does:

```bash
DESIGN_DOC=$(cw_consult_design_doc_canonical_path "$ARTIFACTS_DIR" "$SLUG")
# ... old: assemble all sections + headers + write to $DESIGN_DOC
```

With a per-section draft writer:

```bash
DRAFT_DIR="$ARTIFACTS_DIR/design-doc/.draft"
mkdir -p "$DRAFT_DIR"

# Sections produced by synthesize as seed drafts. Yoda re-drafts each via
# the per-section walk in commands/consult.md Step 11. v0.17.0 single-repo
# shape: 6 sections. Multi-repo extras (execution-dag, cross-repo-notes)
# are NOT seeded here — Yoda drafts them fresh during the walk because they
# require targets.txt content.
SECTIONS=(problem goal architecture components testing success-criteria)
for section in "${SECTIONS[@]}"; do
  case "$section" in
    problem)          heading="## Problem" ;;
    goal)             heading="## Goal" ;;
    architecture)     heading="## Architecture" ;;
    components)       heading="## Components" ;;
    testing)          heading="## Testing" ;;
    success-criteria) heading="## Success Criteria" ;;
  esac
  DRAFT_FILE="$DRAFT_DIR/$section.md"
  TMPF=$(mktemp)
  printf '%s\n\n' "$heading" > "$TMPF"
  # Seed body: adjudicated lines whose [tag] mentions this section heuristically.
  case "$section" in
    problem)
      printf '<!-- seed: cross-verified facts about the current state -->\n' >> "$TMPF"
      grep -E '^- \[' "$ARTIFACTS_DIR/adjudicated.md" | head -5 >> "$TMPF" || true ;;
    goal)
      printf '<!-- seed: claims tagged [Goal] in adjudicated.md -->\n' >> "$TMPF"
      grep -iE '^- \[Goal' "$ARTIFACTS_DIR/adjudicated.md" >> "$TMPF" || true ;;
    architecture)
      printf '<!-- seed: claims tagged [Architecture] -->\n' >> "$TMPF"
      grep -iE '^- \[Architecture' "$ARTIFACTS_DIR/adjudicated.md" >> "$TMPF" || true ;;
    components)
      printf '<!-- seed: claims tagged [Components] -->\n' >> "$TMPF"
      grep -iE '^- \[Components' "$ARTIFACTS_DIR/adjudicated.md" >> "$TMPF" || true ;;
    testing)
      printf '<!-- seed: claims tagged [Testing] or containing "test" -->\n' >> "$TMPF"
      grep -iE '^- \[Testing|^- .*\btest' "$ARTIFACTS_DIR/adjudicated.md" >> "$TMPF" || true ;;
    success-criteria)
      printf '<!-- seed: claims tagged [Success Criteria] -->\n' >> "$TMPF"
      grep -iE '^- \[Success' "$ARTIFACTS_DIR/adjudicated.md" >> "$TMPF" || true ;;
  esac
  # Ensure non-empty body so test assert passes.
  if [[ $(wc -l < "$TMPF") -le 2 ]]; then
    printf '_(no seed content matched; Yoda drafts from scratch in Step 11)_\n' >> "$TMPF"
  fi
  mv "$TMPF" "$DRAFT_FILE"
done

log_info "[synthesize] wrote ${#SECTIONS[@]} seed drafts to $DRAFT_DIR"
```

Important: also DELETE any code that writes `synthesis.md` (legacy v0.12 path) — that file should not be emitted in v0.17.

- [ ] **Step 4: Run test to verify it passes**

```bash
bash tests/test_consult_synthesize_per_section_drafts.sh
```

Expected: `PASS: v0.17.0 consult-synthesize.sh emits per-section seed drafts only`.

- [ ] **Step 5: Run the suite — some 3-trooper synthesize tests will fail**

```bash
bash tests/run.sh 2>&1 | tail -10
```

Expected: 1+ FAIL from existing tests like `test_consult_3trooper_synthesize.sh` that asserted the old `*-design.md` shape. These tests are NOW STALE — they were testing v0.16.0 synthesis behavior that no longer exists. Mark them for the next task.

- [ ] **Step 6: Update or delete v0.16-shaped synthesize tests**

For each failing test that was asserting v0.16's `consult-synthesize.sh` final-doc emission:
- If the test's intent (e.g., 3-trooper tag propagation) is still relevant for v0.17, REWRITE it to assert tag propagation in the SEED DRAFTS instead of the final doc.
- If the test was specifically validating the v0.16 final-doc shape (now walk-assemble's job), DELETE it — Tasks 8-10 cover the new tests.

For `tests/test_consult_3trooper_synthesize.sh`: rewrite the assertions from `assert_contains "$DD_CONTENT" '[rex+cody+bly]'` to `assert_contains "$(cat $DRAFT_DIR/architecture.md)" '[rex+cody+bly]'` (or whichever seed-section the tag was expected in). Same source-set cases, different file.

Run again:

```bash
bash tests/run.sh 2>&1 | tail -5
```

Expected: `FAIL=0`.

- [ ] **Step 7: Commit**

```bash
git add bin/consult-synthesize.sh tests/test_consult_synthesize_per_section_drafts.sh tests/test_consult_3trooper_synthesize.sh
git commit -m "$(cat <<'EOF'
refactor(consult-synthesize): emit per-section seed drafts under .draft/

Synthesize no longer writes a final design doc; that moves to
bin/consult-walk-assemble.sh in Task 8. Instead it splits adjudicated.md
into 6 seed drafts (problem/goal/architecture/components/testing/success-
criteria) under _consult/design-doc/.draft/ for the directive's per-
section walk in Step 11 to consume.

Updated test_consult_3trooper_synthesize.sh to assert tag propagation
in seed drafts rather than the legacy *-design.md path.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: bin/consult-walk-assemble.sh — single-repo path

**Files:**
- Create: `bin/consult-walk-assemble.sh`
- Test: `tests/test_consult_assemble_master_doc_single.sh`

This is the new tail script. It concatenates approved `.draft/<section>.md` files into the canonical design-doc, in the right order, with H1 + frontmatter (multi-repo only). Single-repo path first.

- [ ] **Step 1: Write the failing test**

Create `tests/test_consult_assemble_master_doc_single.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_assemble_master_doc_single.sh
#
# bin/consult-walk-assemble.sh <topic>
# In single-repo mode (no multi-repo.txt OR contents="single"), reads:
#   _consult/design-doc/.draft/{problem,goal,architecture,components,
#                              testing,success-criteria}.md
# and concatenates them into:
#   _consult/design-doc/<YYYY-MM-DD>-<slug>-design.md
# with an H1 derived from topic.txt's first line.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=consult-asm-single-test
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
DR="$TD/_consult/design-doc/.draft"
mkdir -p "$DR"

echo "Add Redis caching to API layer" > "$TD/_consult/topic.txt"

# Stage 6 approved sections.
printf '## Problem\n\nAPI reads from postgres on every request, p99 = 220ms.\n' > "$DR/problem.md"
printf '## Goal\n\nDrop p99 to <50ms by caching session reads in Redis.\n' > "$DR/goal.md"
printf '## Architecture\n\nIntroduce a redis-py client with TTL=300s.\n' > "$DR/architecture.md"
printf '## Components\n\n- src/cache.py (new)\n- src/api.py (modified)\n' > "$DR/components.md"
printf '## Testing\n\n- redis-py mock in unit tests\n- real redis in integration\n' > "$DR/testing.md"
printf '## Success Criteria\n\n- [ ] p99 read latency < 50ms\n- [ ] cache hit rate > 80%%\n' > "$DR/success-criteria.md"

# Run.
DD_PATH=$(../bin/consult-walk-assemble.sh "$TOPIC")

# Path matches canonical pattern.
[[ "$DD_PATH" =~ /design-doc/[0-9]{4}-[0-9]{2}-[0-9]{2}-asm-single-test-design\.md$ ]] \
  || { echo "FAIL: path doesn't match canonical pattern: $DD_PATH" >&2; exit 1; }
assert_file_exists "$DD_PATH" "design-doc written"

# H1 reflects topic.txt.
head -1 "$DD_PATH" | grep -qE '^# Add Redis caching to API layer$' \
  || { echo "FAIL: H1 not derived from topic.txt; got: $(head -1 "$DD_PATH")" >&2; exit 1; }

# All 6 sections present in correct order.
EXPECTED_ORDER="^## Problem
^## Goal
^## Architecture
^## Components
^## Testing
^## Success Criteria"
ACTUAL_ORDER=$(grep -E '^## ' "$DD_PATH")
[[ "$ACTUAL_ORDER" == "## Problem
## Goal
## Architecture
## Components
## Testing
## Success Criteria" ]] || { echo "FAIL: section order wrong; got: $ACTUAL_ORDER" >&2; exit 1; }

# No multi-repo header in single-repo mode.
grep -qE '\*\*Target Sub-Project' "$DD_PATH" && { echo "FAIL: single-repo doc has Target Sub-Project header" >&2; exit 1; } || true

# Skipped sections are tolerated (test that too).
printf '_(skipped)_\n' > "$DR/components.md"
DD_PATH2=$(../bin/consult-walk-assemble.sh "$TOPIC")
grep -qE '^## Components$' "$DD_PATH2"  || { echo "FAIL: heading missing for skipped section" >&2; exit 1; }
grep -qE '_\(skipped\)_'   "$DD_PATH2"  || { echo "FAIL: skipped marker missing in body" >&2; exit 1; }

pass "consult-walk-assemble.sh single-repo: 6 sections concatenated in order"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
bash tests/test_consult_assemble_master_doc_single.sh
```

Expected: fails — `bin/consult-walk-assemble.sh` doesn't exist.

- [ ] **Step 3: Create bin/consult-walk-assemble.sh**

```bash
#!/usr/bin/env bash
# bin/consult-walk-assemble.sh <topic>
#
# Concatenates approved .draft/<section>.md files into the canonical
# design-doc at _consult/design-doc/<YYYY-MM-DD>-<slug>-design.md.
# Single-repo: 6 sections (problem/goal/architecture/components/testing/
# success-criteria). Multi-repo (Task 9): 8 sections + Target Sub-Project(s)
# header. Audit gate (Task 10): runs cw_deploy_audit_doc, exits non-zero
# on FAIL with ISSUE= lines on stderr.
#
# Echoes the absolute path of the written design-doc on stdout.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/log.sh"
source "$ROOT/lib/state.sh"
source "$ROOT/lib/consult.sh"

TOPIC="${1:-}"
[[ -n "$TOPIC" ]] || { log_error "consult-walk-assemble: <topic> required"; exit 2; }

REPO_HASH=$(cw_repo_hash)
STATE_ROOT=$(cw_state_root)
TD="$STATE_ROOT/state/$REPO_HASH/$TOPIC"
ART="$TD/_consult"
DR="$ART/design-doc/.draft"

[[ -d "$DR" ]] || { log_error "consult-walk-assemble: draft dir not found: $DR"; exit 1; }
[[ -f "$ART/topic.txt" ]] || { log_error "consult-walk-assemble: topic.txt not found"; exit 1; }

# H1 from topic.txt's first line.
TITLE=$(head -1 "$ART/topic.txt")
SLUG="${TOPIC#consult-}"
DATE=$(date -u +%Y-%m-%d)
OUT="$ART/design-doc/$DATE-$SLUG-design.md"

# Single-repo section order.
SECTIONS=(problem goal architecture components testing success-criteria)

TMPF=$(mktemp); trap 'rm -f "$TMPF"' EXIT

printf '# %s\n\n' "$TITLE" > "$TMPF"

for section in "${SECTIONS[@]}"; do
  src="$DR/$section.md"
  if [[ -f "$src" ]]; then
    cat "$src" >> "$TMPF"
    printf '\n' >> "$TMPF"
  else
    # Missing draft — emit empty heading (will fail audit; user re-walks).
    case "$section" in
      problem)          heading="## Problem" ;;
      goal)             heading="## Goal" ;;
      architecture)     heading="## Architecture" ;;
      components)       heading="## Components" ;;
      testing)          heading="## Testing" ;;
      success-criteria) heading="## Success Criteria" ;;
    esac
    printf '%s\n\n_(missing draft)_\n\n' "$heading" >> "$TMPF"
  fi
done

mv "$TMPF" "$OUT"
trap - EXIT
log_info "[walk-assemble] wrote $OUT"
printf '%s\n' "$OUT"
```

Make it executable:

```bash
chmod +x bin/consult-walk-assemble.sh
```

- [ ] **Step 4: Run test to verify it passes**

```bash
bash tests/test_consult_assemble_master_doc_single.sh
```

Expected: `PASS: consult-walk-assemble.sh single-repo: 6 sections concatenated in order`.

- [ ] **Step 5: Commit**

```bash
git add bin/consult-walk-assemble.sh tests/test_consult_assemble_master_doc_single.sh
git commit -m "$(cat <<'EOF'
feat(consult-walk-assemble): scaffold single-repo assembly

New tail script that concatenates approved .draft/<section>.md files
into the canonical design-doc with H1 from topic.txt. Single-repo
shape: 6 sections in order. Multi-repo header injection + audit gate
land in Tasks 9-10.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: bin/consult-walk-assemble.sh — multi-repo path

**Files:**
- Modify: `bin/consult-walk-assemble.sh`
- Test: `tests/test_consult_assemble_master_doc_multi.sh`

Add multi-repo handling: when `_consult/multi-repo.txt = multi`, inject `**Date:**` + `**Target Sub-Project(s):**` header lines after H1, and include `execution-dag.md` + `cross-repo-notes.md` between Components and Testing.

- [ ] **Step 1: Write the failing test**

Create `tests/test_consult_assemble_master_doc_multi.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_assemble_master_doc_multi.sh
#
# Multi-repo: when _consult/multi-repo.txt = "multi" and targets.txt exists,
# walk-assemble injects:
#   - **Date:** YYYY-MM-DD line after H1
#   - **Target Sub-Project(s):** slug-a, slug-b, slug-c line after Date
#   - ## Execution DAG between Components and Testing
#   - ## Cross-Repo Notes between Execution DAG and Testing
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=consult-asm-multi-test
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
DR="$TD/_consult/design-doc/.draft"
mkdir -p "$DR" "$TMP/hub/api-server" "$TMP/hub/auth-service"
touch "$TMP/hub/api-server/CLAUDE.md" "$TMP/hub/auth-service/CLAUDE.md"

echo "Migrate session storage from postgres to redis" > "$TD/_consult/topic.txt"
printf 'multi\n' > "$TD/_consult/multi-repo.txt"
{
  printf '# generated 2026-05-08T10:00:00Z by bin/consult-init.sh --targets\n'
  printf 'api-server\t%s/hub/api-server/CLAUDE.md\n' "$TMP"
  printf 'auth-service\t%s/hub/auth-service/CLAUDE.md\n' "$TMP"
} > "$TD/_consult/targets.txt"

# Stage 8 approved drafts (6 base + execution-dag + cross-repo-notes).
printf '## Problem\n\nSession reads on every request.\n' > "$DR/problem.md"
printf '## Goal\n\nSub-50ms session reads.\n' > "$DR/goal.md"
printf '## Architecture\n\n### api-server\n\nUse redis-py client.\n\n### auth-service\n\nMigrate writes too.\n' > "$DR/architecture.md"
printf '## Components\n\n- api-server/cache.py\n- auth-service/storage.py\n' > "$DR/components.md"
printf '## Execution DAG\n\n1. auth-service — migrate write path\n2. api-server — switch read path (depends on 1)\n' > "$DR/execution-dag.md"
printf '## Cross-Repo Notes\n\nauth-service must roll out before api-server.\n' > "$DR/cross-repo-notes.md"
printf '## Testing\n\nIntegration tests cover both repos.\n' > "$DR/testing.md"
printf '## Success Criteria\n\n- [ ] p99 < 50ms\n' > "$DR/success-criteria.md"

DD=$(../bin/consult-walk-assemble.sh "$TOPIC")

# H1 + frontmatter ordering.
head -10 "$DD" | head -1 | grep -qE '^# Migrate session storage from postgres to redis$'         || { echo "FAIL: H1 wrong" >&2; exit 1; }
head -10 "$DD" | grep -qE '^\*\*Date:\*\* [0-9]{4}-[0-9]{2}-[0-9]{2}$'                            || { echo "FAIL: Date frontmatter missing" >&2; exit 1; }
head -10 "$DD" | grep -qE '^\*\*Target Sub-Project\(s\):\*\* api-server, auth-service$'           || { echo "FAIL: Target Sub-Project(s) header wrong" >&2; exit 1; }

# 8 H2 sections in order.
ACTUAL=$(grep -E '^## ' "$DD")
EXPECTED="## Problem
## Goal
## Architecture
## Components
## Execution DAG
## Cross-Repo Notes
## Testing
## Success Criteria"
[[ "$ACTUAL" == "$EXPECTED" ]] || { echo "FAIL: section order; got=[$ACTUAL]" >&2; exit 1; }

# Per-repo subsections preserved under Architecture.
sed -n '/^## Architecture/,/^## Components/p' "$DD" | grep -qE '^### api-server$'    || { echo "FAIL: ### api-server subsection missing" >&2; exit 1; }
sed -n '/^## Architecture/,/^## Components/p' "$DD" | grep -qE '^### auth-service$'  || { echo "FAIL: ### auth-service subsection missing" >&2; exit 1; }

pass "consult-walk-assemble.sh multi-repo: 8 sections + Target Sub-Project(s) header"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
bash tests/test_consult_assemble_master_doc_multi.sh
```

Expected: fails (single-repo logic doesn't inject multi-repo bits).

- [ ] **Step 3: Add multi-repo branching to bin/consult-walk-assemble.sh**

Open `bin/consult-walk-assemble.sh`. After the `SLUG=...; DATE=...; OUT=...` block, add:

```bash
# Multi-repo detection: read _consult/multi-repo.txt + targets.txt.
MULTI_REPO=0
TARGET_SLUGS=""
if [[ -f "$ART/multi-repo.txt" ]]; then
  mode=$(tr -d '[:space:]' < "$ART/multi-repo.txt")
  if [[ "$mode" == "multi" ]]; then
    [[ -f "$ART/targets.txt" ]] || { log_error "walk-assemble: multi-repo.txt=multi but targets.txt missing"; exit 1; }
    MULTI_REPO=1
    # Extract slug column (first TSV col), skip comments, comma-join.
    TARGET_SLUGS=$(grep -v '^#' "$ART/targets.txt" | awk -F'\t' '{print $1}' | paste -sd ',' - | sed 's/,/, /g')
  fi
fi

# Section order depends on mode.
if (( MULTI_REPO )); then
  SECTIONS=(problem goal architecture components execution-dag cross-repo-notes testing success-criteria)
else
  SECTIONS=(problem goal architecture components testing success-criteria)
fi
```

(Replace the existing `SECTIONS=(problem goal ...)` line with this conditional block.)

After the H1 line in the assembly loop, inject multi-repo frontmatter:

```bash
printf '# %s\n\n' "$TITLE" > "$TMPF"

# Multi-repo: emit Date + Target Sub-Project(s) frontmatter immediately after H1.
if (( MULTI_REPO )); then
  printf '**Date:** %s\n' "$DATE" >> "$TMPF"
  printf '**Target Sub-Project(s):** %s\n\n' "$TARGET_SLUGS" >> "$TMPF"
fi
```

Also update the missing-draft fallback block to handle the two new section names:

```bash
case "$section" in
  problem)          heading="## Problem" ;;
  goal)             heading="## Goal" ;;
  architecture)     heading="## Architecture" ;;
  components)       heading="## Components" ;;
  execution-dag)    heading="## Execution DAG" ;;
  cross-repo-notes) heading="## Cross-Repo Notes" ;;
  testing)          heading="## Testing" ;;
  success-criteria) heading="## Success Criteria" ;;
esac
```

- [ ] **Step 4: Run multi-repo test**

```bash
bash tests/test_consult_assemble_master_doc_multi.sh
```

Expected: `PASS: consult-walk-assemble.sh multi-repo: 8 sections + Target Sub-Project(s) header`.

- [ ] **Step 5: Re-run single-repo test (regression check)**

```bash
bash tests/test_consult_assemble_master_doc_single.sh
```

Expected: still PASSES — single-repo path unchanged.

- [ ] **Step 6: Commit**

```bash
git add bin/consult-walk-assemble.sh tests/test_consult_assemble_master_doc_multi.sh
git commit -m "$(cat <<'EOF'
feat(consult-walk-assemble): multi-repo branch

When _consult/multi-repo.txt=multi + targets.txt present, inject
**Date:** + **Target Sub-Project(s):** frontmatter after H1 and include
execution-dag + cross-repo-notes sections in the assembly order. Slugs
are read from targets.txt's first TSV column and comma-joined.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: bin/consult-walk-assemble.sh — audit gate

**Files:**
- Modify: `bin/consult-walk-assemble.sh`
- Test: `tests/test_consult_assemble_audit_gate.sh`
- Test: `tests/test_consult_assemble_audit_retry_mapping.sh`

After assembly, run `cw_deploy_audit_doc` on the written file. On PASS, exit 0 with the path. On FAIL, write the audit verdict to `audit.log`, emit `ISSUE=...` lines to stderr (one per failure), and exit 1.

- [ ] **Step 1: Write the audit-gate test (happy path)**

Create `tests/test_consult_assemble_audit_gate.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_assemble_audit_gate.sh
#
# walk-assemble runs cw_deploy_audit_doc on the assembled doc.
# - PASS: exit 0, write audit.log with VERDICT=PASS, echo path on stdout
# - FAIL: exit 1, write audit.log with VERDICT=FAIL + ISSUE= lines,
#         echo ISSUE= lines on stderr, no path on stdout
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=consult-asm-audit-test
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
DR="$TD/_consult/design-doc/.draft"
mkdir -p "$DR"
echo "Audit gate test" > "$TD/_consult/topic.txt"

# Happy path: all 6 sections present + non-empty.
printf '## Problem\nx\n' > "$DR/problem.md"
printf '## Goal\nx\n' > "$DR/goal.md"
printf '## Architecture\nx\n' > "$DR/architecture.md"
printf '## Components\nx\n' > "$DR/components.md"
printf '## Testing\nx\n' > "$DR/testing.md"
printf '## Success Criteria\nx\n' > "$DR/success-criteria.md"

DD=$(../bin/consult-walk-assemble.sh "$TOPIC" 2>/dev/null)
assert_file_exists "$DD" "design-doc written on PASS"
assert_file_exists "$TD/_consult/design-doc/audit.log" "audit.log written"
grep -qE '^VERDICT=PASS$' "$TD/_consult/design-doc/audit.log" || { echo "FAIL: audit.log doesn't say PASS" >&2; exit 1; }

# Sad path: skip success-criteria → audit FAILS with no_success_section.
rm -f "$TD/_consult/design-doc"/*-design.md "$TD/_consult/design-doc/audit.log"
printf '_(skipped)_\n' > "$DR/success-criteria.md"
ERR=$(../bin/consult-walk-assemble.sh "$TOPIC" 2>&1 >/dev/null) && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: expected exit 1 on audit FAIL, got $rc" >&2; exit 1; }
echo "$ERR" | grep -qE '^ISSUE=no_success_section$' || { echo "FAIL: no_success_section ISSUE not on stderr; got=[$ERR]" >&2; exit 1; }
grep -qE '^VERDICT=FAIL$' "$TD/_consult/design-doc/audit.log"        || { echo "FAIL: audit.log doesn't say FAIL" >&2; exit 1; }
grep -qE '^ISSUE=no_success_section$' "$TD/_consult/design-doc/audit.log" || { echo "FAIL: audit.log missing ISSUE row" >&2; exit 1; }

pass "walk-assemble audit gate: PASS exits 0 with path; FAIL exits 1 with ISSUE= lines"
```

- [ ] **Step 2: Write the retry-mapping test**

Create `tests/test_consult_assemble_audit_retry_mapping.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_assemble_audit_retry_mapping.sh
#
# Sanity check: every ISSUE= cw_deploy_audit_doc emits maps to a section
# (or ASK or header) via cw_consult_audit_issue_to_section. Catches drift
# if either side adds a key the other doesn't know about.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

source ../lib/consult-walk.sh
source ../lib/deploy.sh

# Extract every literal ISSUE= key cw_deploy_audit_doc can emit.
ISSUE_KEYS=$(grep -oE 'issues\+=\("[a-z_]+"\)' ../lib/deploy.sh | sed 's/issues+=("//; s/")$//' | sort -u)
[[ -n "$ISSUE_KEYS" ]] || { echo "FAIL: couldn't extract any ISSUE keys from lib/deploy.sh" >&2; exit 1; }

while IFS= read -r key; do
  got=$(cw_consult_audit_issue_to_section "$key")
  [[ -n "$got" ]] || { echo "FAIL: cw_consult_audit_issue_to_section knows no mapping for ISSUE=$key" >&2; exit 1; }
done <<< "$ISSUE_KEYS"

pass "all cw_deploy_audit_doc ISSUE= keys are mapped by cw_consult_audit_issue_to_section"
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
bash tests/test_consult_assemble_audit_gate.sh
bash tests/test_consult_assemble_audit_retry_mapping.sh
```

Expected: gate test fails (no audit logic in walk-assemble yet); mapping test passes (Task 2's mapping covers all current keys).

- [ ] **Step 4: Add audit gate to bin/consult-walk-assemble.sh**

Open `bin/consult-walk-assemble.sh`. At the bottom, BEFORE the existing `printf '%s\n' "$OUT"` line, add:

```bash
# Audit gate.
source "$ROOT/lib/deploy.sh"
AUDIT_LOG="$ART/design-doc/audit.log"
AUDIT_OUT=$(cw_deploy_audit_doc "$OUT" 2>&1) && AUDIT_RC=0 || AUDIT_RC=$?
printf '%s\n' "$AUDIT_OUT" > "$AUDIT_LOG"
if (( AUDIT_RC != 0 )); then
  # Emit ISSUE= lines (and only ISSUE= lines) on stderr for the directive
  # to parse and route to per-section re-walks via
  # cw_consult_audit_issue_to_section.
  echo "$AUDIT_OUT" | grep -E '^ISSUE=' >&2 || true
  log_error "walk-assemble: cw_deploy_audit_doc FAILED on $OUT (see $AUDIT_LOG)"
  exit 1
fi
log_info "[walk-assemble] audit PASSED for $OUT"
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
bash tests/test_consult_assemble_audit_gate.sh
bash tests/test_consult_assemble_audit_retry_mapping.sh
```

Expected: both PASS.

- [ ] **Step 6: Run full suite**

```bash
bash tests/run.sh 2>&1 | tail -5
```

Expected: `FAIL=0`. New tests added so far this branch should all be green.

- [ ] **Step 7: Commit**

```bash
git add bin/consult-walk-assemble.sh \
        tests/test_consult_assemble_audit_gate.sh \
        tests/test_consult_assemble_audit_retry_mapping.sh
git commit -m "$(cat <<'EOF'
feat(consult-walk-assemble): add cw_deploy_audit_doc gate

After assembly, run cw_deploy_audit_doc. On PASS write audit.log +
exit 0 with path on stdout. On FAIL write audit.log + emit ISSUE=
lines on stderr + exit 1, so the directive can parse them via
cw_consult_audit_issue_to_section and re-walk the offending section.

Mapping-drift test guards against new ISSUE= keys in
cw_deploy_audit_doc that aren't recognized by the walk mapper.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: commands/consult.md — renumber 0-16 + replace synthesize with walk

**Files:**
- Modify: `commands/consult.md`
- Test: (none yet — directive walks are integration-tested in Task 17)

This is the largest single edit. The directive currently has Steps 0, 0.4, 0.5, 1-10. Renumber to clean integers 0-16. The synthesize step (currently Step 8) is REPLACED with a walk-assemble dispatch — synthesize.sh now produces seed drafts, the walk happens during the directive, and walk-assemble.sh is the new tail.

This task does the renumbering ONLY. Multi-repo detect and walk integration land in Tasks 12-13.

- [ ] **Step 1: Read the current directive**

```bash
wc -l commands/consult.md
grep -nE '^### Step ' commands/consult.md
```

Note the existing step boundaries.

- [ ] **Step 2: Apply the renumbering**

For each step heading in `commands/consult.md`, rewrite per this table:

| Current | New |
|---|---|
| `### Step 0 — args-file...` | `### Step 0 — args-file + init + roster` |
| `### Step 0.4 — Escalation phrasing-trigger detection (v0.16.0)` | `### Step 1 — Escalation phrasing-trigger detection` |
| `### Step 0.5 — Yoda fast-path (v0.16.0)` | `### Step 2 — 4-signal complexity check + ROUTE` |
| `### Step 1 — Parallel spawn ...` | `### Step 3 — Parallel spawn ...` |
| `### Step 2 — Parallel research dispatch ...` | `### Step 4 — Parallel research dispatch ...` |
| `### Step 3 — Parallel research wait ...` | `### Step 5 — Parallel research wait ...` |
| `### Step 4 — Diff (N-way Venn)` | `### Step 6 — Diff (N-way Venn)` |
| `### Step 5 — Parallel verify dispatch + wait ...` | `### Step 7 — Parallel verify dispatch (N-aware)` and `### Step 8 — Parallel verify wait (N-aware, with question loop)` |
| `### Step 6 — Adjudicate ...` | `### Step 9 — Adjudicate + Yoda resolves PENDING` |
| `### Step 7 — Resolve PENDING items` | (folded into Step 9) |
| `### Step 8 — Synthesize` | `### Step 11 — Per-section design walk` (and Step 10 multi-repo detect inserted before; Step 12 audit-assemble inserted after — those land in Tasks 12-14) |
| `### Step 8.4 — Drill deeper ...` | `### Step 13 — Drill deeper ...` |
| `### Step 9 — Teardown + archive` | `### Step 14 — Teardown` and `### Step 15 — Archive` (split for clean integers) |
| `### Step 10 — Present synthesis` | `### Step 16 — Present design-doc path` |

Also update every `Set task N → ...` reference to use the new numbering. Search for `Set task` and update accordingly.

- [ ] **Step 3: Update the TaskCreate task list at the top of the directive**

The current task list in `commands/consult.md` has 10 rows (0-9). Replace with 17 rows matching the new step numbering. Preserve subject + activeForm grammar:

```markdown
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
```

- [ ] **Step 4: Update the Step 2 (formerly 0.5) Yoda fast-path block**

The current fast-path block ends with Yoda writing a 6-section "research synthesis" doc (Summary/Findings/Tradeoffs/Recommendation/Open Questions/Sources). Replace with the v0.17 stub design-doc shape. Find this block in the directive and rewrite:

```markdown
**4. If no signal fires:** Yoda writes a deploy-audit-passing design doc INLINE
and exits. No trooper-spawn, no `_consult/` working artifacts beyond
what `consult-init.sh` already created.

Compute the canonical path:

```
DESIGN_DOC_PATH=$(cw_consult_design_doc_canonical_path \
    "$TOPIC_DIR/_consult" "$CONSULT_TOPIC")
```

Write the rigid 6-section design-doc using the **Write tool** (atomic
single-shot write, not append). Trust-label header is fixed on fast path:

```
> **Source:** Master Yoda (single-source)
> **Generated:** <ISO-8601 UTC timestamp>
> **Path:** fast
```

Six sections required (deploy-audit shape — `cw_deploy_audit_doc` requires
Goal + Architecture/Approach + Test + Success Criteria):

- **## Problem** — current state (1-3 sentences); cite code if relevant
- **## Goal** — outcome statement (1 paragraph)
- **## Architecture** — Yoda's recommendation, the bulk of the doc
- **## Components** — files / functions / classes touched
- **## Testing** — what tests cover the change
- **## Success Criteria** — concrete, measurable bullets

After writing, **also write the doc body via Write tool to**
`$TOPIC_DIR/_consult/design-doc/.draft/<section>.md` for each section
(so a future `/consult --resume` could re-run from this state — out of
scope for v0.17 but cheap to seed). Then run `cw_deploy_audit_doc` on
`$DESIGN_DOC_PATH` and surface VERDICT to user. On VERDICT=FAIL: re-draft
the offending section once (max one retry); if still FAIL, surface
ISSUE= list to user and exit 1. On PASS: print path, set all task rows
to completed, exit 0.
```

- [ ] **Step 5: Update Step 9 (formerly 6+7 combined) — Adjudicate + Resolve PENDING**

Combine the old Step 6 (run consult-adjudicate.sh) and Step 7 (Yoda resolves PENDING) into a single Step 9 in the directive. The shell logic is unchanged; only the heading + numbering merges.

- [ ] **Step 6: Run smoke test on the directive's static structure**

```bash
grep -E '^### Step [0-9]+\b' commands/consult.md | head -20
```

Expected output (one line per step):

```
### Step 0 — args-file + init + roster
### Step 1 — Escalation phrasing-trigger detection
### Step 2 — 4-signal complexity check + ROUTE
### Step 3 — Parallel spawn (N-aware, with auto-retry-once + rollback)
### Step 4 — Parallel research dispatch (N-aware)
### Step 5 — Parallel research wait (N-aware, with question loop)
### Step 6 — Diff (N-way Venn)
### Step 7 — Parallel verify dispatch (N-aware)
### Step 8 — Parallel verify wait (N-aware, with question loop)
### Step 9 — Adjudicate + Yoda resolves PENDING
```

(Steps 10-16 land in subsequent tasks.)

- [ ] **Step 7: Verify no orphan v0.16 step references remain**

```bash
grep -E '\b(Step 0\.[45])\b' commands/consult.md && { echo "FAIL: v0.16 step refs left"; false; } || echo "OK: no v0.16 step refs"
```

Expected: `OK: no v0.16 step refs`.

- [ ] **Step 8: Run full suite (regression check)**

```bash
bash tests/run.sh 2>&1 | tail -5
```

Expected: `FAIL=0`. The directive renumbering doesn't break runtime tests because the bin scripts are the actual code — directive is just instructions for Yoda to follow.

- [ ] **Step 9: Commit**

```bash
git add commands/consult.md
git commit -m "$(cat <<'EOF'
refactor(consult): renumber directive to clean integers 0-16

Replaces v0.16's 0/0.4/0.5/1-10 numbering with clean 0-16. Splits
verify-dispatch and verify-wait into separate steps. Folds Adjudicate
+ Resolve PENDING into one step. Steps 10 (multi-repo detect), 11
(per-section walk), 12 (assemble + audit) added in Tasks 12-14.

Fast-path block (Step 2's no-signal branch) updated to write a deploy-
audit-passing 6-section design doc instead of the v0.16 research
synthesis report shape.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: commands/consult.md — Step 10 (multi-repo detection)

**Files:**
- Modify: `commands/consult.md` (insert Step 10 between Step 9 and what was old Step 8)

- [ ] **Step 1: Insert Step 10 in the directive**

After the new Step 9 block ("Adjudicate + Yoda resolves PENDING"), insert this Step 10 block:

````markdown
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
````

- [ ] **Step 2: Validate the directive still has clean step ordering**

```bash
grep -E '^### Step [0-9]+\b' commands/consult.md
```

Expected: Step 10 appears between Step 9 and the next existing step (which will be old Step 8 / new Step 11 after Task 13).

- [ ] **Step 3: Smoke-test the directive's reference to lib/consult-walk.sh**

```bash
grep -nE 'consult-walk\.sh|cw_consult_detect_multi_repo' commands/consult.md
```

Expected: at least 2 hits — one sourcing the lib, one calling the detect helper.

- [ ] **Step 4: Run full suite**

```bash
bash tests/run.sh 2>&1 | tail -5
```

Expected: `FAIL=0`.

- [ ] **Step 5: Commit**

```bash
git add commands/consult.md
git commit -m "$(cat <<'EOF'
feat(consult): add Step 10 multi-repo detection to directive

Auto-detects via cw_consult_detect_multi_repo when --targets wasn't
passed. AskUserQuestion confirms (use as-is / edit / proceed
single-repo). Writes _consult/{multi-repo.txt,targets.txt}.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: commands/consult.md — Step 11 (per-section design walk)

**Files:**
- Modify: `commands/consult.md` (insert Step 11 — replaces old Step 8 synthesize)

- [ ] **Step 1: Insert Step 11 in the directive**

Replace the OLD `### Step 8 — Synthesize` block (now positioned after the new Step 10) with this new Step 11 walk block:

````markdown
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
````

- [ ] **Step 2: Validate ordering**

```bash
grep -E '^### Step [0-9]+\b' commands/consult.md | head -20
```

Expected: Step 11 follows Step 10. Old Step 8 ("Synthesize") is gone.

- [ ] **Step 3: Verify no orphaned references to old Step 8**

```bash
grep -nE '\bStep 8 — Synthesize\b' commands/consult.md && { echo "FAIL: orphan Step 8 ref"; false; } || echo "OK"
```

Expected: `OK`.

- [ ] **Step 4: Run full suite**

```bash
bash tests/run.sh 2>&1 | tail -5
```

Expected: `FAIL=0`.

- [ ] **Step 5: Commit**

```bash
git add commands/consult.md
git commit -m "$(cat <<'EOF'
feat(consult): add Step 11 per-section design walk to directive

Replaces v0.16's "Step 8 Synthesize" with a per-section
Approve/Revise/Skip walk. Synthesize now produces seeds; Yoda walks
through them with the user. Multi-repo adds 2 sections (Execution DAG,
Cross-Repo Notes) and per-repo subsections under Architecture.
Goal + Architecture forbid Skip (deploy-audit-required). Revise loop
caps at 4 rounds with Force-approve / Skip / Abort breakout.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: commands/consult.md — Step 12 (assemble + audit gate)

**Files:**
- Modify: `commands/consult.md`

- [ ] **Step 1: Insert Step 12 directly after Step 11**

```markdown
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
        AskUserQuestion: "Audit emitted unknown ISSUE=$KEY. Commit failing doc / Abort?"
        ;;
    esac
  done

  ATTEMPT=$((ATTEMPT+1))
  if (( ATTEMPT > MAX_ATTEMPT_PER_SECTION )); then
    AskUserQuestion: "Audit retry budget exhausted. Commit failing doc with banner / Abort?"
    if [[ "$ANSWER" == "Commit failing doc with banner" ]]; then
      # Re-run walk-assemble one more time to write doc despite audit FAIL.
      DD_PATH=$("$CLAUDE_PLUGIN_ROOT/bin/consult-walk-assemble.sh" "$CONSULT_TOPIC" 2>/dev/null || true)
      # Banner is appended to top of doc by Yoda using Edit tool.
      break
    fi
    log_error "[step 12] aborting"; exit 1
  fi
done
```

Set task `12` → `completed`.
```

- [ ] **Step 2: Verify Step 12 appears between Step 11 and Step 13**

```bash
grep -E '^### Step [0-9]+\b' commands/consult.md | grep -A1 -B1 'Step 12'
```

Expected: Step 11, Step 12, Step 13 in order.

- [ ] **Step 3: Run full suite**

```bash
bash tests/run.sh 2>&1 | tail -5
```

Expected: `FAIL=0`.

- [ ] **Step 4: Commit**

```bash
git add commands/consult.md
git commit -m "$(cat <<'EOF'
feat(consult): add Step 12 assemble + audit gate to directive

Calls bin/consult-walk-assemble.sh; on audit FAIL parses ISSUE= lines
via cw_consult_audit_issue_to_section and re-walks the offending
section(s). Cap at 2 attempts; on exhaustion AskUserQuestion to commit
failing doc (with banner) or abort.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 15: Delete /spec command + supporting files

**Files:**
- Delete: `commands/spec.md`, `bin/spec-init.sh`, `bin/spec-assemble.sh`, `lib/spec.sh`
- Delete: `tests/test_spec_*.sh` (multiple), `tests/test_consult_design_doc_path.sh` (path canonicalization moves to walk-assemble)

- [ ] **Step 1: List /spec-side files**

```bash
ls commands/spec.md bin/spec-*.sh lib/spec.sh tests/test_spec_*.sh tests/test_consult_design_doc_path.sh 2>/dev/null
```

Expected: at least 4 files in `tests/` and 4 in source dirs. Record the exact list.

- [ ] **Step 2: Delete the source files**

```bash
git rm commands/spec.md bin/spec-init.sh bin/spec-assemble.sh lib/spec.sh
```

- [ ] **Step 3: Delete the spec-side test files**

```bash
git rm tests/test_spec_*.sh tests/test_consult_design_doc_path.sh
```

(If any of those globs miss, list explicitly: `tests/test_spec_directive_static_wiring.sh`, `tests/test_spec_init_source_defaulting.sh`, `tests/test_spec_assemble_single_unchanged.sh`, `tests/test_spec_resume_state.sh` — only delete files that actually exist.)

- [ ] **Step 4: Audit for dangling references to /spec or lib/spec.sh**

```bash
grep -rnE '/clone-wars:spec\b|lib/spec\.sh|cw_spec_resume_state' \
  --include='*.sh' --include='*.md' --include='*.json' \
  commands/ bin/ lib/ tests/ docs/ CLAUDE.md README.md 2>/dev/null
```

Expected: hits ONLY in `docs/` historical files (allowed — the design docs reference v0.14.0 / v0.16.0 history). Zero hits in `commands/`, `bin/`, `lib/`, `tests/`, root files. If any are found, edit them to remove the reference (typical: a stale source line in another lib file).

- [ ] **Step 5: Run full suite**

```bash
bash tests/run.sh 2>&1 | tail -5
```

Expected: `FAIL=0` (and PASS count drops by ~5 from the deleted spec-side tests).

- [ ] **Step 6: Commit**

```bash
git commit -m "$(cat <<'EOF'
remove(spec): delete /clone-wars:spec command + supporting files

v0.17.0 merges /spec into /consult — single command from topic to
deploy-audit-passing design doc. Deleted:
  commands/spec.md, bin/spec-init.sh, bin/spec-assemble.sh,
  lib/spec.sh (cw_spec_resume_state moved to lib/consult-walk.sh
  as cw_consult_walk_section_state in Task 5),
  tests/test_spec_*.sh, tests/test_consult_design_doc_path.sh.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 16: Static wiring test for v0.17 directive

**Files:**
- Create: `tests/test_consult_directive_v017_static_wiring.sh`
- Delete: `tests/test_consult_directive_v016_static_wiring.sh` (superseded)

- [ ] **Step 1: Write the wiring test**

Create `tests/test_consult_directive_v017_static_wiring.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_directive_v017_static_wiring.sh
#
# Static-wiring asserts on commands/consult.md: confirms the v0.17.0
# directive has exactly 17 step labels (0-16), references the v0.17 lib
# helpers + bin scripts, and contains no orphan v0.16 references or /spec
# pointers.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

DIR=../commands/consult.md

# 17 step headings: Step 0, Step 1, ..., Step 16.
for i in $(seq 0 16); do
  grep -qE "^### Step ${i} —" "$DIR" || { echo "FAIL: missing '### Step $i —' heading" >&2; exit 1; }
done

# v0.17 helpers wired.
assert_contains "$(cat $DIR)" "cw_consult_detect_multi_repo"   "Step 10 references multi-repo detector"
assert_contains "$(cat $DIR)" "cw_consult_walk_section_state"  "Step 11 references walk-state helper"
assert_contains "$(cat $DIR)" "cw_consult_audit_issue_to_section" "Step 12 references issue mapper"
assert_contains "$(cat $DIR)" "consult-walk-assemble.sh"       "Step 12 calls walk-assemble"

# v0.17 doc shape (6-section single-repo, 8 multi-repo).
assert_contains "$(cat $DIR)" "SECTIONS=(problem goal architecture components testing success-criteria)"   "single-repo 6 sections"
assert_contains "$(cat $DIR)" "SECTIONS=(problem goal architecture components execution-dag cross-repo-notes testing success-criteria)" "multi-repo 8 sections"

# /spec pointers must be gone.
grep -qE '/clone-wars:spec\b'                  "$DIR" && { echo "FAIL: /clone-wars:spec ref still present" >&2; exit 1; } || true
grep -qE 'cw_consult_design_doc_resume_state' "$DIR" && { echo "FAIL: legacy cw_consult_design_doc_resume_state still referenced" >&2; exit 1; } || true

# v0.16 step labels must be gone (0.4, 0.5, fractional).
grep -qE '\bStep 0\.[0-9]'  "$DIR" && { echo "FAIL: v0.16 fractional step labels still present" >&2; exit 1; } || true

# Yoda fast-path emits 6-section deploy-audit doc, not the v0.16 research synthesis shape.
assert_contains "$(cat $DIR)" "## Problem"        "fast-path Step 2 emits ## Problem"
assert_contains "$(cat $DIR)" "## Success Criteria" "fast-path Step 2 emits ## Success Criteria"
grep -qE 'Summary / Findings / Tradeoffs / Recommendation / Open Questions / Sources' "$DIR" \
  && { echo "FAIL: fast-path still mentions v0.16 6-section research shape" >&2; exit 1; } || true

pass "commands/consult.md static wiring complete (v0.17.0)"
```

- [ ] **Step 2: Run test to verify it passes**

```bash
bash tests/test_consult_directive_v017_static_wiring.sh
```

Expected: PASS.

- [ ] **Step 3: Delete the v016 wiring test**

```bash
git rm tests/test_consult_directive_v016_static_wiring.sh
```

- [ ] **Step 4: Run full suite**

```bash
bash tests/run.sh 2>&1 | tail -5
```

Expected: `FAIL=0`.

- [ ] **Step 5: Commit**

```bash
git add tests/test_consult_directive_v017_static_wiring.sh
git commit -m "$(cat <<'EOF'
test(consult): add v017 directive static wiring; delete v016 version

Asserts 17 step headings (0-16), v0.17 lib/bin references, single +
multi-repo SECTIONS lists, no /spec pointers, no v0.16 fractional step
labels, fast-path emits ## Problem + ## Success Criteria.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 17: End-to-end fast-path smoke test

**Files:**
- Create: `tests/test_consult_fast_path_design_shape.sh`

This test exercises the fast-path (no troopers spawned) end-to-end via stubbing the consult-init + walk-assemble. Verifies the output passes `cw_deploy_audit_doc` deterministically.

- [ ] **Step 1: Write the test**

Create `tests/test_consult_fast_path_design_shape.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_fast_path_design_shape.sh
#
# Fast-path smoke test: stubs the directive's "Yoda inline draft" by
# pre-staging .draft/<section>.md for all 6 sections, then verifies
# consult-walk-assemble.sh produces a doc that passes cw_deploy_audit_doc.
# This exercises the assembly + audit gate without needing tmux/troopers.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=consult-fastpath-e2e
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
DR="$TD/_consult/design-doc/.draft"
mkdir -p "$DR"
echo "What is the safest way to convert a Postgres DECIMAL column to FLOAT?" > "$TD/_consult/topic.txt"

# Yoda's inline draft (simulated).
printf '## Problem\n\nDECIMAL math is exact but slow.\n' > "$DR/problem.md"
printf '## Goal\n\nMigrate column type without write outage.\n' > "$DR/goal.md"
printf '## Architecture\n\nUse pg_repack-style copy + swap.\n' > "$DR/architecture.md"
printf '## Components\n\n- migration script\n- rollback script\n' > "$DR/components.md"
printf '## Testing\n\n- run on staging copy first\n- verify row counts\n' > "$DR/testing.md"
printf '## Success Criteria\n\n- [ ] zero writes lost\n- [ ] rollback path proven\n' > "$DR/success-criteria.md"

# Run walk-assemble.
DD=$(../bin/consult-walk-assemble.sh "$TOPIC")
assert_file_exists "$DD" "design-doc written"

# Audit independently.
source ../lib/log.sh
source ../lib/deploy.sh
cw_deploy_audit_doc "$DD" >/dev/null && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] || { echo "FAIL: audit returned $rc on fast-path output" >&2; exit 1; }

# Six H2 sections present.
COUNT=$(grep -cE '^## ' "$DD")
[[ "$COUNT" -eq 6 ]] || { echo "FAIL: expected 6 H2 sections, got $COUNT" >&2; exit 1; }

pass "fast-path end-to-end: 6-section doc passes cw_deploy_audit_doc"
```

- [ ] **Step 2: Run test to verify it passes**

```bash
bash tests/test_consult_fast_path_design_shape.sh
```

Expected: PASS.

- [ ] **Step 3: Run full suite**

```bash
bash tests/run.sh 2>&1 | tail -5
```

Expected: `FAIL=0`.

- [ ] **Step 4: Commit**

```bash
git add tests/test_consult_fast_path_design_shape.sh
git commit -m "$(cat <<'EOF'
test(consult): fast-path end-to-end smoke test

Stubs Yoda's inline 6-section draft, runs walk-assemble, asserts the
output passes cw_deploy_audit_doc. Independent of tmux/trooper machinery.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 18: Targets-flag-forces-escalation behavior test

**Files:**
- Create: `tests/test_consult_targets_forces_escalation.sh`

This is a static-wiring test asserting the directive treats `--targets` as an escalation signal in Step 2 (so a trivial topic with explicit targets still routes to escalated path).

- [ ] **Step 1: Write the test**

Create `tests/test_consult_targets_forces_escalation.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_targets_forces_escalation.sh
#
# Static asserts that commands/consult.md's Step 2 routing logic treats
# --targets as an escalation signal (forces the escalated path even when
# no signals fire). This is a behavioral spec, validated by reading the
# directive prose.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

DIR=../commands/consult.md

# The Step 2 routing block must list --targets as a fast-path-disqualifier.
# Phrase: "no --targets" or "--targets unset" or "--targets is empty"
# All 3 are acceptable; assert at least one appears in the Step 2 block.
STEP2_BLOCK=$(awk '/^### Step 2 —/,/^### Step 3 —/' "$DIR")

echo "$STEP2_BLOCK" | grep -qE 'no --targets|--targets unset|--targets is empty|TARGETS_RAW|--targets a,b,c' \
  || { echo "FAIL: Step 2 doesn't mention --targets in routing logic" >&2; echo "Step 2 block:" >&2; echo "$STEP2_BLOCK" >&2; exit 1; }

# Also assert the routing description names --targets as escalation signal.
assert_contains "$STEP2_BLOCK" "escalat" "Step 2 mentions escalation"

pass "commands/consult.md Step 2 treats --targets as escalation signal"
```

- [ ] **Step 2: Update commands/consult.md if the test fails**

If the test fails, the Step 2 routing prose needs an explicit mention of `--targets`. Find the Step 2 block and add:

```markdown
**Routing rules** (any one triggers escalated path):
- `--use-force` flag present
- Phrasing trigger fires (Step 1)
- Any 4-signal fires
- `--targets a,b,c` was passed (treated as explicit escalation signal — even on trivial topics, an explicit multi-repo declaration deserves the full pipeline)

If none of the above → fast path.
```

- [ ] **Step 3: Run test to verify it passes**

```bash
bash tests/test_consult_targets_forces_escalation.sh
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add tests/test_consult_targets_forces_escalation.sh commands/consult.md
git commit -m "$(cat <<'EOF'
test(consult): assert --targets forces escalated path

Static wiring test confirming Step 2 routing treats --targets as an
escalation signal (per spec).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 19: Polish — version bump + CLAUDE.md status + final dogfood gate

**Files:**
- Modify: `CLAUDE.md`
- Modify: `.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`

- [ ] **Step 1: Bump plugin.json**

Open `.claude-plugin/plugin.json`. Change `"version": "0.16.0"` (or current) to `"version": "0.17.0"`.

- [ ] **Step 2: Bump marketplace.json**

Open `.claude-plugin/marketplace.json`. Change `"version": "0.16.0"` → `"version": "0.17.0"`. Update the `description` line if it references the deleted /spec command — drop "spec" mentions from the user-facing description.

- [ ] **Step 3: Update CLAUDE.md status**

Find the v0.17.0 placeholder line added in Task 1 and change `[ ]` to `[x]`. Then ADD a fresh dogfood-gate line:

```markdown
- [x] v0.17.0: consult-spec merge — single command from topic to deploy-audit-passing design doc; /spec deleted; multi-repo auto-detect + soft DAG section
- [ ] v0.17.0 strict-dogfood pass on a real machine (release gate — verify fast-path single-repo, escalated single-repo, escalated multi-repo, audit-fail recovery, --targets forces escalation, /clone-wars:deploy hand-off; spec at docs/superpowers/specs/2026-05-08-consult-spec-merge-design.md)
```

Also add a one-line note higher up under "Why this exists" or "Status" recording:

```markdown
- v0.17.0 reverses part of v0.14.0's hub-mode deletion: auto-detect + per-repo
  subsections + soft DAG section come back. Validators (282 LoC) stay deleted.
```

- [ ] **Step 4: Run full suite + smoke-test medic**

```bash
bash tests/run.sh 2>&1 | tail -5
bash bin/medic.sh
```

Expected: tests `FAIL=0`. Medic Verdict `OK`.

- [ ] **Step 5: Commit version bump + status**

```bash
git add CLAUDE.md .claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "$(cat <<'EOF'
chore(release): bump plugin to v0.17.0

Includes the /spec → /consult merge, multi-repo auto-detect, per-section
walk, deploy-audit gate. CLAUDE.md status reflects partial reversal of
v0.14.0 hub-mode deletion (auto-detect + per-repo subsections + soft DAG
restored; 282 LoC of validators stay deleted).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 6: Tag the release**

```bash
git tag -a v0.17.0 -m "v0.17.0: consult-spec merge"
git push origin feat/v0.17.0-consult-spec-merge
git push origin v0.17.0
```

(Don't merge to main yet — wait for the dogfood gate.)

- [ ] **Step 7: Open PR**

```bash
gh pr create --title "v0.17.0: consult-spec merge — single command to deploy-ready design doc" \
  --body "$(cat <<'EOF'
## Summary

- /clone-wars:consult is now the single command from topic to deploy-audit-passing design doc
- /clone-wars:spec is deleted entirely
- Multi-repo auto-detection (cwd siblings + topic-prose grep) + soft DAG section + per-repo Architecture subsections
- v0.16.0 smart-control fast-path / escalated routing preserved
- /clone-wars:deploy stays single-repo at v0.17 (multi-repo docs route to external multi-agent dispatch manually; later restored in-plugin via /deploy v0.20.0+)

## Test plan

- [ ] Single-repo trivial: `/consult what's the diff between mutex and rwlock?` → fast-path stub doc, audit PASS
- [ ] Single-repo escalated: `/consult should we add Redis caching?` → trooper roster, walk, doc, audit PASS
- [ ] Multi-repo escalated: `/consult plan session migration across api-server and auth-service` → auto-detect fires, walk emits 8-section doc with DAG + Per-Repo
- [ ] Audit-fail recovery: deliberately Skip success-criteria → re-walks just that section → audit PASS
- [ ] `--targets foo,bar <trivial>` → forces escalation, multi-repo doc
- [ ] /clone-wars:deploy reads single-repo /consult output cleanly

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 8: After human dogfood gate passes, merge to main**

(Out of scope for this plan — the dogfood gate is intentionally manual and
release-cadence-controlled by the user.)

---

## Self-Review (run by the implementer after the plan completes)

After all 19 tasks land, run this checklist before declaring v0.17.0 done.

### 1. Spec coverage

For each section/requirement in `docs/superpowers/specs/2026-05-08-consult-spec-merge-design.md`, confirm a task implements it:

- ✅ /spec deletion → Task 15
- ✅ Step 0-16 numbering → Task 11
- ✅ Fast-path 6-section stub doc → Task 11 + Task 17
- ✅ Multi-repo detection auto + AskUserQuestion → Task 4 + Task 12
- ✅ Per-section walk Approve/Revise/Skip → Task 13
- ✅ Critical-section skip block (Goal, Architecture) → Task 13
- ✅ Walk-Revise budget cap → Task 13
- ✅ Multi-repo extras (Per-Repo subsections, soft DAG, Cross-Repo Notes) → Tasks 9, 13
- ✅ `Target Sub-Project(s):` plural header → Task 9
- ✅ Date frontmatter → Task 9
- ✅ Soft DAG format → Tasks 3, 13
- ✅ Audit gate + retry → Tasks 10, 14
- ✅ ISSUE→section mapping → Tasks 2, 10, 14
- ✅ `--targets` flag → Task 6
- ✅ `--targets` forces escalation → Task 18
- ✅ Tests for every helper + e2e + static wiring → Tasks 2-10, 16-18
- ✅ /deploy stays single-repo (no `cw_deploy_extract_target` plural extension) → confirmed by NOT modifying lib/deploy.sh

### 2. Placeholder scan

```bash
grep -nE '\b(TBD|TODO|XXX|FIXME)\b' docs/superpowers/plans/2026-05-08-consult-spec-merge-plan.md \
  | grep -v 'TBD/TODO\b' \
  | grep -v 'tbd_marker\|todo_marker' \
  || echo "OK: no placeholder markers"
```

(References to TBD/TODO inside the audit's ISSUE= mapping are legitimate — they're the marker keys cw_deploy_audit_doc emits.)

### 3. Type consistency

Spot-check signatures across tasks:
- `cw_consult_audit_issue_to_section <issue-key>` (Task 2) — used unchanged in Task 14's Step 12 block ✓
- `cw_consult_emit_soft_dag <tsv-path>` (Task 3) — referenced in Task 13's Step 11 multi-repo execution-dag draft ✓
- `cw_consult_detect_multi_repo <cwd> <topic>` (Task 4) — called in Task 12's Step 10 ✓
- `cw_consult_walk_section_state [--with-status] <draft-dir>` (Task 5) — called in Task 13's Step 11 ✓
- `bin/consult-walk-assemble.sh <topic>` (Tasks 8-10) — invoked in Task 14's Step 12 ✓

---

Plan complete and saved to `docs/superpowers/plans/2026-05-08-consult-spec-merge-plan.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
