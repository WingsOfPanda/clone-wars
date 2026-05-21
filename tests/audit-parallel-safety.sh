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
    # Acceptable RHS: any sandbox-derived var. The accept-list is enumerated
    # rather than open-ended so a stray `CLONE_WARS_HOME=/literal/path` still
    # fails. Sandbox vars commonly used across the suite: $TMP, $SANDBOX,
    # $(mktemp ...), $HUB / $HUB_DIR / $ALT / $ART / $TD / $BRANCH / $REPO /
    # $REPO_DIR / $GIT_DIR / $SLUG / $WORK. Also accept $CLONE_WARS_HOME itself
    # (re-export passthrough — outer scope already sandboxed).
    if [[ "$val" =~ ^[\"\']?(\$TMP|\$SANDBOX|\$\(mktemp|\"\$\(mktemp|\$\{TMP|\$\{SANDBOX|\$CLONE_WARS_HOME|\$HUB|\$HUB_DIR|\$ALT|\$ART|\$TD|\$BRANCH|\$REPO|\$REPO_DIR|\$GIT_DIR|\$SLUG|\$WORK) ]]; then
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
  done < <(grep -nE 'cd[[:space:]]+/' "$t" | grep -vE 'dirname[[:space:]]+\"?\$0|\$TMP|\$SANDBOX|\$ART|\$TD|\$BRANCH|\$HUB|\$REPO|\$PLUGIN_ROOT|^[0-9]+:[[:space:]]*echo')

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
