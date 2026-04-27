#!/usr/bin/env bash
# tests/test_colors.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/colors.sh

# 1. cw_palette_for returns "<primary> <secondary>" for known commanders.
PAL=$(cw_palette_for rex)
[[ "$PAL" =~ ^colour[0-9]+\ colour[0-9]+$ ]] || {
  echo "FAIL: rex palette shape wrong: '$PAL'" >&2; exit 1; }
pass "palette has two colour## tokens"

# 2. Case insensitivity: cw_palette_for accepts uppercase.
PAL_LOWER=$(cw_palette_for rex)
PAL_UPPER=$(cw_palette_for REX)
assert_eq "$PAL_LOWER" "$PAL_UPPER" "rex/REX produce same palette"
pass "palette lookup is case-insensitive"

# 3. Default fallback for unknown commanders.
PAL_UNKNOWN=$(cw_palette_for nosuchcommander)
assert_eq "$PAL_UNKNOWN" "white default" "unknown commander → white default"
pass "default fallback for unknowns"

# 4. cw_color_for returns ONLY the primary (first token).
PRIMARY=$(cw_color_for rex)
[[ "$PRIMARY" =~ ^colour[0-9]+$ ]] || {
  echo "FAIL: rex primary shape wrong: '$PRIMARY'" >&2; exit 1; }
EXPECTED=$(cw_palette_for rex | awk '{print $1}')
assert_eq "$PRIMARY" "$EXPECTED" "primary = first token of palette"
pass "cw_color_for returns the primary"

# 5. cw_rank_for maps known commanders to canonical Star Wars ranks.
assert_eq "$(cw_rank_for rex)" "captain"      "rex is captain"
assert_eq "$(cw_rank_for cody)" "commander"   "cody is commander"
assert_eq "$(cw_rank_for wolffe)" "commander" "wolffe is commander"
assert_eq "$(cw_rank_for jesse)" "sergeant"   "jesse is sergeant"
assert_eq "$(cw_rank_for unknown_name)" "trooper" "unknown name → trooper (default rank)"
pass "rank mapping correct for known + default"

# 6. cw_label_for produces "<rank>-<commander>:<model>:<topic>".
LABEL=$(cw_label_for rex codex auth-review)
assert_eq "$LABEL" "captain-rex:codex:auth-review" "label format"
pass "label_for shape"

# 7. cw_label_fmt produces a tmux #[fg=...] format string with primary,
#    secondary, and the topic in plain text. The actual format wraps
#    rank-commander and model in #[fg=...,bold]...#[default] markers,
#    so the model literal sits between '] ' and '#'.
FMT=$(cw_label_fmt rex codex auth-review)
[[ "$FMT" == *'#[fg=colour'* ]] || { echo "FAIL: label_fmt missing #[fg=...]: '$FMT'" >&2; exit 1; }
[[ "$FMT" == *captain-rex* ]] || { echo "FAIL: label_fmt missing rank-commander: '$FMT'" >&2; exit 1; }
[[ "$FMT" == *']codex#['* ]] || { echo "FAIL: label_fmt model not wrapped between ] and #[: '$FMT'" >&2; exit 1; }
[[ "$FMT" == *auth-review* ]] || { echo "FAIL: label_fmt missing topic: '$FMT'" >&2; exit 1; }
pass "label_fmt contains fg color + rank-commander + wrapped model + topic"

# 8. Palette stability — assert specific colors so a future palette edit
#    can't accidentally change canon-color identity. Reflects the v0.0.6
#    fives+dogma swap (was: fives=103, dogma=67; now: fives=67, dogma=103).
assert_eq "$(cw_palette_for rex | awk '{print $1}')"    "colour110" "rex primary stable"
assert_eq "$(cw_palette_for cody | awk '{print $1}')"   "colour137" "cody primary stable"
assert_eq "$(cw_palette_for wolffe | awk '{print $1}')" "colour104" "wolffe primary stable"
assert_eq "$(cw_palette_for fives | awk '{print $1}')"  "colour67"  "fives primary stable (post-v0.0.6 swap; was 103)"
assert_eq "$(cw_palette_for dogma | awk '{print $1}')"  "colour103" "dogma primary stable (post-v0.0.6 swap; was 67)"
# Visual deduplication: fives must NOT be one-shade-away from wolffe.
[[ "$(cw_color_for fives)" != "colour103" ]] || {
  echo "FAIL: fives reverted to colour103 — visually adjacent to wolffe colour104" >&2; exit 1; }
[[ "$(cw_color_for fives)" != "colour105" ]] || {
  echo "FAIL: fives is now colour105 — visually adjacent to wolffe colour104" >&2; exit 1; }
pass "palette stability + fives/wolffe deduplication"

echo "  ALL: ok"
