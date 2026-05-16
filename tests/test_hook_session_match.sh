#!/usr/bin/env bash
# tests/test_hook_session_match.sh
# v0.40.0: UserPromptSubmit hook must read .session_id from stdin JSON
# and emit the resume directive ONLY for active-<own-sid>.txt — other
# sessions' markers in the same project must be invisible.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib/assert.sh

HOOK="$(pwd)/hooks/user-prompt-submit-active-session.sh"
[[ -x "$HOOK" ]] || { echo "FAIL: hook not executable at $HOOK" >&2; exit 1; }

# Sandbox: a synthetic project tree with two parallel deep-research sessions.
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# Compute the repo hash the hook will use ($PWD/.clone-wars/state/<hash>/).
PROJ="$SANDBOX/proj"
mkdir -p "$PROJ"
HASH=$(cd "$PROJ" && printf '%s' "$(realpath .)" | sha256sum | awk '{print $1}')

SID_A=11111111-1111-1111-1111-111111111111
SID_B=22222222-2222-2222-2222-222222222222
SID_C=33333333-3333-3333-3333-333333333333  # no marker file exists for this one

ART_A="$PROJ/.clone-wars/state/$HASH/deep-research-topic-a/_deep-research"
ART_B="$PROJ/.clone-wars/state/$HASH/deep-research-topic-b/_deep-research"
mkdir -p "$ART_A" "$ART_B"
echo "deep-research-topic-a" > "$ART_A/active-${SID_A}.txt"
echo "deep-research-topic-b" > "$ART_B/active-${SID_B}.txt"

# Case 1: stdin carries SID_A → hook emits block referencing topic-a.
out=$(cd "$PROJ" && printf '%s' "{\"session_id\":\"$SID_A\",\"hook_event_name\":\"UserPromptSubmit\"}" | "$HOOK" 2>&1)
[[ "$out" == *"deep-research-topic-a"* ]] \
  || { echo "FAIL: case 1 — expected topic-a in output for session A; got:" >&2; echo "$out" >&2; exit 1; }
[[ "$out" != *"deep-research-topic-b"* ]] \
  || { echo "FAIL: case 1 — topic-b leaked into session A's output" >&2; echo "$out" >&2; exit 1; }
pass "1. session A's hook sees only topic-a"

# Case 2: stdin carries SID_B → hook emits block referencing topic-b.
out=$(cd "$PROJ" && printf '%s' "{\"session_id\":\"$SID_B\",\"hook_event_name\":\"UserPromptSubmit\"}" | "$HOOK" 2>&1)
[[ "$out" == *"deep-research-topic-b"* ]] \
  || { echo "FAIL: case 2 — expected topic-b in output for session B; got:" >&2; echo "$out" >&2; exit 1; }
[[ "$out" != *"deep-research-topic-a"* ]] \
  || { echo "FAIL: case 2 — topic-a leaked into session B's output" >&2; echo "$out" >&2; exit 1; }
pass "2. session B's hook sees only topic-b"

# Case 3: stdin carries SID_C (no matching file) → hook silent.
out=$(cd "$PROJ" && printf '%s' "{\"session_id\":\"$SID_C\",\"hook_event_name\":\"UserPromptSubmit\"}" | "$HOOK" 2>&1)
[[ -z "$out" ]] \
  || { echo "FAIL: case 3 — hook leaked output for unknown session C:" >&2; echo "$out" >&2; exit 1; }
pass "3. session C's hook silent (no matching active-*.txt)"

# Case 4: malformed stdin (no session_id) → hook silent.
out=$(cd "$PROJ" && printf '%s' '{"hook_event_name":"UserPromptSubmit"}' | "$HOOK" 2>&1)
[[ -z "$out" ]] \
  || { echo "FAIL: case 4 — hook emitted output despite missing session_id:" >&2; echo "$out" >&2; exit 1; }
pass "4. hook silent on missing session_id field"

# Case 5: session_id with shell metacharacters → hook silent (defense in depth).
out=$(cd "$PROJ" && printf '%s' '{"session_id":"; rm -rf /"}' | "$HOOK" 2>&1)
[[ -z "$out" ]] \
  || { echo "FAIL: case 5 — hook processed tampered session_id:" >&2; echo "$out" >&2; exit 1; }
pass "5. hook silent on tampered session_id"
