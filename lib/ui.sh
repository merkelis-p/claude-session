# shellcheck shell=bash
# Shared UI primitives for claude-session / vscode-tunnel / remote-status / code-here / remote-help.
# Source it: . "$HOME/.local/share/claude-helpers/ui.sh"

# ---- colors -----------------------------------------------------------------
if [[ -z "${NO_COLOR:-}" && ( -t 1 || "${FORCE_COLOR:-0}" = "1" ) ]]; then
  N=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[34m'; M=$'\033[35m'; C=$'\033[36m'
else
  N= BOLD= DIM= R= G= Y= B= M= C=
fi

# ---- glyphs -----------------------------------------------------------------
GLYPH_OK="${G}●${N}"     # ●
GLYPH_WARN="${Y}○${N}"   # ○
GLYPH_FAIL="${R}✕${N}"   # ✕
GLYPH_CHECK="${G}✓${N}"  # ✓
GLYPH_DASH="${DIM}—${N}" # —
GLYPH_ALERT="${Y}⚠${N}"  # ⚠

# Interpret \uXXXX escapes
ok()    { printf '\xe2\x97\x8f'; }   # ●
warn()  { printf '\xe2\x97\x8b'; }   # ○
fail()  { printf '\xe2\x9c\x95'; }   # ✕
chk()   { printf '\xe2\x9c\x93'; }   # ✓
dash()  { printf '\xe2\x80\x94'; }   # —
alrt()  { printf '\xe2\x9a\xa0'; }   # ⚠

# ---- width ------------------------------------------------------------------
# Visible width: strip ANSI escapes, count Unicode characters (not bytes).
_vlen() {
  LC_ALL=C.UTF-8 awk -v s="$1" 'BEGIN{ gsub(/\033\[[0-9;]*m/, "", s); print length(s) }'
}

# Truncate to a visible width without breaking colors.
# _vtrunc <string> <max-visible-chars>   (the appended '…' counts toward max)
#
# A plain `${s:0:n}` cannot be used here: it counts bytes, so it mangles UTF-8,
# and it counts ANSI escapes against the budget, so a colored line truncates
# earlier than an identical plain one and can be cut mid-escape — leaving the
# terminal stuck in that color for every following line. This walks the string
# instead, copying escape sequences through without charging them to the budget.
_vtrunc() {
  local ell; printf -v ell '\xe2\x80\xa6'
  LC_ALL=C.UTF-8 awk -v s="$1" -v max="$2" -v ell="$ell" '
    BEGIN {
      if (max <= 0) { printf "%s", ""; exit }
      # Already fits: return it untouched. Appending an ellipsis to content that
      # fits would be a lie about the content having been cut. box_line only
      # calls this when the line is too long, but callers cannot be assumed to
      # have checked — the helper has to be correct on its own.
      vis_s = s; gsub(/\033\[[0-9;]*m/, "", vis_s)
      if (length(vis_s) <= max) { printf "%s", s; exit }
      budget = max - 1          # leave room for the ellipsis
      n = length(s); i = 1; vis = 0; out = ""; sawesc = 0
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "\033") {      # copy the escape verbatim, cost 0
          j = i
          while (j <= n && substr(s, j, 1) !~ /[a-zA-Z]/) j++
          out = out substr(s, i, j - i + 1); i = j + 1; sawesc = 1
          continue
        }
        if (vis >= budget) break
        out = out c; vis++; i++
      }
      # Reset only if we actually emitted color, so plain text stays plain.
      printf "%s%s%s", out, ell, (sawesc ? "\033[0m" : "")
    }'
}

# Pick frame width once per script invocation.
_pick_width() {
  local w="${COLUMNS:-0}"
  [[ "$w" -eq 0 ]] && w="$(tput cols 2>/dev/null || echo 78)"
  (( w < 50 )) && w=50
  (( w > 100 )) && w=100
  echo "$w"
}
: "${UI_W:=$(_pick_width)}"

# ---- box drawing ------------------------------------------------------------
box_top() {
  local title="$1" tw fill
  tw=$(_vlen "$title")
  printf '\xe2\x95\xad\xe2\x94\x80 %b%s%b ' "$BOLD" "$title" "$N"
  fill=$(( UI_W - tw - 5 ))
  (( fill > 0 )) && printf '\xe2\x94\x80%.0s' $(seq 1 "$fill")
  printf '\xe2\x95\xae\n'
}

# Content wider than the frame must be TRUNCATED, not just left unpadded.
# Without this the closing '│' is pushed past the frame edge and the whole box
# visibly comes apart — one long chat title was enough to wreck a listing.
# Truncation is width-aware (ANSI escapes stripped, Unicode counted as
# characters) and appends '…' so it is obvious that something was cut. The
# escape sequences themselves are never counted against the budget, so colored
# content truncates at the same visible column as plain content.
box_line() {
  local line="$1" w pad inner
  inner=$(( UI_W - 4 ))
  w=$(_vlen "$line")
  if (( w > inner )); then
    line="$(_vtrunc "$line" "$inner")"
    w=$(_vlen "$line")
  fi
  pad=$(( inner - w ))
  printf '\xe2\x94\x82 %b' "$line"
  (( pad > 0 )) && printf '%*s' "$pad" ''
  printf ' \xe2\x94\x82\n'
}

box_kv() {
  # box_kv "key" "value" [keywidth=10]
  local k="$1" v="$2" kw="${3:-10}"
  printf -v key_padded '%-*s' "$kw" "$k"
  box_line "$(printf '%b%s%b %b' "$DIM" "$key_padded" "$N" "$v")"
}

# Wrap a plain-text paragraph (no ANSI inside) to fit the box.
box_para() {
  local prefix="${2:-}" line maxw=$(( UI_W - 4 - ${#prefix} ))
  while IFS= read -r line; do
    if [[ -n "$prefix" ]]; then
      box_line "$(printf '%b%s%b%s' "$DIM" "$prefix" "$N" "$line")"
    else
      box_line "$line"
    fi
  done < <(fold -s -w "$maxw" <<<"$1")
}

# box_msg <prefix-with-ansi> <plain-body> [continuation-indent="  "]
# First line gets the prefix; subsequent wrapped lines get the indent.
box_msg() {
  local prefix="$1" body="$2" indent="${3:-  }"
  local plen; plen=$(_vlen "$prefix")
  local inner=$(( UI_W - 4 ))
  local first_w=$(( inner - plen ))
  local cont_w=$(( inner - ${#indent} ))
  (( first_w < 20 )) && first_w=20
  (( cont_w < 20 )) && cont_w=20

  local first_chunk
  first_chunk=$(fold -s -w "$first_w" <<<"$body" | head -n1)
  local rest="${body:${#first_chunk}}"
  rest="${rest# }"
  box_line "${prefix}${first_chunk}"
  if [[ -n "$rest" ]]; then
    local cont
    while IFS= read -r cont; do
      box_line "${indent}${cont}"
    done < <(fold -s -w "$cont_w" <<<"$rest")
  fi
}

box_blank() { box_line ""; }

box_sep() {
  # mid-section thin separator
  local fill
  fill=$(( UI_W - 2 ))
  printf '\xe2\x94\x9c'
  printf '\xe2\x94\x80%.0s' $(seq 1 "$fill")
  printf '\xe2\x94\xa4\n'
}

box_bottom() {
  local fill
  fill=$(( UI_W - 2 ))
  printf '\xe2\x95\xb0'
  printf '\xe2\x94\x80%.0s' $(seq 1 "$fill")
  printf '\xe2\x95\xaf\n'
}

# ---- helpers ----------------------------------------------------------------
short_home() { local p="$1"; printf '%s' "${p/#$HOME/~}"; }
truncate_str() {
  local s="$1" max="${2:-30}"
  if (( ${#s} > max )); then
    printf '%s\xe2\x80\xa6' "${s:0:max-1}"   # ...with horizontal ellipsis …
  else
    printf '%s' "$s"
  fi
}

# Convert ms-epoch to "Xs/m/h/d ago"; "-" if empty/0.
ms_relative() {
  local ms="$1"
  [[ -z "$ms" || "$ms" == "null" || "$ms" == "0" ]] && { printf -- '-'; return; }
  local secs=$(( ms / 1000 ))
  local now; now=$(date +%s)
  local delta=$(( now - secs ))
  if   (( delta < 60 ));    then printf '%ds ago' "$delta"
  elif (( delta < 3600 ));  then printf '%dm ago' "$((delta/60))"
  elif (( delta < 86400 )); then printf '%dh ago' "$((delta/3600))"
  else                           printf '%dd ago' "$((delta/86400))"
  fi
}

# Returns the tmux session that owns a given PID, by walking the ppid chain.
# Both lookup tables are built once per process, not once per call. Callers
# enumerate sessions in a loop (claude-session, remote-status, copilot-session),
# so the un-memoized version forked `tmux list-panes` once per session plus a
# `ps` for every step of every ancestor walk — 51 tmux and 93 ps forks in a
# single `claude-session ls`.
#
# The cache is process-lifetime and deliberately not invalidated: every caller is
# a one-shot listing command, and a table rebuilt mid-listing would make rows
# inconsistent with each other rather than fresher. A long-lived caller that
# needs a new snapshot should re-exec (or unset _OT_LOADED).
_OT_LOADED=0
declare -A _OT_PANE2SESS=()
declare -A _OT_PID2PPID=()

_ot_load() {
  (( _OT_LOADED )) && return 0
  local ppid sess pid
  while IFS='|' read -r ppid sess; do
    [[ -n "$ppid" ]] && _OT_PANE2SESS[$ppid]="$sess"
  done < <(tmux list-panes -a -F '#{pane_pid}|#{session_name}' 2>/dev/null || true)
  # One `ps` for the whole ancestry map, then walk it in-shell with zero forks.
  while read -r pid ppid; do
    [[ -n "$pid" ]] && _OT_PID2PPID[$pid]="$ppid"
  done < <(ps -eo pid=,ppid= 2>/dev/null || true)
  _OT_LOADED=1
}

# Returns the tmux session that owns a given PID, by walking the ppid chain.
owner_tmux() {
  local pid="$1"
  _ot_load
  local cur="$pid" hops=0
  while [[ -n "$cur" && "$cur" != "0" && "$cur" != "1" ]]; do
    if [[ -n "${_OT_PANE2SESS[$cur]:-}" ]]; then echo "${_OT_PANE2SESS[$cur]}"; return; fi
    # Bound the walk: a pid->ppid map read at one instant can contain a cycle if
    # pids were recycled mid-read, and an unbounded loop here would hang the
    # caller instead of just returning "unknown".
    (( ++hops > 64 )) && return
    cur="${_OT_PID2PPID[$cur]:-}"
    [[ -n "$cur" ]] || return
  done
}
