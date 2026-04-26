# lib/argsfile.sh — shell-tokenize a one-line args file into stdout, one
# token per line. Supports double-quoted phrases preserved as a single token.
# Used by bin/*.sh when invoked via `--args-file <path>` from the command
# markdown directives — fences off shell injection from $ARGUMENTS.
#
# Parsing semantics: tokenize via `xargs -n1 printf '%s\n'`. xargs parses
# single/double quotes per POSIX rules and emits one whitespace-separated
# token per line. Bash never sees the file content as source — that's the
# load-bearing property: $(...), backticks, ; chained commands, etc., all
# survive as literal text inside their containing quoted token.

cw_args_file_load() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  local line
  IFS= read -r line < "$path" || true
  [[ -n "$line" ]] || return 0
  # xargs reads stdin once with -n1 and prints each token to stdout on its
  # own line. The 2>/dev/null swallows xargs's "unmatched quote" warnings
  # for malformed input — best-effort tokenization, garbage in / garbage out.
  local tokens=()
  while IFS= read -r tok; do
    tokens+=("$tok")
  done < <(printf '%s\n' "$line" | xargs -n1 printf '%s\n' 2>/dev/null)
  printf '%s\n' "${tokens[@]}"
}
