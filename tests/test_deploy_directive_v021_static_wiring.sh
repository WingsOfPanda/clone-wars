#!/usr/bin/env bash
# tests/test_deploy_directive_v021_static_wiring.sh
# Static-wiring asserts on commands/deploy.md for v0.20.1.
# - Frontmatter: allowed-tools includes Skill (NEW v0.20.1)
# - Routing branch present
# - Steps 3a/3b/3c/3d multi-repo headings
# - Step 3b: explicit outer wave loop, build_dag_unit_prompt helper,
#   bin/deploy-wave-wait.sh, "wave" definition, Stage 2 abort via
#   deploy-archive (NOT rm -rf $TOPIC_DIR)
# - Step 3c: writes _deploy/multi-verify-bugs.txt
# - Step 3d: reads _deploy/multi-verify-bugs.txt + MAX_FIX_ROUNDS=3
# - Step 4: multi-repo final-summary loop iterates troopers.txt
# - PREFLIGHT_PANES, dag-waves.txt, Stage 1/2 wording present
# - NEGATIVE: no ACTIVE --design-doc / synthesis.md USAGE
# - NEGATIVE: no bin/deploy-turn-wait.sh in Step 3b/3c/3d
# - NEGATIVE: no literal-placeholder remnants in Step 3b's prompt block
# - NEGATIVE: no rm -rf "$TOPIC_DIR" in Stage 2 abort
# - NEGATIVE: no description='...$ROUND...' single-quote bug
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

DIR=../commands/deploy.md
BODY=$(cat "$DIR")

# Frontmatter
grep -qE '^allowed-tools:.*Skill' "$DIR" \
  || { echo "FAIL: allowed-tools missing Skill (v0.20.1)" >&2; exit 1; }
grep -qE '^allowed-tools:.*AskUserQuestion' "$DIR" \
  || { echo "FAIL: allowed-tools missing AskUserQuestion" >&2; exit 1; }

# Trigger phrases (preserved)
assert_contains "$BODY" "When to use this command" "directive has When-to-use block"
assert_contains "$BODY" "deploy this design"        "directive lists 'deploy this design' trigger"

# Routing branch
assert_contains "$BODY" 'routing.txt'                  "directive reads routing.txt"
assert_contains "$BODY" 'ROUTING == "single-repo"'     "directive branches on single-repo"
assert_contains "$BODY" 'ROUTING == "multi-repo"'      "directive branches on multi-repo"

# Steps 3a/3b/3c/3d
grep -qE '^### Step 3a ' "$DIR" || { echo "FAIL: missing '### Step 3a' heading" >&2; exit 1; }
grep -qE '^### Step 3b ' "$DIR" || { echo "FAIL: missing '### Step 3b' heading" >&2; exit 1; }
grep -qE '^### Step 3c ' "$DIR" || { echo "FAIL: missing '### Step 3c' heading" >&2; exit 1; }
grep -qE '^### Step 3d ' "$DIR" || { echo "FAIL: missing '### Step 3d' heading" >&2; exit 1; }

# v0.20.1 Step 3b additions:
assert_contains "$BODY" "A **wave** is"                          "Step 3b defines 'wave' concept"
grep -qE 'for \(\(w=1; w<=WAVE_COUNT' "$DIR" \
  || { echo "FAIL: Step 3b missing explicit outer wave loop 'for ((w=1; w<=WAVE_COUNT'" >&2; exit 1; }
assert_contains "$BODY" "cw_deploy_build_dag_unit_prompt"        "Step 3b uses build_dag_unit_prompt helper"
assert_contains "$BODY" "bin/deploy-wave-wait.sh"                "Step 3b uses deploy-wave-wait.sh"

# v0.20.1 Step 3b Stage 2 abort: deploy-archive, NOT rm -rf
grep -qE 'deploy-archive\.sh.*"\$TOPIC"' "$DIR" \
  || { echo "FAIL: Stage 2 abort missing deploy-archive.sh call" >&2; exit 1; }
! grep -qE 'rm -rf "\$TOPIC_DIR"' "$DIR" \
  || { echo "FAIL: Stage 2 abort still uses destructive rm -rf \$TOPIC_DIR" >&2; exit 1; }

# v0.20.1 Step 3c writes multi-verify-bugs.txt (≥2 mentions: prose + code)
multi_verify_in_3c=$(awk '/^### Step 3c /,/^### Step 3d /' "$DIR" | grep -c 'multi-verify-bugs.txt' || true)
[[ "$multi_verify_in_3c" -ge 2 ]] || { echo "FAIL: Step 3c missing multi-verify-bugs.txt writer (got $multi_verify_in_3c references)" >&2; exit 1; }

# v0.20.1 Step 3d reads multi-verify-bugs.txt
multi_verify_in_3d=$(awk '/^### Step 3d /,/^### Step 4 /' "$DIR" | grep -c 'multi-verify-bugs.txt' || true)
[[ "$multi_verify_in_3d" -ge 2 ]] || { echo "FAIL: Step 3d missing multi-verify-bugs.txt reader (got $multi_verify_in_3d references)" >&2; exit 1; }

# v0.20.1 Step 4 multi-repo summary loop — checks for the multi-line
# while loop pattern: "while IFS=...read -r CMDR..." appears within
# Step 4, then several lines later "done < ...troopers.txt".
step4_body=$(awk '/^### Step 4 /,/^## / { print }' "$DIR")
echo "$step4_body" | grep -qE 'while IFS=.*read -r CMDR' \
  || { echo "FAIL: Step 4 missing 'while IFS= ... read -r CMDR' loop" >&2; exit 1; }
echo "$step4_body" | grep -qE 'done < .*troopers\.txt' \
  || { echo "FAIL: Step 4 missing 'done < ...troopers.txt' (multi-repo summary loop)" >&2; exit 1; }

# v0.20.1 Step 3d uses MAX_FIX_ROUNDS=3 + AskUserQuestion at cap (preserved)
assert_contains "$BODY" "MAX_FIX_ROUNDS=3"          "directive uses MAX_FIX_ROUNDS=3 cap"
assert_contains "$BODY" "Give up on this sub-repo"  "directive offers 'give up' option at cap"
assert_contains "$BODY" "Escalate to different commander" "directive offers escalate-commander option at cap"

# Preflight + DAG infrastructure (preserved from v0.20.0)
assert_contains "$BODY" "bin/preflight-layout.sh"   "directive references preflight-layout.sh"
assert_contains "$BODY" "--target-pane"             "directive uses --target-pane in spawn calls"
assert_contains "$BODY" "--art-dir"                 "directive uses --art-dir in preflight call"
assert_contains "$BODY" "PREFLIGHT_PANES"           "directive declares PREFLIGHT_PANES array"
assert_contains "$BODY" "dag-waves.txt"             "directive walks dag-waves.txt"
assert_contains "$BODY" "Stage 1 retry-once"        "directive describes Stage 1 retry-once"
assert_contains "$BODY" "Stage 2 partial-success"   "directive describes Stage 2 partial-success"

# v0.20.1 polish: TOPIC_DIR via helper
grep -qE 'TOPIC_DIR=\$\(cw_deploy_topic_dir' "$DIR" \
  || { echo "FAIL: TOPIC_DIR= still string-construction; should use cw_deploy_topic_dir helper" >&2; exit 1; }

# NEGATIVE: no bin/deploy-turn-wait.sh in Steps 3b/3c/3d
multi_turn_wait=$(awk '/^### Step 3b /,/^### Step 4 /' "$DIR" | grep -c 'deploy-turn-wait.sh' || true)
[[ "$multi_turn_wait" -eq 0 ]] || { echo "FAIL: Step 3b/3c/3d still references bin/deploy-turn-wait.sh ($multi_turn_wait times)" >&2; exit 1; }

# NEGATIVE: no literal placeholder remnants in Step 3b's prompt block.
# After v0.20.1 the prompt is built via cw_deploy_build_dag_unit_prompt;
# the literal 'Read /path/to/design-doc. Your sub-repo is "<slug>"'
# placeholder block from v0.20.0 should be gone.
step3b_block=$(awk '/^### Step 3b /,/^### Step 3c /' "$DIR")
if [[ "$step3b_block" == *"Read /path/to/design-doc. Your sub-repo is \"<slug>\""* ]]; then
  echo "FAIL: Step 3b still contains literal '<slug>' placeholder prompt" >&2; exit 1
fi

# NEGATIVE: no ACTIVE --design-doc usage (preserved from v0.20.0)
! grep -qE "find.*synthesis\.md|-o[[:space:]]+-path.*synthesis\.md" "$DIR" \
  || { echo "FAIL: directive has ACTIVE 'find ... synthesis.md' pattern" >&2; exit 1; }
! grep -qE 'consult.*--design-doc|deploy.*--design-doc[^a-zA-Z-]' "$DIR" \
  || { echo "FAIL: directive has ACTIVE --design-doc flag usage" >&2; exit 1; }

# NEGATIVE: line-257 single-quote bug
! grep -qE "description='.*\\\$ROUND" "$DIR" \
  || { echo "FAIL: line-257 single-quote bug still present" >&2; exit 1; }

pass "commands/deploy.md v0.20.1 static wiring complete"
