#!/usr/bin/env bash
# tests/test_consult_synthesize_per_section_drafts.sh
#
# v0.17.0: bin/consult-synthesize.sh produces seed drafts under
# _consult/design-doc/.draft/{problem,goal,architecture,components,testing,success-criteria}.md
# from the adjudicated.md content. It does NOT emit a final design doc;
# that's bin/consult-walk-assemble.sh's job.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=consult-fixture-syn-v17
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_consult/design-doc/.draft"

echo "v0.17 seed-draft synthesis test" > "$TD/_consult/topic.txt"
cat > "$TD/_consult/troopers.txt" <<EOF
codex	rex
claude	cody
EOF

# Stage minimum prerequisites: stage status files for both research and verify.
for stage in research verify; do
  for cmdr in rex cody; do
    cat > "$TD/_consult/$stage-$cmdr.txt" <<EOF
OFFSET=0
$( [[ "$stage" == research ]] && echo FS=ok || echo VS=ok )
EOF
  done
done

# Stage adjudicated.md with cross-verified content covering each section
# topic (synthesize uses heuristics to map content to sections).
cat > "$TD/_consult/adjudicated.md" <<'MD'
## Cross-verified
- [src/auth.py:42] Session storage uses postgres `sessions` table currently. — verified
- [Goal] Migrate to redis-backed session storage with TTL = 24h. — both agree
- [Architecture] Use redis-py with connection pool sized to 20. — both agree
- [Components] auth-service/middleware.py + api-server/session_loader.py. — both agree
- [Testing] redis-py mock in unit tests, real redis in integration. — both agree
- [Success Criteria] p99 session-read latency < 5ms. — both agree

## Adjudicated

## Contested

## Not-verified
MD

# Stage diff.md with an Agreed section.
cat > "$TD/_consult/diff.md" <<'MD'
## Agreed
- [overlap] postgres → redis migration is the goal
## Rex-only
## Cody-only
MD

# Run synthesize.
../bin/consult-synthesize.sh "$TOPIC" >/dev/null

# Each of the 6 single-repo sections must have a seed draft file.
for section in problem goal architecture components testing success-criteria; do
  assert_file_exists "$TD/_consult/design-doc/.draft/$section.md" "$section seed draft exists"
  body=$(cat "$TD/_consult/design-doc/.draft/$section.md")
  [[ -n "$body" ]] || { echo "FAIL: $section seed draft is empty" >&2; exit 1; }
done

# v0.17 negative: NO final design-doc emitted by synthesize.
DD=$(find "$TD/_consult/design-doc" -maxdepth 1 -name '*-design.md' 2>/dev/null | head -1)
[[ -z "$DD" ]] || { echo "FAIL: synthesize emitted final design doc $DD (should be walk-assemble's job)" >&2; exit 1; }

# v0.17 negative: NO synthesis.md (legacy v0.12 file).
[[ ! -f "$TD/_consult/synthesis.md" ]] || { echo "FAIL: legacy synthesis.md still emitted" >&2; exit 1; }

pass "v0.17.0 consult-synthesize.sh emits per-section seed drafts only"
