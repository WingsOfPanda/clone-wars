#!/usr/bin/env bash
# bin/deploy-dag-parse.sh — parse a multi-repo design doc's "## Execution DAG"
# section into TSV files for the v0.20.0 multi-repo deploy flow.
#
# Usage: bin/deploy-dag-parse.sh <design-doc-path> <out-dir>
#
# Writes:
#   <out-dir>/dag-waves.txt — TSV: <wave>\t<step>\t<repo>\t<path|none>\t<desc> per line  (v0.21.0: 5-field; was 4-field)
#   <out-dir>/dag-edges.txt — TSV: <from-step>\t<to-step> per line
#
# rc=0 on success; rc=1 on:
#   - missing/unreadable doc
#   - missing "## Execution DAG" section
#   - malformed prose line (delegated to cw_deploy_dag_parse_line)
#   - cycle detected (delegated to cw_deploy_dag_topological)
# rc=2 on bad args.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deploy-dag.sh"

[[ $# -eq 2 ]] || { echo "Usage: $0 <design-doc-path> <out-dir>" >&2; exit 2; }
DOC="$1"
OUT_DIR="$2"

[[ -f "$DOC" && -r "$DOC" ]] || { log_error "design doc unreadable: $DOC"; exit 1; }
[[ -d "$OUT_DIR" ]] || { log_error "out-dir does not exist: $OUT_DIR"; exit 1; }

# Extract "## Execution DAG" section — lines after "## Execution DAG" until
# the next "^## " heading (or EOF).
DAG_SECTION=$(awk '
  /^## Execution DAG[[:space:]]*$/ { in_dag=1; next }
  /^## / { in_dag=0 }
  in_dag { print }
' "$DOC")

[[ -n "$DAG_SECTION" ]] || { log_error "design doc missing '## Execution DAG' section"; exit 1; }

WAVES_TMP=$(mktemp)
EDGES_TMP=$(mktemp)
ROWS_TMP=$(mktemp)
trap 'rm -f "$WAVES_TMP" "$EDGES_TMP" "$ROWS_TMP"' EXIT

# Collect ordered (step, repo, desc, deps) rows + edges. Bail on any malformed line
# that LOOKS LIKE a DAG line (starts with digit + period) but doesn't parse.
NODES=()
while IFS= read -r line; do
  [[ -z "${line// }" ]] && continue
  # Only attempt to parse lines that look like DAG entries.
  [[ "$line" =~ ^[[:space:]]*[0-9]+\. ]] || continue
  ROW=$(cw_deploy_dag_parse_line "$line") || exit 1
  printf '%s\n' "$ROW" >> "$ROWS_TMP"
  IFS=$'\t' read -r step repo path desc deps <<<"$ROW"
  NODES+=( "$step" )
  if [[ "$deps" != "none" && -n "$deps" ]]; then
    IFS=',' read -ra dep_arr <<<"$deps"
    for d in "${dep_arr[@]}"; do
      [[ -n "$d" ]] && printf '%s\t%s\n' "$d" "$step" >> "$EDGES_TMP"
    done
  fi
done <<< "$DAG_SECTION"

[[ ${#NODES[@]} -gt 0 ]] || { log_error "no DAG lines parsed from '## Execution DAG' section"; exit 1; }

TOPO_TMP=$(mktemp)
cw_deploy_dag_topological "$EDGES_TMP" "${NODES[@]}" > "$TOPO_TMP" || { rm -f "$TOPO_TMP"; exit 1; }

declare -A STEP_TO_ROW
while IFS=$'\t' read -r step repo path desc deps; do
  # v0.21.0: STEP_TO_ROW carries 3 fields (repo\tpath\tdesc) so the final
  # waves TSV is 5-field <wave>\t<step>\t<repo>\t<path>\t<desc>.
  STEP_TO_ROW["$step"]="$repo"$'\t'"$path"$'\t'"$desc"
done < "$ROWS_TMP"

while IFS=$'\t' read -r wave step; do
  printf '%s\t%s\t%s\n' "$wave" "$step" "${STEP_TO_ROW[$step]}" >> "$WAVES_TMP"
done < "$TOPO_TMP"
rm -f "$TOPO_TMP"

mv "$WAVES_TMP" "$OUT_DIR/dag-waves.txt" || { log_error "mv dag-waves.txt failed"; exit 1; }
mv "$EDGES_TMP" "$OUT_DIR/dag-edges.txt" || { log_error "mv dag-edges.txt failed"; exit 1; }

log_ok "deploy-dag-parse: ${#NODES[@]} nodes parsed; waves at $OUT_DIR/dag-waves.txt, edges at $OUT_DIR/dag-edges.txt"
exit 0
