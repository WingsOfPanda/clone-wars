#!/usr/bin/env bash
# lib/deploy-scope.sh — scope conformance check helpers (v0.30.0 item 4).
#
# Helpers:
#   - cw_deploy_extract_components_paths:      parse design doc Components
#                                              tables for file/dir paths
#   - cw_deploy_match_diff_against_components: compare git diff paths against
#                                              listed paths (directory-prefix)
#
# Sourcing-only file. No top-level side effects.

# cw_deploy_extract_components_paths <design-doc-path>
#
# Reads the design doc, locates the `## Components` section, and extracts
# the first cell of every markdown table within it. Strips backticks and
# trims whitespace. Skips header + separator rows. Skips cells that don't
# look like file/directory paths (heuristic: contains `/` OR matches
# `\.[a-zA-Z]+$`).
#
# Empty stdout when no `## Components` section, no tables in it, or no
# cells match the path heuristic.
#
# rc=0 on success.
# rc=1 if file doesn't exist.
# rc=2 on missing arg.
cw_deploy_extract_components_paths() {
  if (( $# < 1 )); then
    echo "cw_deploy_extract_components_paths: usage: <design-doc-path>" >&2
    return 2
  fi
  local doc="$1"
  [[ -f "$doc" ]] || { echo "cw_deploy_extract_components_paths: file missing: $doc" >&2; return 1; }

  awk '
    /^## Components[[:space:]]*$/ { in_section=1; next }
    /^## [^ ]/ && !/^## Components/ { in_section=0; next }
    in_section && /^[[:space:]]*\|/ {
      # Skip separator rows (only |, -, :, spaces).
      if ($0 ~ /^[[:space:]]*\|([[:space:]]*[:-]+[[:space:]]*\|)+[[:space:]]*$/) next
      # Extract first cell.
      line=$0
      sub(/^[[:space:]]*\|[[:space:]]*/, "", line)
      sub(/[[:space:]]*\|.*$/, "", line)
      gsub(/`/, "", line)
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      # Skip header rows (heuristic: header cells look like words, not paths).
      if (line ~ /^(File|Path|Name|Files?[[:space:]]+(edited|moved|touched))$/) next
      # Path heuristic: must contain / OR end with .ext
      if (line ~ /\// || line ~ /\.[a-zA-Z]+$/) {
        print line
      }
    }
  ' "$doc"
}

# cw_deploy_match_diff_against_components <diff-paths-file> <components-paths-file>
#
# For each path in $diff-paths-file, prints the path to stdout if it is
# OUT of scope per $components-paths-file. In-scope paths are suppressed
# (the empty stdout case = clean deploy).
#
# Match rules (path is in-scope iff any of):
#   1. diff_path == listed_path                                          (exact)
#   2. listed_path ends with "/" AND diff_path starts with listed_path   (explicit dir)
#   3. listed_path does NOT end with "/" AND diff_path starts with
#      listed_path "/"                                                   (implicit dir)
#
# Both files: one path per line. Empty lines + leading/trailing whitespace
# tolerated.
#
# rc=0 on success (empty output = all in-scope; non-empty = out-of-scope list).
# rc=1 if either file doesn't exist.
# rc=2 on missing args.
cw_deploy_match_diff_against_components() {
  if (( $# < 2 )); then
    echo "cw_deploy_match_diff_against_components: usage: <diff-paths-file> <components-paths-file>" >&2
    return 2
  fi
  local diff_file="$1" comp_file="$2"
  [[ -f "$diff_file" ]] || { echo "cw_deploy_match_diff_against_components: missing $diff_file" >&2; return 1; }
  [[ -f "$comp_file" ]] || { echo "cw_deploy_match_diff_against_components: missing $comp_file" >&2; return 1; }

  awk -v COMP_FILE="$comp_file" '
    BEGIN {
      n = 0
      while ((getline line < COMP_FILE) > 0) {
        sub(/^[[:space:]]+/, "", line)
        sub(/[[:space:]]+$/, "", line)
        if (line == "") continue
        comp[n++] = line
      }
      close(COMP_FILE)
    }
    {
      path = $0
      sub(/^[[:space:]]+/, "", path)
      sub(/[[:space:]]+$/, "", path)
      if (path == "") next
      in_scope = 0
      for (i = 0; i < n; i++) {
        c = comp[i]
        if (path == c) { in_scope = 1; break }
        if (substr(c, length(c), 1) == "/" && index(path, c) == 1) { in_scope = 1; break }
        if (substr(c, length(c), 1) != "/" && index(path, c "/") == 1) { in_scope = 1; break }
      }
      if (!in_scope) print path
    }
  ' "$diff_file"
}
