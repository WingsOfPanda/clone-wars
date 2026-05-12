# lib/deep-research.sh — helpers for /clone-wars:deep-research.
# Sourced. Depends on lib/log.sh, lib/state.sh, lib/consult.sh, lib/commanders.sh.
#
# Public:
#   cw_deep_research_compute_per_branch_timeout <total-s> <rounds> <K>
#       — ceiling-divide total budget across (rounds * K) branches
#   cw_deep_research_extract_metric <topic-text>
#       — heuristic metric name extraction; empty string if ambiguous
#   cw_deep_research_validate_result_json <relative-path>
#       — schema check; rc=0 valid; rc>0 invalid (stderr); call from branch dir
#   cw_deep_research_extract_approaches <landscape-md-path>
#       — TSV "label\tbrief\n" from meditate landscape ## Approaches section
#   cw_deep_research_allocate_commanders <round> <K>
#       — K codex-eligible commanders, mod-rotated per round (deterministic)
#   cw_deep_research_check_convergence <slug> <round>
#       — rc=0 if delta<1% vs prior round; rc=1 otherwise

# cw_deep_research_compute_per_branch_timeout <total-s> <rounds> <K>
# Ceiling-divide total wall-clock budget across all planned branches.
# Errors with rc=2 if any arg is non-positive integer.
cw_deep_research_compute_per_branch_timeout() {
  local total="${1:-}" rounds="${2:-}" k="${3:-}"
  [[ "$total" =~ ^[1-9][0-9]*$ ]] || { echo "total must be positive integer" >&2; return 2; }
  [[ "$rounds" =~ ^[1-9][0-9]*$ ]] || { echo "rounds must be positive integer" >&2; return 2; }
  [[ "$k" =~ ^[1-9][0-9]*$ ]] || { echo "K must be positive integer" >&2; return 2; }
  local total_branches=$((rounds * k))
  local result=$(( (total + total_branches - 1) / total_branches ))
  printf '%d\n' "$result"
}
