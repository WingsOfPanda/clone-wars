# tests/lib/assert.sh — sourced by every test_*.sh
# Exits non-zero on first failure so tests fail fast.

assert_eq() {
  local actual="$1" expected="$2" msg="${3:-}"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: ${msg:-assert_eq}" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    exit 1
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "FAIL: ${msg:-assert_contains}" >&2
    echo "  haystack: $haystack" >&2
    echo "  needle:   $needle" >&2
    exit 1
  fi
}

assert_exit() {
  local expected_code="$1"; shift
  local out
  out=$("$@" 2>&1); local code=$?
  if [[ "$code" -ne "$expected_code" ]]; then
    echo "FAIL: assert_exit expected $expected_code, got $code" >&2
    echo "  cmd: $*" >&2
    echo "  out: $out" >&2
    exit 1
  fi
}

assert_file_exists() {
  local path="$1" msg="${2:-}"
  if [[ ! -e "$path" ]]; then
    echo "FAIL: ${msg:-assert_file_exists}: $path missing" >&2
    exit 1
  fi
}

pass() { echo "  PASS: $*"; }
