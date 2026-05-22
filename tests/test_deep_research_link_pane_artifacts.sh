#!/usr/bin/env bash
# tests/test_deep_research_link_pane_artifacts.sh — v0.52.0 #20
# Validates cw_deep_research_link_pane_artifacts: creates relative
# symlinks from <art-dir>/troopers/<cmdr>/{outbox.jsonl,inbox.md} to
# the pane dir at <topic-dir>/<cmdr>-codex/{outbox.jsonl,inbox.md}.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

TD="$TMP/topic"
ART="$TD/_deep-research"
mkdir -p "$ART/troopers/rex" "$ART/troopers/keeli" "$ART/troopers/colt"
mkdir -p "$TD/rex-codex" "$TD/keeli-codex" "$TD/colt-codex"
printf '%s\n' rex keeli colt > "$ART/troopers.txt"
for c in rex keeli colt; do
  echo "{\"event\":\"ready\",\"commander\":\"$c\"}" > "$TD/$c-codex/outbox.jsonl"
  echo "inbox text for $c" > "$TD/$c-codex/inbox.md"
done

# Case 1: 3 troopers, 3 outbox + 3 inbox → 6 relative symlinks
cw_deep_research_link_pane_artifacts "$ART" "$TD"

for c in rex keeli colt; do
  for f in outbox.jsonl inbox.md; do
    link="$ART/troopers/$c/$f"
    [[ -L "$link" ]] || { echo "FAIL case1: $link not a symlink" >&2; exit 1; }
    target=$(readlink "$link")
    # Relative (must not start with /)
    case "$target" in
      /*) echo "FAIL case1: $link target is absolute: $target" >&2; exit 1 ;;
    esac
    # Resolves to the pane file
    resolved=$(cd "$(dirname "$link")" && realpath "$target")
    expected=$(realpath "$TD/$c-codex/$f")
    assert_eq "$resolved" "$expected" "case1: $c/$f resolves to pane file"
  done
done
pass "case1: 6 relative symlinks created"

# Case 2: idempotent — run twice, still 6 symlinks, no errors
cw_deep_research_link_pane_artifacts "$ART" "$TD"
for c in rex keeli colt; do
  for f in outbox.jsonl inbox.md; do
    [[ -L "$ART/troopers/$c/$f" ]] || { echo "FAIL case2: $c/$f missing after re-run" >&2; exit 1; }
  done
done
pass "case2: idempotent across reruns"

# Case 3: missing pane outbox → log_warn, no symlink, other 5 still made
rm -f "$TD/rex-codex/outbox.jsonl"
rm -f "$ART/troopers/rex/outbox.jsonl"
cw_deep_research_link_pane_artifacts "$ART" "$TD" 2>"$TMP/link-case3.log"
warn_out=$(cat "$TMP/link-case3.log")
[[ ! -e "$ART/troopers/rex/outbox.jsonl" ]] \
  || { echo "FAIL case3: rex/outbox.jsonl should not exist" >&2; exit 1; }
[[ -L "$ART/troopers/rex/inbox.md" ]] \
  || { echo "FAIL case3: rex/inbox.md should still be a symlink" >&2; exit 1; }
assert_contains "$warn_out" "rex" "case3: warn mentions rex"
pass "case3: missing pane outbox skipped with warn"

echo "ALL: ok"
