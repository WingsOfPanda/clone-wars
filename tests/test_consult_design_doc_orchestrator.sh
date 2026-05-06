#!/usr/bin/env bash
# tests/test_consult_design_doc_orchestrator.sh — v0.4.2 atomic-write end-to-end.
#
# Drives bin/spec-assemble.sh against a fake _consult/design-doc/ dir
# inside an EPHEMERAL git repo (does not touch the real project repo).
# Verifies:
#   - clean run lands at final path, no temp leftovers
#   - dirty run leaves NO file at final path AND NO temp leftover
#   - rerun-after-fix succeeds (the dirty-rerun-blocked-by-collision bug)
#   - filename uses hash suffix from topic.txt
set -euo pipefail
cd "$(dirname "$0")"
PLUGIN_ROOT=$(cd .. && pwd)
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Ephemeral git repo for the orchestrator's git add/commit to operate against.
EREPO="$TMP/erepo"
mkdir -p "$EREPO"
(cd "$EREPO" && git init -q && \
  git config user.email "test@example.com" && \
  git config user.name "Test User")

# Drive the orchestrator from inside the ephemeral repo.
export CLONE_WARS_HOME="$TMP/cw"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export CW_TEST_DATE=2026-04-30
mkdir -p "$CLONE_WARS_HOME"

# Compute the repo hash for the EREPO so the orchestrator finds the topic dir.
# The orchestrator calls cw_repo_hash from CWD via cw_repo_root.
source "$PLUGIN_ROOT/lib/state.sh"
EREPO_HASH=$(cd "$EREPO" && cw_repo_hash)

mk_topic() {
  local topic="$1" topic_text="$2"
  local td="$CLONE_WARS_HOME/state/$EREPO_HASH/$topic"
  mkdir -p "$td/_consult/design-doc"
  printf '%s' "$topic_text" > "$td/_consult/topic.txt"
  echo "$td/_consult/design-doc"
}

clean_sections() {
  local dd="$1"
  cat > "$dd/architecture.md" <<'MD'
The system is fine.

## Tech Stack
- bash
MD
  echo "components text" > "$dd/components.md"
  echo "data flow text"  > "$dd/data-flow.md"
  echo "errors text"     > "$dd/error-handling.md"
  echo "tests text"      > "$dd/testing.md"
}

# Case 1 — clean: lands at final path, no temp leftover, hash suffix present.
DD1=$(mk_topic consult-orch-clean "orch test topic clean")
clean_sections "$DD1"
OUT_REL=$(cd "$EREPO" && bash "$PLUGIN_ROOT/bin/spec-assemble.sh" consult-orch-clean 2>"$TMP/err1") \
  || { echo "FAIL c1: rc nonzero"; cat "$TMP/err1" >&2; exit 1; }
[[ -f "$EREPO/$OUT_REL" ]] || { echo "FAIL c1: output not at $OUT_REL"; exit 1; }
[[ "$OUT_REL" =~ docs/clone-wars/specs/2026-04-30-orch-clean-[0-9a-f]{6}-design\.md ]] \
  || { echo "FAIL c1: hash suffix not in path: $OUT_REL"; exit 1; }
LEFTOVER=$(find "$EREPO/docs/clone-wars/specs/" -name "*.tmp.*" 2>/dev/null | wc -l)
[[ "$LEFTOVER" -eq 0 ]] || { echo "FAIL c1: $LEFTOVER temp leftover(s)"; exit 1; }
pass "v0.4.2: clean run lands at final path with hash suffix, no temp leftover"

# Case 2 — dirty: NO final file, NO temp leftover.
DD2=$(mk_topic consult-orch-dirty "orch test topic dirty")
clean_sections "$DD2"
echo "TBD: not done yet" >> "$DD2/error-handling.md"
if (cd "$EREPO" && bash "$PLUGIN_ROOT/bin/spec-assemble.sh" consult-orch-dirty) 2>"$TMP/err2"; then
  echo "FAIL c2: dirty run should exit nonzero"; exit 1
fi
# Discover what filename WOULD have been produced.
SLUG2=orch-dirty
HASH2=$(printf '%s' "orch test topic dirty" | sha256sum | cut -c1-6)
EXPECTED="$EREPO/docs/clone-wars/specs/2026-04-30-${SLUG2}-${HASH2}-design.md"
[[ ! -e "$EXPECTED" ]] || { echo "FAIL c2: dirty run left final file at $EXPECTED"; exit 1; }
LEFTOVER2=$(find "$EREPO/docs/clone-wars/specs/" -name "*.tmp.*" 2>/dev/null | wc -l)
[[ "$LEFTOVER2" -eq 0 ]] || { echo "FAIL c2: $LEFTOVER2 temp leftover(s) after dirty"; exit 1; }
pass "v0.4.2: dirty run leaves no final file, no temp leftover"

# Case 3 — rerun-after-fix on the same dirty topic.
clean_sections "$DD2"  # replace the dirty section with clean content
OUT_REL=$(cd "$EREPO" && bash "$PLUGIN_ROOT/bin/spec-assemble.sh" consult-orch-dirty 2>"$TMP/err3") \
  || { echo "FAIL c3: rerun rc nonzero"; cat "$TMP/err3" >&2; exit 1; }
[[ -f "$EREPO/$OUT_REL" ]] || { echo "FAIL c3: rerun output not at final path"; exit 1; }
pass "v0.4.2: rerun-after-fix succeeds (dirty-rerun no longer blocked)"

# Case 4 — filename collision DIFFERENT topic-text on same slug-trunc → different hash.
DD3=$(mk_topic consult-orch-clean-2 "orch test topic clean DIFFERENT TEXT")
clean_sections "$DD3"
OUT_REL2=$(cd "$EREPO" && bash "$PLUGIN_ROOT/bin/spec-assemble.sh" consult-orch-clean-2 2>"$TMP/err4") \
  || { echo "FAIL c4: rc nonzero"; cat "$TMP/err4" >&2; exit 1; }
[[ "$OUT_REL2" != "$OUT_REL" ]] || { echo "FAIL c4: same hash for different topic-text"; exit 1; }
pass "v0.4.2: different topic-text → different hash → different filename"

# v0.10 — Case 5: CW_CONSULT_TARGET_HEADER set → assembled doc has the header
# as the second non-blank line.
DD5=$(mk_topic consult-orch-hub "orch test topic hub mode")
clean_sections "$DD5"
OUT_REL5=$(cd "$EREPO" && CW_CONSULT_TARGET_HEADER="**Target Sub-Project:** ARS-Perfusion" \
  bash "$PLUGIN_ROOT/bin/spec-assemble.sh" consult-orch-hub 2>"$TMP/err5") \
  || { echo "FAIL c5: rc nonzero"; cat "$TMP/err5" >&2; exit 1; }
ASSEMBLED5="$EREPO/$OUT_REL5"
[[ -f "$ASSEMBLED5" ]] || { echo "FAIL c5: output not at $OUT_REL5"; exit 1; }
second_line=$(awk 'NF{n++; if(n==2){print; exit}}' "$ASSEMBLED5")
[[ "$second_line" == "**Target Sub-Project:** ARS-Perfusion" ]] \
  || { echo "FAIL c5: header not at second non-blank line; got '$second_line'" >&2; exit 1; }
pass "v0.10: consult-design-doc prepends Target Sub-Project header when CW_CONSULT_TARGET_HEADER set"

# v0.10 — Case 6: CW_CONSULT_TARGET_HEADER unset → no header in output.
DD6=$(mk_topic consult-orch-nohub "orch test topic no hub mode")
clean_sections "$DD6"
unset CW_CONSULT_TARGET_HEADER
OUT_REL6=$(cd "$EREPO" && bash "$PLUGIN_ROOT/bin/spec-assemble.sh" consult-orch-nohub 2>"$TMP/err6") \
  || { echo "FAIL c6: rc nonzero"; cat "$TMP/err6" >&2; exit 1; }
ASSEMBLED6="$EREPO/$OUT_REL6"
[[ -f "$ASSEMBLED6" ]] || { echo "FAIL c6: output not at $OUT_REL6"; exit 1; }
if grep -q 'Target Sub-Project' "$ASSEMBLED6"; then
  echo "FAIL c6: header should NOT be present when CW_CONSULT_TARGET_HEADER unset" >&2; exit 1
fi
pass "v0.10: consult-design-doc omits header when CW_CONSULT_TARGET_HEADER unset"

# v0.10 — Case 7: invalid slug in CW_CONSULT_TARGET_HEADER → script exits 1.
DD7=$(mk_topic consult-orch-badhdr "orch test topic bad header")
clean_sections "$DD7"
if (cd "$EREPO" && CW_CONSULT_TARGET_HEADER="**Target Sub-Project:** Bad/Slug!" \
    bash "$PLUGIN_ROOT/bin/spec-assemble.sh" consult-orch-badhdr) >"$TMP/out7" 2>"$TMP/err7"; then
  echo "FAIL c7: invalid slug should exit nonzero"; exit 1
fi
grep -q "invalid Target Sub-Project slug" "$TMP/err7" \
  || { echo "FAIL c7: expected slug-validation error in stderr"; cat "$TMP/err7" >&2; exit 1; }
pass "v0.10: consult-design-doc rejects invalid Target Sub-Project slug"
