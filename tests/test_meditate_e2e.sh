#!/usr/bin/env bash
# tests/test_meditate_e2e.sh — simulated e2e (no real trooper spawning).
#
# Tests the meditate pipeline from init through synth-final by mocking
# trooper outputs. Real spawn/research/adversary behavior is validated
# by the strict-dogfood release gate.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# Sandbox state
SANDBOX=$(mktemp -d -t cw-meditate-e2e.XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT
export CLONE_WARS_HOME="$SANDBOX"

# Seed providers + contracts
printf 'codex\nclaude\n' > "$SANDBOX/providers-available.txt"
cat > "$SANDBOX/contracts.yaml" <<'EOF'
codex:
  binary: codex
  permission: allow
claude:
  binary: claude
  permission: allow
opencode:
  binary: opencode
  permission: allow
EOF

# Phase 0: init
TOPIC=$("$PLUGIN_ROOT/bin/meditate-init.sh" "compare websocket vs SSE" 2>/dev/null)
[[ -n "$TOPIC" ]] || { echo "FAIL: init produced no topic"; exit 1; }
REPO_HASH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
ART_DIR="$SANDBOX/state/$REPO_HASH/$TOPIC/_meditate"
[[ -d "$ART_DIR" ]] || { echo "FAIL: art dir not created"; exit 1; }
pass "Phase 0: init created $ART_DIR"

# Mock Phase 3 trooper outputs
cat > "$ART_DIR/findings-rex.md" <<'EOF'
# Findings: compare websocket vs SSE

## Summary
Two approaches for bidirectional updates.

## Approaches
1. [https://datatracker.ietf.org/doc/html/rfc6455] WebSocket — bidirectional
2. [https://html.spec.whatwg.org/multipage/server-sent-events.html] SSE — server-push only

## SOTA evidence
Not applicable — protocol-level, no ML.

## Tradeoffs
- WebSocket wins on bidirectional because RFC 6455 supports it
- SSE wins on simplicity per the HTML spec

## Independent Discovery
- https://datatracker.ietf.org/doc/html/rfc6455
- https://html.spec.whatwg.org/multipage/server-sent-events.html
- https://example.com/comparison

## Open questions
- None.

## Notes
EOF
cat > "$ART_DIR/findings-cody.md" <<'EOF'
# Findings: compare websocket vs SSE

## Summary
Cody agrees with Rex on the high-level shape.

## Approaches
1. [tests/test_websockets.py:10] WebSocket — bidirectional
2. [tests/test_sse.py:5] SSE — server-push

## SOTA evidence
Not applicable.

## Tradeoffs
- WebSocket wins on bidirectional per RFC 6455
- SSE wins on simplicity per the spec

## Independent Discovery
- tests/test_websockets.py:10
- tests/test_sse.py:5
- https://example.com/another

## Open questions
- We are uncertain about HTTP/2 server push impact.

## Notes
EOF
pass "Phase 3 (mocked): wrote findings-rex.md + findings-cody.md"

# Phase 5: preliminary synth — script should print the output path
OUT_DRAFT=$("$PLUGIN_ROOT/bin/meditate-synth-preliminary.sh" "$TOPIC")
[[ "$OUT_DRAFT" == "$ART_DIR/landscape-draft.md" ]] \
  || { echo "FAIL: synth-preliminary printed wrong path: $OUT_DRAFT"; exit 1; }
pass "Phase 5: synth-preliminary emits correct output path"

# Mock the draft (Yoda would Write this)
cat > "$ART_DIR/landscape-draft.md" <<'EOF'
## Topic
compare websocket vs SSE

## Approaches
1. WebSocket — bidirectional realtime per RFC 6455
2. SSE — server-push per HTML spec

## Tradeoff matrix
| Priority    | Best fit   | Reason                                |
|-------------|------------|---------------------------------------|
| Bidirection | WebSocket  | RFC 6455 defines bidirectional frames |
| Simplicity  | SSE        | HTML spec server-sent-events section  |

## Findings by trooper
### Rex (codex)
WebSocket vs SSE, both protocols documented.

### Cody (claude)
Agrees with Rex.

## Open questions
- HTTP/2 server push interaction unclear.

## Citations
- https://datatracker.ietf.org/doc/html/rfc6455
- https://html.spec.whatwg.org/multipage/server-sent-events.html
EOF
pass "Phase 5 (mocked): landscape-draft.md written"

# Simulate adversary skip (S1-S5 all hold, user accepts skip)
cat > "$ART_DIR/adversary-skip.txt" <<EOF
timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)
signals_passed: S1=true S2=true S3=true S4=true S5=true
user_decision: skip
EOF
pass "Phase 5.5 (mocked): adversary-skip.txt records skip"

# Phase 8: synth-final on skip path
OUT_FINAL=$("$PLUGIN_ROOT/bin/meditate-synth-final.sh" "$TOPIC")
[[ "$OUT_FINAL" =~ landscape-[0-9]{4}-[0-9]{2}-[0-9]{2}- ]] \
  || { echo "FAIL: synth-final printed wrong path shape: $OUT_FINAL"; exit 1; }
pass "Phase 8: synth-final emits canonical output path with date prefix"

# Verify TOPIC and OUT_FINAL agree
[[ "$OUT_FINAL" == "$ART_DIR/landscape-$(date -u +%Y-%m-%d)-${TOPIC#meditate-}.md" ]] \
  || { echo "FAIL: OUT_FINAL doesn't match expected: $OUT_FINAL"; exit 1; }
pass "Phase 8: output path matches landscape-<date>-<slug>.md shape"

pass "meditate e2e (skip path): 7 assertions green"
