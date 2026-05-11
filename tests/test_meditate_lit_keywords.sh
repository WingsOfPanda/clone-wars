#!/usr/bin/env bash
# tests/test_meditate_lit_keywords.sh — lit-track keyword classifier
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/meditate.sh"

# ML/SOTA topics should classify ON
for topic in \
  "explore SOTA continuous-batching schedulers" \
  "compare transformer vs mamba architectures" \
  "find new loss functions for retrieval embedding" \
  "survey quantization methods for 8B models" \
  "deep dive on attention mechanism variants"; do
  result=$(cw_meditate_classify_topic "$topic")
  [[ "$result" == "ON" ]] || { echo "FAIL: '$topic' got '$result' expected ON" >&2; exit 1; }
done
pass "5 ML/SOTA topics classify ON"

# Non-ML topics should classify OFF
for topic in \
  "deep dive on Postgres logical replication" \
  "explore database sharding strategies" \
  "compare websocket vs SSE for live updates" \
  "research distributed lock patterns" \
  "think about Kubernetes operator design"; do
  result=$(cw_meditate_classify_topic "$topic")
  [[ "$result" == "OFF" ]] || { echo "FAIL: '$topic' got '$result' expected OFF" >&2; exit 1; }
done
pass "5 non-ML topics classify OFF"

pass "lit-keyword classifier behaves correctly across 10 topics"
