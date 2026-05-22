# Parallel Test Runner — Design

**Date:** 2026-05-21
**Status:** Design approved; awaiting implementation plan.

## Problem

`tests/run.sh` is a serial for-loop over 259 test files. Wall time is ~6m42s on a workstation; only ~16s of that is CPU. The remaining 96% is fork/exec overhead for `awk`/`grep`/`tmux`/`bash -c` subprocesses plus a smaller bucket of intentional `sleep` waits in 21 tests (monitor poll cycles, tmux operation settling).

Sequential execution leaves modern multi-core hardware idle. The suite is also a release-time bottleneck: every release lane (v0.46→v0.51) ran `bash tests/run.sh` at least 4–7 times during a refactor-only commit chain; the time accumulates.

## Goal

Replace `tests/run.sh` with a parallel scheduler that:

- Cuts wall time by ≥3× on a 4-core machine, ≥5× on 8-core.
- Preserves exactly the same test results, exit codes, and per-test output formatting that the current serial runner produces.
- Stays pure bash 4.2+ with no new runtime deps (no GNU parallel, no Make, no Python).
- Keeps a `--serial` escape hatch so debugging a flake never requires reverting the runner.

## Architecture

Two files:

```
tests/run.sh        ← rewritten as the scheduler entry point
tests/run-one.sh    ← NEW: per-test wrapper, captures + atomically prints output
```

**Scheduler (`run.sh`):**

1. Parses flags: `--jobs N` (default `$(nproc)`), `--serial` (forces N=1), `--filter PATTERN` (regex applied to filenames before scheduling).
2. Enumerates `test_*.sh`; filters out the 6 outer skips (manual dogfood gates) exactly as today.
3. Pipes the remaining filenames through `xargs -P $JOBS -I{} bash run-one.sh {}`.
4. Aggregates the exit code: any non-zero `run-one.sh` → `run.sh` exits 1.
5. After `xargs` returns, prints a summary line:
   ```
   --- summary ---
   259 tests, 253 ok, 6 outer-skipped, 0 fail
   real    2m04s   (was 6m42s serial)
   ```

**Per-test wrapper (`run-one.sh`):**

```bash
#!/usr/bin/env bash
set -uo pipefail
t="$1"
log=$(mktemp)
trap 'rm -f "$log"' EXIT
if bash "$t" > "$log" 2>&1; then
  status="ok"; rc=0
else
  status="FAIL"; rc=1
fi
{
  flock 1
  echo "=== $t ==="
  cat "$log"
  echo "  $t: $status"
}
exit $rc
```

`flock 1` (a file-descriptor lock on stdout) serializes the entire output block. Concurrent `run-one.sh` processes coordinate through the kernel lock; no test's output ever interleaves another's. The block ordering becomes completion-time order (not source-file order), but every block is byte-identical to what serial produces.

## Isolation contract

Every test must satisfy these invariants. The audit script (`tests/audit-parallel-safety.sh`) enforces them as a permanent lint after migration.

1. **No fixed `/tmp/<name>` paths.** Use `mktemp -d` for sandboxes or `mktemp` for individual files.
2. **No fixed `CLONE_WARS_HOME`.** Always `$(mktemp -d)/cw` or equivalent under the sandbox.
3. **Unique tmux window/session names.** Pattern `cw-<topic>-$$-${RANDOM}` is the established standard; all 13 tmux-using tests already follow it.
4. **No `cd` outside `$(dirname "$0")` or the test's sandbox.** Each test runs in its own bash subshell so cwd doesn't leak, but the rule prevents accidental cross-test writes.
5. **No `pgrep -f` patterns that match sibling tests' command lines.** Saved-memory `feedback_no_unbounded_pgrep_self_match` already bans unbounded `pgrep -f` loops; under parallelism the bar is stricter — any `pgrep -f <pat>` where `<pat>` could match another running test is a race.

Known fixes required before parallel rollout:

- `tests/test_consult_load_prompt_migration.sh` writes to literal `/tmp/items.txt` and `/tmp/verify.md`. Move both to `$(mktemp -d)`.
- The audit will likely surface 1–3 more; fix inline rather than quarantining.

## Components

### `tests/audit-parallel-safety.sh`

Mechanical lint script. Five checks against every `test_*.sh`:

1. `grep` for absolute `/tmp/<word>` writes that aren't `mktemp` outputs.
2. `grep` for `CLONE_WARS_HOME=` assignments to anything not under `$TMP`/`$SANDBOX`/`$(mktemp ...)`.
3. `grep` for tmux session/window names lacking `$$` or `${RANDOM}` in their fixture.
4. `grep` for `pgrep -f` — print each pattern + filename as a **warning** (informational, doesn't fail the audit). Reviewer's job to confirm none match sibling tests. Failing them automatically would have too many false positives; the warning surfaces them for human eyes.
5. `grep` for unsandboxed `cd` to absolute paths.

Output:

```
PASS  255 tests parallel-safe
FAIL  4 tests need fixes:
  test_consult_load_prompt_migration.sh: writes /tmp/items.txt (fixed path)
  test_foo.sh: pgrep -f 'codex' may match sibling tests
  ...
```

Exit 0 on pass, 1 on any fail. After migration, this script runs as the *first* test in `run.sh` (a parallel-unsafe new test fails the suite immediately).

### `tests/run.sh`

Roughly 50 lines. Flag parsing, skip filter, xargs invocation, summary.

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

JOBS=$(nproc)
FILTER=""
SERIAL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs)    JOBS="$2"; shift 2 ;;
    --serial)  SERIAL=1; shift ;;
    --filter)  FILTER="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done
[[ "$SERIAL" -eq 1 ]] && JOBS=1

# Outer skips — preserved exactly from the v0.51 baseline.
SKIPS=(
  'test_consult_question_dogfood_'
  'test_consult_design_doc_walkthrough.sh'
  'test_consult_v050_dogfood.sh'
  'test_deploy_v070_dogfood.sh'
  'test_deploy_v07_dogfood.sh'
  'test_consult_v011_dogfood.sh'
)

mapfile -t TESTS < <(
  ls test_*.sh | while read -r t; do
    for s in "${SKIPS[@]}"; do
      [[ "$t" == *"$s"* ]] && { echo "=== $t === (SKIP — manual gate)" >&2; continue 2; }
    done
    [[ -n "$FILTER" && ! "$t" =~ $FILTER ]] && continue
    echo "$t"
  done
)

START=$(date +%s)
printf '%s\n' "${TESTS[@]}" | xargs -P "$JOBS" -I{} bash run-one.sh {}
rc=$?
END=$(date +%s)

# Summary: count test blocks in our own stdout. Each block has exactly
# one "  test_X.sh: ok" or "  test_X.sh: FAIL" footer line emitted by
# run-one.sh. xargs collects per-child rc; we already have $rc.
# Implementation: a parallel-safe way to count is to have run-one.sh
# append to a shared status file under flock.
exit "$rc"
```

### `tests/run-one.sh`

The atomic-output wrapper shown above. ~15 lines. Sourced by `xargs`; one process per test.

## Data flow

```
run.sh
  └── enumerate test_*.sh
  └── filter SKIPS
  └── filter --filter (if given)
  └── pipe filenames → xargs -P N
                          └── bash run-one.sh test_X.sh
                                  └── bash test_X.sh > $log 2>&1
                                  └── flock 1; print header+log+footer; release
                                  └── exit rc
  └── aggregate exit codes
  └── print summary
  └── exit max(rc)
```

## Migration plan

1. **Audit:** build `audit-parallel-safety.sh`, run it, list the failures.
2. **Fix all flagged tests** (one commit per category of fix).
3. **Add `run-one.sh`** and verify it works under both serial (manual `bash run-one.sh test_X`) and via `xargs -P 1 -I{} bash run-one.sh {}`.
4. **Rewrite `run.sh`** as the scheduler. Add the three flags.
5. **Parity check:**
   - `bash run.sh --serial` matches the v0.51 baseline output (modulo timestamp lines).
   - `bash run.sh` (parallel) produces same `ok`/`FAIL` counts.
   - Run parallel twice back-to-back; same exit codes both times (no order-dependent flakes).
6. **Lock the audit:** `audit-parallel-safety.sh` runs as a **precondition** before `xargs` starts. If it fails (rc=1), `run.sh` prints the audit report and exits 2 without dispatching any tests. New unsafe tests are caught at the suite's first step, before any parallel race can manifest.
7. **Update `CLAUDE.md`** with the parallel-safety contract for new tests.

## Error handling

- **Test fails:** captured in `run-one.sh`'s `$log`; printed atomically; non-zero exit propagated.
- **Test hangs:** no per-test timeout in v1. If a hang becomes a problem, add `timeout 600 bash "$t"` in `run-one.sh` later. Skipping v1 keeps it simple.
- **flock unavailable:** flock is in util-linux, present on every Linux. macOS lacks it natively — if anyone runs the suite there, fall back to `mkdir`-based locks (out of scope for v1; document the macOS gap).
- **xargs propagation:** `xargs -P` returns 123 if any child exits non-zero. We honor that as "some test failed"; `run.sh` exits 1.

## Testing

Self-tests in the test suite itself:

- `test_run_one_atomicity.sh` — spawn two `run-one.sh` instances with overlapping output; assert no interleaving.
- `test_run_serial_parity.sh` — `bash run.sh --serial 2>&1 | wc -l` matches `bash run.sh --filter test_ 2>&1 | wc -l` (same number of lines, same exit code).
- `test_audit_parallel_safety_self.sh` — author the audit script with one intentional positive (the `/tmp/items.txt` violator before its fix) and assert the audit catches it.

Plus the regression bar: full suite green under both modes; run parallel twice for flake check.

## Expected outcome

| Cores | Today (serial) | Parallel |
|------:|---:|---:|
| 4     | 6m42s | ~1m45–2m20s |
| 8     | 6m42s | ~1m10–1m30s |

The asymptote is the longest single test (currently ~13s — the monitor rescan/phase-aware tests). Combining Lane C with Lane A (monitor poll-interval override, ~80% cut to monitor tests) lowers the asymptote to ~3–4s, opening a path to sub-30s suites on 8+ cores. Not in scope for this design but motivates the runtime-floor memory.

## Out of scope

- Test sharding across multiple machines.
- Per-test runtime tracking / "slowest first" scheduling.
- Live progress bar.
- macOS `mkdir`-lock fallback.
- Auto-quarantine of misbehaving tests.

These are valuable but not load-bearing for the speedup. Revisit after parallel ships and we have a stability baseline.
