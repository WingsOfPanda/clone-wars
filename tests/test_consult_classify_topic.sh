#!/usr/bin/env bash
# tests/test_consult_classify_topic.sh — Task 1 (v0.3.0).
# Validates cw_consult_classify_topic regex discipline.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/consult.sh

# brainstorming triggers — narrow set per Codex M-tier feedback.
# "design" alone is too broad; require "design pattern" or paired phrases.
assert_eq "$(cw_consult_classify_topic 'how should we approach the auth flow')" "brainstorming" "how should"
assert_eq "$(cw_consult_classify_topic 'design pattern review')"                 "brainstorming" "design pattern"
assert_eq "$(cw_consult_classify_topic 'what is the best way to handle X')"      "brainstorming" "best way"
assert_eq "$(cw_consult_classify_topic 'decide between Postgres and Mongo')"     "brainstorming" "decide between"
assert_eq "$(cw_consult_classify_topic 'How Should We Approach This?')"          "brainstorming" "case-insensitive"
pass "brainstorming triggers fire on design-shaped topics (narrow set)"

# systematic-debugging triggers.
assert_eq "$(cw_consult_classify_topic 'why is the consult timing out')"      "systematic-debugging" "why"
assert_eq "$(cw_consult_classify_topic 'find edge cases in the parser')"      "systematic-debugging" "edge case"
assert_eq "$(cw_consult_classify_topic 'login is broken after the merge')"    "systematic-debugging" "broken"
assert_eq "$(cw_consult_classify_topic 'regression in checkout flow')"        "systematic-debugging" "regression"
assert_eq "$(cw_consult_classify_topic 'token-refresh bug fixture')"          "systematic-debugging" "bug"
assert_eq "$(cw_consult_classify_topic 'tests are failing on macOS')"         "systematic-debugging" "failing"
pass "systematic-debugging triggers fire on bug-hunt topics"

# none default — "design" alone, "structure" alone, "approach" alone all → none.
assert_eq "$(cw_consult_classify_topic 'review the auth middleware')"            "none" "plain review"
assert_eq "$(cw_consult_classify_topic 'audit lib/state.sh helpers')"            "none" "audit"
assert_eq "$(cw_consult_classify_topic 'document the IPC protocol')"             "none" "doc task"
assert_eq "$(cw_consult_classify_topic 'review the database structure')"         "none" "structure dropped"
assert_eq "$(cw_consult_classify_topic 'approach to error handling')"            "none" "approach dropped"
assert_eq "$(cw_consult_classify_topic 'design considerations document')"        "none" "design alone dropped"
pass "none is the default for narrow review/audit topics (M-tier refinements)"

# Disambiguation when both word classes appear.
assert_eq "$(cw_consult_classify_topic 'audit the structure for bugs')"          "systematic-debugging" "bug overrides absence of design-pattern"
assert_eq "$(cw_consult_classify_topic 'design pattern of the broken module')"   "brainstorming" "design pattern priority over broken"
pass "M-tier disambiguation: design-pattern wins; bug wins when only debugging matches"

# word-boundary discipline.
assert_eq "$(cw_consult_classify_topic 'designed by Alice last quarter')" "none" "word boundary: designed≠design"
assert_eq "$(cw_consult_classify_topic 'whyever it happened')"            "none" "word boundary: whyever≠why"
assert_eq "$(cw_consult_classify_topic 'debugger output review')"         "none" "word boundary: debugger has no trigger"
pass "word-boundary discipline holds"
