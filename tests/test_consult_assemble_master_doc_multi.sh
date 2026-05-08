#!/usr/bin/env bash
# tests/test_consult_assemble_master_doc_multi.sh
#
# Multi-repo: when _consult/multi-repo.txt = "multi" and targets.txt exists,
# walk-assemble injects:
#   - **Date:** YYYY-MM-DD line after H1
#   - **Target Sub-Project(s):** slug-a, slug-b, slug-c line after Date
#   - ## Execution DAG between Components and Testing
#   - ## Cross-Repo Notes between Execution DAG and Testing
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
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

# H1 + frontmatter ordering.
head -10 "$DD" | head -1 | grep -qE '^# Migrate session storage from postgres to redis$'         || { echo "FAIL: H1 wrong" >&2; exit 1; }
head -10 "$DD" | grep -qE '^\*\*Date:\*\* [0-9]{4}-[0-9]{2}-[0-9]{2}$'                            || { echo "FAIL: Date frontmatter missing" >&2; exit 1; }
head -10 "$DD" | grep -qE '^\*\*Target Sub-Project\(s\):\*\* api-server, auth-service$'           || { echo "FAIL: Target Sub-Project(s) header wrong" >&2; cat "$DD" >&2; exit 1; }

# 8 H2 sections in order.
ACTUAL=$(grep -E '^## ' "$DD")
EXPECTED="## Problem
## Goal
## Architecture
## Components
## Execution DAG
## Cross-Repo Notes
## Testing
## Success Criteria"
[[ "$ACTUAL" == "$EXPECTED" ]] || { echo "FAIL: section order; got=[$ACTUAL]" >&2; exit 1; }

# Per-repo subsections preserved under Architecture.
sed -n '/^## Architecture/,/^## Components/p' "$DD" | grep -qE '^### api-server$'    || { echo "FAIL: ### api-server subsection missing" >&2; exit 1; }
sed -n '/^## Architecture/,/^## Components/p' "$DD" | grep -qE '^### auth-service$'  || { echo "FAIL: ### auth-service subsection missing" >&2; exit 1; }

pass "consult-walk-assemble.sh multi-repo: 8 sections + Target Sub-Project(s) header"
