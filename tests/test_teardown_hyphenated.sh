#!/usr/bin/env bash
# tests/test_teardown_hyphenated.sh — regression test for the integration bug
# the v0.0.4 final review caught: bin/teardown.sh's 2-arg branch was using
# ${name##*-} (last-dash strip) which mis-parses hyphenated model keys like
# claude-haiku into model="haiku" + commander="rex-claude". The fix uses
# ${name#${commander}-} (strip known-commander prefix) which yields the
# full hyphenated model.
#
# This test asserts the buggy pattern is gone AND the corrected pattern is
# present. It deliberately doesn't try to invoke teardown end-to-end (that
# requires real tmux + a live trooper) — the static check is the regression
# guard, and bin/send.sh / bin/collect.sh already exercise the same idiom
# successfully.

set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

SH=../bin/teardown.sh

# 1. The buggy pattern model_hint="${name##*-}" must NOT appear anywhere
#    in teardown.sh — neither in the topic-mode loop (which uses
#    cw_pane_meta_read_for_dir) nor in the 2-arg branch.
if grep -qE 'model_hint="\$\{name##\*-\}"' "$SH"; then
  echo "FAIL: bin/teardown.sh still contains the buggy pattern model_hint=\"\${name##*-}\"" >&2
  echo "      this strips ONLY after the LAST '-', mis-parsing hyphenated models" >&2
  exit 1
fi
pass "no buggy ##*- model_hint extraction in teardown.sh"

# 2. The corrected pattern ${name#${commander}-} must appear in the 2-arg
#    branch (the topic-mode loop uses cw_pane_meta_read_for_dir instead,
#    which doesn't need the hint).
if ! grep -qE 'model_hint="\$\{name#\$\{commander\}-\}"' "$SH"; then
  echo "FAIL: bin/teardown.sh missing the corrected pattern model_hint=\"\${name#\${commander}-}\"" >&2
  echo "      this is the prefix-strip form needed for hyphenated-model parity with send.sh/collect.sh" >&2
  exit 1
fi
pass "corrected #\${commander}- prefix-strip present in teardown.sh"

# 3. Static parity check: bin/send.sh and bin/collect.sh use the equivalent
#    prefix-strip via "${d##*/${COMMANDER}-}" (their dir variable d is the
#    full path, hence ##*/). teardown's 2-arg branch normalises to name first
#    then strips, but must produce the same result on hyphenated input.
#    Verify the send.sh pattern still exists (would catch a regression
#    where someone "simplified" send.sh to ${name##*-}).
for f in ../bin/send.sh ../bin/collect.sh; do
  if ! grep -qE 'MODEL_HINT="\$\{d##\*/\$\{COMMANDER\}-\}"' "$f"; then
    echo "FAIL: $(basename "$f") missing the canonical \${d##*/\${COMMANDER}-} hint pattern" >&2
    exit 1
  fi
done
pass "send.sh and collect.sh keep the canonical commander-prefix-strip"

echo "  ALL: ok"
