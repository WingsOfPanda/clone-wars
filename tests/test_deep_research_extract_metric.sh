#!/usr/bin/env bash
# tests/test_deep_research_extract_metric.sh — heuristic metric extractor
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

# Direct keyword hits
got=$(cw_deep_research_extract_metric "optimize MNIST accuracy under 100k params")
[[ "$got" == "accuracy" ]] || { echo "FAIL: expected accuracy, got '$got'" >&2; exit 1; }
pass "extracts 'accuracy'"

got=$(cw_deep_research_extract_metric "minimize p99 latency for endpoint")
[[ "$got" == "latency" ]] || { echo "FAIL: expected latency, got '$got'" >&2; exit 1; }
pass "extracts 'latency'"

got=$(cw_deep_research_extract_metric "reduce model loss")
[[ "$got" == "loss" ]] || { echo "FAIL: expected loss, got '$got'" >&2; exit 1; }
pass "extracts 'loss'"

got=$(cw_deep_research_extract_metric "maximize throughput on the API")
[[ "$got" == "throughput" ]] || { echo "FAIL: expected throughput, got '$got'" >&2; exit 1; }
pass "extracts 'throughput'"

# Whole-word: 'paramsy' should NOT match 'params'
got=$(cw_deep_research_extract_metric "test paramsy thing")
[[ -z "$got" ]] || { echo "FAIL: substring match (paramsy → params); got '$got'" >&2; exit 1; }
pass "whole-word: 'paramsy' does not match 'params'"

# Ambiguous → empty
got=$(cw_deep_research_extract_metric "explore SOTA continuous-batching schedulers")
[[ -z "$got" ]] || { echo "FAIL: ambiguous expected empty, got '$got'" >&2; exit 1; }
pass "ambiguous topic returns empty"

# Multi-candidate: first by position wins
got=$(cw_deep_research_extract_metric "minimize cost while maximizing accuracy")
[[ "$got" == "cost" ]] || { echo "FAIL: expected 'cost' (first by position), got '$got'" >&2; exit 1; }
pass "first-by-position wins (cost before accuracy)"

# Empty input → empty
got=$(cw_deep_research_extract_metric "")
[[ -z "$got" ]] || { echo "FAIL: empty input expected empty, got '$got'" >&2; exit 1; }
pass "empty input returns empty"

# Case insensitive
got=$(cw_deep_research_extract_metric "MAXIMIZE F1 SCORE")
[[ "$got" == "f1" ]] || { echo "FAIL: case-insensitive expected f1, got '$got'" >&2; exit 1; }
pass "case-insensitive match"

echo "test_deep_research_extract_metric: 9 assertions green"
