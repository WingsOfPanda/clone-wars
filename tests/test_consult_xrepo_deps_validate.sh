#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/state.sh
source ../lib/consult.sh

TMPROOT=$(mktemp -d -t cw-xrepo.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT
ART="$TMPROOT/_consult"; mkdir -p "$ART"
printf '%s\n' "hub/A" "hub/B" "hub/C" | cw_consult_targets_persist "$ART"

# (a) Happy
cat > "$TMPROOT/x1.md" <<'X'
| Producer | Artifact | Consumer | Type |
|----------|----------|----------|------|
| A | foo.yaml | B | internal |
| ext-svc | token | C | external |
X
cw_consult_xrepo_deps_validate "$ART" < "$TMPROOT/x1.md" || { echo "FAIL (a)"; exit 1; }
pass "(a) happy"

# (b) Header missing
cat > "$TMPROOT/x2.md" <<'X'
| A | foo.yaml | B | internal |
X
err=$(cw_consult_xrepo_deps_validate "$ART" < "$TMPROOT/x2.md" 2>&1) && { echo "FAIL (b)"; exit 1; } || true
grep -qi 'header' <<< "$err" || { echo "FAIL (b) msg: $err"; exit 1; }
pass "(b) header missing rejected"

# (c) Wrong column count
cat > "$TMPROOT/x3.md" <<'X'
| Producer | Artifact | Consumer | Type |
|----------|----------|----------|------|
| A | foo | B |
X
err=$(cw_consult_xrepo_deps_validate "$ART" < "$TMPROOT/x3.md" 2>&1) && { echo "FAIL (c)"; exit 1; } || true
grep -qi 'column' <<< "$err" || { echo "FAIL (c)"; exit 1; }
pass "(c) wrong column count rejected"

# (d) Type='maybe'
cat > "$TMPROOT/x4.md" <<'X'
| Producer | Artifact | Consumer | Type |
|----------|----------|----------|------|
| A | foo | B | maybe |
X
err=$(cw_consult_xrepo_deps_validate "$ART" < "$TMPROOT/x4.md" 2>&1) && { echo "FAIL (d)"; exit 1; } || true
grep -qi "Type=" <<< "$err" || { echo "FAIL (d)"; exit 1; }
pass "(d) bad Type rejected"

# (e) internal Producer not in targets
cat > "$TMPROOT/x5.md" <<'X'
| Producer | Artifact | Consumer | Type |
|----------|----------|----------|------|
| Z | foo | B | internal |
X
err=$(cw_consult_xrepo_deps_validate "$ART" < "$TMPROOT/x5.md" 2>&1) && { echo "FAIL (e)"; exit 1; } || true
grep -qi "Producer 'Z'" <<< "$err" || { echo "FAIL (e) msg: $err"; exit 1; }
pass "(e) non-target internal Producer rejected"
