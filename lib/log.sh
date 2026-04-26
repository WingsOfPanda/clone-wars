# lib/log.sh — colored status output for medic and friends.
# Sourced; exposes log_info, log_warn, log_error, log_ok.

if [[ -t 2 ]]; then
  _CW_RED=$'\033[31m'; _CW_GRN=$'\033[32m'; _CW_YEL=$'\033[33m'
  _CW_BLU=$'\033[34m'; _CW_RST=$'\033[0m'
else
  _CW_RED=''; _CW_GRN=''; _CW_YEL=''; _CW_BLU=''; _CW_RST=''
fi

log_info()  { printf '%s[INFO]%s  %s\n' "$_CW_BLU" "$_CW_RST" "$*" >&2; }
log_warn()  { printf '%s[WARN]%s  %s\n' "$_CW_YEL" "$_CW_RST" "$*" >&2; }
log_error() { printf '%s[FAIL]%s  %s\n' "$_CW_RED" "$_CW_RST" "$*" >&2; }
log_ok()    { printf '%s[ OK ]%s  %s\n' "$_CW_GRN" "$_CW_RST" "$*" >&2; }
