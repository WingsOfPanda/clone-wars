# lib/argsfile.sh — shell-tokenize a one-line args file into stdout, one
# token per line. Supports double-quoted phrases preserved as a single token.
# Used by bin/*.sh when invoked via `--args-file <path>` from the command
# markdown directives — fences off shell injection from $ARGUMENTS.
#
# Parsing semantics: standard bash word-splitting via `read -ra` against
# the file's first line, EXCEPT we run it inside a controlled subshell with
# default IFS so shell metacharacters in the file are NOT re-interpreted —
# they survive as literal text inside their containing quoted token.

cw_args_file_load() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  local line
  IFS= read -r line < "$path" || true
  [[ -n "$line" ]] || return 0
  # Use eval-with-printf trick: wrap each token in single quotes via xargs,
  # then declare into an array. xargs handles double-quoted phrases per its
  # standard parsing rules.
  local tokens=()
  while IFS= read -r tok; do
    tokens+=("$tok")
  done < <(printf '%s\n' "$line" | xargs -n1 printf '%s\n' 2>/dev/null)
  printf '%s\n' "${tokens[@]}"
}
