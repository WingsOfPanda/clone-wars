# Consult v0.11 Hub-Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a hub-mode track to `/clone-wars:consult` that emits multi-repo design docs (header + DAG + Cross-Repo Deps + Step-tagged tests) consumable by external ARS multi-agent dispatch and future v0.11+ deploy multi-target dispatch, while keeping single-repo behavior byte-identical to v0.10.

**Architecture:** Extend `lib/consult.sh` with hub-detection, targets-persistence, and three new format validators (DAG, Cross-Repo Deps, Acceptance Tests). Thread a `TARGETS=<csv>` placeholder through `consult/{research,verify,drilldown}.md` prompt templates. Modify `bin/consult-init.sh` to persist hub mode at init time, and `bin/consult-design-doc.sh` to run the three validators before commit when `targets.txt` exists. Update `commands/consult.md` directive Step 0 (hub-detect persist), Step 2 prelude (target selection AskUserQuestion + `TARGETS=` threading), and Step 8.5 (3 new sections + per-sub-project drill axis).

**Tech Stack:** pure bash 4.2+, tmux, file IPC. No new runtime deps. Tests use the repo's existing `tests/lib/assert.sh` + `tests/run.sh` discovery.

**Spec:** `docs/superpowers/specs/2026-05-04-consult-hub-mode-design.md`

---

## Task 1: Hub detector with three modes

**Files:**
- Modify: `lib/consult.sh:727-741` (`cw_consult_detect_hub`)
- Test: `tests/test_consult_detect_hub_super.sh`
- Test: `tests/test_consult_detect_hub_subrepo.sh`
- Test: `tests/test_consult_detect_hub_single.sh`
- Test: `tests/test_consult_detect_hub_mixed.sh`
- Test: `tests/test_consult_detect_hub_empty.sh`

The current detector returns one-line-per-leaf names with rc=0/1. v0.11 needs to distinguish three modes (`single-repo`, `hub-subrepo`, `super-hub`) and emit a structured 3-line stdout `MODE=`/`HUBS=`/`LEAVES=` so callers can branch on classification without re-globbing.

- [ ] **Step 1: Write the failing test (super-hub)**

```bash
cat > tests/test_consult_detect_hub_super.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/consult.sh

TMPROOT=$(mktemp -d -t cw-detect-super.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

git init -q "$TMPROOT"
mkdir -p "$TMPROOT/hub_a/leaf1" "$TMPROOT/hub_a/leaf2" "$TMPROOT/hub_b/leaf3"
git init -q "$TMPROOT/hub_a"
git init -q "$TMPROOT/hub_a/leaf1"
git init -q "$TMPROOT/hub_a/leaf2"
git init -q "$TMPROOT/hub_b"
git init -q "$TMPROOT/hub_b/leaf3"

out=$(cw_consult_detect_hub "$TMPROOT") || rc=$?; rc=${rc:-0}
[[ "$rc" -eq 0 ]] || { echo "FAIL: rc=$rc"; exit 1; }
grep -qx 'MODE=super-hub' <<< "$out"  || { echo "FAIL: no MODE=super-hub"; printf '%s\n' "$out"; exit 1; }
grep -qE '^HUBS=hub_[ab],hub_[ab]$' <<< "$out" || { echo "FAIL: HUBS line wrong"; printf '%s\n' "$out"; exit 1; }
grep -q '^LEAVES=' <<< "$out" || { echo "FAIL: no LEAVES line"; exit 1; }
leaves=$(grep '^LEAVES=' <<< "$out" | cut -d= -f2)
for l in hub_a/leaf1 hub_a/leaf2 hub_b/leaf3; do
  [[ ",$leaves," == *,$l,* ]] || { echo "FAIL: leaf $l missing in $leaves"; exit 1; }
done
pass "super-hub detected with HUBS+LEAVES lines"
EOF
chmod +x tests/test_consult_detect_hub_super.sh
```

- [ ] **Step 2: Run test, verify it fails**

Run: `bash tests/test_consult_detect_hub_super.sh`
Expected: FAIL — current detector returns plain leaf names, not the new MODE/HUBS/LEAVES format.

- [ ] **Step 3: Replace `cw_consult_detect_hub` in `lib/consult.sh`**

Replace the function body at `lib/consult.sh:727-741` with:

```bash
# cw_consult_detect_hub <cwd>
# Classifies <cwd> into one of three modes and prints structured stdout:
#   MODE=single-repo|hub-subrepo|super-hub
#   HUBS=<comma-list>      (only when super-hub)
#   LEAVES=<comma-list>    (always when rc=0; <hub>/<leaf> form for super-hub,
#                           <self>/<leaf> form for hub-subrepo)
# Returns 0 when hub-mode (hub-subrepo or super-hub); rc=1 for single-repo
# (preserves v0.10 caller expectation).
cw_consult_detect_hub() {
  local cwd="${1:-}"
  [[ -n "$cwd" ]] || return 1
  [[ -d "$cwd/.git" || -f "$cwd/.git" ]] || return 1

  local self_name child base
  self_name="${cwd##*/}"
  local -a immediate_git=() leaves_subrepo=() hubs=() leaves_super=()
  for child in "$cwd"/*/; do
    [[ -d "$child" ]] || continue
    if [[ -d "$child/.git" || -f "$child/.git" ]]; then
      base="${child%/}"
      immediate_git+=("${base##*/}")
    fi
  done
  [[ ${#immediate_git[@]} -gt 0 ]] || return 1

  # Check whether each immediate git child has its own git grandchildren.
  local hub leaf grandchild has_grand
  for hub in "${immediate_git[@]}"; do
    has_grand=0
    for grandchild in "$cwd/$hub"/*/; do
      [[ -d "$grandchild" ]] || continue
      if [[ -d "$grandchild/.git" || -f "$grandchild/.git" ]]; then
        leaf="${grandchild%/}"
        leaves_super+=("$hub/${leaf##*/}")
        has_grand=1
      fi
    done
    if (( has_grand == 1 )); then
      hubs+=("$hub")
    else
      leaves_subrepo+=("$self_name/$hub")
    fi
  done

  # Classification:
  # - any immediate git child is a hub (has git grandchildren) → super-hub
  # - all immediate git children are leaves → hub-subrepo
  # - mixed: super-hub mode, leaf-less hubs are dropped (per spec error-handling)
  if (( ${#hubs[@]} > 0 )); then
    [[ ${#leaves_super[@]} -gt 0 ]] || return 1
    printf 'MODE=super-hub\n'
    printf 'HUBS=%s\n' "$(IFS=,; echo "${hubs[*]}")"
    printf 'LEAVES=%s\n' "$(IFS=,; echo "${leaves_super[*]}")"
    return 0
  fi
  if (( ${#leaves_subrepo[@]} > 0 )); then
    printf 'MODE=hub-subrepo\n'
    printf 'LEAVES=%s\n' "$(IFS=,; echo "${leaves_subrepo[*]}")"
    return 0
  fi
  return 1
}
```

- [ ] **Step 4: Run super-hub test, verify it passes**

Run: `bash tests/test_consult_detect_hub_super.sh`
Expected: PASS.

- [ ] **Step 5: Add the four sibling tests**

Create `tests/test_consult_detect_hub_subrepo.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/consult.sh

TMPROOT=$(mktemp -d -t cw-detect-subrepo.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

git init -q "$TMPROOT"
mkdir -p "$TMPROOT/leaf1/src" "$TMPROOT/leaf2/src"
git init -q "$TMPROOT/leaf1"
git init -q "$TMPROOT/leaf2"

out=$(cw_consult_detect_hub "$TMPROOT") || rc=$?; rc=${rc:-0}
[[ "$rc" -eq 0 ]] || { echo "FAIL: rc=$rc"; exit 1; }
grep -qx 'MODE=hub-subrepo' <<< "$out" || { echo "FAIL"; exit 1; }
grep -q '^LEAVES=' <<< "$out" || { echo "FAIL: no LEAVES"; exit 1; }
grep -q '^HUBS=' <<< "$out" && { echo "FAIL: HUBS line should be absent in hub-subrepo"; exit 1; }
leaves=$(grep '^LEAVES=' <<< "$out" | cut -d= -f2)
self="$(basename "$TMPROOT")"
[[ ",$leaves," == *,"$self/leaf1",* ]] || { echo "FAIL: $self/leaf1 missing in $leaves"; exit 1; }
[[ ",$leaves," == *,"$self/leaf2",* ]] || { echo "FAIL: $self/leaf2 missing"; exit 1; }
pass "hub-subrepo detected"
```

Create `tests/test_consult_detect_hub_single.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/consult.sh

TMPROOT=$(mktemp -d -t cw-detect-single.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

git init -q "$TMPROOT"
mkdir -p "$TMPROOT/src" "$TMPROOT/docs"   # plain children, no .git

out=$(cw_consult_detect_hub "$TMPROOT") && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: expected rc=1, got $rc"; exit 1; }
[[ -z "$out" ]] || { echo "FAIL: expected empty stdout, got: $out"; exit 1; }
pass "single-repo returns rc=1 + empty stdout (v0.10 backward-compat)"
```

Create `tests/test_consult_detect_hub_mixed.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/consult.sh

TMPROOT=$(mktemp -d -t cw-detect-mixed.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

git init -q "$TMPROOT"
mkdir -p "$TMPROOT/hub_a/leaf1" "$TMPROOT/hub_b"
git init -q "$TMPROOT/hub_a"
git init -q "$TMPROOT/hub_a/leaf1"
git init -q "$TMPROOT/hub_b"   # no grandchild git → leaf-less hub, dropped

out=$(cw_consult_detect_hub "$TMPROOT") && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] || { echo "FAIL"; exit 1; }
grep -qx 'MODE=super-hub' <<< "$out" || { echo "FAIL"; exit 1; }
hubs=$(grep '^HUBS=' <<< "$out" | cut -d= -f2)
[[ "$hubs" == "hub_a" ]] || { echo "FAIL: expected HUBS=hub_a, got $hubs"; exit 1; }
pass "mixed super-hub: leaf-less hub dropped"
```

Create `tests/test_consult_detect_hub_empty.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/consult.sh

TMPROOT=$(mktemp -d -t cw-detect-empty.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

git init -q "$TMPROOT"
mkdir -p "$TMPROOT/hub_a" "$TMPROOT/hub_b"
git init -q "$TMPROOT/hub_a"
git init -q "$TMPROOT/hub_b"   # both leaf-less

out=$(cw_consult_detect_hub "$TMPROOT") && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: expected rc=1 (super-hub with all leaf-less), got $rc"; exit 1; }
pass "all-leaf-less super-hub falls back to single-repo"
```

`chmod +x tests/test_consult_detect_hub_*.sh`.

- [ ] **Step 6: Run all five tests**

Run: `for t in tests/test_consult_detect_hub_*.sh; do bash "$t" || exit 1; done`
Expected: all PASS.

- [ ] **Step 7: Run full test suite to confirm no regression**

Run: `bash tests/run.sh`
Expected: exit 0; the original `cw_consult_detect_hub` callers in `commands/consult.md` Step 8.5 still work because we preserved rc=1 for single-repo (their existing `&& IS_HUB=1 || IS_HUB=0` branching is unchanged).

- [ ] **Step 8: Commit**

```bash
git add lib/consult.sh tests/test_consult_detect_hub_*.sh
git commit -m "feat(consult): cw_consult_detect_hub returns MODE/HUBS/LEAVES lines

Three modes: single-repo (rc=1), hub-subrepo (rc=0), super-hub (rc=0).
Backward-compat: v0.10 callers branching on rc still work."
```

---

## Task 2: Hub-mode + targets persistence helpers

**Files:**
- Modify: `lib/consult.sh` (append after `cw_consult_detect_hub`)
- Test: `tests/test_consult_targets_persist.sh`
- Test: `tests/test_consult_targets_to_header_pair.sh`

- [ ] **Step 1: Write `test_consult_targets_persist.sh`**

```bash
cat > tests/test_consult_targets_persist.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/state.sh
source ../lib/consult.sh

TMPROOT=$(mktemp -d -t cw-targets.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT
ART="$TMPROOT/_consult"
mkdir -p "$ART"

# Happy path round-trip
printf '%s\n' "hub_a/leaf1" "hub_b/leaf3" | cw_consult_targets_persist "$ART"
out=$(cw_consult_targets_load "$ART")
[[ "$out" == $'hub_a/leaf1\nhub_b/leaf3' ]] \
  || { echo "FAIL round-trip: $out"; exit 1; }
pass "round-trip hub_a/leaf1 + hub_b/leaf3"

# Hub-mode persist + load
cw_consult_hub_mode_persist "$ART" "super-hub"
mode=$(cw_consult_hub_mode_load "$ART")
[[ "$mode" == "super-hub" ]] || { echo "FAIL mode: $mode"; exit 1; }
pass "hub-mode persist/load round-trip"

# Default fallback
rm -f "$ART/hub-mode.txt"
mode=$(cw_consult_hub_mode_load "$ART")
[[ "$mode" == "single-repo" ]] || { echo "FAIL default: $mode"; exit 1; }
pass "hub-mode load default = single-repo"

# Slug rejection
if printf '%s\n' "../escape/leaf" | cw_consult_targets_persist "$ART" 2>/dev/null; then
  echo "FAIL: ../escape should be rejected"; exit 1
fi
pass "rejects ../escape slug"

if printf '%s\n' "no-slash-here" | cw_consult_targets_persist "$ART" 2>/dev/null; then
  echo "FAIL: no-slash-here should be rejected"; exit 1
fi
pass "rejects line without slash"

# Empty targets.txt → load rc=1
: > "$ART/targets.txt"
if cw_consult_targets_load "$ART" 2>/dev/null; then
  echo "FAIL: empty targets.txt should rc=1"; exit 1
fi
pass "empty targets.txt → load rc=1"
EOF
chmod +x tests/test_consult_targets_persist.sh
```

- [ ] **Step 2: Run test, verify it fails**

Run: `bash tests/test_consult_targets_persist.sh`
Expected: FAIL — helpers don't exist yet.

- [ ] **Step 3: Add helpers to `lib/consult.sh`** (append after the modified `cw_consult_detect_hub`)

```bash
# cw_consult_hub_mode_persist <art-dir> <mode>
# Atomic-writes <art-dir>/hub-mode.txt. Mode must be one of the three
# detector outputs: single-repo | hub-subrepo | super-hub.
cw_consult_hub_mode_persist() {
  local art="${1:-}" mode="${2:-}"
  [[ -n "$art" ]]  || { echo "cw_consult_hub_mode_persist: missing art-dir" >&2; return 2; }
  [[ -n "$mode" ]] || { echo "cw_consult_hub_mode_persist: missing mode" >&2; return 2; }
  case "$mode" in
    single-repo|hub-subrepo|super-hub) ;;
    *) echo "cw_consult_hub_mode_persist: invalid mode '$mode'" >&2; return 2 ;;
  esac
  printf '%s\n' "$mode" | cw_atomic_write "$art/hub-mode.txt"
}

# cw_consult_hub_mode_load <art-dir>
# Echoes the persisted mode; defaults to single-repo when file is absent.
cw_consult_hub_mode_load() {
  local art="${1:-}"
  [[ -n "$art" ]] || { echo "cw_consult_hub_mode_load: missing art-dir" >&2; return 2; }
  if [[ -f "$art/hub-mode.txt" ]]; then
    tr -d '[:space:]' < "$art/hub-mode.txt"
    printf '\n'
  else
    printf 'single-repo\n'
  fi
}

# cw_consult_targets_persist <art-dir>
# Reads stdin (one <hub>/<leaf> line per target), validates each line
# against ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$, atomic-writes <art-dir>/targets.txt.
# Empty stdin or any invalid line → rc=1 + log_error, no file written.
cw_consult_targets_persist() {
  local art="${1:-}"
  [[ -n "$art" ]] || { echo "cw_consult_targets_persist: missing art-dir" >&2; return 2; }
  local -a lines=()
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ ! "$line" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
      echo "cw_consult_targets_persist: invalid target '$line' (need <hub>/<leaf>)" >&2
      return 1
    fi
    lines+=("$line")
  done
  (( ${#lines[@]} > 0 )) \
    || { echo "cw_consult_targets_persist: stdin empty" >&2; return 1; }
  printf '%s\n' "${lines[@]}" | cw_atomic_write "$art/targets.txt"
}

# cw_consult_targets_load <art-dir>
# Echoes targets one per line. rc=1 if file missing or empty.
cw_consult_targets_load() {
  local art="${1:-}"
  [[ -n "$art" ]] || { echo "cw_consult_targets_load: missing art-dir" >&2; return 2; }
  [[ -s "$art/targets.txt" ]] || return 1
  cat "$art/targets.txt"
}

# cw_consult_targets_to_header_pair <art-dir>
# Reads targets.txt and emits exactly two lines suitable for design-doc
# header insertion:
#   **Target Hub(s):** <comma-separated unique hubs>
#   **Target Sub-Project(s):** <comma-separated unique leaves>
# Hubs are extracted as the prefix before '/'; leaves as the suffix after.
# rc=1 if targets.txt is missing/empty.
cw_consult_targets_to_header_pair() {
  local art="${1:-}"
  [[ -n "$art" ]] || { echo "cw_consult_targets_to_header_pair: missing art-dir" >&2; return 2; }
  [[ -s "$art/targets.txt" ]] || return 1
  local hubs leaves
  hubs=$(cut -d/ -f1 "$art/targets.txt" | awk '!seen[$0]++' | paste -sd, -)
  leaves=$(cut -d/ -f2- "$art/targets.txt" | awk '!seen[$0]++' | paste -sd, -)
  # Convert "a,b" → "a, b" for human-readable headers.
  hubs=$(echo "$hubs" | sed 's/,/, /g')
  leaves=$(echo "$leaves" | sed 's/,/, /g')
  printf '**Target Hub(s):** %s\n' "$hubs"
  printf '**Target Sub-Project(s):** %s\n' "$leaves"
}
```

- [ ] **Step 4: Run persistence test**

Run: `bash tests/test_consult_targets_persist.sh`
Expected: PASS (6 sub-cases).

- [ ] **Step 5: Write `test_consult_targets_to_header_pair.sh`**

```bash
cat > tests/test_consult_targets_to_header_pair.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/state.sh
source ../lib/consult.sh

TMPROOT=$(mktemp -d -t cw-header-pair.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT
ART="$TMPROOT/_consult"; mkdir -p "$ART"

printf '%s\n' "hub_a/leaf1" "hub_a/leaf2" "hub_b/leaf3" \
  | cw_consult_targets_persist "$ART"

out=$(cw_consult_targets_to_header_pair "$ART")
[[ "$(printf '%s' "$out" | wc -l)" -eq 1 ]] || true   # header pair = 2 lines, last has no trailing newline → wc -l = 1
expected_hubs='**Target Hub(s):** hub_a, hub_b'
expected_leaves='**Target Sub-Project(s):** leaf1, leaf2, leaf3'
grep -qxF "$expected_hubs"   <<< "$out" || { echo "FAIL hubs line: $out"; exit 1; }
grep -qxF "$expected_leaves" <<< "$out" || { echo "FAIL leaves line: $out"; exit 1; }
pass "header pair: hubs deduped, leaves preserved in order"

# Empty targets → rc=1
rm "$ART/targets.txt"
if cw_consult_targets_to_header_pair "$ART" 2>/dev/null; then
  echo "FAIL: missing targets.txt should rc=1"; exit 1
fi
pass "missing targets.txt → rc=1"
EOF
chmod +x tests/test_consult_targets_to_header_pair.sh
```

- [ ] **Step 6: Run header-pair test**

Run: `bash tests/test_consult_targets_to_header_pair.sh`
Expected: PASS.

- [ ] **Step 7: Run full test suite**

Run: `bash tests/run.sh`
Expected: exit 0.

- [ ] **Step 8: Commit**

```bash
git add lib/consult.sh tests/test_consult_targets_persist.sh tests/test_consult_targets_to_header_pair.sh
git commit -m "feat(consult): hub-mode + targets persistence helpers

cw_consult_hub_mode_persist/load: single-repo|hub-subrepo|super-hub
cw_consult_targets_persist/load: <hub>/<leaf> line format, slug-validated
cw_consult_targets_to_header_pair: emits **Target Hub(s)** + **Target Sub-Project(s)** lines"
```

---

## Task 3: DAG validator

**Files:**
- Modify: `lib/consult.sh` (append `cw_consult_dag_validate`)
- Test: `tests/test_consult_dag_validate.sh`

DAG body grammar (per `~/.claude/templates/design-doc.md`):
```
Step <N>: <repo>  <description>
        depends: Step <M>[, Step <K>...] | none
```

Strict regex parse, Kahn topological sort, reject cycles + unknown ids + repos outside `targets.txt` leaf set.

- [ ] **Step 1: Write `test_consult_dag_validate.sh`** with 6 cases

```bash
cat > tests/test_consult_dag_validate.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/state.sh
source ../lib/consult.sh

TMPROOT=$(mktemp -d -t cw-dag.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT
ART="$TMPROOT/_consult"; mkdir -p "$ART"
printf '%s\n' "hub_a/ARS-TaskServe" "hub_a/ARS-LVMGateway" "hub_a/ARS-Gateway" \
  | cw_consult_targets_persist "$ART"

# (a) Happy linear
cat > "$TMPROOT/dag1.md" <<'D'
Step 1: ARS-TaskServe  registry.yaml field
        depends: none
Step 2: ARS-LVMGateway  consume new field
        depends: Step 1
Step 3: ARS-Gateway  update endpoint
        depends: Step 2
D
cw_consult_dag_validate "$ART" < "$TMPROOT/dag1.md" || { echo "FAIL (a)"; exit 1; }
pass "(a) happy linear"

# (b) Happy diamond
cat > "$TMPROOT/dag2.md" <<'D'
Step 1: ARS-TaskServe  base
        depends: none
Step 2: ARS-LVMGateway  branch left
        depends: Step 1
Step 3: ARS-Gateway  branch right
        depends: Step 1
Step 4: ARS-TaskServe  merge
        depends: Step 2, Step 3
D
cw_consult_dag_validate "$ART" < "$TMPROOT/dag2.md" || { echo "FAIL (b)"; exit 1; }
pass "(b) happy diamond"

# (c) Cycle 1→2→1
cat > "$TMPROOT/dag3.md" <<'D'
Step 1: ARS-TaskServe  thing
        depends: Step 2
Step 2: ARS-LVMGateway  other
        depends: Step 1
D
err=$(cw_consult_dag_validate "$ART" < "$TMPROOT/dag3.md" 2>&1) && { echo "FAIL (c) — should reject"; exit 1; } || true
grep -qi cycle <<< "$err" || { echo "FAIL (c) message: $err"; exit 1; }
pass "(c) cycle rejected"

# (d) Unknown ref
cat > "$TMPROOT/dag4.md" <<'D'
Step 1: ARS-TaskServe  base
        depends: none
Step 2: ARS-LVMGateway  consume
        depends: Step 99
D
err=$(cw_consult_dag_validate "$ART" < "$TMPROOT/dag4.md" 2>&1) && { echo "FAIL (d)"; exit 1; } || true
grep -q "Step 99" <<< "$err" || { echo "FAIL (d) msg: $err"; exit 1; }
pass "(d) unknown ref rejected"

# (e) Repo not in targets
cat > "$TMPROOT/dag5.md" <<'D'
Step 1: ARS-Foo  not in targets
        depends: none
D
err=$(cw_consult_dag_validate "$ART" < "$TMPROOT/dag5.md" 2>&1) && { echo "FAIL (e)"; exit 1; } || true
grep -q "ARS-Foo" <<< "$err" || { echo "FAIL (e) msg: $err"; exit 1; }
pass "(e) non-target repo rejected"

# (f) Free-form prose
cat > "$TMPROOT/dag6.md" <<'D'
Step 1: ARS-TaskServe  base
        depends: none

Phase 2 (sequential, depends on Phase 1)
D
err=$(cw_consult_dag_validate "$ART" < "$TMPROOT/dag6.md" 2>&1) && { echo "FAIL (f)"; exit 1; } || true
grep -qi 'free-form\|invalid' <<< "$err" || { echo "FAIL (f) msg: $err"; exit 1; }
pass "(f) free-form prose rejected"
EOF
chmod +x tests/test_consult_dag_validate.sh
```

- [ ] **Step 2: Run test, verify it fails**

Run: `bash tests/test_consult_dag_validate.sh`
Expected: FAIL — `cw_consult_dag_validate` doesn't exist.

- [ ] **Step 3: Implement `cw_consult_dag_validate`** (append to `lib/consult.sh`)

```bash
# cw_consult_dag_validate <art-dir>
# Reads stdin (the ## Execution DAG body), validates strict grammar:
#   Step <N>: <repo>  <description>
#           depends: Step <M>[, Step <K>...] | none
# Rejects: free-form prose, unknown step refs, cycles, repos outside
# targets.txt leaf set. Stderr carries human-readable ERROR: messages.
# rc=0 on success, rc=1 on validation failure, rc=2 on missing args.
cw_consult_dag_validate() {
  local art="${1:-}"
  [[ -n "$art" ]] || { echo "cw_consult_dag_validate: missing art-dir" >&2; return 2; }
  local -a leaves=()
  if [[ -s "$art/targets.txt" ]]; then
    while IFS= read -r line; do
      leaves+=("${line#*/}")
    done < "$art/targets.txt"
  fi

  local body
  body=$(cat)
  [[ -n "$body" ]] || { echo "ERROR: DAG body is empty" >&2; return 1; }

  # Parse: walk lines, alternating Step + depends. Allow blank lines
  # between Step blocks. Reject anything else.
  local -A step_repo step_desc
  local -A step_deps   # value: comma-separated dep ids
  local -a step_ids=()
  local current=""
  local lineno=0
  local raw
  while IFS= read -r raw; do
    lineno=$((lineno + 1))
    # Trim trailing CR (POSIX)
    raw="${raw%$'\r'}"
    # Skip blank lines.
    [[ -z "${raw// }" ]] && { current=""; continue; }
    if [[ "$raw" =~ ^Step\ ([0-9]+):\ +([A-Za-z0-9._-]+)\ +(.+)$ ]]; then
      current="${BASH_REMATCH[1]}"
      step_repo[$current]="${BASH_REMATCH[2]}"
      step_desc[$current]="${BASH_REMATCH[3]}"
      step_ids+=("$current")
      continue
    fi
    if [[ "$raw" =~ ^[[:space:]]+depends:[[:space:]]*(.+)$ ]]; then
      [[ -n "$current" ]] || { echo "ERROR: line $lineno depends without preceding Step" >&2; return 1; }
      local deps="${BASH_REMATCH[1]}"
      if [[ "$deps" == "none" ]]; then
        step_deps[$current]=""
      else
        # "Step 1, Step 2" → "1,2"
        local norm
        norm=$(echo "$deps" | sed -E 's/Step[[:space:]]+([0-9]+)/\1/g; s/[[:space:]]//g')
        if [[ ! "$norm" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
          echo "ERROR: line $lineno bad depends syntax: '$deps'" >&2
          return 1
        fi
        step_deps[$current]="$norm"
      fi
      current=""
      continue
    fi
    echo "ERROR: line $lineno is invalid (free-form prose or bad grammar): '$raw'" >&2
    return 1
  done <<< "$body"

  (( ${#step_ids[@]} > 0 )) || { echo "ERROR: no Step blocks found" >&2; return 1; }

  # Reference + repo-membership check.
  local id dep
  declare -A id_set=()
  for id in "${step_ids[@]}"; do id_set[$id]=1; done
  for id in "${step_ids[@]}"; do
    [[ -n "${step_deps[$id]+x}" ]] || { echo "ERROR: Step $id missing depends:" >&2; return 1; }
    if (( ${#leaves[@]} > 0 )); then
      local repo="${step_repo[$id]}"
      local found=0 leaf
      for leaf in "${leaves[@]}"; do
        [[ "$leaf" == "$repo" ]] && { found=1; break; }
      done
      (( found == 1 )) || { echo "ERROR: Step $id repo '$repo' not in targets" >&2; return 1; }
    fi
    if [[ -n "${step_deps[$id]}" ]]; then
      IFS=',' read -ra _deps <<< "${step_deps[$id]}"
      for dep in "${_deps[@]}"; do
        [[ -n "${id_set[$dep]+x}" ]] || { echo "ERROR: Step $id depends on unknown Step $dep" >&2; return 1; }
      done
    fi
  done

  # Kahn topological sort to detect cycles.
  declare -A indeg=()
  declare -A adj=()
  for id in "${step_ids[@]}"; do indeg[$id]=0; done
  for id in "${step_ids[@]}"; do
    if [[ -n "${step_deps[$id]}" ]]; then
      IFS=',' read -ra _deps <<< "${step_deps[$id]}"
      for dep in "${_deps[@]}"; do
        adj[$dep]+="$id "
        indeg[$id]=$((indeg[$id] + 1))
      done
    fi
  done
  local -a queue=()
  for id in "${step_ids[@]}"; do
    (( indeg[$id] == 0 )) && queue+=("$id")
  done
  local processed=0 head
  while (( ${#queue[@]} > 0 )); do
    head="${queue[0]}"
    queue=("${queue[@]:1}")
    processed=$((processed + 1))
    for nbr in ${adj[$head]:-}; do
      indeg[$nbr]=$((indeg[$nbr] - 1))
      (( indeg[$nbr] == 0 )) && queue+=("$nbr")
    done
  done
  if (( processed != ${#step_ids[@]} )); then
    echo "ERROR: DAG has a cycle (processed $processed of ${#step_ids[@]} steps)" >&2
    return 1
  fi
  return 0
}
```

- [ ] **Step 4: Run all 6 cases**

Run: `bash tests/test_consult_dag_validate.sh`
Expected: 6 PASS lines.

- [ ] **Step 5: Run full suite**

Run: `bash tests/run.sh`
Expected: exit 0.

- [ ] **Step 6: Commit**

```bash
git add lib/consult.sh tests/test_consult_dag_validate.sh
git commit -m "feat(consult): cw_consult_dag_validate strict grammar + topo sort

Validates Execution DAG body: regex grammar, Kahn cycle detection,
unknown-step-ref + repo-not-in-targets rejection."
```

---

## Task 4: Cross-Repo Deps validator

**Files:**
- Modify: `lib/consult.sh` (append `cw_consult_xrepo_deps_validate`)
- Test: `tests/test_consult_xrepo_deps_validate.sh`

- [ ] **Step 1: Write the test (5 cases)**

```bash
cat > tests/test_consult_xrepo_deps_validate.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/state.sh
source ../lib/consult.sh

TMPROOT=$(mktemp -d -t cw-xrepo.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT
ART="$TMPROOT/_consult"; mkdir -p "$ART"
printf '%s\n' "hub/A" "hub/B" "hub/C" | cw_consult_targets_persist "$ART"

# (a) Happy
cat > "$TMPROOT/x1.md" <<'X'
| Producer | Artifact | Consumer | Type |
|----------|----------|----------|------|
| A | foo.yaml | B | internal |
| ext-svc | token | C | external |
X
cw_consult_xrepo_deps_validate "$ART" < "$TMPROOT/x1.md" || { echo "FAIL (a)"; exit 1; }
pass "(a) happy"

# (b) Header missing
cat > "$TMPROOT/x2.md" <<'X'
| A | foo.yaml | B | internal |
X
err=$(cw_consult_xrepo_deps_validate "$ART" < "$TMPROOT/x2.md" 2>&1) && { echo "FAIL (b)"; exit 1; } || true
grep -qi 'header' <<< "$err" || { echo "FAIL (b) msg: $err"; exit 1; }
pass "(b) header missing rejected"

# (c) Wrong column count
cat > "$TMPROOT/x3.md" <<'X'
| Producer | Artifact | Consumer | Type |
|----------|----------|----------|------|
| A | foo | B |
X
err=$(cw_consult_xrepo_deps_validate "$ART" < "$TMPROOT/x3.md" 2>&1) && { echo "FAIL (c)"; exit 1; } || true
grep -qi 'column' <<< "$err" || { echo "FAIL (c)"; exit 1; }
pass "(c) wrong column count rejected"

# (d) Type='maybe'
cat > "$TMPROOT/x4.md" <<'X'
| Producer | Artifact | Consumer | Type |
|----------|----------|----------|------|
| A | foo | B | maybe |
X
err=$(cw_consult_xrepo_deps_validate "$ART" < "$TMPROOT/x4.md" 2>&1) && { echo "FAIL (d)"; exit 1; } || true
grep -qi "Type=" <<< "$err" || { echo "FAIL (d)"; exit 1; }
pass "(d) bad Type rejected"

# (e) internal Producer not in targets
cat > "$TMPROOT/x5.md" <<'X'
| Producer | Artifact | Consumer | Type |
|----------|----------|----------|------|
| Z | foo | B | internal |
X
err=$(cw_consult_xrepo_deps_validate "$ART" < "$TMPROOT/x5.md" 2>&1) && { echo "FAIL (e)"; exit 1; } || true
grep -qi "Producer 'Z'" <<< "$err" || { echo "FAIL (e) msg: $err"; exit 1; }
pass "(e) non-target internal Producer rejected"
EOF
chmod +x tests/test_consult_xrepo_deps_validate.sh
```

- [ ] **Step 2: Run test, verify failure**

Run: `bash tests/test_consult_xrepo_deps_validate.sh`
Expected: FAIL — helper missing.

- [ ] **Step 3: Implement** (append to `lib/consult.sh`)

```bash
# cw_consult_xrepo_deps_validate <art-dir>
# Reads stdin (Cross-Repo Deps pipe-table body). Validates header row +
# 4 columns + Type ∈ {internal, external} + internal Producer/Consumer
# both in targets.txt leaf set. Stderr ERROR: messages; rc=0/1/2.
cw_consult_xrepo_deps_validate() {
  local art="${1:-}"
  [[ -n "$art" ]] || { echo "cw_consult_xrepo_deps_validate: missing art-dir" >&2; return 2; }
  local -a leaves=()
  if [[ -s "$art/targets.txt" ]]; then
    while IFS= read -r line; do
      leaves+=("${line#*/}")
    done < "$art/targets.txt"
  fi
  local body
  body=$(cat)
  [[ -n "$body" ]] || { echo "ERROR: xrepo-deps body empty" >&2; return 1; }

  local lineno=0 saw_header=0 saw_sep=0
  local raw
  while IFS= read -r raw; do
    lineno=$((lineno + 1))
    raw="${raw%$'\r'}"
    [[ -z "${raw// }" ]] && continue
    if (( saw_header == 0 )); then
      [[ "$raw" =~ ^\|[[:space:]]*Producer[[:space:]]*\|[[:space:]]*Artifact[[:space:]]*\|[[:space:]]*Consumer[[:space:]]*\|[[:space:]]*Type[[:space:]]*\|$ ]] \
        || { echo "ERROR: line $lineno: missing or wrong header (need | Producer | Artifact | Consumer | Type |)" >&2; return 1; }
      saw_header=1
      continue
    fi
    if (( saw_sep == 0 )); then
      [[ "$raw" =~ ^\|[-:[:space:]|]+\|$ ]] \
        || { echo "ERROR: line $lineno: missing separator row" >&2; return 1; }
      saw_sep=1
      continue
    fi
    # Data row: split on '|' and trim each cell.
    IFS='|' read -ra cells <<< "$raw"
    # Leading + trailing empty cells from |...| → expect 6 cells (2 sentinel empty + 4 data).
    if (( ${#cells[@]} != 6 )); then
      echo "ERROR: line $lineno: expected 4 columns, got $((${#cells[@]} - 2))" >&2
      return 1
    fi
    local producer artifact consumer typ
    producer=$(echo "${cells[1]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    artifact=$(echo "${cells[2]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    consumer=$(echo "${cells[3]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    typ=$(echo      "${cells[4]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -n "$producer" && -n "$artifact" && -n "$consumer" && -n "$typ" ]] \
      || { echo "ERROR: line $lineno: empty cell" >&2; return 1; }
    case "$typ" in
      internal|external) ;;
      *) echo "ERROR: line $lineno: Type='$typ' must be 'internal' or 'external'" >&2; return 1 ;;
    esac
    if [[ "$typ" == "internal" ]] && (( ${#leaves[@]} > 0 )); then
      local found_p=0 found_c=0 leaf
      for leaf in "${leaves[@]}"; do
        [[ "$leaf" == "$producer" ]] && found_p=1
        [[ "$leaf" == "$consumer" ]] && found_c=1
      done
      (( found_p == 1 )) || { echo "ERROR: line $lineno: Producer '$producer' marked internal but not in targets" >&2; return 1; }
      (( found_c == 1 )) || { echo "ERROR: line $lineno: Consumer '$consumer' marked internal but not in targets" >&2; return 1; }
    fi
  done <<< "$body"
  (( saw_header == 1 && saw_sep == 1 )) \
    || { echo "ERROR: xrepo-deps missing header or separator" >&2; return 1; }
  return 0
}
```

- [ ] **Step 4: Run + commit**

Run: `bash tests/test_consult_xrepo_deps_validate.sh && bash tests/run.sh`
Expected: all PASS.

```bash
git add lib/consult.sh tests/test_consult_xrepo_deps_validate.sh
git commit -m "feat(consult): cw_consult_xrepo_deps_validate

4-column pipe table validator: Type ∈ {internal,external}, internal
Producer/Consumer must both be in targets.txt leaf set."
```

---

## Task 5: Acceptance Tests validator

**Files:**
- Modify: `lib/consult.sh` (append `cw_consult_acceptance_tests_validate`)
- Test: `tests/test_consult_acceptance_tests_validate.sh`

The validator needs the DAG body to know which Step ids exist — pass via `<art-dir>` (read from `$art/dag.md` or stdin pre-stage). Simplest: caller passes both via two stdin streams isn't bash-friendly; instead read DAG from `$art/design-doc/dag.md` if present.

- [ ] **Step 1: Write the test (5 cases)**

```bash
cat > tests/test_consult_acceptance_tests_validate.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/state.sh
source ../lib/consult.sh

TMPROOT=$(mktemp -d -t cw-acc.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT
ART="$TMPROOT/_consult"; mkdir -p "$ART/design-doc"
printf '%s\n' "hub/A" "hub/B" | cw_consult_targets_persist "$ART"

cat > "$ART/design-doc/dag.md" <<'D'
Step 1: A  base
        depends: none
Step 2: B  consume
        depends: Step 1
D

# (a) Happy
cat > "$TMPROOT/t1.md" <<'T'
- **Step 1** [A] registry roundtrip
  - Setup: install
  - Run: pytest -k registry
  - Pass: exit 0

- **Step 2** [B] dispatcher routes
  - Run: pytest -k dispatcher
  - Pass: exit 0
T
cw_consult_acceptance_tests_validate "$ART" < "$TMPROOT/t1.md" || { echo "FAIL (a)"; exit 1; }
pass "(a) happy"

# (b) Missing **Step N** tag
cat > "$TMPROOT/t2.md" <<'T'
- [A] registry roundtrip
T
err=$(cw_consult_acceptance_tests_validate "$ART" < "$TMPROOT/t2.md" 2>&1) && { echo "FAIL (b)"; exit 1; } || true
grep -qi "missing \*\*Step" <<< "$err" || { echo "FAIL (b) msg: $err"; exit 1; }
pass "(b) missing **Step N** rejected"

# (c) Missing [<sub-project>] tag
cat > "$TMPROOT/t3.md" <<'T'
- **Step 1** registry roundtrip
T
err=$(cw_consult_acceptance_tests_validate "$ART" < "$TMPROOT/t3.md" 2>&1) && { echo "FAIL (c)"; exit 1; } || true
grep -qi "missing \[" <<< "$err" || { echo "FAIL (c)"; exit 1; }
pass "(c) missing [sub-project] rejected"

# (d) Tag references unknown Step
cat > "$TMPROOT/t4.md" <<'T'
- **Step 99** [A] something
T
err=$(cw_consult_acceptance_tests_validate "$ART" < "$TMPROOT/t4.md" 2>&1) && { echo "FAIL (d)"; exit 1; } || true
grep -qi "Step 99" <<< "$err" || { echo "FAIL (d)"; exit 1; }
pass "(d) unknown Step rejected"

# (e) Tag references unknown sub-project
cat > "$TMPROOT/t5.md" <<'T'
- **Step 1** [Z] something
T
err=$(cw_consult_acceptance_tests_validate "$ART" < "$TMPROOT/t5.md" 2>&1) && { echo "FAIL (e)"; exit 1; } || true
grep -qi "\\[Z\\]" <<< "$err" || { echo "FAIL (e)"; exit 1; }
pass "(e) unknown sub-project rejected"
EOF
chmod +x tests/test_consult_acceptance_tests_validate.sh
```

- [ ] **Step 2: Run, verify failure**

Run: `bash tests/test_consult_acceptance_tests_validate.sh` → FAIL.

- [ ] **Step 3: Implement** (append to `lib/consult.sh`)

```bash
# cw_consult_acceptance_tests_validate <art-dir>
# Reads stdin (## Acceptance Tests body). Each top-level entry
# (line starting with `- `) must begin with `**Step N**` followed by
# `[<sub-project>]`. Cross-references against $art/design-doc/dag.md
# (Step ids) and $art/targets.txt (leaf names). rc=0/1/2.
cw_consult_acceptance_tests_validate() {
  local art="${1:-}"
  [[ -n "$art" ]] || { echo "cw_consult_acceptance_tests_validate: missing art-dir" >&2; return 2; }

  # Collect known Step ids from dag.md (if present) and known leaves.
  local -A known_ids=() known_leaves=()
  if [[ -s "$art/design-doc/dag.md" ]]; then
    while IFS= read -r line; do
      [[ "$line" =~ ^Step\ ([0-9]+): ]] && known_ids[${BASH_REMATCH[1]}]=1
    done < "$art/design-doc/dag.md"
  fi
  if [[ -s "$art/targets.txt" ]]; then
    while IFS= read -r line; do
      known_leaves["${line#*/}"]=1
    done < "$art/targets.txt"
  fi

  local body lineno=0 entry_no=0 raw
  body=$(cat)
  [[ -n "$body" ]] || { echo "ERROR: acceptance-tests body empty" >&2; return 1; }

  while IFS= read -r raw; do
    lineno=$((lineno + 1))
    raw="${raw%$'\r'}"
    # Top-level entry line.
    [[ "$raw" =~ ^-\  ]] || continue
    entry_no=$((entry_no + 1))
    local content="${raw#- }"
    if [[ ! "$content" =~ ^\*\*Step[[:space:]]+([0-9]+)\*\* ]]; then
      echo "ERROR: entry $entry_no (line $lineno): missing **Step N** tag" >&2
      return 1
    fi
    local sid="${BASH_REMATCH[1]}"
    if (( ${#known_ids[@]} > 0 )) && [[ -z "${known_ids[$sid]+x}" ]]; then
      echo "ERROR: entry $entry_no: tagged **Step $sid** which doesn't exist in DAG" >&2
      return 1
    fi
    if [[ ! "$content" =~ \[([A-Za-z0-9._-]+)\] ]]; then
      echo "ERROR: entry $entry_no (line $lineno): missing [sub-project] tag" >&2
      return 1
    fi
    local repo="${BASH_REMATCH[1]}"
    if (( ${#known_leaves[@]} > 0 )) && [[ -z "${known_leaves[$repo]+x}" ]]; then
      echo "ERROR: entry $entry_no: tagged [$repo] which isn't in targets" >&2
      return 1
    fi
  done <<< "$body"

  (( entry_no > 0 )) || { echo "ERROR: no acceptance-test entries found" >&2; return 1; }
  return 0
}
```

- [ ] **Step 4: Run + suite + commit**

```bash
bash tests/test_consult_acceptance_tests_validate.sh && bash tests/run.sh
git add lib/consult.sh tests/test_consult_acceptance_tests_validate.sh
git commit -m "feat(consult): cw_consult_acceptance_tests_validate

Each entry must be **Step N** [<sub-project>] tagged; cross-refs DAG
step ids (from dag.md) and leaf names (from targets.txt)."
```

---

## Task 6: Prompt template updates ({{TARGETS}} + {{SUBPROJECT}})

**Files:**
- Modify: `config/prompt-templates/consult/research.md`
- Modify: `config/prompt-templates/consult/verify.md`
- Modify: `config/prompt-templates/consult/drilldown.md`
- Test: `tests/test_consult_research_prompt_with_targets.sh`
- Test: `tests/test_consult_verify_prompt_with_targets.sh`
- Test: `tests/test_consult_drilldown_prompt_subproject.sh`

The `cw_consult_load_prompt` helper already supports `{{KEY}}` placeholders — just need to add the placeholders to the templates and confirm the surviving-token guard doesn't fire when `TARGETS=` is empty (it doesn't — empty value still resolves the placeholder).

- [ ] **Step 1: Read current templates to understand baseline**

```bash
ls config/prompt-templates/consult/
cat config/prompt-templates/consult/research.md | head -40
cat config/prompt-templates/consult/verify.md | head -40
cat config/prompt-templates/consult/drilldown.md
```

- [ ] **Step 2: Write `test_consult_research_prompt_with_targets.sh`**

```bash
cat > tests/test_consult_research_prompt_with_targets.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/state.sh
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"; PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
source ../lib/consult.sh

# Hub mode: TARGETS non-empty → instruction must be present
out=$(cw_consult_build_research_prompt "decide between X and Y" "/tmp/findings.md" \
        2>/dev/null) || true
# build_research_prompt currently doesn't accept TARGETS — call cw_consult_load_prompt directly.
out=$(cw_consult_load_prompt consult/research.md \
        TOPIC="decide between X and Y" \
        WRITE_TO=/tmp/findings.md \
        TARGETS="hub_a/leaf1,hub_a/leaf2")
grep -q 'Per-sub-project structure' <<< "$out" \
  || { echo "FAIL: expected per-sub-project instruction with TARGETS set"; exit 1; }
grep -q 'hub_a/leaf1' <<< "$out" \
  || { echo "FAIL: targets list not interpolated"; exit 1; }
pass "TARGETS set → per-sub-project instruction emitted"

# Single-repo: TARGETS empty → instruction absent
out=$(cw_consult_load_prompt consult/research.md \
        TOPIC="decide between X and Y" \
        WRITE_TO=/tmp/findings.md \
        TARGETS="")
grep -q 'Per-sub-project structure' <<< "$out" \
  && { echo "FAIL: instruction must be absent when TARGETS empty"; exit 1; } || true
pass "TARGETS empty → instruction absent (single-repo unchanged)"

# Backward-compat: existing build_research_prompt callers pass empty TARGETS implicitly
out=$(cw_consult_build_research_prompt "topic X" "/tmp/findings.md")
grep -q 'Per-sub-project structure' <<< "$out" \
  && { echo "FAIL: build_research_prompt must default TARGETS empty"; exit 1; } || true
pass "build_research_prompt default = single-repo unchanged"
EOF
chmod +x tests/test_consult_research_prompt_with_targets.sh
```

- [ ] **Step 3: Run test, verify it fails**

Expected: FAIL — `{{TARGETS}}` placeholder doesn't exist in template, and `cw_consult_build_research_prompt` doesn't pass it.

- [ ] **Step 4: Add `{{TARGETS}}` block to `config/prompt-templates/consult/research.md`**

Append at the end of the template (before `END_OF_INSTRUCTION` if present, else at the bottom):

```markdown
{{TARGETS_BLOCK_START}}

## Per-sub-project structure

This consultation spans multiple sub-projects. Structure your `findings.md`
with one `### <sub-project>` heading per sub-project, in this order:

{{TARGETS}}

Each sub-section's claims block contributes to the per-sub-project diff +
verify pass downstream.
{{TARGETS_BLOCK_END}}
```

The two sentinel placeholders let us strip the whole block when `TARGETS=`
is empty (the surviving-token guard would otherwise fire on an unresolved
`{{TARGETS}}`). We'll handle the strip in the bash helper rather than the
template engine — modify `cw_consult_build_research_prompt`:

Edit `lib/consult.sh` `cw_consult_build_research_prompt`:

```bash
cw_consult_build_research_prompt() {
  local topic="$1" write_to="$2" targets="${3:-}"
  local out
  out=$(cw_consult_load_prompt consult/research.md \
          "TOPIC=$topic" "WRITE_TO=$write_to" \
          "TARGETS_BLOCK_START=" "TARGETS_BLOCK_END=" \
          "TARGETS=${targets//,/$'\n'- }")
  if [[ -z "$targets" ]]; then
    # Strip the per-sub-project block: lines between (now-empty) sentinels.
    # Sentinels rendered as empty lines; collapse them and the body.
    printf '%s\n' "$out" | awk '
      /^## Per-sub-project structure$/ { skipping=1; next }
      /^Each sub-section/ && skipping { skipping=0; next }
      !skipping { print }
    '
  else
    printf '%s\n' "$out"
  fi
}
```

Same shape for `verify.md` and `drilldown.md`. (Drilldown adds `{{SUBPROJECT}}` separately — see Task 7.)

For `verify.md`, append the same `## Per-sub-project structure` block and modify `cw_consult_build_verify_prompt`:

```bash
cw_consult_build_verify_prompt() {
  local items_file="$1" write_to="$2" targets="${3:-}"
  local items
  items=$(nl -ba -w1 -s'. ' "$items_file")
  local out
  out=$(cw_consult_load_prompt consult/verify.md \
          "ITEMS=$items" "WRITE_TO=$write_to" \
          "TARGETS_BLOCK_START=" "TARGETS_BLOCK_END=" \
          "TARGETS=${targets//,/$'\n'- }")
  if [[ -z "$targets" ]]; then
    printf '%s\n' "$out" | awk '
      /^## Per-sub-project structure$/ { skipping=1; next }
      /^Each sub-section/ && skipping { skipping=0; next }
      !skipping { print }
    '
  else
    printf '%s\n' "$out"
  fi
}
```

- [ ] **Step 5: Mirror the test for `verify.md`** at `tests/test_consult_verify_prompt_with_targets.sh` — same shape, calls `cw_consult_build_verify_prompt` with a stub items file.

```bash
cat > tests/test_consult_verify_prompt_with_targets.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/state.sh
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"; PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
source ../lib/consult.sh

TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
printf '[file:1] x\n' > "$TMP"

out=$(cw_consult_build_verify_prompt "$TMP" /tmp/v.md "hub/A,hub/B")
grep -q 'Per-sub-project structure' <<< "$out" || { echo "FAIL hub mode"; exit 1; }
grep -q 'hub/A' <<< "$out" || { echo "FAIL hub mode targets"; exit 1; }
pass "verify prompt hub mode emits per-sub-project block"

out=$(cw_consult_build_verify_prompt "$TMP" /tmp/v.md "")
grep -q 'Per-sub-project structure' <<< "$out" && { echo "FAIL: single-repo should not include block"; exit 1; } || true
pass "verify prompt single-repo unchanged"
EOF
chmod +x tests/test_consult_verify_prompt_with_targets.sh
```

- [ ] **Step 6: Run all template tests + full suite**

```bash
bash tests/test_consult_research_prompt_with_targets.sh
bash tests/test_consult_verify_prompt_with_targets.sh
bash tests/run.sh
```

**Important regression risk:** modifying `research.md` and `verify.md` templates changes their byte content. The existing `test_consult_load_prompt_migration.sh` byte-equality check WILL fail. Update its baseline fixtures:

```bash
# Capture new baselines
cw_consult_build_research_prompt "decide between LRU and LFU" "/tmp/findings.md" \
  > tests/fixtures/v0.4.2-research-prompt.txt
# Verify same single-repo output as before for the topic + path.
diff tests/fixtures/v0.4.2-research-prompt.txt <(cw_consult_build_research_prompt "decide between LRU and LFU" "/tmp/findings.md")
```

Wait — the baseline is supposed to capture v0.4.2 byte-equality, NOT current. Re-think: the current baseline byte-equals the template output. As long as our awk-strip restores byte-equality for the empty-TARGETS case, the baseline test continues to pass. Verify:

```bash
bash tests/test_consult_load_prompt_migration.sh
```

If byte-different, the awk strip is leaving a trailing blank line or extra newline. Adjust the awk pattern until byte-equal. Common fix: tighten the skipping range to also drop the trailing blank line:

```awk
/^## Per-sub-project structure$/ { skipping=1; next }
skipping && /^Each sub-section/ { skipping=0; getline; next }    # consume the trailing blank too
!skipping { print }
```

Iterate awk + diff until `bash tests/test_consult_load_prompt_migration.sh` passes.

- [ ] **Step 7: Commit**

```bash
git add config/prompt-templates/consult/research.md \
        config/prompt-templates/consult/verify.md \
        lib/consult.sh \
        tests/test_consult_research_prompt_with_targets.sh \
        tests/test_consult_verify_prompt_with_targets.sh
git commit -m "feat(consult): research+verify prompts emit per-sub-project block when TARGETS set

Single-repo callers pass TARGETS='' (default); awk strip restores byte-equal
output for the v0.4.2 baseline migration test."
```

---

## Task 7: Drilldown prompt with optional sub-project axis

**Files:**
- Modify: `config/prompt-templates/consult/drilldown.md`
- Modify: `lib/consult.sh` (`cw_consult_design_doc_drilldown_prompt`)
- Test: `tests/test_consult_drilldown_prompt_subproject.sh`

- [ ] **Step 1: Write the test**

```bash
cat > tests/test_consult_drilldown_prompt_subproject.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/state.sh
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"; PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
source ../lib/consult.sh

# With sub-project axis
out=$(cw_consult_design_doc_drilldown_prompt \
        "Architecture" "/path/to/synthesis.md" "rex" \
        "/path/to/dd-dir" "Add IPC depth." "ARS-TaskServe")
grep -q 'ARS-TaskServe' <<< "$out" || { echo "FAIL: subproject not mentioned"; exit 1; }
grep -q '_scratch/drilldown-architecture-ARS-TaskServe-rex.md' <<< "$out" \
  || { echo "FAIL: subproject path missing"; exit 1; }
pass "subproject axis: prompt scoped + path includes subproject slug"

# Without (backward-compat with v0.5.3+)
out=$(cw_consult_design_doc_drilldown_prompt \
        "Architecture" "/path/to/synthesis.md" "rex" \
        "/path/to/dd-dir" "Add IPC depth.")
grep -q '_scratch/drilldown-architecture-rex.md' <<< "$out" \
  || { echo "FAIL: legacy path missing"; exit 1; }
grep -q 'ARS-' <<< "$out" \
  && { echo "FAIL: legacy mode should not mention any subproject"; exit 1; } || true
pass "no subproject: legacy path unchanged"
EOF
chmod +x tests/test_consult_drilldown_prompt_subproject.sh
```

- [ ] **Step 2: Run test, verify it fails**

Expected: FAIL — helper signature has 5 args.

- [ ] **Step 3: Modify `config/prompt-templates/consult/drilldown.md`**

Add `{{SUBPROJECT_BLOCK_START}}` / `{{SUBPROJECT_BLOCK_END}}` sentinels around an optional block:

```markdown
{{SUBPROJECT_BLOCK_START}}
Scope: drill specifically into **{{SUBPROJECT}}** within this section.
Other sub-projects are out of scope for this drilldown.
{{SUBPROJECT_BLOCK_END}}
```

- [ ] **Step 4: Modify the helper** in `lib/consult.sh`

Replace `cw_consult_design_doc_drilldown_prompt`:

```bash
cw_consult_design_doc_drilldown_prompt() {
  local section="$1" syn="$2" commander="$3" dd_dir="$4" focus="${5:-}" subproject="${6:-}"
  local section_slug
  section_slug=$(printf '%s' "$section" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
  local out_path
  if [[ -n "$subproject" ]]; then
    out_path="$dd_dir/_scratch/drilldown-${section_slug}-${subproject}-${commander}.md"
  else
    out_path="$dd_dir/_scratch/drilldown-${section_slug}-${commander}.md"
  fi
  local resolved_focus="${focus:-Provide more depth, citations, and concrete trade-offs for the $section section.}"
  local out
  out=$(cw_consult_load_prompt consult/drilldown.md \
          "SECTION=$section" "SYN=$syn" "FOCUS=$resolved_focus" "OUT_PATH=$out_path" \
          "SUBPROJECT_BLOCK_START=" "SUBPROJECT_BLOCK_END=" \
          "SUBPROJECT=${subproject:-N/A}")
  if [[ -z "$subproject" ]]; then
    printf '%s\n' "$out" | awk '
      /^Scope: drill specifically into/ { skipping=1; next }
      skipping && /^Other sub-projects/ { skipping=0; getline; next }
      !skipping { print }
    '
  else
    printf '%s\n' "$out"
  fi
}
```

- [ ] **Step 5: Run + baseline check**

```bash
bash tests/test_consult_drilldown_prompt_subproject.sh
bash tests/test_consult_load_prompt_migration.sh    # baseline must still pass
bash tests/run.sh
```

If `test_consult_load_prompt_migration.sh` fails, update fixture or adjust awk strip until byte-equal. The baseline expects:
```
You are drilling deeper into the **Architecture** section ...
... (no subproject block) ...
  /path/to/dd-dir/_scratch/drilldown-architecture-rex.md
... (END_OF_INSTRUCTION)
```

- [ ] **Step 6: Commit**

```bash
git add config/prompt-templates/consult/drilldown.md lib/consult.sh \
        tests/test_consult_drilldown_prompt_subproject.sh
git commit -m "feat(consult): drilldown prompt accepts optional SUBPROJECT axis

When set: scope-narrowed prompt + output path includes subproject slug.
When unset: legacy path/prompt preserved (baseline test still passes)."
```

---

## Task 8: Spec assembly hub-mode + backward-compat baseline

**Files:**
- Modify: `lib/consult.sh` (`cw_consult_design_doc_assemble`)
- Create: `tests/fixtures/v0.10-single-repo-design.md` (baseline)
- Test: `tests/test_consult_design_doc_assemble_hub.sh`
- Test: `tests/test_consult_design_doc_assemble_single_unchanged.sh`

- [ ] **Step 1: Capture the v0.10 single-repo baseline**

Run the assemble helper in single-repo shape and commit the output as the regression baseline:

```bash
mkdir -p /tmp/cw-baseline/dd /tmp/cw-baseline/_consult
for k in architecture components data-flow error-handling testing; do
  printf '## %s\n\nbody\n' "$k" > "/tmp/cw-baseline/dd/$k.md"
done
printf '## Agreed findings\n\n- claim 1\n' > /tmp/cw-baseline/_consult/synthesis.md
( cd /home/liupan/CC/clone-wars && \
  source lib/log.sh && source lib/state.sh && \
  CLAUDE_PLUGIN_ROOT=$(pwd) PLUGIN_ROOT=$(pwd) source lib/consult.sh && \
  CW_TEST_DATE=2026-05-04 cw_consult_design_doc_assemble \
    /tmp/cw-baseline/dd /tmp/cw-baseline/out.md "Sample Topic" \
    "" /tmp/cw-baseline/_consult/synthesis.md )
cp /tmp/cw-baseline/out.md tests/fixtures/v0.10-single-repo-design.md
```

The fixture captures whatever the v0.10 helper currently produces — that's the contract we're freezing.

- [ ] **Step 2: Write `test_consult_design_doc_assemble_single_unchanged.sh`**

```bash
cat > tests/test_consult_design_doc_assemble_single_unchanged.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/state.sh
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"; PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
source ../lib/consult.sh

TMP=$(mktemp -d -t cw-asm-single.XXXXXX); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/dd" "$TMP/_consult"
for k in architecture components data-flow error-handling testing; do
  printf '## %s\n\nbody\n' "$k" > "$TMP/dd/$k.md"
done
printf '## Agreed findings\n\n- claim 1\n' > "$TMP/_consult/synthesis.md"

CW_TEST_DATE=2026-05-04 cw_consult_design_doc_assemble \
  "$TMP/dd" "$TMP/out.md" "Sample Topic" "" "$TMP/_consult/synthesis.md"

diff -u fixtures/v0.10-single-repo-design.md "$TMP/out.md" \
  || { echo "FAIL: single-repo assembly diverged from v0.10 baseline"; exit 1; }
pass "single-repo assembly byte-equal to v0.10 baseline"
EOF
chmod +x tests/test_consult_design_doc_assemble_single_unchanged.sh
```

- [ ] **Step 3: Run baseline test, verify PASS** (proves baseline + helper agree before changes).

- [ ] **Step 4: Write `test_consult_design_doc_assemble_hub.sh`**

```bash
cat > tests/test_consult_design_doc_assemble_hub.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/state.sh
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"; PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
source ../lib/consult.sh

TMP=$(mktemp -d -t cw-asm-hub.XXXXXX); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/dd" "$TMP/_consult"
for k in architecture components data-flow error-handling acceptance-tests dag xrepo-deps; do
  case "$k" in
    dag) printf 'Step 1: A  base\n        depends: none\nStep 2: B  consume\n        depends: Step 1\n' > "$TMP/dd/$k.md" ;;
    xrepo-deps) printf '| Producer | Artifact | Consumer | Type |\n|---|---|---|---|\n| A | foo | B | internal |\n' > "$TMP/dd/$k.md" ;;
    acceptance-tests) printf -- '- **Step 1** [A] base\n  - Run: pytest\n  - Pass: exit 0\n\n- **Step 2** [B] consume\n  - Run: pytest\n  - Pass: exit 0\n' > "$TMP/dd/$k.md" ;;
    *) printf '## %s\n\nbody\n' "$k" > "$TMP/dd/$k.md" ;;
  esac
done
printf '## Agreed findings\n\n- claim 1\n' > "$TMP/_consult/synthesis.md"
printf 'hub/A\nhub/B\n' > "$TMP/_consult/targets.txt"

CW_TEST_DATE=2026-05-04 cw_consult_design_doc_assemble \
  "$TMP/dd" "$TMP/out.md" "Hub Topic" "" "$TMP/_consult/synthesis.md" "$TMP/_consult"

grep -q '^\*\*Target Hub(s):\*\* hub' "$TMP/out.md" || { echo "FAIL: hub header missing"; exit 1; }
grep -q '^\*\*Target Sub-Project(s):\*\* A, B' "$TMP/out.md" || { echo "FAIL: sub-project header missing"; exit 1; }
grep -q '^## Acceptance Tests' "$TMP/out.md" || { echo "FAIL: Acceptance Tests heading missing"; exit 1; }
grep -q '^## Execution DAG' "$TMP/out.md" || { echo "FAIL: DAG heading missing"; exit 1; }
grep -q '^## Cross-Repo Dependencies' "$TMP/out.md" || { echo "FAIL: Cross-Repo Dependencies missing"; exit 1; }
# Hub mode should NOT emit the legacy "Testing" heading
grep -q '^## Testing' "$TMP/out.md" && { echo "FAIL: legacy Testing should not appear in hub mode"; exit 1; } || true
pass "hub-mode assembly emits header pair + DAG + Cross-Repo Deps + Acceptance Tests"
EOF
chmod +x tests/test_consult_design_doc_assemble_hub.sh
```

- [ ] **Step 5: Run hub assemble test, verify it fails** — current `cw_consult_design_doc_assemble` ignores the 6th arg.

- [ ] **Step 6: Modify `cw_consult_design_doc_assemble`** in `lib/consult.sh`

Replace the function body. Key changes:
- Accept optional 6th arg `<targets-path>` (the `_consult/` art-dir, not the file itself).
- When non-empty AND `$targets_dir/targets.txt` is non-empty: prepend header pair after H1, append three new sections at the end (`Acceptance Tests`, `Execution DAG`, `Cross-Repo Dependencies`), use `acceptance-tests.md` instead of `testing.md` for the tests block.

```bash
cw_consult_design_doc_assemble() {
  local section_dir="$1" out="$2" title="$3"
  local topic_text="${4:-}" synthesis_path="${5:-}" targets_dir="${6:-}"
  [[ -d "$section_dir" ]] || { echo "cw_consult_design_doc_assemble: missing $section_dir" >&2; return 1; }
  [[ -n "$title" ]] || { echo "cw_consult_design_doc_assemble: empty title" >&2; return 2; }

  if [[ -n "$topic_text" ]]; then
    title=$(printf '%s' "$topic_text" | tr -s ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))} 1')
  fi

  local goal="(see Architecture section)" arch_line="(see Architecture section)" tech_block=""
  if [[ -n "$synthesis_path" && -f "$synthesis_path" ]]; then
    local syn_goal
    syn_goal=$(awk '
      /^## Agreed findings/ {flag=1; next}
      flag && /^## / {exit}
      flag && NF>0 {sub(/^[[:space:]]*-[[:space:]]*/, ""); print; exit}
    ' "$synthesis_path")
    if [[ -z "$syn_goal" ]]; then
      syn_goal=$(awk '
        /^## Cross-verified/ {flag=1; next}
        flag && /^## / {exit}
        flag && NF>0 {sub(/^[[:space:]]*-[[:space:]]*/, ""); print; exit}
      ' "$synthesis_path")
    fi
    [[ -n "$syn_goal" ]] && goal="${syn_goal:0:200}"
  fi
  if [[ -f "$section_dir/architecture.md" ]]; then
    [[ "$goal" == "(see Architecture section)" ]] && goal=$(head -n1 "$section_dir/architecture.md")
    arch_line=$(awk '
      NR<3 {next}
      /^## / {exit}
      NF==0 {exit}
      {print}
    ' "$section_dir/architecture.md" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')
    [[ -n "$arch_line" ]] || arch_line="(see Architecture section)"
    tech_block=$(awk '/^## Tech Stack$/{flag=1; next} /^## /{flag=0} flag' "$section_dir/architecture.md")
  fi

  # Hub-mode header pair (when targets.txt exists).
  local header_pair=""
  local hub_mode=0
  if [[ -n "$targets_dir" && -s "$targets_dir/targets.txt" ]]; then
    hub_mode=1
    header_pair=$(cw_consult_targets_to_header_pair "$targets_dir")
  fi

  {
    printf '# %s Design\n\n' "$title"
    if (( hub_mode == 1 )); then
      printf '%s\n\n' "$header_pair"
    fi
    printf '**Goal:** %s\n\n' "$goal"
    printf '**Architecture:** %s\n\n' "$arch_line"
    printf '**Tech Stack:**\n'
    if [[ -n "$tech_block" ]]; then
      printf '%s\n' "$tech_block"
    else
      printf '%s\n' '- (see Components section)'
    fi
    printf '\n---\n\n'

    # Core 4 sections — same in both modes.
    local pair key heading
    for pair in 'architecture|Architecture' 'components|Components' 'data-flow|Data Flow' 'error-handling|Error Handling'; do
      key="${pair%%|*}"
      heading="${pair##*|}"
      printf '## %s\n\n' "$heading"
      if [[ -f "$section_dir/$key.md" ]]; then
        cat "$section_dir/$key.md"
        printf '\n'
      else
        printf '_(skipped)_\n\n'
      fi
    done

    # Tests section: hub-mode uses acceptance-tests.md heading, single-repo uses testing.md.
    if (( hub_mode == 1 )); then
      printf '## Acceptance Tests\n\n'
      if [[ -f "$section_dir/acceptance-tests.md" ]]; then
        cat "$section_dir/acceptance-tests.md"; printf '\n'
      else
        printf '_(skipped)_\n\n'
      fi
      printf '## Execution DAG\n\n'
      if [[ -f "$section_dir/dag.md" ]]; then
        cat "$section_dir/dag.md"; printf '\n'
      else
        printf '_(skipped)_\n\n'
      fi
      printf '## Cross-Repo Dependencies\n\n'
      if [[ -f "$section_dir/xrepo-deps.md" ]]; then
        cat "$section_dir/xrepo-deps.md"; printf '\n'
      else
        printf '_(skipped)_\n\n'
      fi
    else
      printf '## Testing\n\n'
      if [[ -f "$section_dir/testing.md" ]]; then
        cat "$section_dir/testing.md"; printf '\n'
      else
        printf '_(skipped)_\n\n'
      fi
    fi
  } > "$out"
}
```

- [ ] **Step 7: Run both assemble tests**

```bash
bash tests/test_consult_design_doc_assemble_single_unchanged.sh
bash tests/test_consult_design_doc_assemble_hub.sh
bash tests/run.sh
```

Expected: both pass; full suite green.

- [ ] **Step 8: Commit**

```bash
git add lib/consult.sh tests/fixtures/v0.10-single-repo-design.md \
        tests/test_consult_design_doc_assemble_hub.sh \
        tests/test_consult_design_doc_assemble_single_unchanged.sh
git commit -m "feat(consult): cw_consult_design_doc_assemble hub-mode

Optional 6th arg targets-dir gates hub-mode output:
- prepends Target Hub(s)+Sub-Project(s) header pair
- emits Acceptance Tests/Execution DAG/Cross-Repo Dependencies sections
- single-repo path byte-equal to v0.10 baseline (regression test)"
```

---

## Task 9: bin/consult-init.sh wiring

**Files:**
- Modify: `bin/consult-init.sh`
- Test: `tests/test_consult_init_persists_hub_mode.sh`

- [ ] **Step 1: Read current `bin/consult-init.sh` to understand layout**

```bash
cat bin/consult-init.sh
```

- [ ] **Step 2: Write the test**

```bash
cat > tests/test_consult_init_persists_hub_mode.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/state.sh
source ../lib/consult.sh

PLUGIN_ROOT=$(cd .. && pwd)
TMP_HOME=$(mktemp -d -t cw-init-hub.XXXXXX)
trap 'rm -rf "$TMP_HOME"' EXIT
export CLONE_WARS_HOME="$TMP_HOME"

# Super-hub fixture
SUPER=$(mktemp -d -t cw-init-super.XXXXXX); trap 'rm -rf "$SUPER" "$TMP_HOME"' EXIT
git init -q "$SUPER"
mkdir -p "$SUPER/hub_x/leaf1" "$SUPER/hub_x/leaf2"
git init -q "$SUPER/hub_x"
git init -q "$SUPER/hub_x/leaf1"
git init -q "$SUPER/hub_x/leaf2"

(
  cd "$SUPER" && \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  topic=$("$PLUGIN_ROOT/bin/consult-init.sh" "test super-hub topic") && \
  echo "$topic"
) > "$TMP_HOME/topic.out"
TOPIC=$(cat "$TMP_HOME/topic.out")
HASH=$( ( cd "$SUPER" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
          source "$PLUGIN_ROOT/lib/state.sh" && cw_repo_hash ) )
ART="$TMP_HOME/state/$HASH/$TOPIC/_consult"
[[ -f "$ART/hub-mode.txt" ]] || { echo "FAIL: hub-mode.txt missing"; exit 1; }
mode=$(tr -d '[:space:]' < "$ART/hub-mode.txt")
[[ "$mode" == "super-hub" ]] || { echo "FAIL: expected super-hub, got '$mode'"; exit 1; }
pass "super-hub fixture → hub-mode.txt = super-hub"

# Single-repo fixture
SINGLE=$(mktemp -d -t cw-init-single.XXXXXX)
git init -q "$SINGLE"
TMP_HOME2=$(mktemp -d -t cw-init-home2.XXXXXX)
export CLONE_WARS_HOME="$TMP_HOME2"
(
  cd "$SINGLE" && \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  "$PLUGIN_ROOT/bin/consult-init.sh" "single-repo topic"
) > "$TMP_HOME2/topic.out"
TOPIC2=$(cat "$TMP_HOME2/topic.out")
HASH2=$( ( cd "$SINGLE" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
           source "$PLUGIN_ROOT/lib/state.sh" && cw_repo_hash ) )
ART2="$TMP_HOME2/state/$HASH2/$TOPIC2/_consult"
mode2=$(tr -d '[:space:]' < "$ART2/hub-mode.txt")
[[ "$mode2" == "single-repo" ]] || { echo "FAIL: expected single-repo, got '$mode2'"; exit 1; }
pass "single-repo fixture → hub-mode.txt = single-repo"

rm -rf "$SINGLE" "$TMP_HOME2"
EOF
chmod +x tests/test_consult_init_persists_hub_mode.sh
```

- [ ] **Step 3: Run test, verify failure** — `consult-init.sh` doesn't write `hub-mode.txt`.

- [ ] **Step 4: Modify `bin/consult-init.sh`**

After the section that creates `_consult/` (find the line that does `mkdir -p "$ART_DIR"`), add:

```bash
# Hub-mode classification (v0.11). Persist before any further work so
# downstream sub-scripts can branch on it.
HUB_OUT=$(cw_consult_detect_hub "$(pwd)") && HUB_RC=0 || HUB_RC=$?
if (( HUB_RC == 0 )); then
  HUB_MODE=$(grep '^MODE=' <<< "$HUB_OUT" | head -1 | cut -d= -f2)
else
  HUB_MODE="single-repo"
fi
cw_consult_hub_mode_persist "$ART_DIR" "$HUB_MODE" \
  || log_warn "hub-mode persist failed for $ART_DIR"
```

Make sure `lib/consult.sh` is sourced (it likely already is — verify by reading the file's `source` block at top).

- [ ] **Step 5: Run test + full suite**

```bash
bash tests/test_consult_init_persists_hub_mode.sh
bash tests/run.sh
```

- [ ] **Step 6: Commit**

```bash
git add bin/consult-init.sh tests/test_consult_init_persists_hub_mode.sh
git commit -m "feat(consult): bin/consult-init.sh persists hub-mode.txt at init

Calls cw_consult_detect_hub on conductor cwd; writes
single-repo|hub-subrepo|super-hub to _consult/hub-mode.txt before
returning the topic slug. Downstream directives branch on this file."
```

---

## Task 10: bin/consult-design-doc.sh wiring (validators + targets-dir threading)

**Files:**
- Modify: `bin/consult-design-doc.sh`

The directive (commands/consult.md Step 8.5) will be modified in Task 11 to author the three new section files (`dag.md`, `xrepo-deps.md`, `acceptance-tests.md`). For this task we only need the bin script to:
1. Pass `_consult/` (containing `targets.txt`) as the 6th arg to `cw_consult_design_doc_assemble`.
2. Run the three new validators when `_consult/targets.txt` is non-empty.
3. Re-emit validator stderr verbatim so the directive can grep + re-enter the offending section walk.

- [ ] **Step 1: Read current `bin/consult-design-doc.sh`**

```bash
cat bin/consult-design-doc.sh
```

- [ ] **Step 2: Modify the assemble + self-review block**

Locate the `cw_consult_design_doc_assemble` call. Replace with:

```bash
TARGETS_DIR=""
if [[ -s "$ART_DIR/targets.txt" ]]; then
  TARGETS_DIR="$ART_DIR"
fi

cw_consult_design_doc_assemble \
  "$DD_DIR" "$OUT_PATH" "$TITLE" \
  "$TOPIC_TEXT" "$ART_DIR/synthesis.md" \
  "$TARGETS_DIR" \
  || { log_error "assemble failed"; exit 1; }

# Hub-mode validators — run only when targets.txt is non-empty.
if [[ -n "$TARGETS_DIR" ]]; then
  for v in dag:cw_consult_dag_validate \
           xrepo-deps:cw_consult_xrepo_deps_validate \
           acceptance-tests:cw_consult_acceptance_tests_validate; do
    section="${v%%:*}"
    fn="${v##*:}"
    if [[ -s "$DD_DIR/$section.md" ]]; then
      "$fn" "$ART_DIR" < "$DD_DIR/$section.md" \
        || { log_error "validator $fn rejected $section.md (see stderr above)"; exit 1; }
    else
      log_error "hub-mode requires $DD_DIR/$section.md (missing or empty)"
      exit 1
    fi
  done
fi
```

- [ ] **Step 3: Run full suite**

```bash
bash tests/run.sh
```

The change is invisible to single-repo callers (no `targets.txt` → no validator block runs).

- [ ] **Step 4: Commit**

```bash
git add bin/consult-design-doc.sh
git commit -m "feat(consult): design-doc bin runs validators + threads targets-dir

When _consult/targets.txt is non-empty: pass _consult/ as 6th arg to
assemble (triggers hub-mode output) and run dag/xrepo-deps/
acceptance-tests validators sequentially before commit. Missing
section files in hub mode are a hard error."
```

---

## Task 11: commands/consult.md directive — Step 0 + Step 2 prelude + Step 8.5

**Files:**
- Modify: `commands/consult.md`
- Test: `tests/test_consult_directive_hub_mode.sh`

Three insertion points in the directive. Static-wiring test grep-asserts each.

- [ ] **Step 1: Write the static-wiring test**

```bash
cat > tests/test_consult_directive_hub_mode.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

DIRECTIVE="$(cd .. && pwd)/commands/consult.md"

# Step 0 wiring: detect_hub call + hub-mode.txt mention
grep -q 'cw_consult_detect_hub' "$DIRECTIVE" \
  || { echo "FAIL: directive must call cw_consult_detect_hub"; exit 1; }
grep -q 'hub-mode.txt' "$DIRECTIVE" \
  || { echo "FAIL: directive must reference hub-mode.txt"; exit 1; }
pass "Step 0: detect_hub + hub-mode.txt referenced"

# Step 2 prelude: target selection + TARGETS threading
grep -q 'cw_consult_targets_persist\|targets.txt' "$DIRECTIVE" \
  || { echo "FAIL: Step 2 must persist targets.txt"; exit 1; }
grep -q 'TARGETS=' "$DIRECTIVE" \
  || { echo "FAIL: Step 2 must thread TARGETS= into research-send"; exit 1; }
pass "Step 2: target-selection AskUserQuestion + TARGETS threading"

# Step 8.5: per-sub-project drill axis + 3 new sections + hub-mode validators
grep -q 'Execution DAG' "$DIRECTIVE" \
  || { echo "FAIL: Step 8.5 must reference Execution DAG section"; exit 1; }
grep -q 'Cross-Repo Dependencies' "$DIRECTIVE" \
  || { echo "FAIL: Step 8.5 must reference Cross-Repo Dependencies"; exit 1; }
grep -q 'Acceptance Tests' "$DIRECTIVE" \
  || { echo "FAIL: Step 8.5 must reference Acceptance Tests heading"; exit 1; }
grep -q 'per-sub-project' "$DIRECTIVE" \
  || { echo "FAIL: Step 8.5 must add per-sub-project drill axis"; exit 1; }
pass "Step 8.5: 3 new sections + per-sub-project drill axis wired"
EOF
chmod +x tests/test_consult_directive_hub_mode.sh
```

- [ ] **Step 2: Run test, verify failure**

Expected: 4 PASS lines or first failure on `cw_consult_detect_hub` not being in the directive.

- [ ] **Step 3: Edit `commands/consult.md` Step 0**

Find the existing Step 0 closing block. After the `consult-init.sh` invocation that returns the topic, add:

```markdown
### Step 0.5 — Hub-mode classification

After `consult-init.sh` returns `$CONSULT_TOPIC`, the init script has already
persisted `_consult/hub-mode.txt`. Read it back and surface to the rest of
the directive:

```
HUB_MODE=$(cw_consult_hub_mode_load "$TOPIC_DIR/_consult")
log_info "hub mode: $HUB_MODE"
```

When `HUB_MODE != single-repo`, Step 2 prelude runs target selection
(below). When `HUB_MODE == single-repo`, the directive proceeds to Step 1
unchanged from v0.10.
```

- [ ] **Step 4: Insert Step 1.5 — Target selection (pre-research)**

After Step 0.5, before Step 1 (parallel spawn):

```markdown
### Step 1.5 — Target selection (hub mode only)

Skip this step when `HUB_MODE == single-repo`. Otherwise the conductor
must let the user pick which leaf sub-projects this consultation should
cover, BEFORE research dispatch (the research prompt needs the list).

1. Re-run the detector to grab `LEAVES=` (and `HUBS=` for super-hub):
   ```
   HUB_OUT=$(cw_consult_detect_hub "$(pwd)")
   LEAVES=$(grep '^LEAVES=' <<< "$HUB_OUT" | cut -d= -f2 | tr ',' '\n')
   HUBS=$(grep '^HUBS=' <<< "$HUB_OUT" | cut -d= -f2 | tr ',' '\n' || true)
   ```

2. **hub-subrepo mode:** single AskUserQuestion (multi-select), options =
   `LEAVES` (one option per `<self>/<leaf>`).

3. **super-hub mode:** two-step.
   - AskUserQuestion #1 (multi-select) over `HUBS`.
   - For each chosen hub, filter `LEAVES` to entries starting `<hub>/`.
   - AskUserQuestion #2 (multi-select) over the filtered leaf list.

4. **Empty-selection re-prompt:** if user selects nothing, re-prompt once.
   Second empty selection → AskUserQuestion `"No targets chosen. Continue
   as single-repo / Abort?"`. On Continue, overwrite
   `_consult/hub-mode.txt` with `single-repo` and skip persisting
   `targets.txt`. On Abort, teardown + archive + exit.

5. Persist:
   ```
   printf '%s\n' "${CHOSEN_LEAVES[@]}" \
     | cw_consult_targets_persist "$TOPIC_DIR/_consult"
   ```
```

- [ ] **Step 5: Modify Step 2 (research dispatch) to thread `TARGETS=`**

In the existing Step 2 block, change the parallel sends from:

```
"$CLAUDE_PLUGIN_ROOT/bin/consult-research-send.sh" "$CONSULT_TOPIC" rex  codex
"$CLAUDE_PLUGIN_ROOT/bin/consult-research-send.sh" "$CONSULT_TOPIC" cody claude
```

to:

```
TARGETS=""
if [[ -s "$TOPIC_DIR/_consult/targets.txt" ]]; then
  TARGETS=$(cw_consult_targets_load "$TOPIC_DIR/_consult" | paste -sd, -)
fi
CW_CONSULT_TARGETS="$TARGETS" \
  "$CLAUDE_PLUGIN_ROOT/bin/consult-research-send.sh" "$CONSULT_TOPIC" rex  codex
CW_CONSULT_TARGETS="$TARGETS" \
  "$CLAUDE_PLUGIN_ROOT/bin/consult-research-send.sh" "$CONSULT_TOPIC" cody claude
```

And modify `bin/consult-research-send.sh` to pass `$CW_CONSULT_TARGETS` to `cw_consult_build_research_prompt` as the new 3rd arg. (Trivial 1-line change in that script — locate the `cw_consult_build_research_prompt` call, add `"${CW_CONSULT_TARGETS:-}"`.)

Mirror for Step 5 (verify dispatch) → `bin/consult-verify-send.sh` (3rd arg to `cw_consult_build_verify_prompt`).

- [ ] **Step 6: Modify Step 8.5 — add 3 new sections + per-sub-project drill axis**

In the existing Step 8.5 section list:

```
SECTIONS=(architecture components data-flow error-handling testing)
SECTION_TITLES=(Architecture Components "Data Flow" "Error Handling" Testing)
```

Branch on `HUB_MODE`:

```
if [[ "$HUB_MODE" == "single-repo" ]]; then
  SECTIONS=(architecture components data-flow error-handling testing)
  SECTION_TITLES=(Architecture Components "Data Flow" "Error Handling" Testing)
else
  SECTIONS=(architecture components data-flow error-handling acceptance-tests dag xrepo-deps)
  SECTION_TITLES=(Architecture Components "Data Flow" "Error Handling" "Acceptance Tests" "Execution DAG" "Cross-Repo Dependencies")
fi
```

In the **Drill-down sub-loop**, when `HUB_MODE != single-repo`, expand the
trooper-choice AskUserQuestion options to include per-sub-project axis:

```
TROOPER_OPTIONS=("rex (codex)" "cody (claude)" "both (parallel)")
if [[ "$HUB_MODE" != "single-repo" ]]; then
  while IFS= read -r leaf; do
    SP="${leaf#*/}"
    TROOPER_OPTIONS+=("rex on $SP" "cody on $SP" "both on $SP")
  done < "$TOPIC_DIR/_consult/targets.txt"
fi
```

When user picks a per-sub-project option, parse `SP` and call
`bin/consult-drilldown.sh` with the new sub-project arg (drilldown bin
script needs a 6th positional arg `<subproject>` — pass through to
`cw_consult_design_doc_drilldown_prompt`).

Modify `bin/consult-drilldown.sh` to accept and forward the optional
6th arg (likely a small change — locate the helper call, append `"${6:-}"`).

- [ ] **Step 7: Run static-wiring test + full suite**

```bash
bash tests/test_consult_directive_hub_mode.sh
bash tests/run.sh
```

If the static-wiring test fails, adjust the directive text until all 4 PASS lines appear.

- [ ] **Step 8: Commit**

```bash
git add commands/consult.md bin/consult-research-send.sh \
        bin/consult-verify-send.sh bin/consult-drilldown.sh \
        tests/test_consult_directive_hub_mode.sh
git commit -m "feat(consult): directive Step 0.5 / 1.5 / 8.5 hub-mode wiring

Step 0.5: load hub-mode from _consult/hub-mode.txt.
Step 1.5: target-selection AskUserQuestion (single-step for hub-subrepo,
two-step for super-hub) + persist targets.txt. Empty-selection re-prompt
fallback to single-repo.
Step 2/5: thread CW_CONSULT_TARGETS into research-send + verify-send so
prompts include the per-sub-project structure block.
Step 8.5: hub-mode section list extended (acceptance-tests + dag +
xrepo-deps); per-sub-project drill axis added to trooper-choice prompt.
Bin scripts research-send/verify-send/drilldown grow optional last
positional arg for targets/subproject."
```

---

## Task 12: Polish + version bump + dogfood gate placeholder

**Files:**
- Modify: `CLAUDE.md` (status line for v0.11.0)
- Modify: `.claude-plugin/plugin.json` (version bump)
- Create: `tests/test_consult_v011_dogfood.sh` (skipped manual gate stub)

- [ ] **Step 1: Update `CLAUDE.md` status section**

Find the status checklist near the bottom (the `## Status` block, last few entries currently around v0.10.0). Insert:

```markdown
- [x] v0.11.0: consult hub-mode — Target Hub(s) + Target Sub-Project(s) headers, Execution DAG, Cross-Repo Dependencies table, Step-tagged Acceptance Tests; cw_consult_detect_hub returns MODE/HUBS/LEAVES; 3 new validators (dag/xrepo-deps/acceptance-tests); single-repo behavior byte-identical to v0.10
- [ ] v0.11.0 strict-dogfood pass on a real machine (release gate — see tests/test_consult_v011_dogfood.sh scenarios CW-DF-CONS-1..4)
```

- [ ] **Step 2: Bump `.claude-plugin/plugin.json` version**

```bash
sed -i 's/"version": "0.10.[0-9]*"/"version": "0.11.0"/' .claude-plugin/plugin.json
grep version .claude-plugin/plugin.json
```

- [ ] **Step 3: Create dogfood gate stub**

```bash
cat > tests/test_consult_v011_dogfood.sh <<'EOF'
#!/usr/bin/env bash
# tests/test_consult_v011_dogfood.sh — manual release gate, NOT run by tests/run.sh
#
# Scenarios:
#   CW-DF-CONS-1: from /home/liupan/ARS/, super-hub detection + two-step
#                 AskUserQuestion + hub-mode design doc with header pair +
#                 DAG + Cross-Repo Deps + tagged tests.
#   CW-DF-CONS-2: from /home/liupan/ARS/ars_fleet/, hub-subrepo +
#                 single-step multi-select + hub-mode shape.
#   CW-DF-CONS-3: from /home/liupan/CC/clone-wars/, single-repo unchanged
#                 (no DAG / Cross-Repo / tagged-tests blocks).
#   CW-DF-CONS-4: hub-mode validator failure path — author cyclic DAG,
#                 verify validator catches + re-enters walk + accepts fix.
#
# Each scenario runs /clone-wars:consult interactively. Mark PASS/FAIL by
# inspecting the committed design doc against the success criteria in
# docs/superpowers/specs/2026-05-04-consult-hub-mode-design.md §"Release
# gate".
set -euo pipefail
echo "This test is interactive. Run /clone-wars:consult manually per the"
echo "scenarios above and confirm the success criteria in the spec."
exit 0
EOF
chmod +x tests/test_consult_v011_dogfood.sh
```

Add the SKIP entry to `tests/run.sh`:

```bash
# Find the existing SKIP case block in tests/run.sh and add:
    test_consult_v011_dogfood.sh)
      echo "=== $t === (SKIP — manual v0.11 release gate, run explicitly)"
      continue ;;
```

- [ ] **Step 4: Final full suite + commit**

```bash
bash tests/run.sh
git add CLAUDE.md .claude-plugin/plugin.json \
        tests/test_consult_v011_dogfood.sh tests/run.sh
git commit -m "chore(release): bump plugin to v0.11.0 + dogfood gate stub

CLAUDE.md status updated; plugin.json bumped; dogfood gate placeholder
added (manual scenarios CW-DF-CONS-1..4 documented inline)."
```

---

## Self-review

- **Spec coverage**: every Components-section helper from the spec has a Task above (detector, persistence, three validators, prompt templates, drilldown helper, assemble, init bin, design-doc bin, directive). The two state files (`hub-mode.txt`, `targets.txt`) are written by Tasks 9 and 11 respectively. The Error Handling table maps to `cw_consult_targets_persist` (slug rejection, Task 2), DAG/xrepo/tests validators (Tasks 3-5), Step 1.5 empty-selection re-prompt (Task 11), and the existing question protocol (unchanged).
- **Placeholder scan**: no `TBD`/`TODO`/`fill in later`/"similar to Task N" found.
- **Type consistency**: `cw_consult_detect_hub` always emits `MODE=`/`HUBS=`/`LEAVES=` lines (Task 1); all consumers (Tasks 9, 11) parse via `grep '^MODE='`/`'^HUBS='`/`'^LEAVES='`. `targets.txt` shape `<hub>/<leaf>` is consistent across Task 2 (persist), Task 3 (DAG validator reads `${line#*/}`), Task 4 (xrepo validator same), Task 5 (acceptance-tests validator same), Task 8 (assemble passes art-dir), Task 11 (directive). `cw_consult_design_doc_assemble` 6th arg is the `_consult/` art-dir (containing `targets.txt`), not the targets file path itself — consistent across Tasks 8, 10.

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-04-consult-hub-mode-plan.md`. The user already requested **Subagent-Driven** execution — I'll dispatch one implementer subagent per task with two-stage review (spec compliance, then code quality) per the `superpowers:subagent-driven-development` skill.
