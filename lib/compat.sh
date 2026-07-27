# shellcheck shell=bash
# compat.sh — one portability shim for claude-session (Linux + macOS).
#
# Rule: prefer implementations that need NO OS branch. Written against `ps` and
# `kill` instead of /proc, most wrappers are identical on both platforms; only
# date/stat/readlink/timeout genuinely differ.
#
# Rule: never fail silently. A wrapper that cannot answer returns non-zero so the
# caller can surface it — a silently-disabled safety check is worse than an error.

# linux | darwin. CLAUDE_COMPAT_OS overrides it so tests can drive either branch.
_compat_os() {
  if [[ -n "${CLAUDE_COMPAT_OS:-}" ]]; then printf '%s' "$CLAUDE_COMPAT_OS"; return 0; fi
  case "$(uname -s 2>/dev/null)" in
    Darwin) printf 'darwin' ;;
    *)      printf 'linux' ;;
  esac
}

# ---- process wrappers (no OS branch) ---------------------------------------
_proc_alive()     { [[ -n "${1:-}" ]] && kill -0 "$1" 2>/dev/null; }
_proc_comm()      { [[ -n "${1:-}" ]] || return 1; ps -o comm= -p "$1" 2>/dev/null | sed 's/^ *//;s/ *$//'; }
_proc_args()      { [[ -n "${1:-}" ]] || return 1; ps -o args= -p "$1" 2>/dev/null | sed 's/^ *//'; }
_proc_owner_uid() { [[ -n "${1:-}" ]] || return 1; ps -o uid= -p "$1" 2>/dev/null | tr -d ' '; }

# `ps -o etime=` -> seconds. Format: [[dd-]hh:]mm:ss (also bare ss on macOS).
_etime_to_s() {
  local e="${1:-}" d=0 h=0 m=0 s=0
  [[ -z "$e" ]] && return 1
  e="${e// /}"
  if [[ "$e" == *-* ]]; then d="${e%%-*}"; e="${e#*-}"; fi
  case "$(awk -F: '{print NF}' <<<"$e")" in
    3) IFS=: read -r h m s <<<"$e" ;;
    2) IFS=: read -r m s <<<"$e" ;;
    1) s="$e" ;;
    *) return 1 ;;
  esac
  # strip leading zeros so arithmetic never reads them as octal
  printf '%s' "$(( 10#${d:-0}*86400 + 10#${h:-0}*3600 + 10#${m:-0}*60 + 10#${s:-0} ))"
}

_proc_elapsed_s() {
  [[ -n "${1:-}" ]] || return 1
  local e; e="$(ps -o etime= -p "$1" 2>/dev/null | tr -d ' ')"
  [[ -z "$e" ]] && return 1
  _etime_to_s "$e"
}

# Whole process table as 6 TSV fields: pid ppid etimes pcpu comm args.
#
# `ps comm=` can contain spaces (npm rewrites its process title, so comm is
# literally "npm run dev"), which shifts every field after it and corrupts args.
# The fix is NOT to fetch comm per pid — that forks one `ps` per process and made
# `ls`/`doctor` take minutes on a 500-process host. Instead ask ps twice, each
# time with the variable-width column LAST so parsing is unambiguous, and join
# the two streams by pid in a single awk. Two forks total, regardless of process
# count. etime -> seconds is computed in the same awk (a shell loop would fork a
# subshell per row for that too).
_proc_table() {
  { ps -eo pid=,comm=                        2>/dev/null | sed 's/^[[:space:]]*/C /'
    ps -eo pid=,ppid=,etime=,pcpu=,args=     2>/dev/null | sed 's/^[[:space:]]*/P /'
  } | awk '
    function etsec(e,   a,n,d,h,m,s) {
      d=0; h=0; m=0; s=0
      if (e ~ /-/) { split(e, a, "-"); d=a[1]; e=a[2] }
      n = split(e, a, ":")
      if      (n == 3) { h=a[1]; m=a[2]; s=a[3] }
      else if (n == 2) { m=a[1]; s=a[2] }
      else             { s=a[1] }
      return d*86400 + h*3600 + m*60 + s
    }
    $1 == "C" {
      pid = $2
      $1=""; $2=""; sub(/^[[:space:]]+/, "")
      comm[pid] = $0
      next
    }
    $1 == "P" {
      pid=$2; ppid=$3; et=$4; pc=$5
      $1=""; $2=""; $3=""; $4=""; $5=""; sub(/^[[:space:]]+/, "")
      args = $0
      c = (pid in comm) ? comm[pid] : args
      if (c == "") { c = args; sub(/[[:space:]].*$/, "", c) }
      printf "%s\t%s\t%s\t%s\t%s\t%s\n", pid, ppid, etsec(et), pc, c, args
    }
  '
}

_reverse_lines() { awk '{a[NR]=$0} END{for(i=NR;i>0;i--) print a[i]}'; }

# ---- date / stat / path (genuine OS branches) ------------------------------
_file_mtime() {
  local f="${1:-}"; [[ -n "$f" && -e "$f" ]] || return 1
  case "$(_compat_os)" in
    darwin) stat -f '%m' "$f" 2>/dev/null ;;
    *)      stat -c '%Y' "$f" 2>/dev/null ;;
  esac
}

# epoch -> formatted string. $2 = strftime format incl. leading '+' (default ISO).
_epoch_to_human() {
  local e="${1:-}" fmt="${2:-+%Y-%m-%d %H:%M}"
  [[ "$e" =~ ^[0-9]+$ ]] || return 1
  case "$(_compat_os)" in
    darwin) date -r "$e" "$fmt" 2>/dev/null ;;
    *)      date -d "@$e" "$fmt" 2>/dev/null ;;
  esac
}

# "YYYY-MM-DD HH:MM[:SS]" (or anything GNU date groks on Linux) -> epoch.
_parse_datetime() {
  local s="${1:-}"; [[ -n "$s" ]] || return 1
  case "$(_compat_os)" in
    darwin)
      local out
      out="$(date -j -f '%Y-%m-%d %H:%M:%S' "$s" +%s 2>/dev/null)" \
        || out="$(date -j -f '%Y-%m-%d %H:%M' "$s" +%s 2>/dev/null)" \
        || return 1
      printf '%s' "$out" ;;
    *)      date -d "$s" +%s 2>/dev/null || return 1 ;;
  esac
}

# Next occurrence of clock time HH:MM as an epoch (today if still ahead, else tomorrow).
_next_clock_epoch() {
  local t="${1:-}" now target
  [[ "$t" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || return 1
  now="$(date +%s)"
  target="$(_parse_datetime "$(date '+%Y-%m-%d') $t:00")" || return 1
  if (( target <= now )); then
    local tomorrow
    case "$(_compat_os)" in
      darwin) tomorrow="$(date -v+1d '+%Y-%m-%d' 2>/dev/null)" ;;
      *)      tomorrow="$(date -d 'tomorrow' '+%Y-%m-%d' 2>/dev/null)" ;;
    esac
    [[ -n "$tomorrow" ]] || return 1
    target="$(_parse_datetime "$tomorrow $t:00")" || return 1
  fi
  printf '%s' "$target"
}

_readlink_f() {
  local p="${1:-}"; [[ -n "$p" ]] || return 1
  if readlink -f "$p" 2>/dev/null; then return 0; fi
  # BSD readlink has no -f; perl ships with macOS.
  perl -MCwd=abs_path -e 'print abs_path(shift)' "$p" 2>/dev/null || return 1
}

# timeout(1) is GNU; macOS has it only via coreutils (gtimeout).
_timeout() {
  local dur="${1:-}"; shift || return 1
  if command -v timeout >/dev/null 2>&1; then timeout "$dur" "$@"; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$dur" "$@"; return $?; fi
  # Last resort: run unbounded but say so, rather than silently ignoring the cap.
  echo "claude-session: no timeout(1)/gtimeout found — running without a time cap (brew install coreutils)" >&2
  "$@"
}
