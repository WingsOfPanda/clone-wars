# v0.20.0 Deploy Multi-Repo DAG Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add multi-repo DAG-aware path to `/clone-wars:deploy` (codex troopers per sub-repo, parallel waves, full superpowers ceremony per trooper, conductor cross-repo verification + fix-loop) while keeping the single-repo path byte-equal to v0.19.0.

**Architecture:** Auto-detect from design-doc header in `bin/deploy-init.sh` (writes `routing.txt`). Multi-repo path: parse `## Execution DAG` prose into waves → preflight-allocate one pane per sub-repo → wave-by-wave parallel `bin/spawn.sh --target-pane --cwd` → each codex trooper runs full superpowers ceremony on its sub-repo's slice → conductor verifies cross-repo invariants (escalates to full verification on "feels unsafe" trigger) → MAX_FIX_ROUNDS=3 fix-loop with AskUserQuestion at cap. Single-repo path unchanged.

**Tech Stack:** bash 4.2+, tmux ≥3.0. No Node/Python. Tests use plain bash + `tests/lib/assert.sh`. Tmux-dependent tests use isolated tmux windows (require `$TMUX` set, skip otherwise).

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `lib/deploy-dag.sh` | Create (~150 lines) | DAG parse / topological sort / unique repos / fan-in detection |
| `bin/deploy-dag-parse.sh` | Create (~70 lines) | Read design doc → write `_deploy/dag-waves.txt` + `_deploy/dag-edges.txt` |
| `bin/deploy-multi-init.sh` | Create (~80 lines) | Commander assignment from clone trooper pool + per-repo provider detect |
| `bin/preflight-layout.sh` | Modify (~10 lines) | Add `--art-dir <path>` flag (additive; defaults to consult path) |
| `lib/deploy.sh` | Modify (~15 lines in `cw_deploy_detect_provider`) | Reject `--provider opencode` |
| `bin/deploy-init.sh` | Modify (~15 lines) | Auto-detect single vs multi-repo header, write `_deploy/routing.txt` |
| `commands/deploy.md` | Modify (substantial — ~150 line delta) | Frontmatter `allowed-tools`, trigger phrases, drop `--design-doc`/synthesis refs, routing branch, NEW Steps 3a/3b/4/5 for multi-repo, fix `description=` interpolation bug |
| `bin/deploy-teardown.sh` | Modify (~15 lines) | Mirror v0.19.0 consult-teardown orphan cleanup for `_deploy/preflight-panes.txt` |
| `tests/test_deploy_dag_lib.sh` | Create | Unit tests for all 4 lib/deploy-dag.sh helpers |
| `tests/test_deploy_dag_parse.sh` | Create | E2E test for bin/deploy-dag-parse.sh (linear / diamond / cycle / missing-DAG / malformed) |
| `tests/test_deploy_multi_init.sh` | Create | Commander assignment + cody-skip + plugin-detect per sub-repo |
| `tests/test_preflight_layout_artdir_flag.sh` | Create | `--art-dir` flag works; consult zero-arg path still works (regression guard) |
| `tests/test_deploy_provider_no_opencode.sh` | Create | `--provider opencode` rejected with rc≠0 + clear error |
| `tests/test_deploy_init_routing_autodetect.sh` | Create | Single-repo doc → `routing.txt = single-repo`; multi-repo doc → `routing.txt = multi-repo` |
| `tests/test_deploy_teardown_preflight_orphans.sh` | Create | Mirror v0.19.0 consult-teardown orphan test for deploy |
| `tests/test_deploy_multi_preflight.sh` | Create | Tmux-dep: multi-repo preflight allocates K=3 evenly-sized panes |
| `tests/test_deploy_directive_v020_static_wiring.sh` | Create | Locks in v0.20.0 directive prose (Steps 3a/3b, MAX_FIX_ROUNDS=3, AskUserQuestion at-cap, allowed-tools, no synthesis refs, trigger phrases) |
| `.claude-plugin/plugin.json` | Modify | 0.19.0 → 0.20.0 |
| `.claude-plugin/marketplace.json` | Modify | 0.19.0 → 0.20.0 |
| `CLAUDE.md` | Modify | v0.20.0 status entry + dogfood gate |

---

## Test scaffolding patterns

**Pure-bash tests (no tmux):** standard pattern using `assert_contains` / `assert_eq` / `assert_file_exists` / `pass`. Sandbox state via `mktemp -d` + `export CLONE_WARS_HOME="$SANDBOX/.clone-wars"`. Trap cleanup. Same shape as `tests/test_consult_init_*.sh`.

**Tmux-dependent tests:** Skip when `$TMUX` is unset. Spawn isolated test window via `tmux new-window -d -n "$TEST_WIN"`. Trap kills window on EXIT. Same shape as `tests/test_preflight_layout.sh` (v0.19.0). Note: preflight-layout.sh uses `$TMUX_PANE` for Yoda discovery, so when the test sends preflight via `tmux send-keys` into the test window's pane, `$TMUX_PANE` correctly resolves to the test pane (not the conductor's pane).

---

## Task 1: Branch + baseline

**Files:** read-only verification.

- [ ] **Step 1: Verify on the right branch**

```bash
git rev-parse --abbrev-ref HEAD
```

Expected: `feat/v0.20.0-deploy-multi-repo-dag`.

- [ ] **Step 2: Run baseline tests for files we'll touch**

```bash
for t in test_spawn_validation.sh test_spawn_rollback.sh \
         test_pane_respawn.sh test_preflight_layout.sh \
         test_consult_directive_v019_static_wiring.sh \
         test_consult_init_prefers_active.sh; do
  echo "=== $t ==="; timeout 30 bash "tests/$t" 2>&1 | tail -2
done
```

Expected: each prints `PASS`. Any FAIL → stop, baseline is broken.

- [ ] **Step 3: Confirm spec is committed on this branch**

```bash
git log --oneline -1 docs/superpowers/specs/2026-05-09-deploy-multi-repo-dag-design.md
```

Expected: `2f69637 docs(spec): v0.20.0 deploy multi-repo DAG design`.

No commit needed for Task 1.

---

## Task 2: `lib/deploy-dag.sh` — DAG parse / topological sort / unique repos / fan-in

**Files:**
- Create: `lib/deploy-dag.sh`
- Create: `tests/test_deploy_dag_lib.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_deploy_dag_lib.sh`:

```bash
#!/usr/bin/env bash
# tests/test_deploy_dag_lib.sh
# Unit tests for lib/deploy-dag.sh helpers.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deploy-dag.sh"

# --- cw_deploy_dag_parse_line ---

# Simple line: no deps
line="1. foo — initial setup"
result=$(cw_deploy_dag_parse_line "$line")
assert_eq "$result" $'1\tfoo\tinitial setup\tnone' "parse_line: simple"

# With single dep
line="2. bar — depends on foo (depends on 1)"
result=$(cw_deploy_dag_parse_line "$line")
assert_eq "$result" $'2\tbar\tdepends on foo\t1' "parse_line: single dep"

# With multiple deps
line="3. baz — bridge layer (depends on 1, 2)"
result=$(cw_deploy_dag_parse_line "$line")
assert_eq "$result" $'3\tbaz\tbridge layer\t1,2' "parse_line: multiple deps"

# Malformed: missing step number
err=$(cw_deploy_dag_parse_line "foo — bad" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: malformed line should rc!=0" >&2; exit 1; }
pass "parse_line: malformed rejects"

# --- cw_deploy_dag_topological ---

# Linear: 1 → 2 → 3
EDGES_TSV=$(mktemp)
trap 'rm -f "$EDGES_TSV" "$WAVES_TSV"' EXIT
printf '1\t2\n2\t3\n' > "$EDGES_TSV"
WAVES_TSV=$(mktemp)
cw_deploy_dag_topological "$EDGES_TSV" 1 2 3 > "$WAVES_TSV"
mapfile -t lines < "$WAVES_TSV"
assert_eq "${lines[0]}" $'1\t1' "topological linear: wave 1 = node 1"
assert_eq "${lines[1]}" $'2\t2' "topological linear: wave 2 = node 2"
assert_eq "${lines[2]}" $'3\t3' "topological linear: wave 3 = node 3"

# Parallel wave: 1, 2, 3 with no deps
: > "$EDGES_TSV"
cw_deploy_dag_topological "$EDGES_TSV" 1 2 3 > "$WAVES_TSV"
# All three should be wave 1
nwave1=$(awk -F$'\t' '$1==1' "$WAVES_TSV" | wc -l)
assert_eq "$nwave1" "3" "topological parallel: 3 nodes in wave 1"

# Cycle: 1 → 2 → 1
printf '1\t2\n2\t1\n' > "$EDGES_TSV"
err=$(cw_deploy_dag_topological "$EDGES_TSV" 1 2 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: cycle should rc!=0" >&2; exit 1; }
echo "$err" | grep -qi 'cycle' || { echo "FAIL: cycle error msg unclear: $err" >&2; exit 1; }
pass "topological: cycle detected"

# --- cw_deploy_dag_unique_repos ---

WAVES=$(mktemp)
printf '1\t1\tfoo\tdesc1\n1\t2\tbar\tdesc2\n2\t3\tfoo\tdesc3\n' > "$WAVES"
result=$(cw_deploy_dag_unique_repos "$WAVES" | sort)
expected=$'bar\nfoo'
assert_eq "$result" "$expected" "unique_repos: dedupes + sorts"
rm -f "$WAVES"

# --- cw_deploy_dag_fan_in_repos ---

EDGES=$(mktemp)
WAVES2=$(mktemp)
# diamond: 4 has 2 incoming (from 2, 3); should be flagged
# Build edges: 1→2, 1→3, 2→4, 3→4
printf '1\t2\n1\t3\n2\t4\n3\t4\n' > "$EDGES"
# waves: 1 in wave 1; 2,3 in wave 2; 4 in wave 3 (with repo "join")
printf '1\t1\troot\tx\n2\t2\tleft\tx\n2\t3\tright\tx\n3\t4\tjoin\tx\n' > "$WAVES2"
result=$(cw_deploy_dag_fan_in_repos "$EDGES" "$WAVES2")
assert_eq "$result" "join" "fan_in_repos: identifies join node (fan-in=2)"
rm -f "$EDGES" "$WAVES2"

pass "lib/deploy-dag.sh helpers all green"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
timeout 30 bash tests/test_deploy_dag_lib.sh
```

Expected: FAIL — `lib/deploy-dag.sh: No such file`.

- [ ] **Step 3: Create `lib/deploy-dag.sh`**

```bash
# lib/deploy-dag.sh — DAG helpers for /clone-wars:deploy multi-repo path.
#
# Sourcing-only file. Parses the soft-DAG prose format produced by
# cw_consult_emit_soft_dag (lib/consult-walk.sh) into TSV, runs Kahn's
# topological sort to compute waves (parallel-execution levels), and
# exposes utility queries for the multi-repo deploy directive.
#
# Format produced by cw_consult_emit_soft_dag (matches what shows up
# in the assembled design doc's "## Execution DAG" section):
#   1. <repo> — <description>
#   2. <repo> — <description> (depends on 1)
#   3. <repo> — <description> (depends on 1, 2)

# cw_deploy_dag_parse_line <prose-line>
# Echoes TSV: <step>\t<repo>\t<desc>\t<deps-csv|none>
# rc=0 on valid line; rc=1 on malformed.
cw_deploy_dag_parse_line() {
  local line="$1"
  # Regex: <step>. <repo> — <desc> (optional " (depends on <csv>)")
  if [[ "$line" =~ ^([0-9]+)\.[[:space:]]+([a-z0-9-]+)[[:space:]]+—[[:space:]]+(.+)$ ]]; then
    local step="${BASH_REMATCH[1]}"
    local repo="${BASH_REMATCH[2]}"
    local rest="${BASH_REMATCH[3]}"
    local deps="none"
    local desc="$rest"
    # Strip optional " (depends on N, M, ...)" suffix
    if [[ "$rest" =~ ^(.+)[[:space:]]+\(depends[[:space:]]+on[[:space:]]+([0-9, ]+)\)[[:space:]]*$ ]]; then
      desc="${BASH_REMATCH[1]}"
      deps=$(printf '%s' "${BASH_REMATCH[2]}" | tr -d ' ')
    fi
    printf '%s\t%s\t%s\t%s\n' "$step" "$repo" "$desc" "$deps"
    return 0
  fi
  log_error "cw_deploy_dag_parse_line: malformed line: $line"
  return 1
}

# cw_deploy_dag_topological <edges-tsv> <node1> <node2> ...
# Reads edges TSV (each line: <from>\t<to>) + list of all node ids.
# Echoes TSV: <wave-num>\t<node-id> (wave 1 = no incoming deps).
# rc=0 on success; rc=1 on cycle.
cw_deploy_dag_topological() {
  local edges_file="$1"; shift
  declare -A indegree
  declare -A children
  local n
  for n in "$@"; do
    indegree["$n"]=0
    children["$n"]=""
  done
  # Build indegree + adjacency
  if [[ -s "$edges_file" ]]; then
    while IFS=$'\t' read -r from to; do
      [[ -n "$from" && -n "$to" ]] || continue
      indegree["$to"]=$(( ${indegree["$to"]:-0} + 1 ))
      children["$from"]="${children["$from"]} $to"
    done < "$edges_file"
  fi
  # Kahn: process all zero-indegree nodes per wave; then decrement; repeat.
  local wave=1
  local emitted=0
  local total=$#
  while (( emitted < total )); do
    local current_wave=()
    for n in "${!indegree[@]}"; do
      [[ "${indegree[$n]}" == "0" ]] || continue
      [[ "${indegree[$n]}" == "DONE" ]] && continue
      current_wave+=( "$n" )
    done
    if (( ${#current_wave[@]} == 0 )); then
      log_error "cw_deploy_dag_topological: cycle detected (no zero-indegree nodes left, ${emitted}/${total} processed)"
      return 1
    fi
    # Sort current_wave numerically for deterministic order
    local sorted
    sorted=$(printf '%s\n' "${current_wave[@]}" | sort -n)
    while IFS= read -r n; do
      printf '%s\t%s\n' "$wave" "$n"
      indegree["$n"]="DONE"
      emitted=$(( emitted + 1 ))
      # Decrement children's indegree
      local c
      for c in ${children["$n"]:-}; do
        [[ "${indegree[$c]:-DONE}" == "DONE" ]] && continue
        indegree["$c"]=$(( ${indegree["$c"]} - 1 ))
      done
    done <<< "$sorted"
    wave=$(( wave + 1 ))
  done
  return 0
}

# cw_deploy_dag_unique_repos <waves-tsv>
# Reads waves TSV (<wave>\t<step>\t<repo>\t<desc> per line); echoes
# unique repo slugs sorted alphabetically.
cw_deploy_dag_unique_repos() {
  local waves_file="$1"
  [[ -f "$waves_file" ]] || { log_error "cw_deploy_dag_unique_repos: file not found: $waves_file"; return 1; }
  awk -F'\t' '{ print $3 }' "$waves_file" | sort -u
}

# cw_deploy_dag_fan_in_repos <edges-tsv> <waves-tsv>
# Echoes the list of repo slugs whose corresponding step has 2+ incoming
# dependencies. Used by the "feels unsafe" heuristic: a repo with multiple
# upstream waves is more likely to be affected by their interactions.
cw_deploy_dag_fan_in_repos() {
  local edges_file="$1" waves_file="$2"
  [[ -f "$edges_file" ]] || { log_error "cw_deploy_dag_fan_in_repos: edges file not found: $edges_file"; return 1; }
  [[ -f "$waves_file" ]] || { log_error "cw_deploy_dag_fan_in_repos: waves file not found: $waves_file"; return 1; }
  declare -A indegree
  while IFS=$'\t' read -r from to; do
    [[ -n "$to" ]] || continue
    indegree["$to"]=$(( ${indegree["$to"]:-0} + 1 ))
  done < "$edges_file"
  # For each step with indegree >= 2, print its repo slug
  while IFS=$'\t' read -r wave step repo desc; do
    [[ -n "$step" ]] || continue
    if (( ${indegree[$step]:-0} >= 2 )); then
      printf '%s\n' "$repo"
    fi
  done < "$waves_file"
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
timeout 30 bash tests/test_deploy_dag_lib.sh
```

Expected: `PASS: lib/deploy-dag.sh helpers all green`.

- [ ] **Step 5: Commit**

```bash
git add lib/deploy-dag.sh tests/test_deploy_dag_lib.sh
git commit -m "$(cat <<'EOF'
feat(deploy-dag): add lib/deploy-dag.sh helpers (parse / topological / unique / fan-in)

Four helpers for v0.20.0 multi-repo deploy:
- cw_deploy_dag_parse_line: parse one soft-DAG prose line into TSV
- cw_deploy_dag_topological: Kahn's algo → wave grouping + cycle detection
- cw_deploy_dag_unique_repos: dedupe sorted repo list
- cw_deploy_dag_fan_in_repos: identify nodes with 2+ incoming deps
  (feeds the conductor's "feels unsafe" heuristic)

Sourcing-only file. Tests cover linear / parallel / diamond / cycle.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `bin/deploy-dag-parse.sh` — end-to-end DAG parsing

**Files:**
- Create: `bin/deploy-dag-parse.sh`
- Create: `tests/test_deploy_dag_parse.sh`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# tests/test_deploy_dag_parse.sh
# E2E test for bin/deploy-dag-parse.sh — happy paths + failure modes.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# Test A: 3-repo linear DAG
DOC1="$SANDBOX/doc1.md"
OUT1="$SANDBOX/out1"; mkdir -p "$OUT1"
cat > "$DOC1" <<'EOF'
# Test Doc

## Execution DAG

1. auth — set up auth schema
2. api — depends on auth (depends on 1)
3. ui — frontend wiring (depends on 2)

## Other Section
EOF
"$PLUGIN_ROOT/bin/deploy-dag-parse.sh" "$DOC1" "$OUT1" || { echo "FAIL: linear DAG parse rc!=0" >&2; exit 1; }
assert_file_exists "$OUT1/dag-waves.txt" "linear: dag-waves.txt written"
assert_file_exists "$OUT1/dag-edges.txt" "linear: dag-edges.txt written"
mapfile -t WAVES < "$OUT1/dag-waves.txt"
[[ ${#WAVES[@]} -eq 3 ]] || { echo "FAIL: linear should have 3 wave lines (got ${#WAVES[@]})" >&2; exit 1; }
assert_eq "${WAVES[0]}" $'1\t1\tauth\tset up auth schema' "linear wave 1"
assert_eq "${WAVES[1]}" $'2\t2\tapi\tdepends on auth' "linear wave 2"
assert_eq "${WAVES[2]}" $'3\t3\tui\tfrontend wiring' "linear wave 3"
pass "deploy-dag-parse linear DAG"

# Test B: diamond DAG
DOC2="$SANDBOX/doc2.md"
OUT2="$SANDBOX/out2"; mkdir -p "$OUT2"
cat > "$DOC2" <<'EOF'
## Execution DAG

1. shared — define interfaces
2. left — implement left side (depends on 1)
3. right — implement right side (depends on 1)
4. join — wire both sides (depends on 2, 3)
EOF
"$PLUGIN_ROOT/bin/deploy-dag-parse.sh" "$DOC2" "$OUT2" || { echo "FAIL: diamond DAG parse rc!=0" >&2; exit 1; }
mapfile -t WAVES2 < "$OUT2/dag-waves.txt"
[[ ${#WAVES2[@]} -eq 4 ]] || { echo "FAIL: diamond should have 4 wave lines (got ${#WAVES2[@]})" >&2; exit 1; }
# Wave 1: shared (step 1); Wave 2: left+right (steps 2, 3); Wave 3: join (step 4)
[[ "${WAVES2[0]}" == 1$'\t'1$'\t'shared* ]] || { echo "FAIL: diamond wave 1 not shared: ${WAVES2[0]}" >&2; exit 1; }
nwave2=$(awk -F$'\t' '$1==2' "$OUT2/dag-waves.txt" | wc -l)
[[ "$nwave2" -eq 2 ]] || { echo "FAIL: diamond wave 2 should have 2 nodes" >&2; exit 1; }
nwave3=$(awk -F$'\t' '$1==3' "$OUT2/dag-waves.txt" | wc -l)
[[ "$nwave3" -eq 1 ]] || { echo "FAIL: diamond wave 3 should have 1 node" >&2; exit 1; }
pass "deploy-dag-parse diamond DAG"

# Test C: missing DAG section → rc=1
DOC3="$SANDBOX/doc3.md"
OUT3="$SANDBOX/out3"; mkdir -p "$OUT3"
cat > "$DOC3" <<'EOF'
# No DAG here

Just regular content.
EOF
err=$("$PLUGIN_ROOT/bin/deploy-dag-parse.sh" "$DOC3" "$OUT3" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: missing DAG should rc!=0" >&2; exit 1; }
echo "$err" | grep -qi 'execution dag' || { echo "FAIL: error should mention DAG: $err" >&2; exit 1; }
pass "deploy-dag-parse rejects missing DAG section"

# Test D: cycle → rc=1
DOC4="$SANDBOX/doc4.md"
OUT4="$SANDBOX/out4"; mkdir -p "$OUT4"
cat > "$DOC4" <<'EOF'
## Execution DAG

1. a — first (depends on 2)
2. b — second (depends on 1)
EOF
err=$("$PLUGIN_ROOT/bin/deploy-dag-parse.sh" "$DOC4" "$OUT4" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: cycle should rc!=0" >&2; exit 1; }
echo "$err" | grep -qi 'cycle' || { echo "FAIL: cycle error unclear: $err" >&2; exit 1; }
pass "deploy-dag-parse rejects cycle"

# Test E: malformed line → rc=1
DOC5="$SANDBOX/doc5.md"
OUT5="$SANDBOX/out5"; mkdir -p "$OUT5"
cat > "$DOC5" <<'EOF'
## Execution DAG

1. valid — first
not-a-dag-line at all
EOF
err=$("$PLUGIN_ROOT/bin/deploy-dag-parse.sh" "$DOC5" "$OUT5" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: malformed should rc!=0" >&2; exit 1; }
pass "deploy-dag-parse rejects malformed line"
```

- [ ] **Step 2: Run test (expect FAIL)**

```bash
timeout 30 bash tests/test_deploy_dag_parse.sh
```

Expected: FAIL — `bin/deploy-dag-parse.sh: No such file`.

- [ ] **Step 3: Create `bin/deploy-dag-parse.sh`**

```bash
#!/usr/bin/env bash
# bin/deploy-dag-parse.sh — parse a multi-repo design doc's "## Execution DAG"
# section into TSV files for the v0.20.0 multi-repo deploy flow.
#
# Usage: bin/deploy-dag-parse.sh <design-doc-path> <out-dir>
#
# Writes:
#   <out-dir>/dag-waves.txt — TSV: <wave>\t<step>\t<repo>\t<desc> per line
#   <out-dir>/dag-edges.txt — TSV: <from-step>\t<to-step> per line
#
# rc=0 on success; rc=1 on:
#   - missing/unreadable doc
#   - missing "## Execution DAG" section
#   - any malformed prose line (delegated to cw_deploy_dag_parse_line)
#   - cycle detected (delegated to cw_deploy_dag_topological)
# rc=2 on bad args.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deploy-dag.sh"

[[ $# -eq 2 ]] || { echo "Usage: $0 <design-doc-path> <out-dir>" >&2; exit 2; }
DOC="$1"
OUT_DIR="$2"

[[ -f "$DOC" && -r "$DOC" ]] || { log_error "design doc unreadable: $DOC"; exit 1; }
[[ -d "$OUT_DIR" ]] || { log_error "out-dir does not exist: $OUT_DIR"; exit 1; }

# Extract "## Execution DAG" section: lines after "## Execution DAG" until
# the next "^## " heading (or EOF).
DAG_SECTION=$(awk '
  /^## Execution DAG[[:space:]]*$/ { in_dag=1; next }
  /^## / { in_dag=0 }
  in_dag { print }
' "$DOC")

[[ -n "$DAG_SECTION" ]] || { log_error "design doc missing '## Execution DAG' section"; exit 1; }

# Parse each line that matches the DAG-line shape (skip blanks + non-matching lines)
WAVES_TMP=$(mktemp)
EDGES_TMP=$(mktemp)
ROWS_TMP=$(mktemp)
trap 'rm -f "$WAVES_TMP" "$EDGES_TMP" "$ROWS_TMP"' EXIT

# Collect ordered (step, repo, desc, deps) rows + edges. Bail on any malformed line.
NODES=()
while IFS= read -r line; do
  # Skip blank lines and obvious non-DAG content
  [[ -z "${line// }" ]] && continue
  [[ "$line" =~ ^[[:space:]]*[0-9]+\. ]] || continue
  ROW=$(cw_deploy_dag_parse_line "$line") || exit 1
  printf '%s\n' "$ROW" >> "$ROWS_TMP"
  IFS=$'\t' read -r step repo desc deps <<<"$ROW"
  NODES+=( "$step" )
  if [[ "$deps" != "none" && -n "$deps" ]]; then
    IFS=',' read -ra dep_arr <<<"$deps"
    for d in "${dep_arr[@]}"; do
      [[ -n "$d" ]] && printf '%s\t%s\n' "$d" "$step" >> "$EDGES_TMP"
    done
  fi
done <<< "$DAG_SECTION"

[[ ${#NODES[@]} -gt 0 ]] || { log_error "no DAG lines parsed from '## Execution DAG' section"; exit 1; }

# Run topological sort
TOPO_TMP=$(mktemp)
cw_deploy_dag_topological "$EDGES_TMP" "${NODES[@]}" > "$TOPO_TMP" || { rm -f "$TOPO_TMP"; exit 1; }

# Join topological output (wave, step) with rows (step, repo, desc, deps) → waves
declare -A STEP_TO_ROW
while IFS=$'\t' read -r step repo desc deps; do
  STEP_TO_ROW["$step"]="$repo"$'\t'"$desc"
done < "$ROWS_TMP"

while IFS=$'\t' read -r wave step; do
  printf '%s\t%s\t%s\n' "$wave" "$step" "${STEP_TO_ROW[$step]}" >> "$WAVES_TMP"
done < "$TOPO_TMP"
rm -f "$TOPO_TMP"

# Atomic install
mv "$WAVES_TMP" "$OUT_DIR/dag-waves.txt" || { log_error "mv dag-waves.txt failed"; exit 1; }
mv "$EDGES_TMP" "$OUT_DIR/dag-edges.txt" || { log_error "mv dag-edges.txt failed"; exit 1; }

log_ok "deploy-dag-parse: ${#NODES[@]} nodes parsed; waves at $OUT_DIR/dag-waves.txt, edges at $OUT_DIR/dag-edges.txt"
exit 0
```

- [ ] **Step 4: Make it executable**

```bash
chmod +x bin/deploy-dag-parse.sh
```

- [ ] **Step 5: Run test**

```bash
timeout 30 bash tests/test_deploy_dag_parse.sh
```

Expected: 5× `PASS` lines.

- [ ] **Step 6: Commit**

```bash
git add bin/deploy-dag-parse.sh tests/test_deploy_dag_parse.sh
git commit -m "$(cat <<'EOF'
feat(deploy-dag): add bin/deploy-dag-parse.sh + e2e tests

Reads design doc, extracts the '## Execution DAG' section, parses each
prose line via cw_deploy_dag_parse_line, runs topological sort via
cw_deploy_dag_topological, writes _deploy/dag-waves.txt + dag-edges.txt.

Tests cover: linear (1→2→3), diamond (1→{2,3}→4), missing-DAG section,
cycle detection, malformed line.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `bin/deploy-multi-init.sh` — commander assignment + per-repo provider detect

**Files:**
- Create: `bin/deploy-multi-init.sh`
- Create: `tests/test_deploy_multi_init.sh`

The clone trooper pool from `config/commanders.yaml` (26 names). For codex assignments, skip `cody` (reserved for the claude-on-plugin-dev exception). Effective pool size: 25.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# tests/test_deploy_multi_init.sh
# Tests bin/deploy-multi-init.sh — commander assignment + per-repo provider.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
SANDBOX=$(mktemp -d)
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"
mkdir -p "$CLONE_WARS_HOME"
trap 'rm -rf "$SANDBOX"' EXIT

source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

TOPIC="multi-init-test-$$"
REPO_HASH=$(cw_repo_hash)
ART_DIR="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC/_deploy"
mkdir -p "$ART_DIR"

# Create 3 sibling sub-repos, each with a CLAUDE.md
mkdir -p "$SANDBOX/auth" "$SANDBOX/api" "$SANDBOX/ui"
echo "# auth" > "$SANDBOX/auth/CLAUDE.md"
echo "# api"  > "$SANDBOX/api/CLAUDE.md"
echo "# ui"   > "$SANDBOX/ui/CLAUDE.md"

# Synthesize dag-waves.txt (output from deploy-dag-parse.sh)
cat > "$ART_DIR/dag-waves.txt" <<EOF
1	1	auth	set up auth
2	2	api	build api
3	3	ui	wire frontend
EOF

# Run multi-init from the SANDBOX so $PWD-relative sub-repo lookup works
( cd "$SANDBOX" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLONE_WARS_HOME="$CLONE_WARS_HOME" \
  "$PLUGIN_ROOT/bin/deploy-multi-init.sh" "$TOPIC" )

assert_file_exists "$ART_DIR/troopers.txt" "troopers.txt written"

mapfile -t LINES < "$ART_DIR/troopers.txt"
[[ ${#LINES[@]} -eq 3 ]] || { echo "FAIL: expected 3 trooper rows (got ${#LINES[@]})" >&2; exit 1; }

# First line: commander=rex (pool[0]); cwd=auth; provider=codex (no plugin.json)
assert_eq "${LINES[0]}" "rex	$SANDBOX/auth	codex" "first commander = rex (pool[0])"
# Second line: commander=wolffe (pool[2]; cody at pool[1] is skipped)
assert_eq "${LINES[1]}" "wolffe	$SANDBOX/api	codex" "second commander = wolffe (cody skipped)"
# Third line: commander=bly (pool[3])
assert_eq "${LINES[2]}" "bly	$SANDBOX/ui	codex" "third commander = bly"

pass "deploy-multi-init assigns commanders deterministically + skips cody"

# Test B: a sub-repo IS a Claude plugin → provider=claude for THAT one only
SANDBOX2=$(mktemp -d)
export CLONE_WARS_HOME="$SANDBOX2/.clone-wars"
mkdir -p "$CLONE_WARS_HOME"
TOPIC2="multi-init-plugin-$$"
ART2="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC2/_deploy"
mkdir -p "$ART2"
mkdir -p "$SANDBOX2/lib-a" "$SANDBOX2/lib-b/.claude-plugin"
echo "# a" > "$SANDBOX2/lib-a/CLAUDE.md"
echo "# b" > "$SANDBOX2/lib-b/CLAUDE.md"
echo '{}' > "$SANDBOX2/lib-b/.claude-plugin/plugin.json"
cat > "$ART2/dag-waves.txt" <<EOF
1	1	lib-a	x
1	2	lib-b	y
EOF
( cd "$SANDBOX2" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLONE_WARS_HOME="$CLONE_WARS_HOME" \
  "$PLUGIN_ROOT/bin/deploy-multi-init.sh" "$TOPIC2" )
mapfile -t LINES2 < "$ART2/troopers.txt"
# lib-a → codex, lib-b → claude (has plugin.json → cw_deploy_detect_provider returns claude)
assert_eq "${LINES2[0]}" "rex	$SANDBOX2/lib-a	codex" "lib-a → codex"
# lib-b is plugin → assigned cody (the reserved claude commander)
assert_eq "${LINES2[1]}" "cody	$SANDBOX2/lib-b	claude" "lib-b → cody/claude (plugin)"
rm -rf "$SANDBOX2"

pass "deploy-multi-init: plugin sub-repo → cody/claude"

# Test C: missing sub-repo → rc=1
SANDBOX3=$(mktemp -d)
export CLONE_WARS_HOME="$SANDBOX3/.clone-wars"
mkdir -p "$CLONE_WARS_HOME"
TOPIC3="multi-init-missing-$$"
ART3="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC3/_deploy"
mkdir -p "$ART3"
cat > "$ART3/dag-waves.txt" <<EOF
1	1	does-not-exist	x
EOF
err=$( cd "$SANDBOX3" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLONE_WARS_HOME="$CLONE_WARS_HOME" \
  "$PLUGIN_ROOT/bin/deploy-multi-init.sh" "$TOPIC3" 2>&1 ) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: missing sub-repo should rc!=0" >&2; exit 1; }
echo "$err" | grep -qi 'not found\|does not exist' || { echo "FAIL: error msg unclear: $err" >&2; exit 1; }
rm -rf "$SANDBOX3"

pass "deploy-multi-init: missing sub-repo rejects"
```

- [ ] **Step 2: Run test (expect FAIL)**

```bash
timeout 30 bash tests/test_deploy_multi_init.sh
```

Expected: FAIL — `bin/deploy-multi-init.sh: No such file`.

- [ ] **Step 3: Create `bin/deploy-multi-init.sh`**

```bash
#!/usr/bin/env bash
# bin/deploy-multi-init.sh — assign one commander per sub-repo + per-repo
# provider detection. Writes _deploy/troopers.txt for the v0.20.0 multi-repo
# deploy flow.
#
# Usage: bin/deploy-multi-init.sh <topic>
#
# Reads:
#   _deploy/<topic>/dag-waves.txt — wave/step/repo/desc TSV (from deploy-dag-parse.sh)
#   $PWD/<repo-slug>/CLAUDE.md or AGENTS.md — sub-repo presence check
#
# Writes:
#   _deploy/<topic>/troopers.txt — TSV: <commander>\t<sub-repo-cwd>\t<provider>
#
# Commander assignment: deterministic; pool order from config/commanders.yaml.
# Codex sub-repos consume pool order skipping `cody` (reserved for claude).
# Plugin sub-repos (have .claude-plugin/plugin.json) → use `cody` + claude.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"
source "$PLUGIN_ROOT/lib/deploy-dag.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <topic>" >&2; exit 2; }
TOPIC="$1"
cw_deploy_assert_topic "$TOPIC"

ART_DIR=$(cw_deploy_art_dir "$TOPIC")
WAVES_FILE="$ART_DIR/dag-waves.txt"
[[ -f "$WAVES_FILE" ]] || { log_error "dag-waves.txt not found at $WAVES_FILE"; exit 1; }

# Get unique repos in DAG order (stable: first-occurrence order from waves file)
declare -a REPOS_ORDERED=()
declare -A SEEN
while IFS=$'\t' read -r wave step repo desc; do
  [[ -n "$repo" ]] || continue
  if [[ -z "${SEEN[$repo]:-}" ]]; then
    REPOS_ORDERED+=( "$repo" )
    SEEN["$repo"]=1
  fi
done < "$WAVES_FILE"

# Read commander pool from config/commanders.yaml (skip cody for codex)
COMMANDERS_YAML="${CLONE_WARS_HOME:-$HOME/.clone-wars}/commanders.yaml"
[[ -f "$COMMANDERS_YAML" ]] || COMMANDERS_YAML="$PLUGIN_ROOT/config/commanders.yaml"
[[ -f "$COMMANDERS_YAML" ]] || { log_error "commanders.yaml not found"; exit 1; }
mapfile -t POOL < <(awk '/^[[:space:]]*-[[:space:]]+/ { gsub(/^[[:space:]]*-[[:space:]]+/, ""); print }' "$COMMANDERS_YAML")

# Assignment loop
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
CODEX_IDX=0  # cursor into POOL for codex assignments (skips cody)
for repo in "${REPOS_ORDERED[@]}"; do
  CWD="$PWD/$repo"
  [[ -d "$CWD" ]] || { log_error "sub-repo '$repo' not found at $CWD"; exit 1; }
  [[ -f "$CWD/CLAUDE.md" || -f "$CWD/AGENTS.md" ]] \
    || { log_error "sub-repo '$repo' has no CLAUDE.md or AGENTS.md at $CWD"; exit 1; }

  PROVIDER=$(cw_deploy_detect_provider "$CWD")
  if [[ "$PROVIDER" == "claude" ]]; then
    COMMANDER="cody"
  else
    # Find next non-cody pool entry
    while [[ "${POOL[$CODEX_IDX]:-}" == "cody" ]]; do
      CODEX_IDX=$(( CODEX_IDX + 1 ))
    done
    [[ -n "${POOL[$CODEX_IDX]:-}" ]] || { log_error "commander pool exhausted at index $CODEX_IDX (need ${#REPOS_ORDERED[@]} commanders)"; exit 1; }
    COMMANDER="${POOL[$CODEX_IDX]}"
    CODEX_IDX=$(( CODEX_IDX + 1 ))
  fi
  printf '%s\t%s\t%s\n' "$COMMANDER" "$CWD" "$PROVIDER" >> "$TMP"
done

mv "$TMP" "$ART_DIR/troopers.txt" || { log_error "mv troopers.txt failed"; exit 1; }
log_ok "deploy-multi-init: ${#REPOS_ORDERED[@]} troopers assigned for topic $TOPIC"
while IFS= read -r line; do printf '  %s\n' "$line"; done < "$ART_DIR/troopers.txt"
exit 0
```

- [ ] **Step 4: Make it executable**

```bash
chmod +x bin/deploy-multi-init.sh
```

- [ ] **Step 5: Run test**

```bash
timeout 30 bash tests/test_deploy_multi_init.sh
```

Expected: 3× `PASS` lines.

- [ ] **Step 6: Commit**

```bash
git add bin/deploy-multi-init.sh tests/test_deploy_multi_init.sh
git commit -m "$(cat <<'EOF'
feat(deploy-multi): add bin/deploy-multi-init.sh — commander assignment + provider detect

Reads _deploy/<topic>/dag-waves.txt; for each unique repo in DAG order:
- Validate sub-repo path exists at $PWD/<slug> + has CLAUDE.md/AGENTS.md
- cw_deploy_detect_provider per sub-repo (claude for plugin repos, codex
  otherwise)
- Assign commander from config/commanders.yaml pool. Plugin sub-repos
  get 'cody' (reserved). Codex sub-repos get next non-cody pool entry.
Writes _deploy/<topic>/troopers.txt TSV: <commander>\t<cwd>\t<provider>.

Tests: 3-repo deterministic assignment, plugin sub-repo → cody/claude,
missing sub-repo rejects.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Generalize `bin/preflight-layout.sh` with `--art-dir` flag

The v0.19.0 preflight uses `cw_consult_art_dir "$TOPIC"` to resolve the troopers.txt path. The deploy multi-repo flow needs the equivalent under `_deploy/`. Add an additive `--art-dir <abs-path>` flag that, when provided, overrides the consult-derived path. When absent, behavior is byte-equal to v0.19.0 (consult path).

**Files:**
- Modify: `bin/preflight-layout.sh`
- Create: `tests/test_preflight_layout_artdir_flag.sh`

- [ ] **Step 1: Write the failing test (regression + new flag)**

```bash
#!/usr/bin/env bash
# tests/test_preflight_layout_artdir_flag.sh
# Verifies preflight-layout.sh accepts an additive --art-dir flag.
# Without the flag, it falls through to cw_consult_art_dir (v0.19.0 behavior).
# With the flag, it uses the given path (for the v0.20.0 deploy multi-repo flow).
#
# This test does NOT spin up tmux — it tests the arg-parse + path resolution
# layer only. The full pane-allocation behavior is covered by
# test_preflight_layout.sh (consult path) and test_deploy_multi_preflight.sh
# (deploy path).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
SANDBOX=$(mktemp -d)
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"
mkdir -p "$CLONE_WARS_HOME"
trap 'rm -rf "$SANDBOX"' EXIT

# --- Test A: --art-dir flag accepted; with bad path → rc!=0 with "troopers.txt not found"
err=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$PLUGIN_ROOT/bin/preflight-layout.sh" --art-dir /nonexistent topic 3 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: --art-dir /nonexistent should rc!=0" >&2; exit 1; }
echo "$err" | grep -qi 'troopers.txt not found' \
  || { echo "FAIL: error should mention troopers.txt: $err" >&2; exit 1; }
pass "--art-dir: bad path rejected with troopers.txt error"

# --- Test B: without --art-dir flag, falls through to cw_consult_art_dir
# (script will fail on missing troopers.txt at the consult-derived path,
# proving the v0.19.0 code path is reachable)
err=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$PLUGIN_ROOT/bin/preflight-layout.sh" some-topic 2 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: missing troopers.txt should rc!=0" >&2; exit 1; }
echo "$err" | grep -qi 'troopers.txt not found' \
  || { echo "FAIL: legacy path should fail on troopers.txt not found: $err" >&2; exit 1; }
pass "preflight-layout (no flag): legacy code path reachable (v0.19.0 byte-equal)"
```

- [ ] **Step 2: Run test (expect FAIL — flag not yet supported)**

```bash
timeout 20 bash tests/test_preflight_layout_artdir_flag.sh
```

Expected: FAIL — preflight-layout.sh treats `--art-dir` as the topic name and produces a different error.

- [ ] **Step 3: Modify `bin/preflight-layout.sh` to accept `--art-dir`**

Find this block in `bin/preflight-layout.sh`:

```bash
[[ $# -eq 2 ]] || { echo "Usage: $0 <topic> <N>" >&2; exit 2; }
TOPIC="$1"
N="$2"
```

Replace with:

```bash
# v0.20.0: --art-dir <abs-path> overrides the consult-derived art-dir
# (additive; preserves v0.19.0 zero-flag invocation byte-equal).
ART_DIR_OVERRIDE=""
if [[ "${1:-}" == "--art-dir" ]]; then
  [[ -n "${2:-}" ]] || { echo "--art-dir requires a value" >&2; exit 2; }
  ART_DIR_OVERRIDE="$2"
  shift 2
fi
[[ $# -eq 2 ]] || { echo "Usage: $0 [--art-dir <abs-path>] <topic> <N>" >&2; exit 2; }
TOPIC="$1"
N="$2"
```

Then find:

```bash
ART_DIR="$(cw_consult_art_dir "$TOPIC")"
```

Replace with:

```bash
if [[ -n "$ART_DIR_OVERRIDE" ]]; then
  ART_DIR="$ART_DIR_OVERRIDE"
else
  ART_DIR="$(cw_consult_art_dir "$TOPIC")"
fi
```

- [ ] **Step 4: Run test**

```bash
timeout 20 bash tests/test_preflight_layout_artdir_flag.sh
```

Expected: 2× `PASS` lines.

- [ ] **Step 5: Verify v0.19.0 consult preflight test still passes (regression)**

```bash
timeout 60 bash tests/test_preflight_layout.sh 2>&1 | tail -3
```

Expected: `PASS: bin/preflight-layout.sh: N=3 happy path...`.

- [ ] **Step 6: Commit**

```bash
git add bin/preflight-layout.sh tests/test_preflight_layout_artdir_flag.sh
git commit -m "$(cat <<'EOF'
feat(preflight): add --art-dir flag for v0.20.0 multi-repo deploy

Additive flag: when set, --art-dir <abs-path> overrides the consult-derived
art-dir resolution. Without the flag, behavior is byte-equal to v0.19.0
(falls through to cw_consult_art_dir, used by /clone-wars:consult).

Used by v0.20.0 deploy multi-repo path to point preflight at the
_deploy/<topic>/ dir instead of _consult/<topic>/.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Drop opencode from `cw_deploy_detect_provider`

**Files:**
- Modify: `lib/deploy.sh` (the `cw_deploy_detect_provider` function around line 234)
- Create: `tests/test_deploy_provider_no_opencode.sh`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# tests/test_deploy_provider_no_opencode.sh
# Verifies cw_deploy_detect_provider rejects --provider opencode.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

# Test A: override "opencode" → rc!=0 + clear error
err=$(cw_deploy_detect_provider "$PWD" "opencode" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: opencode override should rc!=0" >&2; exit 1; }
echo "$err" | grep -qi 'opencode' || { echo "FAIL: error should mention opencode: $err" >&2; exit 1; }
echo "$err" | grep -qi 'codex\|claude' || { echo "FAIL: error should suggest codex/claude: $err" >&2; exit 1; }
pass "cw_deploy_detect_provider rejects --provider opencode"

# Test B: codex override still works
result=$(cw_deploy_detect_provider "$PWD" "codex")
assert_eq "$result" "codex" "codex override accepted"

# Test C: claude override still works
result=$(cw_deploy_detect_provider "$PWD" "claude")
assert_eq "$result" "claude" "claude override accepted"

# Test D: unknown override → rc!=0
err=$(cw_deploy_detect_provider "$PWD" "gemini" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: unknown override should rc!=0" >&2; exit 1; }
pass "cw_deploy_detect_provider rejects unknown override"

# Test E: no override + no plugin.json → codex (existing behavior)
SANDBOX=$(mktemp -d)
result=$(cw_deploy_detect_provider "$SANDBOX")
assert_eq "$result" "codex" "no override + no plugin.json → codex"
rm -rf "$SANDBOX"
```

- [ ] **Step 2: Run test (expect FAIL)**

```bash
timeout 20 bash tests/test_deploy_provider_no_opencode.sh
```

Expected: FAIL — current `cw_deploy_detect_provider` accepts opencode override (returns it verbatim).

- [ ] **Step 3: Modify `cw_deploy_detect_provider` in `lib/deploy.sh`**

Find this block (around line 234):

```bash
cw_deploy_detect_provider() {
  local repo_root="${1:-}"
  local override="${2:-}"
  [[ -n "$repo_root" ]] || { log_error "cw_deploy_detect_provider: missing repo-root arg"; return 2; }
  if [[ -n "$override" ]]; then
    printf '%s\n' "$override"
    return 0
  fi
  if [[ -f "$repo_root/.claude-plugin/plugin.json" ]]; then
    printf 'claude\n'
  else
    printf 'codex\n'
  fi
}
```

Replace with:

```bash
cw_deploy_detect_provider() {
  local repo_root="${1:-}"
  local override="${2:-}"
  [[ -n "$repo_root" ]] || { log_error "cw_deploy_detect_provider: missing repo-root arg"; return 2; }
  if [[ -n "$override" ]]; then
    case "$override" in
      codex|claude)
        printf '%s\n' "$override"
        return 0
        ;;
      opencode)
        log_error "deploy: opencode is not a supported provider in v0.20.0+; use codex (default) or claude (plugin-dev)"
        return 1
        ;;
      *)
        log_error "deploy: unknown provider override '$override' (allowed: codex, claude)"
        return 1
        ;;
    esac
  fi
  if [[ -f "$repo_root/.claude-plugin/plugin.json" ]]; then
    printf 'claude\n'
  else
    printf 'codex\n'
  fi
}
```

- [ ] **Step 4: Run test**

```bash
timeout 20 bash tests/test_deploy_provider_no_opencode.sh
```

Expected: 4× `PASS` lines.

- [ ] **Step 5: Commit**

```bash
git add lib/deploy.sh tests/test_deploy_provider_no_opencode.sh
git commit -m "$(cat <<'EOF'
feat(deploy): drop opencode from cw_deploy_detect_provider (v0.20.0)

cw_deploy_detect_provider now whitelists the override values to
{codex, claude}. Passing --provider opencode rejects with a clear
error message; unknown overrides also reject. Auto-detect (no
override) is unchanged: claude on plugin repos, codex elsewhere.

Reflects v0.20.0 deploy policy: codex-only by default with claude
exception for plugin-dev. opencode remains supported in
/clone-wars:consult (separate roster mechanism via medic).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Update `bin/deploy-init.sh` — auto-detect routing

**Files:**
- Modify: `bin/deploy-init.sh`
- Create: `tests/test_deploy_init_routing_autodetect.sh`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# tests/test_deploy_init_routing_autodetect.sh
# Verifies bin/deploy-init.sh writes _deploy/<topic>/routing.txt with
# 'single-repo' or 'multi-repo' based on design-doc header form.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
SANDBOX=$(mktemp -d)
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"
mkdir -p "$CLONE_WARS_HOME"
trap 'rm -rf "$SANDBOX"' EXIT

# Synthesize a minimal git repo so cw_deploy_branch_create has something to act on
GIT_DIR="$SANDBOX/repo"
mkdir -p "$GIT_DIR"
( cd "$GIT_DIR" && git init -q && git commit -q --allow-empty -m "init" )

# Test A: single-repo design doc → routing.txt = single-repo
DOC_S="$GIT_DIR/2026-05-09-singlerepo-design.md"
cat > "$DOC_S" <<'EOF'
# Single

## Goal
Do a thing.

## Architecture
Approach: do it.

## Testing
Run tests.

## Success Criteria
- [ ] Tests pass.
EOF
( cd "$GIT_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLONE_WARS_HOME="$CLONE_WARS_HOME" \
  "$PLUGIN_ROOT/bin/deploy-init.sh" --no-branch --topic singlerepotest "$DOC_S" )

source "$PLUGIN_ROOT/lib/state.sh"
REPO_HASH=$(cd "$GIT_DIR" && cw_repo_hash)
ART_S="$CLONE_WARS_HOME/state/$REPO_HASH/singlerepotest/_deploy"
assert_file_exists "$ART_S/routing.txt" "single-repo: routing.txt written"
routing=$(cat "$ART_S/routing.txt")
assert_eq "$routing" "single-repo" "single-repo: routing = single-repo"

# Test B: multi-repo design doc → routing.txt = multi-repo
DOC_M="$GIT_DIR/2026-05-09-multirepo-design.md"
cat > "$DOC_M" <<'EOF'
# Multi

**Target Sub-Project(s):** auth, api

## Goal
Do many things.

## Architecture
Approach.

## Execution DAG

1. auth — first
2. api — second (depends on 1)

## Testing
Tests.

## Success Criteria
- [ ] Done.
EOF
( cd "$GIT_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLONE_WARS_HOME="$CLONE_WARS_HOME" \
  "$PLUGIN_ROOT/bin/deploy-init.sh" --no-branch --topic multirepotest "$DOC_M" )

ART_M="$CLONE_WARS_HOME/state/$REPO_HASH/multirepotest/_deploy"
assert_file_exists "$ART_M/routing.txt" "multi-repo: routing.txt written"
routing=$(cat "$ART_M/routing.txt")
assert_eq "$routing" "multi-repo" "multi-repo: routing = multi-repo"

pass "deploy-init routing auto-detect: single + multi both correct"
```

- [ ] **Step 2: Run test (expect FAIL)**

```bash
timeout 30 bash tests/test_deploy_init_routing_autodetect.sh
```

Expected: FAIL — `routing.txt` doesn't exist (deploy-init doesn't write it yet).

- [ ] **Step 3: Modify `bin/deploy-init.sh` to write `routing.txt`**

Find the block where `topic.txt` is written (around line 80-85):

```bash
printf '%s' "$TOPIC" > "$ART_DIR/topic.txt" \
  || { log_error "could not write $ART_DIR/topic.txt"; exit 1; }
```

Add this block immediately after:

```bash
# v0.20.0: auto-detect routing from design-doc header form.
# - **Target Sub-Project(s):** plural + ## Execution DAG → multi-repo
# - else → single-repo (byte-equal to v0.19.0)
if grep -qE '^\*\*Target Sub-Project\(s\):\*\*' "$DESIGN_PATH" \
   && grep -qE '^## Execution DAG\b' "$DESIGN_PATH"; then
  ROUTING="multi-repo"
else
  ROUTING="single-repo"
fi
printf '%s\n' "$ROUTING" > "$ART_DIR/routing.txt" \
  || { log_error "could not write $ART_DIR/routing.txt"; exit 1; }
log_info "routing: $ROUTING"
```

- [ ] **Step 4: Run test**

```bash
timeout 30 bash tests/test_deploy_init_routing_autodetect.sh
```

Expected: `PASS: deploy-init routing auto-detect: single + multi both correct`.

- [ ] **Step 5: Commit**

```bash
git add bin/deploy-init.sh tests/test_deploy_init_routing_autodetect.sh
git commit -m "$(cat <<'EOF'
feat(deploy-init): write _deploy/<topic>/routing.txt (single|multi-repo)

Auto-detect from design-doc header form:
- **Target Sub-Project(s):** plural + ## Execution DAG → multi-repo
- else → single-repo (byte-equal v0.19.0)

The routing.txt file is the conductor's read-only signal for which
deploy code path the directive should follow (added in subsequent
commit to commands/deploy.md).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Rewrite `commands/deploy.md` — frontmatter, source-defaulting, routing branch, multi-repo Steps

This is the largest task in the plan. Multiple sub-edits.

**Files:**
- Modify: `commands/deploy.md` (substantial — frontmatter + intro + Steps 0-1 + new Steps 3a/3b/4/5 multi-repo + fix line-257 bug)

- [ ] **Step 1: Add `allowed-tools` to frontmatter + trigger phrases preamble**

Find the frontmatter block at the top of `commands/deploy.md` (lines 1-5). Locate the existing frontmatter's closing `---`. Modify so it reads:

```yaml
---
description: Audit a design doc, dispatch to codex troopers (claude on plugin repos) for plan/implement/self-verify, then cross-verify and fix-loop. Multi-repo DAG-aware (v0.20.0).
argument-hint: [--no-branch] [--branch <n>] [--topic <slug>] [--provider codex|claude] [--max-rounds 5] <design-doc-path>
allowed-tools: Bash, Write, Read, Edit, AskUserQuestion
---
```

Then find the line that says `# /clone-wars:deploy` (typically line 7). Add a "When to use" block immediately after the H1, before the existing prose:

```markdown
**When to use this command.** Invoke `/clone-wars:deploy` when the user
asks to implement, ship, or execute a design doc produced by
`/clone-wars:consult`. Trigger phrases: "deploy this design", "implement
the spec at <path>", "ship <design-path>", "execute the design-doc",
"spawn troopers for <design>". Single-repo design docs run today's
single-trooper flow; multi-repo design docs (`**Target Sub-Project(s):**`
header + `## Execution DAG` section) automatically route through the
v0.20.0 multi-repo DAG flow.

```

- [ ] **Step 2: Drop `--design-doc` and `synthesis.md` from the source-defaulting section**

Find the block that describes how to default the design-doc path when `$ARGUMENTS` doesn't include one. Look for references to `--design-doc`, `synthesis.md`, or a `find` invocation that includes both `*-design.md` AND `synthesis.md`. Replace with a clean v0.17.0+ formulation:

Search for: `synthesis.md` or `--design-doc` in the directive. Locate the surrounding paragraph + bash block. Replace it with:

```markdown
**Source-defaulting** (when `$ARGUMENTS` doesn't include a `.md` path):
Find the most recent consult-produced audit-passing design doc:

```
STATE_ROOT="${CLONE_WARS_HOME:-$HOME/.clone-wars}/state"
DESIGN_DOC=$(find "$STATE_ROOT" -path '*/_consult/design-doc/*-design.md' -print0 2>/dev/null \
  | xargs -0 ls -t 2>/dev/null | head -1)
[[ -n "$DESIGN_DOC" ]] || { log_error "no consult design-doc found; run /clone-wars:consult first or pass <path>"; exit 1; }
```

(v0.20.0: dropped pre-v0.12 `--design-doc` flag and `synthesis.md`
fallback. The `/clone-wars:spec` command was removed in v0.17.0;
consult v0.17+ produces audit-passing design-docs directly.)
```

- [ ] **Step 3: Add the routing branch right after deploy-init.sh runs (Step 0 area)**

In `commands/deploy.md` Step 0 (around line 130 where `cw_deploy_audit_doc` is called), find where the directive transitions from init → audit → Step 1 (spawn). After the audit succeeds, add:

```markdown
**Routing branch (v0.20.0).** After `cw_deploy_audit_doc` returns
PASS, read the routing decision written by `bin/deploy-init.sh`:

```
ROUTING=$(cat "$ART_DIR/routing.txt")
log_info "deploy routing: $ROUTING"
```

If `$ROUTING == "single-repo"`: continue with Steps 1.1, 1, 2, 3, 4
exactly as v0.19.0 (single-trooper flow, no multi-repo ceremony).

If `$ROUTING == "multi-repo"`: skip Step 1.1; proceed to NEW Step 3a
(preflight) → Step 3b (DAG wave dispatch) → Step 4 (final verification)
→ Step 5 (fix-loop). The single-repo Steps 1, 2, 3 below are
**inactive** on this branch.

```

- [ ] **Step 4: Add NEW Step 3a — multi-repo preflight**

After the existing single-repo Steps 1-3, insert NEW Step 3a (multi-repo only):

```markdown
### Step 3a — Preflight pane allocation (multi-repo)

**Active only when `$ROUTING == "multi-repo"`.**

Set task `3a` → `in_progress`.

The `bin/deploy-init.sh` already invoked `bin/deploy-dag-parse.sh`
(NEW v0.20.0) to produce `_deploy/<topic>/dag-waves.txt` and
`dag-edges.txt`, and `bin/deploy-multi-init.sh` to produce
`_deploy/<topic>/troopers.txt`. (If those files are missing, deploy-init
would have already failed. Defensive check:)

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
"$CLAUDE_PLUGIN_ROOT/bin/preflight-layout.sh" --art-dir "$ART_DIR" "$TOPIC" "$N"
```

Note the `--art-dir` flag points preflight at the deploy art-dir
instead of the consult art-dir (preflight-layout.sh accepts this
flag as of v0.20.0).

Load pane assignments:

```
declare -A PREFLIGHT_PANES
while IFS=$'\t' read -r cmdr pane; do
  [[ -n "$cmdr" && -n "$pane" ]] && PREFLIGHT_PANES["$cmdr"]="$pane"
done < "$ART_DIR/preflight-panes.txt"
```

Set task `3a` → `completed`.

```

- [ ] **Step 5: Add NEW Step 3b — DAG wave dispatch**

```markdown
### Step 3b — DAG wave dispatch (multi-repo)

**Active only when `$ROUTING == "multi-repo"`.**

Set task `3b` → `in_progress`.

Walk `_deploy/<topic>/dag-waves.txt` wave-by-wave. For each wave: issue
K parallel `bin/spawn.sh --target-pane <pane> --cwd <sub-repo-cwd>`
calls (one per sub-repo in the wave); send the DAG-unit prompt to
each trooper's inbox; background-await for K done events.

```
mapfile -t WAVES < "$ART_DIR/dag-waves.txt"
declare -A REPO_TO_CMDR
declare -A REPO_TO_CWD
declare -A REPO_TO_PROVIDER
while IFS=$'\t' read -r cmdr cwd provider; do
  # Map cwd's basename (which IS the repo slug) → cmdr
  repo=$(basename "$cwd")
  REPO_TO_CMDR["$repo"]="$cmdr"
  REPO_TO_CWD["$repo"]="$cwd"
  REPO_TO_PROVIDER["$repo"]="$provider"
done < "$ART_DIR/troopers.txt"

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
```

For each wave, **issue K parallel `Bash` tool calls in a single message**
— one per repo in the wave. Each call spawns a codex (or claude) trooper
into its pre-allocated pane, pinned to its sub-repo cwd, and dispatches
the DAG-unit prompt via inbox + send.

Canonical wave dispatch per repo:

```
"$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" "${REPO_TO_CMDR[$repo]}" "${REPO_TO_PROVIDER[$repo]}" \
  "$TOPIC" \
  --target-pane "${PREFLIGHT_PANES[${REPO_TO_CMDR[$repo]}]}" \
  --cwd "${REPO_TO_CWD[$repo]}"
```

DAG-unit inbox prompt (write via `bin/send.sh` with `--from master-yoda`
after spawn returns ready):

```
Read /path/to/design-doc. Your sub-repo is "<slug>".

Multi-repo design docs use `### <slug>` subsection headings inside the
Architecture and Components sections — focus on the subsections matching
your slug. The DAG context (Step <N> of <total>) is in the
"## Execution DAG" section; you depend on: <upstream-slug-list>.

Run the full superpowers ceremony for your sub-repo:
1. superpowers:writing-plans — produce an implementation plan from the
   design-doc's slice for "<slug>", saved to
   docs/superpowers/plans/YYYY-MM-DD-<topic>-<slug>-plan.md
2. superpowers:subagent-driven-development — execute the plan task-by-
   task, two-stage review per task
3. superpowers:verification-before-completion — confirm tests pass,
   diff matches the plan, no half-finished work, before reporting done

Report status via outbox: emit {"event":"done"} when all tasks are
complete and verified. Emit {"event":"error", "reason":"..."} on any
unrecoverable failure.
END_OF_INSTRUCTION
```

After dispatching the wave's K spawn+send pairs, **issue K parallel
background `Bash` tool calls** for `bin/turn-wait.sh` (or
`bin/deploy-turn-wait.sh`) — one per trooper. Each runs in
`run_in_background: true`, emits a notification on completion. Yoda
processes notifications as they arrive (mirrors v0.19.0 consult
Step 5's pattern).

Wait until ALL K notifications have arrived AND all K state files show
`TS=ok` (or terminal failure state). Then proceed to the next wave.

#### Failure handling — Stage 1 retry-once + Stage 2 partial-success (multi-repo)

After a wave's K spawns return rc tuples:

- **All K succeed** → continue to next wave. After last wave, set task
  `3b` → `completed`.

- **At least one fails AND `SPAWN_RETRY_COUNT == 0`** → **Stage 1
  retry-once**: full teardown + re-preflight + re-dispatch the entire
  wave (mirrors v0.19.0 consult Step 3b). Most cold-start failures
  absorbed here.

- **At least one fails AND `SPAWN_RETRY_COUNT == 1`** → **Stage 2
  partial-success offer**: AskUserQuestion ("M/K spawned in this wave
  after retry. Proceed degraded with N=M / Abort all?"). On "Proceed
  degraded": rewrite `_deploy/troopers.txt` to drop the failed entry
  + continue to next wave with reduced roster. On "Abort all": full
  teardown + `rm -rf "$TOPIC_DIR"` + exit 1.

Set task `3b` → `completed` only after ALL waves succeed (or user
elected to proceed degraded).
```

- [ ] **Step 6: Add NEW Step 4 — Conductor's final verification**

```markdown
### Step 4 — Final verification (multi-repo)

**Active only when `$ROUTING == "multi-repo"`.**

Set task `4` → `in_progress`.

After all waves complete, the conductor (Yoda) does its own verification.
Default = cross-repo invariants only. Escalate to full check (all tests
+ Success Criteria diff review) on any of three "feels unsafe" triggers.

**Compute the unsafe signal:**

```
source "$CLAUDE_PLUGIN_ROOT/lib/deploy-dag.sh"
WAVE_COUNT=$(awk -F$'\t' '{print $1}' "$ART_DIR/dag-waves.txt" | sort -u | wc -l)
FAN_IN_REPOS=$(cw_deploy_dag_fan_in_repos "$ART_DIR/dag-edges.txt" "$ART_DIR/dag-waves.txt")
SHARED_PATHS=""
# Compute git-diff overlap across sub-repos: any path appearing in 2+ commits
# (declare which troopers' diffs to consider — only those with a branch base)
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

If any verification check finds a bug, proceed to Step 5 fix-loop.
If all green, set task `4` → `completed` and proceed to Step 6.

```

- [ ] **Step 7: Add NEW Step 5 — Fix-loop**

```markdown
### Step 5 — Fix-loop (multi-repo)

**Active only when `$ROUTING == "multi-repo"` AND Step 4 found bugs.**

Set task `5` → `in_progress`.

For each bug found in Step 4, identify the offending sub-repo. The
trooper that owns that sub-repo is still alive in its pre-allocated
pane (commander + cwd both available from `_deploy/troopers.txt`).

Initialize per-sub-repo fix-round counter:

```
declare -A FIX_ROUNDS
MAX_FIX_ROUNDS=3
```

For each (sub-repo, bug-description) pair:

1. Look up the trooper:
   ```
   CMDR=$(awk -F$'\t' -v r="$REPO" '$2 ~ ("/" r "$") { print $1 }' "$ART_DIR/troopers.txt")
   ```

2. Send a fix-prompt via the trooper's inbox:

   ```
   /clone-wars:send --from master-yoda "$CMDR" "$TOPIC" "FIX REQUEST (round ${FIX_ROUNDS[$REPO]:-1} of $MAX_FIX_ROUNDS):
   
   I detected the following issue in your sub-repo:
   
   <bug-description>
   
   Please fix it using the same superpowers ceremony (writing-plans for the
   fix → subagent-driven-development → verification-before-completion).
   Report done via outbox when verified.
   END_OF_INSTRUCTION"
   ```

3. Background-await for the trooper's done event (mirrors Step 3b's
   await pattern).

4. Re-run Step 4's verification for THIS sub-repo. If green, mark fix
   resolved.

5. If still buggy AND `${FIX_ROUNDS[$REPO]} -lt $MAX_FIX_ROUNDS`:
   `FIX_ROUNDS[$REPO]=$(( ${FIX_ROUNDS[$REPO]:-0} + 1 ))` and loop back
   to step 2.

6. If still buggy AND `${FIX_ROUNDS[$REPO]} -ge $MAX_FIX_ROUNDS`:
   AskUserQuestion:
   - Question: "Sub-repo '$REPO' hit MAX_FIX_ROUNDS=3 fix attempts.
     Bug remains: <bug>. What now?"
   - Options:
     - `Give up on this sub-repo` — mark FAILED in `_deploy/results.txt`;
       continue verification for other sub-repos
     - `Continue more rounds` — bump `FIX_ROUNDS[$REPO]` and re-loop
     - `Escalate to different commander` — pick next available
       commander from the pool, spawn fresh trooper with same `--cwd`,
       reset `FIX_ROUNDS[$REPO]=0`

After all bugs resolved (or given up on), set task `5` → `completed`.

```

- [ ] **Step 8: Fix the `description='...$ROUND...'` interpolation bug**

Find the line containing `description='master yoda await cody round=$ROUND turn (background)'` (around line 257 in v0.19.0; line numbers may have shifted). Replace single quotes with double quotes:

```
description="master yoda await cody round=$ROUND turn (background)"
```

- [ ] **Step 9: Smoke-check structure**

```bash
echo "Step 3a count:  $(grep -c '^### Step 3a ' commands/deploy.md)"
echo "Step 3b count:  $(grep -c '^### Step 3b ' commands/deploy.md)"
echo "Step 4 count:   $(grep -c '^### Step 4 ' commands/deploy.md)"
echo "Step 5 count:   $(grep -c '^### Step 5 ' commands/deploy.md)"
echo "MAX_FIX_ROUNDS: $(grep -c 'MAX_FIX_ROUNDS=3' commands/deploy.md)"
echo "PREFLIGHT_PANES: $(grep -c 'PREFLIGHT_PANES' commands/deploy.md)"
echo "synthesis.md refs: $(grep -c 'synthesis.md' commands/deploy.md)"
echo "--design-doc refs: $(grep -c '\-\-design\-doc' commands/deploy.md)"
echo "trigger phrases:  $(grep -c 'Trigger phrases\|deploy this design\|implement the spec' commands/deploy.md)"
echo "allowed-tools:    $(grep -c '^allowed-tools:' commands/deploy.md)"
```

Expected:
- Step 3a/3b/4/5: each ≥1
- MAX_FIX_ROUNDS=3: ≥1
- PREFLIGHT_PANES: ≥3
- synthesis.md refs: 0
- --design-doc refs: 0
- trigger phrases: ≥1
- allowed-tools: 1

- [ ] **Step 10: Commit**

```bash
git add commands/deploy.md
git commit -m "$(cat <<'EOF'
feat(deploy): rewrite directive for v0.20.0 multi-repo DAG path

Frontmatter:
- Add allowed-tools (was missing entirely; matches medic + consult v0.18.x)
- argument-hint advertises --provider codex|claude (was undocumented)
- description emphasizes "deploy-audit-passing design doc" + multi-repo

Source-defaulting cleanup:
- Drop pre-v0.12 --design-doc and synthesis.md fallback (gone since v0.12)
- Single source: latest *-design.md under _consult/design-doc/

Routing branch (NEW):
- Read $ART_DIR/routing.txt (written by bin/deploy-init.sh)
- single-repo → today's Steps 1.1, 1, 2, 3, 4 (byte-equal v0.19.0)
- multi-repo → NEW Steps 3a, 3b, 4, 5

NEW Steps 3a/3b/4/5 (multi-repo):
- 3a: preflight via bin/preflight-layout.sh --art-dir
- 3b: DAG wave dispatch with K parallel spawn calls per wave; trooper
  inbox prompt invokes superpowers ceremony per sub-repo; Stage 1/Stage 2
  failure handling mirrors v0.19.0 consult
- 4: conductor's final verification — cross-repo invariants by default;
  escalate to full check on 3 "feels unsafe" triggers (wave count >= 3,
  fan-in repos, shared filesystem paths)
- 5: fix-loop with MAX_FIX_ROUNDS=3 cap; AskUserQuestion at cap
  (give up / continue / escalate to different commander)

Trigger phrases preamble + when-to-use block (mirror medic v0.18.2 polish).

Bug fix: description='...$ROUND...' single-quote interpolation
(line ~257 in v0.19.0) → double quotes so $ROUND interpolates.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Extend `bin/deploy-teardown.sh` for multi-repo orphan cleanup

**Files:**
- Modify: `bin/deploy-teardown.sh`
- Create: `tests/test_deploy_teardown_preflight_orphans.sh`

This mirrors the v0.19.0 `bin/consult-teardown.sh` extension (commit a029abc).

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# tests/test_deploy_teardown_preflight_orphans.sh
# Mirrors test_consult_teardown_preflight_orphans.sh but for /clone-wars:deploy.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

[[ -n "${TMUX:-}" ]] || { echo "  SKIP: no tmux session ($TMUX unset)" >&2; exit 0; }
command -v tmux >/dev/null || { echo "  SKIP: tmux not on PATH" >&2; exit 0; }

PLUGIN_ROOT="$(cd .. && pwd)"
SANDBOX=$(mktemp -d)
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"
mkdir -p "$CLONE_WARS_HOME"

source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

TOPIC="deploy-orphan-test-$$"
REPO_HASH=$(cw_repo_hash)
ART_DIR="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC/_deploy"
mkdir -p "$ART_DIR"

# Open isolated test window with 3 panes
TEST_WIN="cw-deploy-orphan-$$-${RANDOM}"
tmux new-window -d -n "$TEST_WIN"
trap 'tmux kill-window -t "$TEST_WIN" 2>/dev/null || true; rm -rf "$SANDBOX"' EXIT
sleep 0.3

BASE_PANE=$(tmux list-panes -t "$TEST_WIN" -F '#{pane_id}' | head -1)
PANE1=$(tmux split-window -P -F '#{pane_id}' -t "$BASE_PANE" -h 'sleep infinity')
PANE2=$(tmux split-window -P -F '#{pane_id}' -t "$PANE1" -v 'sleep infinity')
PANE3=$(tmux split-window -P -F '#{pane_id}' -t "$PANE2" -v 'sleep infinity')

# preflight-panes has 3; troopers.txt only has 2 → PANE3 is orphan
cat > "$ART_DIR/preflight-panes.txt" <<EOF
rex	$PANE1
wolffe	$PANE2
bly	$PANE3
EOF
cat > "$ART_DIR/troopers.txt" <<EOF
rex	$SANDBOX/auth	codex
wolffe	$SANDBOX/api	codex
EOF

# Stub state dirs for rex+wolffe so teardown.sh has something to find
mkdir -p "$SANDBOX/auth" "$SANDBOX/api"
echo "init" > "$SANDBOX/auth/CLAUDE.md"
echo "init" > "$SANDBOX/api/CLAUDE.md"

# Invoke deploy-teardown
"$PLUGIN_ROOT/bin/deploy-teardown.sh" "$TOPIC" 2>&1 || true
sleep 0.5

# All 3 preflight panes should be killed (rex+wolffe via troopers.txt; bly via orphan path)
for p in "$PANE1" "$PANE2" "$PANE3"; do
  if tmux list-panes -a -F '#{pane_id}' | grep -qx "$p"; then
    echo "FAIL: pane $p still alive after deploy-teardown" >&2; exit 1
  fi
done

# preflight-panes.txt should be removed by orphan extension
[[ ! -f "$ART_DIR/preflight-panes.txt" ]] \
  || { echo "FAIL: preflight-panes.txt should be removed by deploy-teardown" >&2; exit 1; }

pass "deploy-teardown kills preflight orphan panes (PANE3 not in troopers.txt)"
```

- [ ] **Step 2: Run test (expect FAIL)**

```bash
timeout 60 bash tests/test_deploy_teardown_preflight_orphans.sh
```

Expected: FAIL — `bin/deploy-teardown.sh` doesn't yet handle preflight-panes.txt.

- [ ] **Step 3: Inspect current `bin/deploy-teardown.sh`**

```bash
cat bin/deploy-teardown.sh
```

Note the current script's structure (likely 14 lines per file-structure note above).

- [ ] **Step 4: Extend `bin/deploy-teardown.sh` with the orphan-cleanup block**

After the existing teardown logic (which iterates trooper state-dirs / panes), append the orphan-cleanup block. The shape mirrors v0.19.0 consult-teardown.sh's extension:

```bash
# v0.20.0: also kill any preflight pane that is NOT in troopers.txt
# (orphan sentinel left over from Stage 2 partial-success abort, fix-loop
# "give up" abort, or pre-spawn Ctrl-C). Idempotent — safe when
# preflight-panes.txt is absent.
PFP_FILE="$ART_DIR/preflight-panes.txt"
if [[ -f "$PFP_FILE" ]]; then
  declare -A LIVE_CMDRS=()
  if [[ -f "$ART_DIR/troopers.txt" ]]; then
    while IFS=$'\t' read -r cmdr cwd provider; do
      [[ -n "$cmdr" ]] && LIVE_CMDRS["$cmdr"]=1
    done < "$ART_DIR/troopers.txt"
  fi
  while IFS=$'\t' read -r cmdr pane; do
    [[ -n "$cmdr" && -n "$pane" ]] || continue
    [[ "${LIVE_CMDRS[$cmdr]:-0}" == "1" ]] && continue  # not orphan
    log_info "killing preflight orphan pane $pane (commander=$cmdr)"
    tmux kill-pane -t "$pane" 2>/dev/null || log_warn "kill-pane $pane failed (already dead?)"
  done < "$PFP_FILE"
  rm -f "$PFP_FILE"
fi
```

If the existing `bin/deploy-teardown.sh` doesn't already have an `ART_DIR=` resolution near the top, prepend it:

```bash
[[ $# -ge 1 ]] || { echo "Usage: $0 <topic>" >&2; exit 2; }
TOPIC="$1"
ART_DIR=$(cw_deploy_art_dir "$TOPIC")
```

(The existing script may already have these — keep one copy.)

- [ ] **Step 5: Run test**

```bash
timeout 60 bash tests/test_deploy_teardown_preflight_orphans.sh
```

Expected: `PASS: deploy-teardown kills preflight orphan panes (PANE3 not in troopers.txt)`.

- [ ] **Step 6: Commit**

```bash
git add bin/deploy-teardown.sh tests/test_deploy_teardown_preflight_orphans.sh
git commit -m "$(cat <<'EOF'
feat(deploy-teardown): clean preflight orphan panes (v0.20.0)

Mirrors v0.19.0 consult-teardown's orphan-cleanup extension. After the
existing roster teardown, walks _deploy/preflight-panes.txt and kills
any pane whose commander is NOT in troopers.txt. Handles three cases:
- Stage 2 partial-success abort
- Fix-loop "give up on this sub-repo" leaving allocated pane
- User Ctrl-C between preflight and dispatch

Idempotent — no-op when preflight-panes.txt is absent (single-repo
deploys + pre-v0.20 archived deploys unaffected).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Tmux-dependent test for multi-repo preflight

**Files:**
- Create: `tests/test_deploy_multi_preflight.sh`

This validates the full preflight flow for the deploy art-dir using `--art-dir` flag.

- [ ] **Step 1: Write the test**

```bash
#!/usr/bin/env bash
# tests/test_deploy_multi_preflight.sh
# Tmux-dep: bin/preflight-layout.sh --art-dir <deploy-art-dir> allocates
# K=3 evenly-sized panes for the v0.20.0 multi-repo deploy flow.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

[[ -n "${TMUX:-}" ]] || { echo "  SKIP: no tmux session ($TMUX unset)" >&2; exit 0; }
command -v tmux >/dev/null || { echo "  SKIP: tmux not on PATH" >&2; exit 0; }

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

SANDBOX=$(mktemp -d)
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"
mkdir -p "$CLONE_WARS_HOME"

source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"

TOPIC="deploy-multi-preflight-$$"
REPO_HASH=$(cw_repo_hash)
ART_DIR="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC/_deploy"
mkdir -p "$ART_DIR"

# preflight-layout.sh expects troopers.txt with TSV. For deploy multi-repo,
# the format is <commander>\t<cwd>\t<provider>. preflight-layout.sh uses
# cw_consult_load_troopers which is a generic 2-col reader and tolerates
# extra columns — verify:
cat > "$ART_DIR/troopers.txt" <<EOF
rex	/tmp/auth	codex
wolffe	/tmp/api	codex
bly	/tmp/ui	codex
EOF

TEST_WIN="cw-deploy-pf-$$-${RANDOM}"
tmux new-window -d -n "$TEST_WIN"
trap 'tmux kill-window -t "$TEST_WIN" 2>/dev/null || true; rm -rf "$SANDBOX"; rm -f /tmp/cw-deploy-pf-$$.log' EXIT
sleep 0.5

YODA_PANE=$(tmux list-panes -t "$TEST_WIN" -F '#{pane_id}' | head -1)
LOG_FILE="/tmp/cw-deploy-pf-$$.log"

tmux send-keys -t "$YODA_PANE" "CLAUDE_PLUGIN_ROOT='$PLUGIN_ROOT' CLONE_WARS_HOME='$CLONE_WARS_HOME' bash '$PLUGIN_ROOT/bin/preflight-layout.sh' --art-dir '$ART_DIR' '$TOPIC' 3 > '$LOG_FILE' 2>&1; echo PFRC=\$?" Enter

got_pfrc=""
for _ in $(seq 1 30); do
  out=$(tmux capture-pane -p -t "$YODA_PANE" 2>/dev/null)
  if [[ "$out" == *"PFRC=0"* ]]; then got_pfrc=0; break; fi
  if [[ "$out" == *"PFRC=1"* ]]; then got_pfrc=1; break; fi
  if [[ "$out" == *"PFRC=2"* ]]; then got_pfrc=2; break; fi
  sleep 0.5
done
[[ "$got_pfrc" == "0" ]] || { echo "FAIL: preflight rc=$got_pfrc" >&2; if [[ -f "$LOG_FILE" ]]; then cat "$LOG_FILE" >&2; fi; exit 1; }

# Verify preflight-panes.txt was written under the deploy art-dir
PFP="$ART_DIR/preflight-panes.txt"
assert_file_exists "$PFP" "preflight-panes.txt written under deploy art-dir"

mapfile -t LINES < "$PFP"
[[ ${#LINES[@]} -eq 3 ]] || { echo "FAIL: expected 3 lines in preflight-panes.txt (got ${#LINES[@]})" >&2; exit 1; }

# Heights within ±5 rows
heights=()
for line in "${LINES[@]}"; do
  pane="${line#*$'\t'}"
  heights+=( "$(tmux display-message -p -t "$pane" '#{pane_height}')" )
done
hmin=${heights[0]}; hmax=${heights[0]}
for h in "${heights[@]}"; do
  (( h < hmin )) && hmin=$h
  (( h > hmax )) && hmax=$h
done
diff=$(( hmax - hmin ))
(( diff <= 5 )) || { echo "FAIL: pane heights uneven (min=$hmin max=$hmax diff=$diff)" >&2; exit 1; }

pass "bin/preflight-layout.sh --art-dir <deploy>: K=3 panes allocated under _deploy/, even heights"
```

- [ ] **Step 2: Run test**

```bash
timeout 60 bash tests/test_deploy_multi_preflight.sh
```

Expected: `PASS: bin/preflight-layout.sh --art-dir <deploy>: K=3 panes allocated under _deploy/, even heights`.

- [ ] **Step 3: Commit**

```bash
git add tests/test_deploy_multi_preflight.sh
git commit -m "$(cat <<'EOF'
test(deploy-preflight): multi-repo preflight allocates K=3 panes under _deploy/

Tmux-dep test that drives bin/preflight-layout.sh --art-dir <deploy-art-dir>
end-to-end: 3-trooper TSV (commander\tcwd\tprovider) → 3 evenly-sized
sentinel panes + preflight-panes.txt under _deploy/<topic>/.

Validates that the v0.19.0 preflight machinery (split-window per
trooper, select-layout main-vertical, sentinel banners) works for the
v0.20.0 deploy art-dir via the new --art-dir flag.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Static-wiring test for v0.20.0 directive

**Files:**
- Create: `tests/test_deploy_directive_v020_static_wiring.sh`

- [ ] **Step 1: Write the test**

```bash
#!/usr/bin/env bash
# tests/test_deploy_directive_v020_static_wiring.sh
# Static-wiring asserts on commands/deploy.md for v0.20.0:
# - Frontmatter: allowed-tools listed
# - Routing branch present (reads routing.txt)
# - NEW Steps 3a/3b/4/5 multi-repo headings
# - MAX_FIX_ROUNDS=3 + AskUserQuestion at-cap wording
# - PREFLIGHT_PANES array used (mirrors v0.19.0 consult)
# - Trigger phrases at top
# - NEGATIVE: no --design-doc references; no synthesis.md references
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

DIR=../commands/deploy.md
BODY=$(cat "$DIR")

# Frontmatter
grep -qE '^allowed-tools:' "$DIR" \
  || { echo "FAIL: frontmatter missing allowed-tools" >&2; exit 1; }
grep -qE '^allowed-tools:.*AskUserQuestion' "$DIR" \
  || { echo "FAIL: allowed-tools missing AskUserQuestion" >&2; exit 1; }

# Trigger phrases
assert_contains "$BODY" "When to use this command" "directive has When-to-use block"
assert_contains "$BODY" "deploy this design"        "directive lists 'deploy this design' trigger"

# Routing branch (reads routing.txt written by deploy-init.sh)
assert_contains "$BODY" 'routing.txt'                  "directive reads routing.txt"
assert_contains "$BODY" 'ROUTING == "single-repo"'     "directive branches on single-repo"
assert_contains "$BODY" 'ROUTING == "multi-repo"'      "directive branches on multi-repo"

# New v0.20.0 Steps for multi-repo
grep -qE '^### Step 3a ' "$DIR" || { echo "FAIL: missing '### Step 3a' heading" >&2; exit 1; }
grep -qE '^### Step 3b ' "$DIR" || { echo "FAIL: missing '### Step 3b' heading" >&2; exit 1; }
# Step 4 may exist for single-repo too; assert that AT LEAST ONE Step 4 mentions
# multi-repo final verification
grep -qE 'final verification|cross-repo invariants|feels unsafe' "$DIR" \
  || { echo "FAIL: directive missing multi-repo final-verification prose" >&2; exit 1; }
# Step 5: fix-loop
assert_contains "$BODY" "MAX_FIX_ROUNDS=3"          "directive uses MAX_FIX_ROUNDS=3 cap"
assert_contains "$BODY" "Give up on this sub-repo"  "directive offers 'give up' option at cap"
assert_contains "$BODY" "Escalate to different commander" "directive offers escalate-commander option at cap"

# Preflight + DAG infrastructure
assert_contains "$BODY" "bin/preflight-layout.sh"   "directive references preflight-layout.sh"
assert_contains "$BODY" "--target-pane"             "directive uses --target-pane in spawn calls"
assert_contains "$BODY" "--art-dir"                 "directive uses --art-dir in preflight call"
assert_contains "$BODY" "PREFLIGHT_PANES"           "directive declares PREFLIGHT_PANES array"
assert_contains "$BODY" "dag-waves.txt"             "directive walks dag-waves.txt"
assert_contains "$BODY" "Stage 1 retry-once"        "directive describes Stage 1 retry-once"
assert_contains "$BODY" "Stage 2 partial-success"   "directive describes Stage 2 partial-success"

# Superpowers ceremony in DAG-unit prompt
assert_contains "$BODY" "superpowers:writing-plans"             "DAG-unit prompt invokes superpowers:writing-plans"
assert_contains "$BODY" "superpowers:subagent-driven-development" "DAG-unit prompt invokes subagent-driven-development"
assert_contains "$BODY" "superpowers:verification-before-completion" "DAG-unit prompt invokes verification-before-completion"

# NEGATIVE: no --design-doc references (deprecated v0.12, gone in v0.20)
! grep -qE '\-\-design\-doc' "$DIR" \
  || { echo "FAIL: directive still references --design-doc (gone since v0.12)" >&2; exit 1; }
# NEGATIVE: no synthesis.md references (removed v0.12)
! grep -qE 'synthesis\.md' "$DIR" \
  || { echo "FAIL: directive still references synthesis.md (gone since v0.12)" >&2; exit 1; }

# NEGATIVE: line-257 single-quote bug — no `description='.*\$ROUND` patterns
! grep -qE "description='.*\\\$ROUND" "$DIR" \
  || { echo "FAIL: line-257 single-quote bug still present (description='...\$ROUND')" >&2; exit 1; }

pass "commands/deploy.md v0.20.0 static wiring complete"
```

- [ ] **Step 2: Run the test**

```bash
timeout 30 bash tests/test_deploy_directive_v020_static_wiring.sh
```

Expected: `PASS: commands/deploy.md v0.20.0 static wiring complete`. If anything fails, the directive prose from Task 8 needs fixing — go back to that file, fix, re-run.

- [ ] **Step 3: Commit**

```bash
git add tests/test_deploy_directive_v020_static_wiring.sh
git commit -m "$(cat <<'EOF'
test(deploy): static-wiring asserts for v0.20.0 directive

Locks in: frontmatter allowed-tools, trigger phrases, routing branch,
NEW multi-repo Steps 3a/3b + final verification + MAX_FIX_ROUNDS=3
fix-loop with AskUserQuestion at cap, --art-dir / PREFLIGHT_PANES /
dag-waves.txt references, full superpowers ceremony in DAG-unit prompt.

Negative-asserts: no --design-doc refs (deprecated v0.12, gone v0.20),
no synthesis.md refs (gone v0.12), no line-257 single-quote bug.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Plugin version bump 0.19.0 → 0.20.0 + CLAUDE.md status entry

**Files:**
- Modify: `.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Bump plugin.json**

Find this line in `.claude-plugin/plugin.json`:

```json
  "version": "0.19.0",
```

Replace with:

```json
  "version": "0.20.0",
```

- [ ] **Step 2: Bump marketplace.json (two occurrences)**

```bash
grep -n '"version":' .claude-plugin/marketplace.json
```

Both occurrences should be replaced with `"version": "0.20.0"`.

- [ ] **Step 3: Add CLAUDE.md status entries**

Locate the `v0.19.0` row in CLAUDE.md (use `grep -n 'v0.19.0:' CLAUDE.md`). Insert two new rows immediately after the v0.19.0 dogfood gate:

```markdown
- [x] v0.20.0: deploy multi-repo DAG path — auto-detect from design-doc header (`**Target Sub-Project(s):**` plural + `## Execution DAG` → multi-repo; else → single-repo byte-equal v0.19.0). Multi-repo path: `bin/deploy-dag-parse.sh` parses soft-DAG prose into waves (Kahn topological sort + cycle detection); `bin/deploy-multi-init.sh` assigns one commander per sub-repo from clone trooper pool (cody reserved for claude/plugin-dev); reused v0.19.0 `bin/preflight-layout.sh` (additive `--art-dir` flag) for pane allocation; commands/deploy.md NEW Steps 3a (preflight) + 3b (DAG wave dispatch with K parallel spawn calls per wave + Stage 1 retry-once + Stage 2 partial-success) + 4 (conductor's final verification — cross-repo invariants by default, escalate to full check on 3 "feels unsafe" triggers: wave count ≥3, fan-in repos, shared filesystem paths) + 5 (fix-loop with MAX_FIX_ROUNDS=3 cap + AskUserQuestion at cap: give up / continue / escalate to different commander). Codex trooper runs full superpowers ceremony per sub-repo (writing-plans → subagent-driven-development → verification-before-completion). `bin/deploy-teardown.sh` extension cleans preflight orphan panes (mirrors v0.19.0 consult-teardown). `cw_deploy_detect_provider` drops opencode (rejects `--provider opencode` with clear error; codex/claude only). Drops `--design-doc` + `synthesis.md` references entirely (gone since v0.12). Frontmatter polish (`allowed-tools`, trigger phrases, --provider in argument-hint). Fixes line-257 `description='...$ROUND...'` interpolation bug. 8 new tests + extends consult-init regression-tested. `/clone-wars:deploy` for single-repo design-doc is byte-equal to v0.19.0.
- [ ] v0.20.0 strict-dogfood pass on a real machine (release gate — verify: (1) 3-sub-repo multi-repo deploy walks DAG correctly with parallel waves; (2) each codex trooper invokes superpowers ceremony on its sub-repo's design-doc slice via `### <slug>` subsection focus; (3) cross-repo final-verify default doesn't false-positive on simple linear DAGs; (4) fix-loop cap surfaces AskUserQuestion at round 3; (5) `--provider opencode` rejected with clear error; (6) single-repo deploy unchanged from v0.19.0 — same trooper, same single-turn flow, same archive shape; (7) `_deploy/preflight-panes.txt` orphans cleaned up after Stage 2 partial-success abort)
```

- [ ] **Step 4: Commit**

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json CLAUDE.md
git commit -m "$(cat <<'EOF'
chore(release): bump plugin to v0.20.0 + CLAUDE.md status entry

v0.20.0 — deploy multi-repo DAG path. Two-phase trooper allocation
(reused v0.19.0 preflight + new --art-dir flag) + DAG wave dispatch
+ conductor's final verification + fix-loop with MAX_FIX_ROUNDS=3.
Single-repo deploy byte-equal to v0.19.0.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Final test sweep + push + PR

- [ ] **Step 1: Run all v0.20.0-relevant tests**

```bash
for t in test_deploy_dag_lib.sh test_deploy_dag_parse.sh \
         test_deploy_multi_init.sh test_preflight_layout_artdir_flag.sh \
         test_deploy_provider_no_opencode.sh \
         test_deploy_init_routing_autodetect.sh \
         test_deploy_teardown_preflight_orphans.sh \
         test_deploy_multi_preflight.sh \
         test_deploy_directive_v020_static_wiring.sh \
         test_pane_respawn.sh test_preflight_layout.sh \
         test_preflight_layout_rollback.sh \
         test_spawn_target_pane_strict.sh \
         test_consult_teardown_preflight_orphans.sh \
         test_consult_directive_v019_static_wiring.sh \
         test_consult_directive_v017_static_wiring.sh \
         test_spawn_validation.sh test_spawn_rollback.sh \
         test_medic_directive_v018_static_wiring.sh \
         test_active_providers_path.sh \
         test_consult_init_prefers_active.sh \
         test_consult_init_falls_back_to_available.sh \
         test_consult_init_handles_stale_active.sh; do
  printf '=== %s ===\n' "$t"
  timeout 60 bash "tests/$t" 2>&1 | tail -2
  rc=${PIPESTATUS[0]}
  echo "rc=$rc"
done
```

Expected: every test prints `PASS:` or `SKIP:` (skips acceptable for tmux-dep when `$TMUX` unset). Any FAIL → fix before pushing.

- [ ] **Step 2: Push the branch**

```bash
git push -u origin feat/v0.20.0-deploy-multi-repo-dag
```

- [ ] **Step 3: Open the PR**

```bash
gh pr create --title "feat(deploy): multi-repo DAG-aware deploy (v0.20.0)" --body "$(cat <<'EOF'
## Summary

Adds multi-repo DAG-aware path to `/clone-wars:deploy` while keeping the single-repo path byte-equal to v0.19.0.

When `/clone-wars:consult` produces a multi-repo design doc (`**Target Sub-Project(s):**` header + `## Execution DAG` section), deploy now spawns one codex trooper per sub-repo (deterministic commander assignment from the clone trooper pool, claude trooper on plugin-dev sub-repos), walks the DAG by waves dispatching parallel troopers where the DAG allows, each trooper runs the full superpowers ceremony on its sub-repo's slice, conductor does final cross-repo verification, fix-loop on a per-sub-repo basis with `MAX_FIX_ROUNDS=3` + `AskUserQuestion` at cap.

Backwards compat: single-repo deploy (no `**Target Sub-Project(s):**` header) takes today's v0.19.0 code path unchanged.

## What changes

- **NEW** `lib/deploy-dag.sh` (~150 lines, 4 helpers: parse_line / topological / unique_repos / fan_in_repos)
- **NEW** `bin/deploy-dag-parse.sh` (parses `## Execution DAG` prose → `_deploy/dag-waves.txt` + `dag-edges.txt`)
- **NEW** `bin/deploy-multi-init.sh` (commander assignment + per-repo provider detect → `_deploy/troopers.txt`)
- **MODIFIED** `bin/preflight-layout.sh` — additive `--art-dir <abs-path>` flag (consult zero-arg path unchanged byte-equal)
- **MODIFIED** `lib/deploy.sh` — `cw_deploy_detect_provider` rejects `--provider opencode` (codex/claude only)
- **MODIFIED** `bin/deploy-init.sh` — auto-detect routing → write `_deploy/<topic>/routing.txt`
- **MODIFIED** `commands/deploy.md` — frontmatter `allowed-tools`, trigger phrases, source-defaulting cleanup (drop `--design-doc` + `synthesis.md`), routing branch, NEW Steps 3a/3b/4/5 for multi-repo, fix line-257 `description='...$ROUND...'` interpolation bug
- **MODIFIED** `bin/deploy-teardown.sh` — preflight orphan cleanup (mirrors v0.19.0 consult-teardown)

## Test plan

- [x] `tests/test_deploy_dag_lib.sh` — 4 lib helpers (linear / parallel / diamond / cycle)
- [x] `tests/test_deploy_dag_parse.sh` — e2e parse (linear / diamond / missing-DAG / cycle / malformed)
- [x] `tests/test_deploy_multi_init.sh` — commander assignment + cody-skip + plugin-detect per sub-repo
- [x] `tests/test_preflight_layout_artdir_flag.sh` — `--art-dir` flag + legacy regression
- [x] `tests/test_deploy_provider_no_opencode.sh` — `--provider opencode` rejected
- [x] `tests/test_deploy_init_routing_autodetect.sh` — single-repo + multi-repo `routing.txt` correct
- [x] `tests/test_deploy_teardown_preflight_orphans.sh` — orphan cleanup (tmux-dep)
- [x] `tests/test_deploy_multi_preflight.sh` — K=3 panes via `--art-dir <deploy>` (tmux-dep)
- [x] `tests/test_deploy_directive_v020_static_wiring.sh` — directive prose
- [x] All v0.19.0 regression tests continue to pass without modification
- [ ] After merge: dogfood `/clone-wars:deploy <multi-repo-design-doc>` on a 3-sub-repo project (release gate per CLAUDE.md)

## Spec / plan

- Spec: `docs/superpowers/specs/2026-05-09-deploy-multi-repo-dag-design.md`
- Plan: `docs/superpowers/plans/2026-05-09-deploy-multi-repo-dag-plan.md`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: `gh` prints the PR URL.

- [ ] **Step 4: Report PR URL to user.**

---

## Self-review checklist

| Spec section | Implementing task(s) |
|---|---|
| `lib/deploy-dag.sh` helpers | Task 2 |
| `bin/deploy-dag-parse.sh` | Task 3 |
| `bin/deploy-multi-init.sh` | Task 4 |
| `bin/preflight-layout.sh` `--art-dir` flag | Task 5 |
| `cw_deploy_detect_provider` opencode reject | Task 6 |
| `bin/deploy-init.sh` routing.txt auto-detect | Task 7 |
| `commands/deploy.md` frontmatter (allowed-tools) | Task 8 Step 1 |
| `commands/deploy.md` trigger phrases | Task 8 Step 1 |
| `commands/deploy.md` source-defaulting (drop --design-doc / synthesis) | Task 8 Step 2 |
| `commands/deploy.md` routing branch | Task 8 Step 3 |
| `commands/deploy.md` Step 3a (preflight) | Task 8 Step 4 |
| `commands/deploy.md` Step 3b (DAG wave dispatch + Stage 1/2) | Task 8 Step 5 |
| `commands/deploy.md` Step 4 (final verification + feels-unsafe heuristics) | Task 8 Step 6 |
| `commands/deploy.md` Step 5 (fix-loop with cap + AskUserQuestion) | Task 8 Step 7 |
| `commands/deploy.md` line-257 `description=` bug fix | Task 8 Step 8 |
| `bin/deploy-teardown.sh` orphan cleanup | Task 9 |
| Tmux-dep multi-repo preflight test | Task 10 |
| Static-wiring test | Task 11 |
| Plugin version bump + CLAUDE.md | Task 12 |
| Final test sweep + PR | Task 13 |

All spec sections covered. Type signatures consistent: `cw_deploy_dag_parse_line` returns TSV `<step>\t<repo>\t<desc>\t<deps-csv>` in Task 2, parsed identically in Task 3. `cw_deploy_dag_topological` signature `<edges-tsv> <node1> <node2> ...` is consistent. `cw_deploy_detect_provider <repo-root> [<override>]` signature unchanged from v0.19.0.

Failure mode coverage matches spec table: preflight rollback (existing v0.19.0 trap covers it), Stage 1 retry-once + Stage 2 partial-success (Task 8 Step 5), trooper TS=failed (Task 8 Step 5 same handling), fix-loop cap (Task 8 Step 7), --provider opencode reject (Task 6), DAG cycle detection (Task 2 + Task 3), missing sub-repo (Task 4), orphan pane cleanup (Task 9).

Ready for execution.
