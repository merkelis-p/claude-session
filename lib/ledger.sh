# shellcheck shell=bash
# ledger.sh — the transfer subsystem + transfer ledger for claude-session.
# Sourced by claude-session after titles.sh (its functions call _title_for_file
# and _preview_for_sid from titles.sh, and _account_* helpers from the entrypoint,
# all resolved at dispatch time).

# Uses compat.sh's _file_mtime/_epoch_to_human/_parse_datetime/_reverse_lines.
# Same reasoning as schedule.sh: the entrypoint sources compat.sh first, but a
# standalone `. ledger.sh` must not end up calling missing wrappers — a bare
# rc=127 there would surface as an unexplained "?" date, not an error.
if ! command -v _epoch_to_human >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/compat.sh"
fi

# ---- transfer ---------------------------------------------------------------
# Move or copy one chat's on-disk state from one account to another. Two things
# travel, each landing at the same relative path under the destination account:
#   projects/<encoded-cwd>/<sessionId>.jsonl   the transcript
#   file-history/<sessionId>/                  its file-edit history, if any
# The transcript alone is what `claude --resume` needs (verified 2026-07-18 by a
# hand-run copy), so a missing file-history is not an error.
#
# This is purely a data operation: it never touches tmux, never kills anything,
# and never launches Claude. Closing out the source session stays a separate,
# deliberate `claude-session kill`.

# Every transcript in one account, newest first -> TR_SID / TR_PROJDIR, count in
# TR_COUNT. Depth-2 glob on purpose: subagent transcripts live one level deeper
# and are not independently resumable.
#
# ONE `stat` call for every file's mtime, not one `_file_mtime` (itself one
# `stat` fork) PER FILE, and dirname/basename via parameter expansion, not the
# external `dirname`/`basename` commands. The original shape forked THREE
# external processes per transcript — fine for `transfer`'s own occasional,
# human-initiated picker, but this function is also the chats section's
# window enumeration (lib/json.sh's `_sid_transcript_map`), where it runs on
# every poll: measured on a 200-transcript account, the old shape cost ~600
# execve calls and several SECONDS, blowing the ≤400ms poll budget on this
# step alone before a single row was even built. Output is byte-identical —
# same TR_SID/TR_PROJDIR content and order, same TR_COUNT/TR_TOTAL — only the
# cost changed.
declare -a TR_SID TR_PROJDIR
TR_COUNT=0
TR_TOTAL=0
_build_transfer_index() {
  local acct_dir="$1" limit="${2:-0}"
  TR_SID=(); TR_PROJDIR=(); TR_COUNT=0; TR_TOTAL=0
  shopt -s nullglob
  local -a files=()
  local f
  for f in "$acct_dir/projects"/*/*.jsonl; do
    [[ -f "$f" ]] && files+=("$f")
  done
  # Explicit `return 0`, not a bare `return`: a bare one would return the
  # exit status of the failing `((...))` test that triggered it (1, since
  # `((0))` is false) — turning "no transcripts, nothing to do" into a
  # reported FAILURE. `set -e` then aborted the caller's entire script on
  # this line for an empty account, silently, before any output — that
  # regression is exactly why this is spelled out rather than left implicit.
  (( ${#files[@]} )) || return 0

  local rows=""
  local sm sf
  while IFS=$'\t' read -r sm sf; do
    [[ -z "$sf" ]] && continue
    rows+="$sm"$'\t'"$sf"$'\n'
  done < <(
    case "$(_compat_os)" in
      darwin) stat -f $'%m\t%N' "${files[@]}" 2>/dev/null ;;
      *)      stat -c $'%Y\t%n' "${files[@]}" 2>/dev/null ;;
    esac
  )
  [[ -z "$rows" ]] && return

  local i=0
  while IFS=$'\t' read -r _mtime f; do
    [[ -z "$f" ]] && continue
    TR_TOTAL=$((TR_TOTAL+1))
    # Keep counting past the cap so the caller can report what it didn't show.
    (( limit > 0 && i >= limit )) && continue
    i=$((i+1))
    TR_SID[$i]="${f##*/}"; TR_SID[$i]="${TR_SID[$i]%.jsonl}"
    TR_PROJDIR[$i]="${f%/*}"
  done < <(sort -rn <<<"$rows")
  TR_COUNT="$i"
}

# Pick one chat from the source account. Sets TR_PICKED_SID / TR_PICKED_PROJDIR;
# returns 1 if the user quit without choosing.
TR_PICKED_SID=""
TR_PICKED_PROJDIR=""
_transfer_pick() {
  local acct="$1" acct_dir i line num ans
  acct_dir="$(_account_dir_or_default "$acct")"
  TR_PICKED_SID=""; TR_PICKED_PROJDIR=""

  if command -v fzf >/dev/null 2>&1; then
    local input=""
    for ((i=1;i<=TR_COUNT;i++)); do
      input+="$(printf '%s\t%s\t%b%s%b  %b%s%b' \
        "${TR_SID[$i]}" "${TR_PROJDIR[$i]}" \
        "$Y" "$(_title_for_file "${TR_PROJDIR[$i]}/${TR_SID[$i]}.jsonl")" "$N" \
        "$DIM" "$(basename "${TR_PROJDIR[$i]}")" "$N")"$'\n'
    done
    line="$(printf '%s' "$input" | fzf --ansi --delimiter='\t' --with-nth=3 \
        --height=90% --reverse --prompt="transfer from $acct > " \
        --preview="$0 _preview {1} - $acct" --preview-window='right:60%:wrap')" || return 1
    [[ -z "$line" ]] && return 1
    TR_PICKED_SID="$(cut -f1 <<<"$line")"
    TR_PICKED_PROJDIR="$(cut -f2 <<<"$line")"
    return 0
  fi

  for ((i=1;i<=TR_COUNT;i++)); do
    printf '%b[%d]%b %b%-52s%b %b%s%b\n' "$BOLD" "$i" "$N" \
      "$Y" "$(truncate_str "$(_title_for_file "${TR_PROJDIR[$i]}/${TR_SID[$i]}.jsonl")" 52)" "$N" \
      "$DIM" "$(basename "${TR_PROJDIR[$i]}")" "$N"
  done
  while true; do
    printf '\n%btransfer from %s%b  #=pick · p#=preview · q=quit %b>%b ' \
      "$BOLD" "$acct" "$N" "$BOLD" "$N"
    read -r ans || return 1
    case "$ans" in
      ''|q|Q)  return 1 ;;
      p[0-9]*) num="${ans#p}"
               if (( num>=1 && num<=TR_COUNT )); then
                 printf '\n'; _preview_for_sid "${TR_SID[$num]}" "" "$acct_dir"
               else echo "?"; fi ;;
      [0-9]*)  if (( ans>=1 && ans<=TR_COUNT )); then
                 TR_PICKED_SID="${TR_SID[$ans]}"; TR_PICKED_PROJDIR="${TR_PROJDIR[$ans]}"
                 return 0
               else echo "?"; fi ;;
      *)       echo "?" ;;
    esac
  done
}

# Same validation --account= gets: shape first, then "is it actually registered".
_validate_transfer_account() {
  local name="$1" label="$2"
  [[ "$name" == "default" ]] && return 0
  [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] \
    || { echo "claude-session transfer: $label name must match [a-zA-Z0-9_-]+" >&2; exit 2; }
  _account_config_dir "$name" >/dev/null 2>&1 \
    || { echo "claude-session transfer: unknown account '$name' — register it first: claude-session accounts add $name" >&2; exit 2; }
}

LEDGER_FILE="${LEDGER_FILE:-$HOME/.config/claude-helpers/transfer-log.jsonl}"
declare -A XFER_BADGE

_ledger_new_id() {
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 3
  else printf '%06x' "$(( (RANDOM << 15 | RANDOM) & 0xffffff ))"; fi
}

# Durability gate. Args: sid title from to verb [undoOf] [redoOf].
# Prints the new id on success; returns non-zero (mutating nothing) on failure.
_ledger_append() {
  local sid="$1" title="$2" from="$3" to="$4" verb="$5" undoof="${6:-}" redoof="${7:-}"
  mkdir -p "$(dirname "$LEDGER_FILE")" 2>/dev/null || return 1
  local id ts line last
  id="$(_ledger_new_id)"; ts="$(date +%s)"
  line="$(jq -cn --arg id "$id" --argjson ts "$ts" --arg sid "$sid" --arg title "$title" \
    --arg from "$from" --arg to "$to" --arg verb "$verb" --arg u "$undoof" --arg r "$redoof" \
    '{id:$id,ts:$ts,sid:$sid,title:$title,from:$from,to:$to,verb:$verb,
      undoOf:(if $u=="" then null else $u end),redoOf:(if $r=="" then null else $r end)}')" || return 1
  printf '%s\n' "$line" >> "$LEDGER_FILE" || return 1
  last="$(tail -1 "$LEDGER_FILE" 2>/dev/null)"
  [[ "$(jq -r '.id // empty' <<<"$last" 2>/dev/null)" == "$id" ]] || return 1
  printf '%s' "$id"
}

# Pre-transfer guard. Args: sid from to dst_exists(0|1). 0=proceed, non-zero=refuse.
_ledger_guard() {
  local sid="$1" from="$2" to="$3" dst_exists="$4"
  [[ -f "$LEDGER_FILE" ]] || return 0
  if (( dst_exists == 1 )); then
    local prior
    prior="$(jq -r --arg s "$sid" --arg t "$to" \
      'select(.sid==$s and .to==$t and (.verb=="move" or .verb=="copy")) | "\(.ts)\t\(.verb)"' \
      "$LEDGER_FILE" 2>/dev/null | tail -1)"
    if [[ -n "$prior" && "$FORCE" == 0 ]]; then
      echo "claude-session transfer: already transferred ($(cut -f2 <<<"$prior")) $sid → $to on $(_epoch_to_human "$(cut -f1 <<<"$prior")" '+%Y-%m-%d %H:%M' || echo '?') — refusing to duplicate (use --force)" >&2
      return 2
    fi
  fi
  local rt
  rt="$(jq -r --arg s "$sid" --arg t "$to" --arg f "$from" \
    'select(.sid==$s and .to==$f and .from==$t and (.verb=="move" or .verb=="copy")) | .ts' \
    "$LEDGER_FILE" 2>/dev/null | tail -1)"
  if [[ -n "$rt" ]]; then
    [[ "$FORCE" == 1 ]] && return 0
    if ! _cs_interactive; then
      echo "claude-session transfer: round-trip detected ($to → $from earlier) — re-run with --force to confirm" >&2
      return 2
    fi
    printf 'round-trip: %s was moved %s → %s before. Send it back %s → %s? [y/N] ' "$sid" "$to" "$from" "$from" "$to" >&2
    local ans; read -r ans; [[ "$ans" == [yY] ]] || { echo "cancelled" >&2; return 2; }
  fi
  return 0
}

# Load newest inbound provenance into XFER_BADGE[sid#to] = "from|ts".
_ledger_provenance_load() {
  XFER_BADGE=()
  [[ -f "$LEDGER_FILE" ]] || return 0
  local sid to from ts
  while IFS=$'\t' read -r sid to from ts; do
    [[ -z "$sid" ]] && continue
    XFER_BADGE["$sid#$to"]="$from|$ts"     # append order = oldest→newest; newest overwrites
  done < <(jq -r 'select(.verb=="move" or .verb=="copy") | [.sid,.to,.from,.ts] | @tsv' "$LEDGER_FILE" 2>/dev/null)
}

# Echo a badge for (sid, account) or nothing.
_transfer_badge() {
  local key="${1}#${2}" v
  v="${XFER_BADGE[$key]:-}"
  [[ -z "$v" ]] && return 0
  printf '⇄ from %s · %s' "${v%%|*}" "$(_epoch_to_human "${v#*|}" '+%b%d' || echo '?')"
}

cmd_transfer_log() {
  local f_from="" f_to="" f_sid="" f_since="" f_limit=0 a
  for a in "$@"; do case "$a" in
    --from=*) f_from="${a#*=}";; --to=*) f_to="${a#*=}";;
    --sid=*) f_sid="${a#*=}";; --since=*) f_since="${a#*=}";; --limit=*) f_limit="${a#*=}";;
  esac; done
  # Validate --since BEFORE any output: a failed parse must reject the filter
  # outright, never silently fall through to "list everything" (since_ts=0
  # would match every entry).
  local since_ts=0
  if [[ -n "$f_since" ]]; then
    since_ts="$(_parse_datetime "$f_since")" \
      || { echo "claude-session transfer log: --since='$f_since' is not a recognizable date/time — refusing to filter (use e.g. --since=2026-07-01)" >&2; exit 2; }
  fi
  box_top "Transfer log"
  if [[ ! -s "$LEDGER_FILE" ]]; then
    box_line "$(printf '%bno transfers recorded yet%b' "$DIM" "$N")"; box_bottom; return 0
  fi
  local shown=0 id ts sid title from to verb
  while IFS=$'\t' read -r id ts sid title from to verb; do
    [[ -n "$f_from" && "$from" != "$f_from" ]] && continue
    [[ -n "$f_to"   && "$to"   != "$f_to"   ]] && continue
    [[ -n "$f_sid"  && "$sid"  != "$f_sid"* ]] && continue
    (( since_ts > 0 && ts < since_ts )) && continue
    (( f_limit > 0 && shown >= f_limit )) && break
    shown=$((shown+1))
    box_line "$(printf '%b%s%b  %s  %b%s → %s%b  %s  %s  %b"%s"%b' \
      "$BOLD" "$id" "$N" "$(_epoch_to_human "$ts" '+%Y-%m-%d %H:%M' || echo '?')" \
      "$C" "$from" "$to" "$N" "$verb" "$(truncate_str "$sid" 8)" "$Y" "$(truncate_str "$title" 40)" "$N")"
  done < <(jq -r '[.id,.ts,.sid,.title,.from,.to,.verb]|@tsv' "$LEDGER_FILE" 2>/dev/null | _reverse_lines)
  (( shown == 0 )) && box_line "$(printf '%bno entries match%b' "$DIM" "$N")"
  box_bottom
}

cmd_transfer_undo() {
  local arg="${1:-}" entry
  [[ -s "$LEDGER_FILE" ]] || { echo "claude-session transfer undo: nothing to undo (empty ledger)" >&2; exit 1; }
  if [[ -z "$arg" ]]; then entry="$(tail -1 "$LEDGER_FILE")"
  else
    entry="$(jq -c --arg a "$arg" 'select(.id==$a)' "$LEDGER_FILE" 2>/dev/null | tail -1)"
    [[ -z "$entry" ]] && entry="$(jq -c --arg a "$arg" 'select(.sid==$a or (.sid|startswith($a)))' "$LEDGER_FILE" 2>/dev/null | tail -1)"
  fi
  [[ -n "$entry" ]] || { echo "claude-session transfer undo: no ledger entry for '$arg'" >&2; exit 1; }
  local sid from to verb ts title oid
  sid="$(jq -r .sid <<<"$entry")"; from="$(jq -r .from <<<"$entry")"; to="$(jq -r .to <<<"$entry")"
  verb="$(jq -r .verb <<<"$entry")"; ts="$(jq -r .ts <<<"$entry")"; title="$(jq -r .title <<<"$entry")"
  oid="$(jq -r .id <<<"$entry")"
  local to_dir from_dir dst_jsonl
  to_dir="$(_account_dir_or_default "$to")"; from_dir="$(_account_dir_or_default "$from")"
  dst_jsonl="$(find "$to_dir/projects" -maxdepth 2 -name "$sid.jsonl" 2>/dev/null | head -1)"
  [[ -n "$dst_jsonl" ]] || { echo "claude-session transfer undo: dest copy for $sid not found in $to (already gone?)" >&2; exit 1; }
  local dmt
  if ! dmt="$(_file_mtime "$dst_jsonl")"; then
    echo "claude-session transfer undo: cannot read the destination's mtime — refusing to undo blind (use --force to override)" >&2
    [[ "$FORCE" == 0 ]] && exit 2
    dmt=0
  fi
  if (( dmt > ts + 2 )); then
    if [[ "$FORCE" == 0 ]] && ! _cs_interactive; then
      echo "claude-session transfer undo: dest copy changed since transfer — refusing (resumed?). Use --force." >&2; exit 2
    fi
    if [[ "$FORCE" == 0 ]]; then
      printf 'dest copy of %s changed since it moved. Undo discards that newer copy. Proceed? [y/N] ' "$sid" >&2
      local ans; read -r ans; [[ "$ans" == [yY] ]] || { echo "cancelled" >&2; exit 2; }
    fi
  fi
  local newid
  if [[ "$verb" == "move" ]]; then
    local slug from_proj; slug="$(basename "$(dirname "$dst_jsonl")")"; from_proj="$from_dir/projects/$slug"
    mkdir -p "$from_proj"
    newid="$(FORCE=1 _ledger_append "$sid" "$title" "$to" "$from" "move" "$oid" "")" \
      || { echo "claude-session transfer undo: ledger write failed — aborting, nothing moved" >&2; exit 1; }
    mv -f "$dst_jsonl" "$from_proj/$sid.jsonl"
    if [[ -d "$to_dir/file-history/$sid" ]]; then
      mkdir -p "$from_dir/file-history"; rm -rf "$from_dir/file-history/$sid"; mv -f "$to_dir/file-history/$sid" "$from_dir/file-history/$sid"
    fi
  else
    newid="$(FORCE=1 _ledger_append "$sid" "$title" "$to" "$from" "undo" "$oid" "")" \
      || { echo "claude-session transfer undo: ledger write failed — aborting" >&2; exit 1; }
    rm -f "$dst_jsonl"; rm -rf "$to_dir/file-history/$sid"
  fi
  echo "claude-session: undid $verb of $sid ($to → $from). ledger entry $newid" >&2
}

cmd_transfer_redo() {
  local id="${1:-}" entry
  [[ -n "$id" ]] || { echo "claude-session transfer redo: an entry id is required (see: claude-session transfer log)" >&2; exit 2; }
  entry="$(jq -c --arg a "$id" 'select(.id==$a)' "$LEDGER_FILE" 2>/dev/null | tail -1)"
  [[ -n "$entry" ]] || { echo "claude-session transfer redo: no ledger entry with id '$id'" >&2; exit 1; }
  local sid from to verb
  sid="$(jq -r .sid <<<"$entry")"; from="$(jq -r .from <<<"$entry")"; to="$(jq -r .to <<<"$entry")"; verb="$(jq -r .verb <<<"$entry")"
  echo "claude-session: redoing $id — $verb $sid $from → $to" >&2
  TO_ACCOUNT="$to"; FROM_ACCOUNT="$from"; REDO_OF="$id"
  TRANSFER_MOVE=0; [[ "$verb" == "move" ]] && TRANSFER_MOVE=1
  cmd_transfer "$sid"
}

cmd_transfer_prune() {
  local id="${1:-}"
  [[ -n "$id" ]] || { echo "claude-session transfer prune: an entry id is required" >&2; exit 2; }
  [[ -f "$LEDGER_FILE" ]] || { echo "claude-session transfer prune: no ledger" >&2; exit 1; }
  local found; found="$(jq -c --arg a "$id" 'select(.id==$a)' "$LEDGER_FILE" 2>/dev/null | head -1)"
  [[ -n "$found" ]] || { echo "claude-session transfer prune: no entry id '$id'" >&2; exit 1; }
  if [[ "$FORCE" == 0 ]] && ! _cs_interactive; then
    echo "claude-session transfer prune: needs confirmation — re-run with --force" >&2; exit 2
  fi
  if [[ "$FORCE" == 0 ]] && _cs_interactive; then
    printf 'prune ledger entry %s (record only, chat data untouched)? [y/N] ' "$id" >&2
    local ans; read -r ans; [[ "$ans" == [yY] ]] || { echo "cancelled" >&2; exit 0; }
  fi
  local tmp; tmp="$(mktemp)"
  if jq -c --arg a "$id" 'select(.id!=$a)' "$LEDGER_FILE" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$LEDGER_FILE"; echo "claude-session: pruned ledger entry $id (chat data untouched)" >&2
  else
    rm -f "$tmp"; echo "claude-session transfer prune: failed — ledger untouched" >&2; exit 1
  fi
}

cmd_transfer() {
  case "${1:-}" in
    log)   shift; cmd_transfer_log "$@"; return ;;
    undo)  shift; cmd_transfer_undo "$@"; return ;;
    redo)  shift; cmd_transfer_redo "$@"; return ;;
    prune) shift; cmd_transfer_prune "$@"; return ;;
  esac

  local sid="${1:-}"
  local from="$FROM_ACCOUNT" to="$TO_ACCOUNT"

  if [[ -z "$to" ]]; then
    echo "claude-session transfer: --to=<account> is required (the destination account)" >&2
    echo "  usage: claude-session transfer [sessionId] --to=<account> [--from=<account>] [--move] [--force]" >&2
    exit 2
  fi
  _validate_transfer_account "$to" "--to"
  _validate_transfer_account "$from" "--from"
  if [[ "$to" == "$from" ]]; then
    echo "claude-session transfer: --to and --from must differ (both are '$to')" >&2
    exit 2
  fi

  local src_dir dst_dir
  src_dir="$(_account_dir_or_default "$from")"
  dst_dir="$(_account_dir_or_default "$to")"

  local proj_dir=""
  if [[ -z "$sid" ]]; then
    _build_transfer_index "$src_dir" "$TRANSFER_LIMIT"
    if (( TR_COUNT == 0 )); then
      printf '%bno chats found in account %b%s%b%b (%s)%b\n' \
        "$DIM" "$BOLD" "$from" "$N" "$DIM" "$(short_home "$src_dir")" "$N"
      return 0
    fi
    if (( PLAIN == 1 )) || ! _cs_interactive || [[ ! -t 1 ]]; then
      echo "claude-session transfer: picking a chat needs a terminal — pass an explicit sessionId" >&2
      echo "  claude-session transfer <sessionId> --to=$to --from=$from" >&2
      exit 2
    fi
    # Never let a cap read as "that's everything" — say what was left out.
    if (( TR_TOTAL > TR_COUNT )); then
      printf '%bshowing the %d most recent of %d chats in %s — raise with --limit=N, or pass a sessionId%b\n' \
        "$DIM" "$TR_COUNT" "$TR_TOTAL" "$from" "$N"
    fi
    _transfer_pick "$from" || { printf '%bcancelled%b\n' "$DIM" "$N"; return 0; }
    sid="$TR_PICKED_SID"
    proj_dir="$TR_PICKED_PROJDIR"
    [[ -n "$sid" ]] || return 0
  fi

  if [[ -z "$proj_dir" ]]; then
    local hit
    hit="$(find "$src_dir/projects" -maxdepth 2 -name "$sid.jsonl" 2>/dev/null | head -1 || true)"
    if [[ -z "$hit" ]]; then
      echo "claude-session transfer: no transcript for '$sid' in account '$from' ($(short_home "$src_dir"))" >&2
      echo "  list the source account's chats:  claude-session transfer --to=$to --from=$from" >&2
      exit 1
    fi
    proj_dir="$(dirname "$hit")"
  fi

  local slug src_jsonl dst_proj dst_jsonl src_hist dst_hist
  slug="$(basename "$proj_dir")"
  src_jsonl="$proj_dir/$sid.jsonl"
  dst_proj="$dst_dir/projects/$slug"
  dst_jsonl="$dst_proj/$sid.jsonl"
  src_hist="$src_dir/file-history/$sid"
  dst_hist="$dst_dir/file-history/$sid"

  # dst_jsonl's own existence is now the ledger's job (_ledger_guard, below —
  # it distinguishes "already transferred this before" from a foreign file and
  # says so specifically). The file-history sidecar isn't ledger-tracked, so it
  # keeps its own never-clobber check here.
  if (( FORCE == 0 )); then
    if [[ -e "$src_hist" && -e "$dst_hist" ]]; then
      echo "claude-session transfer: $(short_home "$dst_hist") already exists — refusing to overwrite (use --force)" >&2
      exit 2
    fi
  fi

  local dst_exists=0; [[ -e "$dst_jsonl" ]] && dst_exists=1
  _ledger_guard "$sid" "$from" "$to" "$dst_exists" || exit $?

  # Backstop: never clobber an existing destination transcript without --force,
  # even when no ledger entry explains it (post-prune, manual dst, or no ledger yet).
  if (( FORCE == 0 && dst_exists == 1 )); then
    echo "claude-session transfer: $(short_home "$dst_jsonl") already exists — refusing to overwrite (use --force)" >&2
    exit 2
  fi

  local verb="copied" verbword="copy"
  if (( TRANSFER_MOVE == 1 )); then verb="moved"; verbword="move"; fi

  # Durability gate: record BEFORE mutating the source. Title snapshot from the
  # source, which still exists at this point.
  local ledger_id
  ledger_id="$(_ledger_append "$sid" "$(_title_for_file "$src_jsonl")" "$from" "$to" "$verbword" "" "${REDO_OF:-}")" \
    || { echo "claude-session transfer: could not write ledger — aborting, nothing changed" >&2; exit 1; }

  mkdir -p "$dst_proj"
  if (( TRANSFER_MOVE == 1 )); then mv -f "$src_jsonl" "$dst_jsonl"; else cp -f "$src_jsonl" "$dst_jsonl"; fi

  local hist_note="(none)"
  if [[ -d "$src_hist" ]]; then
    mkdir -p "$dst_dir/file-history"
    rm -rf "$dst_hist"
    if (( TRANSFER_MOVE == 1 )); then mv -f "$src_hist" "$dst_hist"; else cp -r "$src_hist" "$dst_hist"; fi
    hist_note="$(find "$dst_hist" -type f 2>/dev/null | wc -l) file(s)"
  fi

  local title cwd
  title="$(_title_for_file "$dst_jsonl")"
  cwd="$(_cwd_in_transcript "$dst_jsonl")"
  [[ -z "$cwd" ]] && cwd="$HOME"

  box_top "Transfer"
  box_line "$(printf '%b%s%b' "$Y" "$(truncate_str "$title" 62)" "$N")"
  box_line "$(printf '%b%s%b' "$DIM" "$sid" "$N")"
  box_line "$(printf '  %bledger%b        %s' "$DIM" "$N" "$ledger_id")"
  box_blank
  box_line "$(printf '%b%s%b %b→%b %b%s%b   %b(%s)%b' \
    "$BOLD" "$from" "$N" "$C" "$N" "$BOLD" "$to" "$N" "$DIM" "$verb" "$N")"
  # Full transcript paths blow past the box border — the project dir plus the
  # sessionId printed above is the same information, and it fits.
  box_line "$(printf '  %blanded in%b     %s' "$DIM" "$N" "$(short_home "$dst_proj")")"
  box_line "$(printf '  %bfile-history%b  %s' "$DIM" "$N" "$hist_note")"
  box_blank
  # One invocation that both opens a durable session under the DESTINATION
  # account and resumes this very chat in it — no `/resume` picker step. Relies
  # on the native `--resume` pass-through, so nothing has to be typed twice.
  # (Deliberately no session-multiplexer verbs in this function — it stays a
  # pure data operation; the launch itself lives in _transfer_maybe_launch.)
  local next_acct=""
  [[ "$to" != "default" ]] && next_acct=" --account=$to"
  box_line "$(printf '%bnext:%b cd %s && claude-session%s --resume %s' \
    "$BOLD" "$N" "$(short_home "$cwd")" "$next_acct" "$sid")"
  box_line "$(printf '      %badd --launch next time to transfer AND open it in one go%b' "$DIM" "$N")"
  if (( TRANSFER_MOVE == 0 )); then
    box_blank
    box_line "$(printf '%bsource kept in %s — retire it with: claude-session kill%b' \
      "$DIM" "$from" "$N")"
  fi
  box_bottom

  # cmd_transfer stays a pure data operation (see its header comment) — record
  # what landed where, and let _transfer_maybe_launch (a separate function,
  # called by the entrypoint after cmd_transfer returns) decide whether to
  # actually resume the destination session.
  LAST_TRANSFER_SID="$sid"
  LAST_TRANSFER_TO="$to"
  LAST_TRANSFER_DST_JSONL="$dst_jsonl"
}

# ---- transfer --launch (instant move/copy-and-resume) ----------------------
# Not part of cmd_transfer's own body on purpose: cmd_transfer is documented
# (and test-enforced) as a pure data operation that never touches tmux. The
# entrypoint's dispatch calls this separately, right after cmd_transfer
# returns, using the LAST_TRANSFER_* state cmd_transfer just recorded. A no-op
# unless --launch was passed and a transfer actually completed (log/undo/redo/
# prune and early-return paths in cmd_transfer never set LAST_TRANSFER_*).
LAST_TRANSFER_SID=""
LAST_TRANSFER_TO=""
LAST_TRANSFER_DST_JSONL=""
_transfer_maybe_launch() {
  (( TRANSFER_LAUNCH == 1 )) || return 0
  [[ -n "$LAST_TRANSFER_DST_JSONL" ]] || return 0
  local launch_cwd; launch_cwd="$(_cwd_in_transcript "$LAST_TRANSFER_DST_JSONL")"; [[ -z "$launch_cwd" ]] && launch_cwd="$HOME"
  local to_dir; to_dir="$(_account_config_dir "$LAST_TRANSFER_TO" 2>/dev/null || true)"
  local sbase; sbase="$(basename "$launch_cwd")"; sbase="${sbase//[.:]/_}"
  local suffix=""; [[ "$LAST_TRANSFER_TO" != "default" ]] && suffix="-${LAST_TRANSFER_TO//[.:]/_}"
  local lsess="$sbase-claude$suffix"
  if tmux has-session -t "$lsess" 2>/dev/null; then
    echo "claude-session: destination session '$lsess' already exists — attach with: claude-session $sbase $([[ "$LAST_TRANSFER_TO" != default ]] && echo "--account=$LAST_TRANSFER_TO")" >&2
  else
    _launch_native "$lsess" "$launch_cwd" "$to_dir" -- --resume "$LAST_TRANSFER_SID"
  fi
}
