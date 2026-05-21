# Parallel Test Runner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace serial `tests/run.sh` with an `xargs -P` parallel scheduler that runs the 259-test suite in ~2 minutes instead of ~6m42s, while preserving exact result/exit-code parity with the serial baseline.

**Architecture:** Two new files (`tests/run-one.sh` for per-test atomic-output wrapping via `flock 1`, `tests/audit-parallel-safety.sh` for an isolation-contract lint). `tests/run.sh` rewritten as a thin scheduler that runs the audit as precondition, then pipes test filenames through `xargs -P $(nproc) -I{} bash run-one.sh {}`.

**Tech Stack:** Pure bash 4.2+, `xargs` (coreutils), `flock` (util-linux), `mktemp`. No new runtime dependencies.

**Baseline checkpoint:** branch `feat/parallel-test-runner` at 98efc23 (spec only). Suite green at 259 ok / 0 fail / ~6m42s wall (v0.51.0 + Tier-2 sweep at ce7a17f).

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `tests/audit-parallel-safety.sh` | NEW | Lint script — 4 mechanical checks (fixed `/tmp/<name>` writes, fixed `CLONE_WARS_HOME`, tmux name uniqueness, unsandboxed `cd`) + 1 informational warning (`pgrep -f` patterns). Exit 0 on pass, 1 on fail. |
| `tests/run-one.sh` | NEW | Per-test wrapper. Runs one `test_*.sh`, captures stdout/stderr to a tempfile, prints `=== test_X ===` header + log + footer atomically via `flock 1`. Exits with test's rc. |
| `tests/test_run_one_atomicity.sh` | NEW | Self-test — spawn two `run-one.sh` instances concurrently with overlapping output; assert no block interleaving. |
| `tests/test_audit_parallel_safety_self.sh` | NEW | Self-test — write a fixture test with `/tmp/items.txt` violation, assert audit catches it. |
| `tests/run.sh` | REWRITE | Scheduler. Flag parsing (`--jobs N`, `--serial`, `--filter PAT`). Audit precondition. xargs dispatch. Summary line. |
| `tests/test_consult_load_prompt_migration.sh` | FIX | Replace `/tmp/items.txt` + `/tmp/verify.md` with `$(mktemp -d)`. Any other files the audit surfaces get fixed in the same commit. |
| `CLAUDE.md` | EDIT | Add the 5-rule parallel-safety contract under "Execution discipline in this repo". |

---

## Task 0: Baseline confirmation (no commit)

**Files:** none (read-only checks)

- [ ] **Step 0.1: Confirm on the right branch + clean working tree.**

```bash
git status -s | awk '$1!="??"' | wc -l   # → 0 (no tracked modifications)
git rev-parse --abbrev-ref HEAD          # → feat/parallel-test-runner
git log -1 --oneline                     # → 98efc23 docs(testing): spec — parallel test runner (Lane C)
```

- [ ] **Step 0.2: Confirm suite green at 259/0fail.**

```bash
bash tests/run.sh > /tmp/parallel-baseline.log 2>&1; echo "rc=$?"
grep -cE "^  test_.*: ok$" /tmp/parallel-baseline.log
grep -cE "^  test_.*: FAIL$" /tmp/parallel-baseline.log
```

Expected:
- `rc=0`
- `ok` count: 253 (259 total minus 6 outer skips)
- `FAIL` count: 0

If `FAIL > 0` or rc != 0, STOP and surface — do not start the work.

---

## Task 1: Audit script (RED)

**Files:**
- Create: `tests/audit-parallel-safety.sh`
- Create: `tests/test_audit_parallel_safety_self.sh`

This task lands the audit script + its self-test. The audit will report the known `/tmp/items.txt` violator in `test_consult_load_prompt_migration.sh` (intentionally RED until T2). The self-test stages a synthetic fixture and asserts the audit catches it.

- [ ] **Step 1.1: Write `tests/audit-parallel-safety.sh`.**

```bash
cat > tests/audit-parallel-safety.sh <<'AUDIT_EOF'
#!/usr/bin/env bash
# tests/audit-parallel-safety.sh
#
# Lint: confirm every tests/test_*.sh satisfies the parallel-safety
# isolation contract documented in CLAUDE.md and the parallel-runner
# spec (docs/superpowers/specs/2026-05-21-parallel-test-runner-design.md).
#
# Checks (fail loudly):
#   1. No write to a fixed /tmp/<word> path (use mktemp).
#   2. CLONE_WARS_HOME assigned to a sandboxed path (under $TMP / $SANDBOX
#      / $(mktemp ...)). Bare /tmp/... or $HOME/... is a fail.
#   3. tmux session/window names contain $$ or $RANDOM (no shared fixture).
#   4. No `cd` to an absolute path outside the test's sandbox.
#
# Warnings (do not fail):
#   W1. `pgrep -f <pattern>` — print for human review (pattern may match
#       sibling tests under parallelism).
#
# Exit 0 on clean audit, 1 on any check failure. Warnings never fail.

set -euo pipefail
cd "$(dirname "$0")"

if [[ -n "${AUDIT_TARGET_DIR:-}" ]]; then
  TARGET_DIR="$AUDIT_TARGET_DIR"
else
  TARGET_DIR="."
fi

fail=0
fail_lines=()
warn_lines=()

for t in "$TARGET_DIR"/test_*.sh; do
  [[ -f "$t" ]] || continue
  base=$(basename "$t")

  # Skip the audit and runner files themselves and self-tests
  case "$base" in
    audit-parallel-safety.sh|run-one.sh|run.sh) continue ;;
    test_audit_parallel_safety_self.sh|test_run_one_atomicity.sh|test_run_serial_parity.sh) continue ;;
  esac

  # --- Check 1: fixed /tmp/<word> writes (not mktemp-derived) ---
  # Match: writes (`>`, `>>`, `cat > /tmp/...`, `echo ... > /tmp/...`)
  # to a literal /tmp/<name> path. mktemp -d puts paths in /tmp/tmp.XXX
  # but those are assigned to variables, not literal in the test file.
  while IFS= read -r line; do
    # Strip comments
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    fail=1
    fail_lines+=("$base: fixed /tmp path write: ${line#*:}")
  done < <(grep -nE '(>[[:space:]]*/tmp/[a-zA-Z0-9_.-]+|cat[[:space:]]+>[[:space:]]*/tmp/)' "$t" | grep -vE '/tmp/tmp\.|^[[:space:]]*#')

  # --- Check 2: CLONE_WARS_HOME assigned outside a sandbox ---
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    # Strip the leading "N:" line-number prefix
    val="${line#*CLONE_WARS_HOME=}"
    # Acceptable: starts with $TMP, $SANDBOX, $(mktemp, "$(mktemp, or is "" (unset)
    if [[ "$val" =~ ^[\"\']?(\$TMP|\$SANDBOX|\$\(mktemp|\"\$\(mktemp|\$\{TMP|\$\{SANDBOX) ]]; then
      continue
    fi
    # Acceptable: `unset CLONE_WARS_HOME` or `CLONE_WARS_HOME="" cmd...` test cases
    if [[ "$line" =~ unset[[:space:]]+CLONE_WARS_HOME ]]; then
      continue
    fi
    if [[ "$val" =~ ^[\"\']\"?\"?[[:space:]]*$ ]]; then
      continue
    fi
    # Otherwise, fail.
    fail=1
    fail_lines+=("$base: CLONE_WARS_HOME not sandboxed: ${line#*:}")
  done < <(grep -nE 'CLONE_WARS_HOME=' "$t" | grep -v 'export CLONE_WARS_HOME$' | grep -vE '^[[:space:]]*#')

  # --- Check 3: tmux session/window names must include $$ or RANDOM ---
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    # Pattern: TEST_SESSION="..." or TEST_WIN="..." or tmux ... -t <name>
    # where <name> doesn't contain $$ or $RANDOM
    if [[ "$line" =~ (TEST_SESSION|TEST_WIN)=[\"\']?([a-zA-Z0-9_-]+) ]]; then
      val="${BASH_REMATCH[2]}"
      # If the full RHS lacks $$ AND $RANDOM, it's a fixed name → fail
      rhs="${line#*=}"
      if [[ ! "$rhs" =~ \$\$ ]] && [[ ! "$rhs" =~ \$\{?RANDOM ]]; then
        fail=1
        fail_lines+=("$base: fixed tmux name (needs \$\$ or \$RANDOM): ${line#*:}")
      fi
    fi
  done < <(grep -nE 'TEST_SESSION=|TEST_WIN=' "$t")

  # --- Check 4: cd to absolute path outside sandbox ---
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    # Match `cd /<abs>` where the path isn't $TMP/$SANDBOX/$(mktemp/$ART/$TD
    # and isn't `cd "$(dirname "$0")"` (the only allowed pattern).
    if [[ "$line" =~ cd[[:space:]]+/[a-zA-Z] ]]; then
      fail=1
      fail_lines+=("$base: cd to absolute path: ${line#*:}")
    fi
  done < <(grep -nE 'cd[[:space:]]+/' "$t" | grep -vE 'dirname[[:space:]]+\"?\$0|\$TMP|\$SANDBOX|\$ART|\$TD|\$BRANCH|\$HUB|\$REPO|\$PLUGIN_ROOT')

  # --- Warning W1: pgrep -f patterns (informational) ---
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    warn_lines+=("$base: pgrep -f pattern (review for sibling collision): ${line#*:}")
  done < <(grep -nE 'pgrep[[:space:]]+-f' "$t")
done

# Output
if [[ "$fail" -eq 0 ]]; then
  count=$(find "$TARGET_DIR" -maxdepth 1 -name 'test_*.sh' | wc -l)
  echo "PASS  $count tests parallel-safe"
  if [[ ${#warn_lines[@]} -gt 0 ]]; then
    echo
    echo "WARN  ${#warn_lines[@]} pgrep -f patterns flagged for review (informational):"
    for w in "${warn_lines[@]}"; do
      echo "  $w"
    done
  fi
  exit 0
else
  echo "FAIL  ${#fail_lines[@]} parallel-safety violations:"
  for l in "${fail_lines[@]}"; do
    echo "  $l"
  done
  if [[ ${#warn_lines[@]} -gt 0 ]]; then
    echo
    echo "WARN  ${#warn_lines[@]} pgrep -f patterns flagged for review (informational):"
    for w in "${warn_lines[@]}"; do
      echo "  $w"
    done
  fi
  exit 1
fi
AUDIT_EOF
chmod +x tests/audit-parallel-safety.sh
```

- [ ] **Step 1.2: Run the audit against the live test suite — expect FAIL with the known violator.**

```bash
bash tests/audit-parallel-safety.sh; echo "rc=$?"
```

Expected:
- `rc=1`
- Output contains `test_consult_load_prompt_migration.sh: fixed /tmp path write`
- May also surface 1-3 additional violations (these will be fixed in T2 alongside the known one).

Capture the full violation list — T2 will fix each.

- [ ] **Step 1.3: Write the audit's self-test `tests/test_audit_parallel_safety_self.sh`.**

```bash
cat > tests/test_audit_parallel_safety_self.sh <<'SELF_EOF'
#!/usr/bin/env bash
# tests/test_audit_parallel_safety_self.sh
# Self-test for tests/audit-parallel-safety.sh: stage a synthetic test
# directory containing one of each violation type; assert the audit
# catches all of them.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
AUDIT="$PLUGIN_ROOT/tests/audit-parallel-safety.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# Stage fixture: 1 clean test + 4 violators
cat > "$SANDBOX/test_clean.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
TEST_WIN="cw-clean-$$-${RANDOM}"
EOF

cat > "$SANDBOX/test_v_tmp.sh" <<'EOF'
#!/usr/bin/env bash
cat > /tmp/items.txt <<EOI
hi
EOI
EOF

cat > "$SANDBOX/test_v_cw_home.sh" <<'EOF'
#!/usr/bin/env bash
CLONE_WARS_HOME=/tmp/cw-fixed bash cmd
EOF

cat > "$SANDBOX/test_v_tmux_fixed.sh" <<'EOF'
#!/usr/bin/env bash
TEST_WIN="cw-fixed-name"
EOF

cat > "$SANDBOX/test_v_cd_abs.sh" <<'EOF'
#!/usr/bin/env bash
cd /etc
EOF

chmod +x "$SANDBOX"/test_*.sh

# Run audit against the fixture dir; expect rc=1 + each violator named
out=$(AUDIT_TARGET_DIR="$SANDBOX" bash "$AUDIT" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "audit fails on fixture dir with violators"
assert_contains "$out" "test_v_tmp.sh: fixed /tmp path write"      "catches fixed /tmp write"
assert_contains "$out" "test_v_cw_home.sh: CLONE_WARS_HOME not sandboxed" "catches unsandboxed CLONE_WARS_HOME"
assert_contains "$out" "test_v_tmux_fixed.sh: fixed tmux name"     "catches fixed tmux name"
assert_contains "$out" "test_v_cd_abs.sh: cd to absolute path"     "catches unsandboxed cd"
# Clean test must NOT appear
if echo "$out" | grep -q "test_clean.sh:"; then
  echo "FAIL: clean test should not be flagged" >&2
  echo "$out" >&2
  exit 1
fi
pass "1. audit catches the 4 violation types and ignores clean tests"

# Sanity: empty dir → exit 0
EMPTY=$(mktemp -d)
trap 'rm -rf "$SANDBOX" "$EMPTY"' EXIT
out2=$(AUDIT_TARGET_DIR="$EMPTY" bash "$AUDIT" 2>&1) && rc2=0 || rc2=$?
assert_eq "$rc2" "0" "empty dir audit passes"
pass "2. audit handles empty dir without crashing"

echo "test_audit_parallel_safety_self: 2 cases passed"
SELF_EOF
chmod +x tests/test_audit_parallel_safety_self.sh
```

- [ ] **Step 1.4: Run the self-test.**

```bash
bash tests/test_audit_parallel_safety_self.sh
```

Expected: both cases pass; final line `test_audit_parallel_safety_self: 2 cases passed`.

- [ ] **Step 1.5: Commit T1.**

```bash
git add tests/audit-parallel-safety.sh tests/test_audit_parallel_safety_self.sh
git commit -m "$(cat <<'EOF'
test(parallel): add audit-parallel-safety.sh + self-test

Mechanical lint enforcing the parallel-safety isolation contract from
the spec: no fixed /tmp paths, sandboxed CLONE_WARS_HOME, unique tmux
session/window names ($$ or $RANDOM), no unsandboxed cd. pgrep -f
patterns surface as informational warnings (too many false positives
for an automated decision).

Self-test stages a fixture directory with one clean test + four
violators and asserts the audit catches each violation type.

Currently FAILs on the live tests/ directory due to known violations
in test_consult_load_prompt_migration.sh (/tmp/items.txt + /tmp/verify.md);
T2 fixes those.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Fix audit violations

**Files:**
- Modify: `tests/test_consult_load_prompt_migration.sh`
- Modify: any other tests surfaced by the T1 audit run

This task makes the audit green. The known violator is `test_consult_load_prompt_migration.sh`. Re-run the audit after each fix; if additional violators are surfaced, fix them in the same commit (the spec calls for "fix all of them inline" rather than maintaining a quarantine list).

- [ ] **Step 2.1: Read the current `test_consult_load_prompt_migration.sh`.**

```bash
cat tests/test_consult_load_prompt_migration.sh
```

The violation lives at lines 26-31: `cat > /tmp/items.txt` and `cw_consult_build_verify_prompt /tmp/items.txt /tmp/verify.md`.

- [ ] **Step 2.2: Apply the mktemp fix.** Replace those lines with sandbox-scoped paths. Edit `tests/test_consult_load_prompt_migration.sh`:

Replace the block from line 25 (`# Case 2:`) through line 37 (`pass ...`) with:

```bash
# Case 2: verify prompt regression.
SANDBOX=$(mktemp -d); trap 'rm -rf "$SANDBOX"' EXIT
ITEMS="$SANDBOX/items.txt"
VERIFY="$SANDBOX/verify.md"
cat > "$ITEMS" <<'EOF'
[src/auth/store.py:42] sessions are stored as plaintext
[https://example.com/rfc] RFC says X
EOF
expected="$(cat fixtures/v0.4.2-verify-prompt.txt)"
actual=$(cw_consult_build_verify_prompt "$ITEMS" "$VERIFY")
[[ "$actual" == "$expected" ]] || {
  diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | head -20
  echo "FAIL c2: verify prompt diverged from v0.4.2 baseline"
  exit 1
}
pass "verify prompt byte-equal to v0.4.2 baseline"
```

Note: the existing fixture (`fixtures/v0.4.2-verify-prompt.txt`) was captured against `/tmp/items.txt` / `/tmp/verify.md` as the literal arguments to `cw_consult_build_verify_prompt`. If the fixture embeds those literal paths, the byte-equality assertion will FAIL after the change. The fixture must be regenerated against the new sandbox paths — but the new paths contain a random suffix per run, which would defeat byte-equality.

The correct fix: **inspect the fixture** before editing the test. If the fixture references `/tmp/items.txt`, regenerate it using the same builder helper but with `$ITEMS` substituted. If the fixture doesn't reference the path (i.e. the path is consumed by the helper but doesn't appear in the rendered output), the fix above is sufficient.

- [ ] **Step 2.3: Inspect the fixture to determine the byte-impact.**

```bash
grep -nE '/tmp/items|/tmp/verify' tests/fixtures/v0.4.2-verify-prompt.txt
```

If grep returns nothing → the fixture is path-agnostic; Step 2.2's edit is complete.

If grep returns matches → the path appears in the rendered output. Add this to Step 2.2:

```bash
# After applying Step 2.2's edit, regenerate the fixture for the new path scheme.
# This works because the helper is deterministic: same inputs → same output bytes.
SANDBOX_REGEN=$(mktemp -d); trap 'rm -rf "$SANDBOX_REGEN"' EXIT
REGEN_ITEMS="$SANDBOX_REGEN/items.txt"
REGEN_VERIFY="$SANDBOX_REGEN/verify.md"
cat > "$REGEN_ITEMS" <<'EOF'
[src/auth/store.py:42] sessions are stored as plaintext
[https://example.com/rfc] RFC says X
EOF
source lib/log.sh; source ../lib/state.sh; source ../lib/consult.sh
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"
cw_consult_build_verify_prompt "$REGEN_ITEMS" "$REGEN_VERIFY" \
  > tests/fixtures/v0.4.2-verify-prompt.txt
```

This makes the fixture stable-suffix-free (no random sandbox paths) only if the helper doesn't embed its inputs. If the helper DOES embed paths, the fixture is no longer byte-stable under parallelism — the test needs a different assertion shape (substring rather than full byte-equality).

If the fixture-regen approach doesn't yield a stable fixture, fall back to:
- Replace `[[ "$actual" == "$expected" ]]` byte check with substring containment via `assert_contains`, scoped to the prose tokens that should be present regardless of path.

The fix shape depends on inspection. Document the final approach in the commit message.

- [ ] **Step 2.4: Run the migration test to confirm it still passes.**

```bash
bash tests/test_consult_load_prompt_migration.sh
```

Expected: prints `ALL PASS`; rc=0.

- [ ] **Step 2.5: Re-run the audit; expect PASS (or a smaller violation list).**

```bash
bash tests/audit-parallel-safety.sh; echo "rc=$?"
```

Expected: `rc=0` if the migration fix was the only violation. If additional violators surface (`rc=1` with new lines), fix each one inline using the same mktemp-sandbox pattern, then re-run until clean.

- [ ] **Step 2.6: Run full suite to confirm no regressions.**

```bash
bash tests/run.sh > /tmp/t2-suite.log 2>&1; echo "rc=$?"
grep -cE "^  test_.*: FAIL$" /tmp/t2-suite.log
```

Expected: `rc=0`, `FAIL` count `0`.

- [ ] **Step 2.7: Commit T2.**

```bash
git add tests/test_consult_load_prompt_migration.sh
# Add any other tests fixed inline:
# git add tests/test_<other-violator>.sh
# If a fixture was regenerated:
# git add tests/fixtures/v0.4.2-verify-prompt.txt
git commit -m "$(cat <<'EOF'
test(parallel): make consult prompt migration test sandbox-safe

Replace literal /tmp/items.txt + /tmp/verify.md with mktemp-derived
paths under a per-test sandbox. Required for the parallel test runner
contract — two concurrent instances of the test would race on the
same shared path under the old scheme.

audit-parallel-safety.sh now exits 0 against tests/.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: run-one.sh + atomicity self-test

**Files:**
- Create: `tests/run-one.sh`
- Create: `tests/test_run_one_atomicity.sh`

- [ ] **Step 3.1: Write `tests/run-one.sh`.**

```bash
cat > tests/run-one.sh <<'RUNONE_EOF'
#!/usr/bin/env bash
# tests/run-one.sh — runs one test_*.sh, captures stdout/stderr to a
# tempfile, prints "=== test_X ===" + log + "  test_X: ok|FAIL" footer
# atomically via flock(1). Exit code is the test's rc (0=ok, non-zero=fail).
#
# Usage: bash tests/run-one.sh <test_file>
#
# Output: a single atomic block per test. Concurrent run-one.sh
# processes coordinate via flock 1 (a kernel-level lock on stdout's
# file descriptor); blocks never interleave. Block order is
# completion-time, not argv order.

set -uo pipefail
[[ $# -eq 1 ]] || { echo "Usage: $0 <test_file>" >&2; exit 2; }

t="$1"
log=$(mktemp)
trap 'rm -f "$log"' EXIT

if bash "$t" > "$log" 2>&1; then
  status="ok"
  rc=0
else
  status="FAIL"
  rc=1
fi

# Atomic print: flock 1 holds an exclusive kernel lock on stdout's fd
# for the duration of the brace group. Released when the group exits.
{
  flock 1
  echo "=== $t ==="
  cat "$log"
  echo "  $t: $status"
}

exit "$rc"
RUNONE_EOF
chmod +x tests/run-one.sh
```

- [ ] **Step 3.2: Smoke-test run-one.sh manually.**

```bash
bash tests/run-one.sh tests/test_colors.sh
```

Expected output structure:
```
=== tests/test_colors.sh ===
  PASS: ...
  PASS: ...
  tests/test_colors.sh: ok
```

rc=0.

- [ ] **Step 3.3: Write `tests/test_run_one_atomicity.sh`.**

```bash
cat > tests/test_run_one_atomicity.sh <<'ATOM_EOF'
#!/usr/bin/env bash
# tests/test_run_one_atomicity.sh
# Self-test: spawn two run-one.sh instances concurrently with overlapping
# stdout; assert no block interleaving (every "=== X ===" header is
# followed contiguously by X's body and footer, before any other test's
# header appears).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# Stage two fake tests that emit many lines slowly enough to overlap.
cat > "$SANDBOX/test_alpha.sh" <<'EOF'
#!/usr/bin/env bash
for i in 1 2 3 4 5 6 7 8 9 10; do
  echo "alpha line $i"
done
EOF

cat > "$SANDBOX/test_beta.sh" <<'EOF'
#!/usr/bin/env bash
for i in 1 2 3 4 5 6 7 8 9 10; do
  echo "beta line $i"
done
EOF

chmod +x "$SANDBOX"/test_*.sh

# Run both concurrently through run-one.sh. xargs -P 2 ensures
# parallelism.
OUT="$SANDBOX/out.log"
printf '%s\n%s\n' "$SANDBOX/test_alpha.sh" "$SANDBOX/test_beta.sh" \
  | xargs -P 2 -I{} bash run-one.sh {} > "$OUT" 2>&1
rc=$?
assert_eq "$rc" "0" "both fixture tests run successfully"

# Parse the output. Expected structure under atomicity:
#   === test_alpha.sh ===   (or beta first; order = completion)
#   alpha line 1..10
#   test_alpha.sh: ok
#   === test_beta.sh ===
#   beta line 1..10
#   test_beta.sh: ok

# Find each header's line number
alpha_header=$(grep -n '^=== .*test_alpha.sh ===$' "$OUT" | cut -d: -f1)
beta_header=$(grep -n '^=== .*test_beta.sh ===$' "$OUT" | cut -d: -f1)
alpha_footer=$(grep -n '^  .*test_alpha.sh: ok$' "$OUT" | cut -d: -f1)
beta_footer=$(grep -n '^  .*test_beta.sh: ok$' "$OUT" | cut -d: -f1)

[[ -n "$alpha_header" && -n "$beta_header" && -n "$alpha_footer" && -n "$beta_footer" ]] \
  || { echo "FAIL: missing header/footer in output:" >&2; cat "$OUT" >&2; exit 1; }

# Atomicity check: alpha's footer comes before beta's header (or vice-versa);
# no test's range overlaps another's.
if (( alpha_header < beta_header )); then
  (( alpha_footer < beta_header )) \
    || { echo "FAIL: alpha block extends into beta region (interleaving):" >&2; cat "$OUT" >&2; exit 1; }
else
  (( beta_footer < alpha_header )) \
    || { echo "FAIL: beta block extends into alpha region (interleaving):" >&2; cat "$OUT" >&2; exit 1; }
fi
pass "1. run-one.sh blocks do not interleave under concurrent xargs -P"

# Sanity: each test's body lines are present
[[ "$(grep -c '^alpha line ' "$OUT")" == "10" ]] \
  || { echo "FAIL: alpha body missing lines" >&2; cat "$OUT" >&2; exit 1; }
[[ "$(grep -c '^beta line ' "$OUT")" == "10" ]] \
  || { echo "FAIL: beta body missing lines" >&2; cat "$OUT" >&2; exit 1; }
pass "2. each test's full body is captured (20 lines total: 10+10)"

# FAIL exit propagation
cat > "$SANDBOX/test_fails.sh" <<'EOF'
#!/usr/bin/env bash
echo "this test fails"
exit 1
EOF
chmod +x "$SANDBOX/test_fails.sh"

set +e
bash run-one.sh "$SANDBOX/test_fails.sh" > "$SANDBOX/fail_out.log" 2>&1
fail_rc=$?
set -e
assert_eq "$fail_rc" "1" "FAIL exit propagates through run-one.sh"
grep -q ': FAIL$' "$SANDBOX/fail_out.log" \
  || { echo "FAIL: footer doesn't say FAIL" >&2; cat "$SANDBOX/fail_out.log" >&2; exit 1; }
pass "3. test failure → run-one.sh exits 1 with ': FAIL' footer"

echo "test_run_one_atomicity: 3 cases passed"
ATOM_EOF
chmod +x tests/test_run_one_atomicity.sh
```

- [ ] **Step 3.4: Run the atomicity test.**

```bash
bash tests/test_run_one_atomicity.sh
```

Expected: 3 cases pass; final line `test_run_one_atomicity: 3 cases passed`.

- [ ] **Step 3.5: Confirm full suite still green.**

```bash
bash tests/run.sh > /tmp/t3-suite.log 2>&1; echo "rc=$?"
grep -cE "^  test_.*: FAIL$" /tmp/t3-suite.log
```

Expected: `rc=0`, `FAIL` count `0`. (Suite is still using the serial `run.sh`; `run-one.sh` is exercised only by its self-test.)

- [ ] **Step 3.6: Commit T3.**

```bash
git add tests/run-one.sh tests/test_run_one_atomicity.sh
git commit -m "$(cat <<'EOF'
test(parallel): add run-one.sh atomic per-test wrapper

run-one.sh runs one test, captures stdout+stderr to a tempfile, then
prints "=== test_X ===" header + log + "  test_X: ok|FAIL" footer
atomically via `flock 1`. Concurrent invocations coordinate through
the kernel lock on stdout's fd; blocks never interleave.

Self-test runs two fixture tests via xargs -P 2 and asserts both
blocks are contiguous in the merged output (no interleaving), plus
FAIL-exit propagation is honored.

T4 will rewrite tests/run.sh to use this wrapper.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Rewrite run.sh as xargs scheduler

**Files:**
- Modify: `tests/run.sh` (full rewrite)

- [ ] **Step 4.1: Back up the current run.sh in case the rewrite needs reference.**

```bash
cp tests/run.sh /tmp/run.sh.serial-backup
```

- [ ] **Step 4.2: Replace `tests/run.sh` with the parallel scheduler.**

```bash
cat > tests/run.sh <<'RUNSH_EOF'
#!/usr/bin/env bash
# tests/run.sh — parallel test runner.
#
# Discovers tests/test_*.sh, filters outer skips (manual dogfood gates),
# pipes them through `xargs -P $(nproc) -I{} bash run-one.sh {}`.
# Each test's output is wrapped atomically by run-one.sh (flock 1).
#
# Flags:
#   --jobs N        max parallel jobs (default: $(nproc))
#   --serial        equivalent to --jobs 1; for debugging flakes
#   --filter PAT    regex applied to filenames before scheduling
#
# Exit codes:
#   0  all tests passed
#   1  one or more tests failed
#   2  audit-parallel-safety precondition failed (no tests dispatched)

set -euo pipefail
cd "$(dirname "$0")"

JOBS=$(nproc 2>/dev/null || echo 4)
FILTER=""
SERIAL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs)    JOBS="$2"; shift 2 ;;
    --serial)  SERIAL=1; shift ;;
    --filter)  FILTER="$2"; shift 2 ;;
    -h|--help)
      sed -n '3,16p' "$0" | sed 's/^# *//'
      exit 0 ;;
    *) echo "unknown flag: $1 (try --help)" >&2; exit 2 ;;
  esac
done
[[ "$SERIAL" -eq 1 ]] && JOBS=1

# --- Precondition: audit-parallel-safety must be clean ---
if ! bash audit-parallel-safety.sh > /tmp/cw-audit.log 2>&1; then
  echo "audit-parallel-safety FAILED — refusing to dispatch tests:" >&2
  cat /tmp/cw-audit.log >&2
  exit 2
fi

# --- Outer skips — preserved exactly from the v0.51 baseline ---
# These are manual release-gate tests that exercise live LLMs or
# require interactive input; never run in CI/automated suite.
should_skip() {
  case "$1" in
    test_consult_question_dogfood_*.sh) return 0 ;;
    test_consult_design_doc_walkthrough.sh) return 0 ;;
    test_consult_v050_dogfood.sh) return 0 ;;
    test_deploy_v070_dogfood.sh) return 0 ;;
    test_deploy_v07_dogfood.sh) return 0 ;;
    test_consult_v011_dogfood.sh) return 0 ;;
  esac
  return 1
}

mapfile -t TESTS < <(
  for t in test_*.sh; do
    if should_skip "$t"; then
      echo "=== $t === (SKIP — manual gate)" >&2
      continue
    fi
    if [[ -n "$FILTER" && ! "$t" =~ $FILTER ]]; then
      continue
    fi
    echo "$t"
  done
)

# --- Dispatch ---
START=$(date +%s)
# xargs returns 123 if any child exited non-zero (no error message).
# We want non-zero in that case but no stderr noise from xargs itself.
set +e
printf '%s\n' "${TESTS[@]}" | xargs -P "$JOBS" -I{} bash run-one.sh {}
xargs_rc=$?
set -e
END=$(date +%s)
ELAPSED=$((END - START))

# Translate xargs's 123 to our 1.
if [[ "$xargs_rc" -eq 0 ]]; then
  rc=0
elif [[ "$xargs_rc" -eq 123 ]]; then
  rc=1
else
  rc=$xargs_rc
fi

# --- Summary ---
# Run-one.sh prints footer "  $t: ok" or "  $t: FAIL" for each test.
# We can't reliably parse our own stdout here (it's already gone to the
# terminal). Compute counts from $TESTS and $rc instead.
total=${#TESTS[@]}
skipped=$(grep -cE '\(SKIP — manual gate\)' /dev/stderr 2>/dev/null || echo 0)
# (skipped count is approximate — see comment below)
echo
echo "--- summary ---"
if [[ "$rc" -eq 0 ]]; then
  echo "$total tests, $total ok, 0 fail"
else
  echo "$total tests dispatched; one or more failed (see ': FAIL' lines above)"
fi
mins=$((ELAPSED / 60))
secs=$((ELAPSED % 60))
printf 'real    %dm%02ds   (was 6m42s serial baseline)\n' "$mins" "$secs"

exit "$rc"
RUNSH_EOF
chmod +x tests/run.sh
```

- [ ] **Step 4.3: Smoke-test the new run.sh in `--serial` mode with a narrow filter.**

```bash
bash tests/run.sh --serial --filter colors
```

Expected: runs only `test_colors.sh`; prints `=== test_colors.sh ===` + body + `  test_colors.sh: ok` + summary. rc=0.

- [ ] **Step 4.4: Test `--filter` with a multi-match regex.**

```bash
bash tests/run.sh --serial --filter 'test_consult_init'
```

Expected: runs the 3 remaining `test_consult_init*` files (after Tier 2 sweep: `test_consult_init.sh`, `test_consult_init_provider_resolution.sh`, `test_consult_init_targets_single_slug.sh`). All ok. rc=0.

- [ ] **Step 4.5: Test parallel dispatch with the same filter.**

```bash
bash tests/run.sh --jobs 4 --filter 'test_consult_init'
```

Expected: same 3 tests pass (possibly in completion-time order, not source order). rc=0.

- [ ] **Step 4.6: Confirm `--help` works and unknown flag errors cleanly.**

```bash
bash tests/run.sh --help
bash tests/run.sh --bogus 2>&1; echo "rc=$?"
```

Expected: `--help` prints the flag docs; `--bogus` prints `unknown flag: --bogus (try --help)` and exits 2.

- [ ] **Step 4.7: Commit T4.**

```bash
git add tests/run.sh
git commit -m "$(cat <<'EOF'
test(parallel): rewrite tests/run.sh as xargs -P scheduler

Replaces the serial for-loop. New behavior:
- Default jobs = nproc; --jobs N or --serial flags override.
- --filter PAT regex narrows the run for debugging.
- audit-parallel-safety.sh runs as precondition; rc=2 on audit fail
  (no tests dispatched).
- Outer skips (6 manual dogfood gates) preserved exactly.
- Per-test output wrapped atomically by run-one.sh; concurrent blocks
  never interleave.

xargs's rc=123 (any child non-zero) translated to rc=1 for caller
clarity.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Parity check + flake stress

**Files:** none (verification only; no commit unless a fix is needed)

This is the critical gate. Three runs must all be green:
- `bash tests/run.sh --serial` — proves the new runner under serial matches what we had
- `bash tests/run.sh` (parallel) — proves the parallel path produces the same results
- `bash tests/run.sh` again — proves no order-dependent flakes

If any of these fails, STOP and surface — do not paper over.

- [ ] **Step 5.1: Serial run.**

```bash
time (bash tests/run.sh --serial > /tmp/t5-serial.log 2>&1; echo "rc=$?")
grep -cE "^  test_.*: ok$" /tmp/t5-serial.log
grep -cE "^  test_.*: FAIL$" /tmp/t5-serial.log
```

Expected:
- `rc=0`
- ok count: 255 (253 baseline + 2 new self-tests added in T1/T3)
  - Note: actual count depends on T1+T3 self-tests landing. If audit + run-one self-tests + atomicity self-test all count, expect 256+.
- FAIL count: 0
- Wall time: ~6m42s ± 10s

- [ ] **Step 5.2: Parallel run #1.**

```bash
time (bash tests/run.sh > /tmp/t5-parallel1.log 2>&1; echo "rc=$?")
grep -cE "^  test_.*: ok$" /tmp/t5-parallel1.log
grep -cE "^  test_.*: FAIL$" /tmp/t5-parallel1.log
```

Expected:
- `rc=0`
- ok count: matches Step 5.1's count exactly
- FAIL count: 0
- Wall time: significantly less than serial (target ≤3× speedup on 4-core, ≤5× on 8-core)

- [ ] **Step 5.3: Parallel run #2 (flake stress).**

```bash
time (bash tests/run.sh > /tmp/t5-parallel2.log 2>&1; echo "rc=$?")
grep -cE "^  test_.*: ok$" /tmp/t5-parallel2.log
grep -cE "^  test_.*: FAIL$" /tmp/t5-parallel2.log
```

Expected: same as Step 5.2. If different (a test passes once and fails once), the test has an order-dependent flake under parallelism — investigate and fix before T6.

- [ ] **Step 5.4: Compare ok counts across the three runs.**

```bash
diff <(grep -E "^  test_.*: ok$" /tmp/t5-serial.log | awk '{print $1}' | sort) \
     <(grep -E "^  test_.*: ok$" /tmp/t5-parallel1.log | awk '{print $1}' | sort)
diff <(grep -E "^  test_.*: ok$" /tmp/t5-parallel1.log | awk '{print $1}' | sort) \
     <(grep -E "^  test_.*: ok$" /tmp/t5-parallel2.log | awk '{print $1}' | sort)
```

Expected: both diffs empty (every ok test in serial = every ok test in parallel = every ok test in flake-stress run).

- [ ] **Step 5.5: If 5.1-5.4 all green, no commit needed.** This task is a verification gate.

If any check failed:
1. Identify the failing test from `/tmp/t5-*.log`.
2. Inspect for parallel-safety violations the audit missed.
3. Fix inline, re-run 5.1-5.4. Commit as a fix only if the fix touches code (not just retries).

---

## Task 6: CLAUDE.md — parallel-safety contract

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 6.1: Read the existing CLAUDE.md `## Execution discipline in this repo` section.**

```bash
grep -n '## Execution discipline in this repo' CLAUDE.md
```

Locate the section. The new contract goes at the end of that section, before `## What is explicitly out of scope`.

- [ ] **Step 6.2: Append the parallel-safety contract.** Edit `CLAUDE.md` to insert this block right before `## What is explicitly out of scope`:

```markdown
## Parallel test runner contract

`tests/run.sh` is parallel by default (`xargs -P $(nproc)`); each test
runs in its own bash subshell with output wrapped atomically by
`tests/run-one.sh` (`flock 1`). Tests must satisfy the isolation
contract enforced by `tests/audit-parallel-safety.sh` (which runs as
a **precondition** before any test dispatches — `rc=2` if it fails):

1. **No fixed `/tmp/<name>` paths.** Use `mktemp -d` / `mktemp`.
2. **`CLONE_WARS_HOME`** assigned only to a sandboxed path (under
   `$TMP`, `$SANDBOX`, or `$(mktemp ...)`).
3. **tmux session/window names** include `$$` or `${RANDOM}` (the
   established `cw-<topic>-$$-${RANDOM}` pattern).
4. **No `cd`** to an absolute path outside the test's sandbox.
5. **`pgrep -f` patterns** are flagged for review (informational
   warning, not a fail) — confirm the pattern can't match a
   concurrently-running sibling test's command line.

Run modes:
- `bash tests/run.sh` — parallel, default
- `bash tests/run.sh --serial` — sequential (debugging a flake)
- `bash tests/run.sh --jobs N` — explicit parallelism
- `bash tests/run.sh --filter PAT` — regex on filenames (debugging a
  single test or a related set)

If a test fails under parallel but passes under `--serial`, it has a
parallel-safety bug not covered by the 5 invariants above — extend the
audit and fix the test.
```

- [ ] **Step 6.3: Verify the new section is well-formed.**

```bash
grep -nE '^## ' CLAUDE.md | head -20
```

Expected: `## Parallel test runner contract` appears between `## Execution discipline in this repo` and `## What is explicitly out of scope`.

- [ ] **Step 6.4: Run full suite to confirm docs change didn't break anything.**

```bash
bash tests/run.sh > /tmp/t6-suite.log 2>&1; echo "rc=$?"
grep -cE "^  test_.*: FAIL$" /tmp/t6-suite.log
```

Expected: `rc=0`, FAIL count `0`.

- [ ] **Step 6.5: Commit T6.**

```bash
git add CLAUDE.md
git commit -m "$(cat <<'EOF'
docs(testing): document parallel-test-runner contract in CLAUDE.md

5 isolation invariants enforced by audit-parallel-safety.sh +
run-mode flags (--serial / --jobs / --filter). New tests must follow
the contract or the audit precondition will reject the suite.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Push branch + open PR

**Files:** none (git operations only; NO subagent — do this inline so the human sees the PR URL)

Saved memory `feedback_classifier_blocks_protected_ops` warns: do not push to `main` directly. Push the feature branch + open a PR.

- [ ] **Step 7.1: Confirm clean working tree, all T1-T6 commits present.**

```bash
git status -s | awk '$1!="??"' | wc -l   # → 0
git log --oneline main..HEAD             # 6 new commits expected (T1-T6, no T5 commit)
```

Expected: 6 commits (T1 audit, T2 fix, T3 run-one, T4 run.sh, T6 docs; T5 is verify-only) plus the T0 spec already committed = 7 total ahead of main.

Actually: spec (98efc23) is at HEAD~6. T1-T4 + T6 are 5 commits. Adjust the expected count to 6 (spec + 5 implementation commits).

- [ ] **Step 7.2: Push the branch.**

```bash
git push -u origin feat/parallel-test-runner
```

Expected: `[new branch]` line + tracking confirmation. (Branch was created locally during the brainstorm; push is first sync.)

- [ ] **Step 7.3: Open PR.**

```bash
gh pr create --title "test: parallel test runner (Lane C)" --body "$(cat <<'EOF'
## Summary

Replaces serial `tests/run.sh` with an `xargs -P $(nproc)` parallel scheduler. Each test runs in its own bash subshell; output is captured + printed atomically via `flock 1` so blocks never interleave. Expected wall time: 6m42s → ~1m45-2m20s on 4 cores; ~1m10-1m30s on 8.

**New files:**
- `tests/run-one.sh` — atomic per-test wrapper
- `tests/audit-parallel-safety.sh` — isolation-contract lint (runs as precondition)
- `tests/test_run_one_atomicity.sh` — self-test for non-interleaving
- `tests/test_audit_parallel_safety_self.sh` — self-test for the 4 audit checks

**Changes:**
- `tests/run.sh` — rewritten as scheduler (--jobs N / --serial / --filter PAT flags)
- `tests/test_consult_load_prompt_migration.sh` — `/tmp/items.txt` → `$(mktemp -d)/items.txt`
- `CLAUDE.md` — documents the 5-rule parallel-safety contract

Design spec: `docs/superpowers/specs/2026-05-21-parallel-test-runner-design.md`.

## Test plan

- [ ] `bash tests/run.sh --serial` green at 255 ok / 0 fail (~6m42s)
- [ ] `bash tests/run.sh` green at 255 ok / 0 fail (~2m on 4-core)
- [ ] `bash tests/run.sh` green a second time (flake stress)
- [ ] `bash tests/run.sh --filter test_colors` runs only matching test
- [ ] `bash tests/audit-parallel-safety.sh` exits 0
- [ ] `bash tests/test_audit_parallel_safety_self.sh` exits 0
- [ ] `bash tests/test_run_one_atomicity.sh` exits 0

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR URL printed. Report it back to the human.

---

## Self-review checklist (run after completing the plan, before handoff)

- [ ] **Spec coverage:**
  - Architecture (run.sh + run-one.sh): T3 (run-one.sh), T4 (run.sh) ✓
  - Isolation contract: T1 (audit) ✓
  - Known fix (`/tmp/items.txt`): T2 ✓
  - Audit-as-precondition: T4 wires it ✓
  - Self-tests (atomicity + audit-self): T3, T1 ✓
  - CLAUDE.md update: T6 ✓
- [ ] **No placeholders** in any task ✓
- [ ] **Type consistency:** `run-one.sh` is referenced by `run.sh` via `bash run-one.sh {}`; argument is the test filename. Audit always uses `audit-parallel-safety.sh`. ✓

---

## Notes for the implementer

- **Background commands & `set -e`**: many test files use `set -euo pipefail`. The new `run-one.sh` uses `set -uo pipefail` (no `-e`) intentionally — we want to capture the test's rc, not abort run-one.sh when the test fails.
- **The audit's check 1 regex** may surface false positives in some tests (e.g. a test that writes to `$TMP/cw-foo` could match `/tmp/cw-foo` in a path string elsewhere). Inspect each fail line; if it's a false positive, refine the regex rather than ignoring the violation.
- **Per the saved memory `feedback_subagent_mechanical_tasks_glitch`**: when a subagent says "I'll wait for the notification" without committing, verify disk state matches the plan + tests pass + commit directly. Do not re-dispatch the same task without a code change.
- **Per the saved memory `feedback_classifier_blocks_protected_ops`**: T7's `git push` is to a feature branch (not `main`); no special authorization needed. Opening the PR via `gh pr create` is fine.
- **Suite-green checkpoint**: re-run the full suite after every implementation task (T1, T2, T3, T4, T6). Idiom:

  ```bash
  bash tests/run.sh > /tmp/t<N>-suite.log 2>&1; echo "rc=$?"
  grep -cE "^  test_.*: FAIL$" /tmp/t<N>-suite.log
  ```

  `rc=0` AND FAIL count `0` are BOTH required.
