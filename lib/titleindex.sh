# shellcheck shell=bash
# titleindex.sh — a persisted cache of chat titles, and nothing more.
#
# WHY: measured on this host, 6810 transcripts x ~35ms of title extraction is ~54s.
# Batching the read (titles.sh) gets that to ~8ms each, which is still ~54s for the
# whole set and ~400ms for a 50-row window — exactly the poll budget, with zero
# headroom. So titles are cached, and a cache miss falls back lazily.
#
# IT IS A CACHE. Deleting this file loses nothing: every entry can be recomputed
# from the transcript it names. It therefore lives under XDG_CACHE_HOME, is never
# backed up, is never migrated, and an unreadable one is simply a cold cache.
#
# FORMAT — one entry per line, 5 tab-separated fields after a version header:
#   #v1 <built-epoch>
#   <transcript-path>\t<mtime>\t<size>\t<source>\t<title>
# Later lines win, so the lazy fallback can APPEND instead of rewriting; _ti_rebuild
# compacts. Titles are tab/newline-free by construction (titles.sh squashes them).
#
# INVALIDATION — a hit requires path, mtime AND size to match exactly.
#   * mtime alone is not enough: `cp` and restore-from-backup can produce a file
#     with a size the cache knows and a timestamp it does not, and vice versa.
#   * size alone is not enough: an in-place edit of equal length changes nothing.
#   * both together are sufficient in practice because title records are APPENDED
#     to the JSONL — a new title always grows the file and moves its mtime.
#   * there is no time-based expiry: a file that has not changed cannot have
#     acquired a new title, so ageing an entry out would only cost a re-read.
# A WRONG TITLE FROM A STALE ENTRY IS WORSE THAN A SLOW CORRECT ONE, so every
# mismatch is a miss, and every unparseable line is a miss — never a loose parse.
#
# Uses compat.sh's _file_mtime. The entrypoint already sources compat.sh before
# this file, but tests may source this file standalone — pull in the sibling
# compat.sh (same directory as this file) when that hasn't happened yet, same
# guard shape as ledger.sh/schedule.sh/json.sh.
if ! command -v _file_mtime >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/compat.sh"
fi

TITLE_INDEX="${TITLE_INDEX:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-helpers/titles.tsv}"
TITLE_INDEX_VERSION=1

declare -A _TI=()
TI_STATE="cold"; TI_ENTRIES=0; TI_SKIPPED=0; TI_DUPES=0; TI_HITS=0; TI_MISSES=0
_TI_LOADED=0

_ti_key() { printf '%s\t%s\t%s' "$1" "$2" "$3"; }

# One awk over the whole file. A line is loaded only if it has 5 fields, numeric
# mtime and size, and no control characters; anything else is COUNTED and skipped,
# so `doctor` can report a damaged cache instead of the cache quietly shrinking.
_ti_load() {
  (( _TI_LOADED )) && return 0
  _TI_LOADED=1
  [[ -r "$TITLE_INDEX" ]] || { TI_STATE="cold"; return 0; }
  local hdr; hdr="$(head -1 "$TITLE_INDEX" 2>/dev/null || true)"
  if [[ "$hdr" != "#v$TITLE_INDEX_VERSION "* ]]; then
    # An unknown version is ignored WHOLE. Reading fields we do not understand the
    # meaning of would be the one failure mode this cache must not have.
    TI_STATE="cold"; return 0
  fi
  local line k
  while IFS= read -r line; do
    if [[ "$line" != *$'\t'*$'\t'*$'\t'*$'\t'* ]]; then TI_SKIPPED=$((TI_SKIPPED+1)); continue; fi
    IFS=$'\t' read -r p m sz src title <<<"$line"
    if [[ ! "$m" =~ ^[0-9]+$ || ! "$sz" =~ ^[0-9]+$ || -z "$p" ]]; then
      TI_SKIPPED=$((TI_SKIPPED+1)); continue
    fi
    k="$(_ti_key "$p" "$m" "$sz")"
    [[ -n "${_TI[$k]:-}" ]] && TI_DUPES=$((TI_DUPES+1))
    _TI[$k]="$src"$'\t'"$title"          # later line wins
    TI_ENTRIES=$((TI_ENTRIES+1))
  done < <(awk 'NR>1' "$TITLE_INDEX" 2>/dev/null || true)
  if (( TI_SKIPPED > 0 )); then TI_STATE="corrupt"; else TI_STATE="warm"; fi
}

_ti_lookup() {
  _ti_load
  local v="${_TI[$(_ti_key "$1" "$2" "$3")]:-}"
  if [[ -n "$v" ]]; then TI_HITS=$((TI_HITS+1)); printf '%s' "$v"; return 0; fi
  TI_MISSES=$((TI_MISSES+1)); return 1
}

# Append one entry. Cheap enough to call per resolved row; _ti_rebuild compacts.
# The directory is 0700 and the file 0600: these titles are the user's own prompts.
_ti_put() {
  local d; d="$(dirname "$TITLE_INDEX")"
  [[ -d "$d" ]] || { mkdir -p "$d" && chmod 700 "$d"; }
  if [[ ! -f "$TITLE_INDEX" ]]; then
    ( umask 077; printf '#v%s %s\n' "$TITLE_INDEX_VERSION" "$(date +%s)" > "$TITLE_INDEX" )
  fi
  # Refuse to write through a symlink: this file is 0600 by intent, and following
  # a swapped symlink would leak its contents somewhere else entirely.
  [[ -L "$TITLE_INDEX" ]] && { echo "claude-session: $TITLE_INDEX is a symlink — refusing to write the title cache" >&2; return 1; }
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$TITLE_INDEX"
}

# Full build. Written to a temp file in the SAME directory and moved into place, so
# a reader can never see a partial index and an interrupted build leaves the old
# one intact. No lock: `mv` is atomic, two concurrent builders means the loser's
# work is lost, and losing cache work costs a re-read and nothing else.
_ti_rebuild() {
  local d tmp acct dir i f m sz r
  d="$(dirname "$TITLE_INDEX")"; [[ -d "$d" ]] || { mkdir -p "$d" && chmod 700 "$d"; }
  tmp="$(mktemp "$d/titles.tsv.tmp.XXXXXX")" || return 1
  chmod 600 "$tmp"
  trap 'rm -f "$tmp"' RETURN
  printf '#v%s %s\n' "$TITLE_INDEX_VERSION" "$(date +%s)" > "$tmp"
  while IFS=$'\t' read -r acct dir; do
    _build_transfer_index "$dir" 0
    for (( i=1; i<=TR_COUNT; i++ )); do
      f="${TR_PROJDIR[$i]}/${TR_SID[$i]}.jsonl"
      m="$(_file_mtime "$f" 2>/dev/null || echo 0)"; sz="$(wc -c < "$f" 2>/dev/null || echo 0)"
      r="$(_title_read "$f")"
      printf '%s\t%s\t%s\t%s\n' "$f" "$m" "${sz// /}" "$r" >> "$tmp"
    done
  done < <(_all_accounts)
  mv -f "$tmp" "$TITLE_INDEX" && trap - RETURN
}

_ti_stats() { _ti_load; printf '%s\t%s\t%s\t%s\t%s\t%s' \
  "$TI_STATE" "$TI_HITS" "$TI_MISSES" "$TI_ENTRIES" "$TI_DUPES" "$TI_SKIPPED"; }

# Resolve a bounded window of sids: index first, transcript second, write back.
# THIS is the lazy fallback — the app calls it for the rows it is about to paint,
# so a cold cache costs one 8ms read per visible row instead of blocking a list.
#
# _ti_load is primed HERE, once, in this function's own (non-subshell) frame.
# Every _ti_lookup call below runs inside `$(...)`, i.e. its own forked subshell —
# without this priming call, _ti_load's `_TI_LOADED` guard would never see itself
# set in the PARENT, so each iteration would re-fork awk and re-parse the entire
# index from scratch, once per row, exactly the per-row-fork anti-pattern this
# project has already paid for twice (_session_rows, owner_tmux). Priming here
# means the subshells inherit an already-populated `_TI` by fork-copy instead.
_titles_window() {
  local acct_dir="$1"; shift
  _ti_load
  local sid f m sz r rows=""
  for sid in "$@"; do
    [[ -z "$sid" ]] && continue
    f="$(_transcript_for_sid "$sid" "" "$acct_dir")"
    if [[ -z "$f" || ! -f "$f" ]]; then
      rows+="$(printf '%s\tunknown\tnone\t' "$sid")"$'\n'; continue
    fi
    m="$(_file_mtime "$f" 2>/dev/null || echo 0)"; sz="$(wc -c < "$f" 2>/dev/null || echo 0)"; sz="${sz// /}"
    if r="$(_ti_lookup "$f" "$m" "$sz")"; then :; else
      r="$(_title_read "$f")"; _ti_put "$f" "$m" "$sz" "${r%%$'\t'*}" "${r#*$'\t'}" || true
    fi
    rows+="$(printf '%s\tknown\t%s' "$sid" "$r")"$'\n'
  done
  jq -Rn --argjson sv "$JSON_SCHEMA_VERSION" \
    '{schemaVersion:$sv, items: [inputs | select(length>0) | split("\t")
      | {sessionId: .[0],
         title: {state: .[1], source: .[2], value: (if .[1]=="known" then .[3] else "" end)}}]}' <<<"$rows"
}
