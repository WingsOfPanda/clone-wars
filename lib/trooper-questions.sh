# lib/trooper-questions.sh — v0.50.0 trooper escalation protocol.
# Provides the verify-dispatcher + reply-formatter + line-validator that
# both the deploy and consult lanes call when a trooper emits a
# {"event":"question","claim":{...}} event. Pure functions, no I/O side
# effects beyond stdout/stderr.

# cw_trooper_question_verify <kind> <value>
# Verify a claim of `kind` (path|git|env|cmd|test) carrying `value`.
# Returns:
#   rc=0  claim VERIFIES (file exists, ref resolves, env set non-empty,
#         cmd on PATH, test exits 0)
#   rc=1  claim DISPROVED (file missing, ref unknown, env unset/empty,
#         cmd absent, test exits non-zero)
#   rc=2  UNVERIFIABLE (unknown kind, empty value, banned test command,
#         test timeout, malformed input)
# Prints evidence to stdout: ls -ld for path, rev-parse hash for git,
# value for env, command -v output for cmd, captured stdout+stderr for
# test. kind=test runs `timeout 30 bash -c "$value" 2>&1`.
cw_trooper_question_verify() {
  local kind="${1:-}" value="${2:-}"
  [[ -n "$kind" && -n "$value" ]] || return 2
  case "$kind" in
    path)
      if [[ -e "$value" && -r "$value" ]]; then
        ls -ld -- "$value" 2>/dev/null
        return 0
      fi
      return 1
      ;;
    git)
      local sha
      if sha=$(git rev-parse --verify "$value" 2>/dev/null); then
        printf '%s\n' "$sha"
        return 0
      fi
      return 1
      ;;
    env)
      local val="${!value:-}"
      if [[ -n "$val" ]]; then
        printf '%s\n' "$val"
        return 0
      fi
      return 1
      ;;
    cmd)
      local path
      if path=$(command -v -- "$value" 2>/dev/null); then
        printf '%s\n' "$path"
        return 0
      fi
      return 1
      ;;
    test)
      # Soft-spot guard: ban running the project's own test suite via this
      # protocol. Troopers must run their own tests; this kind is for
      # diagnostic checks under 30s only.
      if [[ "$value" == "tests/run.sh"* || "$value" == "bash tests/run.sh"* ]]; then
        return 2
      fi
      local out rc
      out=$(timeout 30 bash -c -- "$value" 2>&1)
      rc=$?
      printf '%s\n' "$out"
      # 124 = timeout fired → UNVERIFIABLE, not disproved.
      [[ "$rc" -eq 124 ]] && return 2
      [[ "$rc" -eq 0 ]]   && return 0
      return 1
      ;;
    *)
      return 2
      ;;
  esac
}

# cw_trooper_question_format_reply <kind> <value> <rc> <evidence>
# Format an inbox.md reply body for the trooper. <evidence> is the
# string captured from cw_trooper_question_verify's stdout. Body
# always begins with one of three verdict lines (FOUND / NOT FOUND /
# UNVERIFIABLE) and ends with a "Resume implementation." directive.
# Stdout: full reply body, ready to be piped into bin/send.sh.
cw_trooper_question_format_reply() {
  local kind="$1" value="$2" rc="$3" evidence="$4"
  local verdict
  case "$rc" in
    0) verdict="FOUND" ;;
    1) verdict="NOT FOUND" ;;
    *) verdict="UNVERIFIABLE" ;;
  esac
  cat <<EOF
From: master-yoda

Verdict: $verdict
Claim kind: $kind
Claim value: $value

Evidence:
$evidence

EOF
  if [[ "$kind" == "test" ]]; then
    cat <<'EOF'
NOTE: kind=test was a diagnostic check only — running your full test
suite is your job, not mine. Use this protocol for short verification
queries, not for offloading work.

EOF
  fi
  cat <<'EOF'
Resume implementation.
EOF
}

# cw_trooper_question_validate_line <json-line>
# rc=0 iff the line is a parseable {"event":"question",...} with:
#   - non-empty "text" field
#   - if "claim" field present, it has a "kind" with value in
#     {path,git,env,cmd,test} and a non-empty "value"
#   - ASCII-only (printable 0x20-0x7E plus tab)
# Fail-closed against malformed input. Used by wait scripts.
cw_trooper_question_validate_line() {
  local line="${1:-}"
  [[ "$line" == *'"event":"question"'* ]] || return 1
  # ASCII-only (printable + tab). Reject anything outside.
  if LC_ALL=C printf '%s' "$line" | LC_ALL=C grep -q $'[^\t -~]'; then
    return 1
  fi
  # text field present + non-empty + no escaped quote/backslash.
  printf '%s' "$line" | grep -qE '"text":"[^"\\]+"' || return 1
  # If claim object present, validate its kind + value.
  if printf '%s' "$line" | grep -q '"claim":{'; then
    local kind
    kind=$(printf '%s' "$line" | sed -n 's/.*"claim":{[^}]*"kind":"\([a-z]*\)".*/\1/p')
    case "$kind" in
      path|git|env|cmd|test) ;;
      *) return 1 ;;
    esac
    printf '%s' "$line" | grep -qE '"claim":\{[^}]*"value":"[^"\\]+"' || return 1
  fi
  return 0
}
