#!/usr/bin/env bash
# tests/test_consult_assemble_master_doc_single.sh
#
# bin/consult-walk-assemble.sh <topic>
# In single-repo mode (no multi-repo.txt OR contents="single"), reads:
#   _consult/design-doc/.draft/{problem,goal,architecture,components,
#                              testing,success-criteria}.md
# and concatenates them into:
#   _consult/design-doc/<YYYY-MM-DD>-<slug>-design.md
# with an H1 derived from topic.txt's first line.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=consult-asm-single-test
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
DR="$TD/_consult/design-doc/.draft"
mkdir -p "$DR"

echo "Add Redis caching to API layer" > "$TD/_consult/topic.txt"

# Stage 6 approved sections.
printf '## Problem\n\nAPI reads from postgres on every request, p99 = 220ms.\n' > "$DR/problem.md"
printf '## Goal\n\nDrop p99 to <50ms by caching session reads in Redis.\n' > "$DR/goal.md"
printf '## Architecture\n\nIntroduce a redis-py client with TTL=300s.\n' > "$DR/architecture.md"
printf '## Components\n\n- src/cache.py (new)\n- src/api.py (modified)\n' > "$DR/components.md"
printf '## Testing\n\n- redis-py mock in unit tests\n- real redis in integration\n' > "$DR/testing.md"
printf '## Success Criteria\n\n- [ ] p99 read latency < 50ms\n- [ ] cache hit rate > 80%%\n' > "$DR/success-criteria.md"

# Run.
DD_PATH=$(../bin/consult-walk-assemble.sh "$TOPIC")

# Path matches canonical pattern.
[[ "$DD_PATH" =~ /design-doc/[0-9]{4}-[0-9]{2}-[0-9]{2}-asm-single-test-design\.md$ ]] \
  || { echo "FAIL: path doesn't match canonical pattern: $DD_PATH" >&2; exit 1; }
assert_file_exists "$DD_PATH" "design-doc written"

# H1 reflects topic.txt.
head -1 "$DD_PATH" | grep -qE '^# Add Redis caching to API layer$' \
  || { echo "FAIL: H1 not derived from topic.txt; got: $(head -1 "$DD_PATH")" >&2; exit 1; }

# All 6 sections present in correct order.
ACTUAL_ORDER=$(grep -E '^## ' "$DD_PATH")
[[ "$ACTUAL_ORDER" == "## Problem
## Goal
## Architecture
## Components
## Testing
## Success Criteria" ]] || { echo "FAIL: section order wrong; got: $ACTUAL_ORDER" >&2; exit 1; }

# No multi-repo header in single-repo mode.
grep -qE '\*\*Target Sub-Project' "$DD_PATH" && { echo "FAIL: single-repo doc has Target Sub-Project header" >&2; exit 1; } || true

# Skipped sections are tolerated.
rm "$DD_PATH"
printf '_(skipped)_\n' > "$DR/components.md"
DD_PATH2=$(../bin/consult-walk-assemble.sh "$TOPIC")
grep -qE '_\(skipped\)_'   "$DD_PATH2"  || { echo "FAIL: skipped marker missing in body" >&2; exit 1; }

pass "consult-walk-assemble.sh single-repo: 6 sections concatenated in order"
