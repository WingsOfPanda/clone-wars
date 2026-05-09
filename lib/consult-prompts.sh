# lib/consult-prompts.sh — prompt template loaders + builders.
# Sourced by lib/consult.sh shim. Depends on lib/log.sh; reads templates from
# $CLAUDE_PLUGIN_ROOT/config/prompt-templates/consult/.

# cw_consult_strip_block <begin-regex> <end-regex>
# Reads stdin, drops lines between (and including) the first match of
# begin-regex through the first subsequent match of end-regex, plus one
# trailing line (the consumed terminator). Used by template-builder helpers
# to remove sentinel-bracketed optional blocks while preserving byte-equality
# with v0.4.2 baselines for the empty-input case.
cw_consult_strip_block() {
  local begin_re="$1" end_re="$2"
  awk -v b="$begin_re" -v e="$end_re" '
    $0 ~ b               { skipping=1; next }
    skipping && $0 ~ e   { skipping=0; getline; next }
    !skipping            { print }
  '
}

# cw_consult_build_verify_prompt <items_file> <write_to>
# Build the verify-round prompt body. Reads <items_file> (one `[cite] text` per
# line) and emits a self-contained instruction, terminated by END_OF_INSTRUCTION.
# Prompts are uniform across cwd (v0.14.0 dropped the per-sub-project block).
cw_consult_build_verify_prompt() {
  local items_file="$1" write_to="$2"
  local items
  items=$(nl -ba -w1 -s'. ' "$items_file")
  local out
  out=$(cw_consult_load_prompt consult/verify.md \
          "ITEMS=$items" "WRITE_TO=$write_to" \
          "TARGETS_BLOCK_START=" "TARGETS_BLOCK_END=" \
          "TARGETS=")
  # Strip the per-sub-project sentinel block to preserve v0.4.2 byte-equality.
  # The sentinels render as empty inline tokens; the strip range brackets the
  # H2 heading through the line ending "verify pass downstream." and the
  # trailing-line consume absorbs the blank that follows.
  printf '%s\n' "$out" | cw_consult_strip_block '^## Per-sub-project structure$' '^verify pass downstream\\.$'
}

# cw_consult_build_research_prompt <topic> <write_to>
# Build the research-round prompt body. Emits a self-contained instruction
# with the required Findings structure and citation rules, terminated by
# END_OF_INSTRUCTION.
# Prompts are uniform across cwd (v0.14.0 dropped the per-sub-project block).
cw_consult_build_research_prompt() {
  local topic="$1" write_to="$2"
  local out
  out=$(cw_consult_load_prompt consult/research.md \
          "TOPIC=$topic" "WRITE_TO=$write_to" \
          "TARGETS_BLOCK_START=" "TARGETS_BLOCK_END=" \
          "TARGETS=")
  # Strip the per-sub-project sentinel block (see verify builder for rationale).
  printf '%s\n' "$out" | cw_consult_strip_block '^## Per-sub-project structure$' '^verify pass downstream\\.$'
}

# cw_consult_design_doc_drilldown_prompt <section> <design-doc-path> <commander> <dd-dir> <focus> [subproject] [out_path_override]
# Builds a focused inbox payload asking <commander> to drill into <section>.
# Trooper writes to <dd-dir>/_scratch/drilldown-<section-slug>-<commander>.md
# (the _scratch/ subdir keeps per-section trooper output out of the user-facing
# design-doc directory, which should contain only the final assembled spec).
# <focus> is optional pushback text from the user; default applies if empty.
# If <subproject> is non-empty, the output path becomes
# <dd-dir>/_scratch/drilldown-<section-slug>-<subproject>-<commander>.md and
# the prompt scope-narrows to that sub-project. Empty/omitted preserves
# v0.5.3 byte-equal output (single-repo).
# <out_path_override> (optional 7th arg): when non-empty, replaces the derived
# path verbatim. Used by bin/consult-drilldown.sh's collision-counter loop to
# inject -2/-3/.../-99 suffixed paths when prior drill outputs already exist.
cw_consult_design_doc_drilldown_prompt() {
  local section="$1" syn="$2" commander="$3" dd_dir="$4" focus="${5:-}" subproject="${6:-}" out_path_override="${7:-}"
  if [[ -n "$subproject" ]]; then
    if [[ ! "$subproject" =~ ^${CW_SLUG_REGEX_BASE}$ ]]; then
      echo "cw_consult_design_doc_drilldown_prompt: invalid subproject '$subproject' (need ${CW_SLUG_REGEX_BASE})" >&2
      return 2
    fi
  fi
  local section_slug
  section_slug=$(printf '%s' "$section" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
  local out_path
  if [[ -n "$out_path_override" ]]; then
    out_path="$out_path_override"
  elif [[ -n "$subproject" ]]; then
    out_path="$dd_dir/_scratch/drilldown-${section_slug}-${subproject}-${commander}.md"
  else
    out_path="$dd_dir/_scratch/drilldown-${section_slug}-${commander}.md"
  fi
  local resolved_focus="${focus:-Provide more depth, citations, and concrete trade-offs for the $section section.}"
  local out
  out=$(cw_consult_load_prompt consult/drilldown.md \
          "SECTION=$section" \
          "SYN=$syn" \
          "FOCUS=$resolved_focus" \
          "OUT_PATH=$out_path" \
          "SUBPROJECT_BLOCK_START=" "SUBPROJECT_BLOCK_END=" \
          "SUBPROJECT=${subproject:-N/A}")
  if [[ -z "$subproject" ]]; then
    # Single-repo: strip the per-sub-project block to match v0.5.3 baseline byte-for-byte.
    # Sentinels render as empty inline tokens, so the Scope and "Other sub-projects"
    # lines bracket the block; getline consumes the trailing blank line for byte-equality.
    printf '%s\n' "$out" | cw_consult_strip_block '^Scope: drill specifically into' '^Other sub-projects'
  else
    printf '%s\n' "$out"
  fi
}

# cw_consult_parse_design_doc_flag <args>
# Token-aware parse: removes only EXACT --design-doc tokens (not substrings).
# Emits "<flag>\t<topic>" on stdout, where <flag> ∈ {0,1}.
# Subshell-safe (does not export anything; caller parses stdout).
cw_consult_parse_design_doc_flag() {
  local raw="${1:-}"
  local flag=0
  local -a kept=()
  local tok
  # IFS-split on whitespace; -r preserves backslashes.
  read -r -a all <<< "$raw"
  for tok in "${all[@]}"; do
    if [[ "$tok" == "--design-doc" ]]; then
      flag=1
    else
      kept+=("$tok")
    fi
  done
  printf '%s\t%s\n' "$flag" "${kept[*]}"
}

# cw_consult_parse_use_force_flag <args>
# v0.16.0: Token-aware parse: removes only EXACT --use-force tokens (not substrings
# like --use-force-please or --use-forced). Mirrors cw_consult_parse_design_doc_flag.
# Emits "<flag>\t<topic>" on stdout, where <flag> ∈ {0,1}.
# Subshell-safe (does not export anything; caller parses stdout).
cw_consult_parse_use_force_flag() {
  local raw="${1:-}"
  local flag=0
  local -a kept=()
  local tok
  # IFS-split on whitespace; -r preserves backslashes.
  read -r -a all <<< "$raw"
  for tok in "${all[@]}"; do
    if [[ "$tok" == "--use-force" ]]; then
      flag=1
    else
      kept+=("$tok")
    fi
  done
  printf '%s\t%s\n' "$flag" "${kept[*]}"
}

# cw_consult_load_prompt <relpath> [VAR=value ...]
# Reads $CLAUDE_PLUGIN_ROOT/config/prompt-templates/<relpath> and substitutes
# every {{VAR}} placeholder using single-pass sed. Returns:
#   rc=0 — rendered prompt printed to stdout
#   rc=1 — template not found (path printed to stderr)
#   rc=2 — bad call (no CLAUDE_PLUGIN_ROOT, surviving {{VAR}}, or no relpath)
#
# Single-pass: a value containing {{...}} is NOT recursively expanded; if a
# user-supplied value reintroduces a placeholder the surviving-token guard
# fires. This is the safer behavior — recursion would amplify mistakes.
cw_consult_load_prompt() {
  local relpath="${1:-}"
  [[ -n "$relpath" ]] || { echo "cw_consult_load_prompt: relpath required" >&2; return 2; }
  shift
  local plugin_root="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}"
  [[ -n "$plugin_root" ]] || { echo "cw_consult_load_prompt: CLAUDE_PLUGIN_ROOT not set" >&2; return 2; }
  local tmpl="$plugin_root/config/prompt-templates/$relpath"
  [[ -f "$tmpl" ]] || { echo "cw_consult_load_prompt: template not found: $tmpl" >&2; return 1; }

  # Build a sed script: one s|{{KEY}}|escaped-value|g per VAR=value pair.
  # Pipe delimiter so / in values stays literal; escape \, &, and | in value.
  local script="" pair key val esc
  for pair in "$@"; do
    key="${pair%%=*}"
    val="${pair#*=}"
    [[ "$pair" == *=* && -n "$key" ]] || { echo "cw_consult_load_prompt: bad VAR=value '$pair'" >&2; return 2; }
    esc=${val//\\/\\\\}    # \  → \\
    esc=${esc//&/\\&}      # &  → \&
    esc=${esc//|/\\|}      # |  → \|
    esc=${esc//$'\n'/\\$'\n'}   # newlines: sed `s` needs a literal newline escape
    script+="s|{{${key}}}|${esc}|g;"
  done

  local rendered
  rendered=$(sed -e "$script" "$tmpl") || return 1

  if printf '%s\n' "$rendered" | grep -qE '\{\{[A-Z_][A-Z0-9_]*\}\}'; then
    {
      echo "cw_consult_load_prompt: unresolved placeholders in $relpath:"
      printf '%s\n' "$rendered" | grep -oE '\{\{[A-Z_][A-Z0-9_]*\}\}' | sort -u | sed 's/^/  /'
    } >&2
    return 2
  fi

  printf '%s\n' "$rendered"
}
