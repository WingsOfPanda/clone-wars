#!/usr/bin/env bash
# tests/test_consult_assemble_master_doc.sh
# bin/consult-walk-assemble.sh master-doc assembly modes.
# 3 cases: single-repo (6 sections, no Target Sub-Project header),
#          multi-repo (8 sections + plural Target Sub-Project(s) header),
#          single-sub (6 sections + singular Target Sub-Project header).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')

# Standard 6 sections used by all cases.
seed_six_sections() {
  local draft=$1
  printf '## Problem\n\nAPI reads from postgres on every request, p99 = 220ms.\n' > "$draft/problem.md"
  printf '## Goal\n\nDrop p99 to <50ms by caching session reads in Redis.\n'      > "$draft/goal.md"
  printf '## Architecture\n\nIntroduce a redis-py client with TTL=300s.\n'        > "$draft/architecture.md"
  printf '## Components\n\n- src/cache.py (new)\n- src/api.py (modified)\n'       > "$draft/components.md"
  printf '## Testing\n\n- redis-py mock in unit tests\n- real redis in integration\n' > "$draft/testing.md"
  printf '## Success Criteria\n\n- [ ] p99 read latency < 50ms\n- [ ] cache hit rate > 80%%\n' > "$draft/success-criteria.md"
}

# --- Case 1: single-repo mode ---
TOPIC=consult-asm-single-test
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
DR="$TD/_consult/design-doc/.draft"
mkdir -p "$DR"
echo "Add Redis caching to API layer" > "$TD/_consult/topic.txt"
seed_six_sections "$DR"

DD_PATH=$(../bin/consult-walk-assemble.sh "$TOPIC")
[[ "$DD_PATH" =~ /design-doc/[0-9]{4}-[0-9]{2}-[0-9]{2}-asm-single-test-design\.md$ ]] \
  || { echo "FAIL: single path doesn't match canonical pattern: $DD_PATH" >&2; exit 1; }
assert_file_exists "$DD_PATH" "single: design-doc written"
head -1 "$DD_PATH" | grep -qE '^# Add Redis caching to API layer$' \
  || { echo "FAIL: single H1 not derived from topic.txt; got: $(head -1 "$DD_PATH")" >&2; exit 1; }
ACTUAL=$(grep -E '^## ' "$DD_PATH")
[[ "$ACTUAL" == "## Problem
## Goal
## Architecture
## Components
## Testing
## Success Criteria" ]] || { echo "FAIL: single section order: $ACTUAL" >&2; exit 1; }
grep -qE '\*\*Target Sub-Project' "$DD_PATH" \
  && { echo "FAIL: single-repo doc has Target Sub-Project header" >&2; exit 1; } || true

# Skipped sections are tolerated.
rm "$DD_PATH"
printf '_(skipped)_\n' > "$DR/components.md"
DD_PATH2=$(../bin/consult-walk-assemble.sh "$TOPIC")
grep -qE '_\(skipped\)_' "$DD_PATH2" \
  || { echo "FAIL: skipped marker missing in body" >&2; exit 1; }
pass "1. single-repo: 6 sections concatenated, no Target Sub-Project, skipped marker tolerated"

# --- Case 2: multi-repo mode ---
TOPIC=consult-asm-multi-test
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
DR="$TD/_consult/design-doc/.draft"
mkdir -p "$DR" "$TMP/hub/api-server" "$TMP/hub/auth-service"
touch "$TMP/hub/api-server/CLAUDE.md" "$TMP/hub/auth-service/CLAUDE.md"
echo "Migrate session storage from postgres to redis" > "$TD/_consult/topic.txt"
printf 'multi\n' > "$TD/_consult/multi-repo.txt"
{
  printf '# generated 2026-05-08T10:00:00Z by bin/consult-init.sh --targets\n'
  printf 'api-server\t%s/hub/api-server/CLAUDE.md\n' "$TMP"
  printf 'auth-service\t%s/hub/auth-service/CLAUDE.md\n' "$TMP"
} > "$TD/_consult/targets.txt"

# Stage 8 approved drafts (6 base + execution-dag + cross-repo-notes).
printf '## Problem\n\nSession reads on every request.\n' > "$DR/problem.md"
printf '## Goal\n\nSub-50ms session reads.\n' > "$DR/goal.md"
printf '## Architecture\n\n### api-server\n\nUse redis-py client.\n\n### auth-service\n\nMigrate writes too.\n' > "$DR/architecture.md"
printf '## Components\n\n- api-server/cache.py\n- auth-service/storage.py\n' > "$DR/components.md"
printf '## Execution DAG\n\n1. auth-service — migrate write path\n2. api-server — switch read path (depends on 1)\n' > "$DR/execution-dag.md"
printf '## Cross-Repo Notes\n\nauth-service must roll out before api-server.\n' > "$DR/cross-repo-notes.md"
printf '## Testing\n\nIntegration tests cover both repos.\n' > "$DR/testing.md"
printf '## Success Criteria\n\n- [ ] p99 < 50ms\n' > "$DR/success-criteria.md"

DD=$(../bin/consult-walk-assemble.sh "$TOPIC")
head -10 "$DD" | head -1 | grep -qE '^# Migrate session storage from postgres to redis$' \
  || { echo "FAIL: multi H1 wrong" >&2; exit 1; }
head -10 "$DD" | grep -qE '^\*\*Date:\*\* [0-9]{4}-[0-9]{2}-[0-9]{2}$' \
  || { echo "FAIL: multi Date frontmatter missing" >&2; exit 1; }
head -10 "$DD" | grep -qE '^\*\*Target Sub-Project\(s\):\*\* api-server, auth-service$' \
  || { echo "FAIL: multi Target Sub-Project(s) header wrong" >&2; cat "$DD" >&2; exit 1; }
ACTUAL=$(grep -E '^## ' "$DD")
EXPECTED="## Problem
## Goal
## Architecture
## Components
## Execution DAG
## Cross-Repo Notes
## Testing
## Success Criteria"
[[ "$ACTUAL" == "$EXPECTED" ]] || { echo "FAIL: multi section order: $ACTUAL" >&2; exit 1; }
sed -n '/^## Architecture/,/^## Components/p' "$DD" | grep -qE '^### api-server$' \
  || { echo "FAIL: ### api-server subsection missing" >&2; exit 1; }
sed -n '/^## Architecture/,/^## Components/p' "$DD" | grep -qE '^### auth-service$' \
  || { echo "FAIL: ### auth-service subsection missing" >&2; exit 1; }
pass "2. multi-repo: 8 sections + plural Target Sub-Project(s) header + per-repo subsections"

# --- Case 3: single-sub mode ---
TOPIC=consult-asm-single-sub-test
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
DR="$TD/_consult/design-doc/.draft"
mkdir -p "$DR"
echo "Move frame selection BEFORE motion correction in arsperfusion CTP pipeline" \
  > "$TD/_consult/topic.txt"
printf '## Problem\n\nStep 2 motion-corrects 30 frames when halftime only needs 9.\n' > "$DR/problem.md"
printf '## Goal\n\nDrop motion-correction wall-clock from 30s to ~10s in halftime mode.\n' > "$DR/goal.md"
printf '## Architecture\n\nPre-select frames after DICOM load when ctp_protocol in {halftime, two_phase}.\n' > "$DR/architecture.md"
printf '## Components\n\n- arsperfusion/construct/engine.py (modified)\n' > "$DR/components.md"
printf '## Testing\n\n- arsperfusion unit tests + AD0332-T3-0001 reference dataset\n' > "$DR/testing.md"
printf '## Success Criteria\n\n- [ ] halftime motion-correction wall-clock < 12s\n- [ ] TTP regression resolved\n' > "$DR/success-criteria.md"
printf 'single-sub\n' > "$TD/_consult/multi-repo.txt"
printf '# generated %s by test\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TD/_consult/targets.txt"
printf 'arsperfusion\t%s/hub/arsperfusion/CLAUDE.md\n' "$TMP" >> "$TD/_consult/targets.txt"

DD_PATH=$(../bin/consult-walk-assemble.sh "$TOPIC")
assert_file_exists "$DD_PATH" "single-sub: design-doc written"
grep -qE '^\*\*Target Sub-Project:\*\* arsperfusion$' "$DD_PATH" \
  || { echo "FAIL: single-sub singular Target Sub-Project header missing; head:" >&2; head -5 "$DD_PATH" >&2; exit 1; }
grep -qE '^\*\*Target Sub-Project\(s\):\*\*' "$DD_PATH" \
  && { echo "FAIL: single-sub has plural Target Sub-Project(s) header" >&2; exit 1; } || true
ACTUAL=$(grep -E '^## ' "$DD_PATH")
[[ "$ACTUAL" == "## Problem
## Goal
## Architecture
## Components
## Testing
## Success Criteria" ]] || { echo "FAIL: single-sub section order: $ACTUAL" >&2; exit 1; }
assert_file_exists "$TD/_consult/design-doc/audit.log" "single-sub: audit.log written"
grep -q '^VERDICT=PASS' "$TD/_consult/design-doc/audit.log" \
  || { echo "FAIL: single-sub audit did not pass; audit.log:" >&2; cat "$TD/_consult/design-doc/audit.log" >&2; exit 1; }
pass "3. single-sub: singular Target Sub-Project header + 6 sections + audit PASS"

echo "test_consult_assemble_master_doc: 3 cases passed"
