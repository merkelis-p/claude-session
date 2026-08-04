# shellcheck shell=bash
# titleindex.sh — a persisted cache of chat titles, and nothing more.
#
# WHY: a full rebuild (_ti_rebuild — mtime + size + a title read, per
# transcript, across every account) measures ~35-39ms per transcript,
# hermetically, in a fake HOME with synthetic two-line transcripts (1,000
# transcripts: 39.35s / 39.35ms each; 2,000: 71.33s / 35.66ms each — both runs
# via the real CLI's `_titles --rebuild`). Linearly extrapolated to this
# host's actual count, 6,810 transcripts, that is ~240s (~4 minutes) — not
# the ~54s an earlier version of this comment claimed (that number was
# simply the wrong side of a mis-multiplication, understating the real cost
# by ~4-5x). titles.sh's batched `_title_read` alone (no mtime, no size, just
# the read) is ~8ms in isolation — see its own header — but a full rebuild
# also pays for `_file_mtime` and `wc -c` per transcript, which is where the
# rest of the ~35ms comes from. Either way it's minutes, not tens of seconds,
# for the whole account — so titles are cached, and a cache miss falls back
# lazily. The read alone is what sets the WINDOW budget: ~8ms x 50 rows is
# ~400ms — exactly the poll budget, with zero headroom.
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
TI_STATE="cold"; TI_ENTRIES=0; TI_SKIPPED=0; TI_DUPES=0; TI_STALE=0; TI_HITS=0; TI_MISSES=0
_TI_LOADED=0

_ti_key() { printf '%s\t%s\t%s' "$1" "$2" "$3"; }

# One awk over the whole file, for whole-file statistics ONLY (_ti_stats, the
# doctor check). This is NOT on the window's hot path — see _ti_lookup_window
# below for that. A line is loaded only if it has >=5 fields, numeric mtime and
# size, and a non-empty path; anything else is COUNTED and skipped, so `doctor`
# can report a damaged cache instead of the cache quietly shrinking.
#
# The field split, numeric validation and STALE computation all happen inside
# the one awk process; the bash loop below only ever does inline string
# concatenation and the `read` builtin — never `$(...)` — because a fork per
# index line is exactly the mistake measured on this cache: 6,810 lines of
# `k="$(_ti_key ...)"` took _ti_load from ~1.8s to ~15.8s by itself.
#
# STALE: a line is superseded (dead weight) if the SAME transcript path
# recurs LATER in the file with a DIFFERENT (mtime,size) — the file changed
# since this line was written, so this exact key can never be looked up
# again. That requires knowing what comes after a line, so the awk script
# below does two internal passes over its own buffered arrays (right-to-left
# to compute staleness, then left-to-right to emit) — still one process, one
# read of the file, no second bash loop. STALE is distinct from a DUPE (the
# same path+mtime+size written twice, a write anomaly): a run of the same key
# repeated verbatim is never counted stale, only dup'd.
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
  local k p m sz src title stale
  # Split on the tab directly in the loop's own `read`. The two-stage form this
  # replaced (`read -r line` then `read <<<"$line"`) built a HERESTRING per line,
  # which bash implements with a temp file — measured at ~1.4s for `doctor` on a
  # 6810-entry index versus ~0.4s here, for identical parsing. Overflow behaviour
  # is unchanged: extra embedded tabs still land in the last variable only.
  while IFS=$'\t' read -r stale p m sz src title; do
    # The summary row (always last) carries the skipped-line count in the `p`
    # slot and a sentinel of "END" where a real row would have "0" or "1" —
    # `stale` is first specifically so an overflowed title (extra embedded
    # tabs, tolerated the same way the old 5-field `read` tolerated them)
    # never gets misread as this sentinel: the overflow can only land in the
    # LAST variable (title), never the first.
    if [[ "$stale" == "END" ]]; then TI_SKIPPED=$((TI_SKIPPED + p)); continue; fi
    k="$p"$'\t'"$m"$'\t'"$sz"             # inline concatenation — no subshell fork
    [[ -n "${_TI[$k]:-}" ]] && TI_DUPES=$((TI_DUPES+1))
    _TI[$k]="$src"$'\t'"$title"           # later line wins
    TI_ENTRIES=$((TI_ENTRIES+1))
    [[ "$stale" == "1" ]] && TI_STALE=$((TI_STALE+1))
  done < <(awk -F'\t' -v OFS='\t' '
    NR==1 { next }                         # header
    {
      if (NF < 5) { skipped++; next }
      p=$1; m=$2; s=$3; src=$4
      title=$5; for (i=6;i<=NF;i++) title = title OFS $i
      if (m !~ /^[0-9]+$/ || s !~ /^[0-9]+$/ || length(p) == 0) { skipped++; next }
      n++
      L_p[n]=p; L_m[n]=m; L_s[n]=s; L_src[n]=src; L_title[n]=title
    }
    END {
      # Right-to-left: distinct[p]/sole[p] track, scanning from the end, how
      # many DIFFERENT (mtime,size) pairs for path p have been seen so far
      # among lines AFTER i — that is exactly "superseded by a later line
      # with a different mtime/size".
      for (i = n; i >= 1; i--) {
        p = L_p[i]; mykey = L_m[i] SUBSEP L_s[i]
        dc = distinct[p] + 0
        if      (dc >= 2) is_stale[i] = 1
        else if (dc == 1) is_stale[i] = (sole[p] == mykey) ? 0 : 1
        else               is_stale[i] = 0
        fk = p SUBSEP mykey
        if (!(fk in seen)) {
          seen[fk] = 1
          distinct[p] = dc + 1
          if (dc + 1 == 1) sole[p] = mykey
        }
      }
      for (i = 1; i <= n; i++) print is_stale[i], L_p[i], L_m[i], L_s[i], L_src[i], L_title[i]
      print "END", skipped+0, "", "", "", ""
    }
  ' "$TITLE_INDEX" 2>/dev/null || true)
  # Precedence: corrupt (unparseable lines present) beats stale (compaction
  # opportunity) beats an entries==0 index (nothing to serve — NOT "warm": a
  # cache that cannot hit is the same over-claim as a check that never ran
  # reporting PASS) beats warm.
  #
  # STALE threshold: hysteresis + an absolute floor, not a bare majority.
  # Every message appends to a transcript, and every poll of a window
  # containing it appends a fresh index line — a `stale > live` majority
  # (the previous rule) is reached by the THIRD poll of the same handful of
  # chats and never clears, so `doctor` flagged a perfectly healthy,
  # perfectly-working cache as an ongoing issue within seconds of normal use.
  # Two conditions now have to hold at once:
  #   * stale is at least 3x live (TI_ENTRIES - TI_STALE) — dead weight has to
  #     be the dominant shape of the file, not merely present, before a
  #     ~141s-per-4000-transcript rebuild is worth recommending;
  #   * AND at least 300 stale lines outright — a floor so a small, everyday
  #     account (a handful of chats, edited a normal number of times) never
  #     trips this on volume alone. 300 is small next to the reference host's
  #     6,810-transcript index, but far above what ordinary day-to-day editing
  #     of a handful of chats produces before a user would ever run `doctor`.
  # Both numbers are chosen so the state is actionable ("this is worth a
  # rebuild") rather than ambient ("this is always true of a cache that works
  # exactly as designed").
  if (( TI_SKIPPED > 0 )); then
    TI_STATE="corrupt"
  elif (( TI_ENTRIES == 0 )); then
    TI_STATE="cold"
  elif (( TI_STALE >= 300 && TI_STALE > (TI_ENTRIES - TI_STALE) * 3 )); then
    TI_STATE="stale"
  else
    TI_STATE="warm"
  fi
}

_ti_lookup() {
  _ti_load
  local v="${_TI[$(_ti_key "$1" "$2" "$3")]:-}"
  if [[ -n "$v" ]]; then TI_HITS=$((TI_HITS+1)); printf '%s' "$v"; return 0; fi
  TI_MISSES=$((TI_MISSES+1)); return 1
}

# Batch lookup for the window path: ONE awk pass over the index, given the set
# of requested keys, emitting only the lines that match. This is the "one awk
# over the index" the window needs — cost proportional to the WINDOW (the
# newline-separated "path<TAB>mtime<TAB>size" keys passed in $1, at most
# CHAT_LIMIT rows), never to the index (6,810 lines and growing without bound,
# since every mtime/size change appends rather than compacts). No bash loop
# ever iterates the index here — the awk script alone does the field split,
# structural validation and "later line wins" resolution — and no bash loop
# iterates per requested key either (they are all handed to awk in one shot).
#
# Same structural-validity rule as _ti_load: >=5 fields, numeric mtime/size,
# non-empty path. A line failing that is never matched, exactly the "counted
# and skipped, never loosely parsed" rule — it just isn't the whole-file
# COUNT this function needs (_ti_load owns that, for doctor).
_ti_lookup_window() {
  local keys="$1"
  [[ -n "$keys" ]] || return 0
  [[ -r "$TITLE_INDEX" ]] || return 0
  local hdr; hdr="$(head -1 "$TITLE_INDEX" 2>/dev/null || true)"
  [[ "$hdr" == "#v$TITLE_INDEX_VERSION "* ]] || return 0
  awk -F'\t' -v OFS='\t' '
    NR==FNR { if (length($0)) wanted[$0]=1; next }   # file 1: the requested keys
    FNR==1  { next }                                  # file 2: skip its header
    {
      if (NF < 5) next
      if ($2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || length($1) == 0) next
      key = $1 OFS $2 OFS $3
      if (!(key in wanted)) next
      title = $5; for (i = 6; i <= NF; i++) title = title OFS $i
      out[key] = $4 OFS title            # later line wins (forward scan order)
    }
    END { for (k in out) print k OFS out[k] }
  ' <(printf '%s' "$keys") "$TITLE_INDEX" 2>/dev/null
}

# Append one entry. Cheap enough to call per resolved row; _ti_rebuild compacts.
# The directory is 0700 and the file 0600: these titles are the user's own prompts.
_ti_put() {
  local d; d="$(dirname "$TITLE_INDEX")"
  [[ -d "$d" ]] || { mkdir -p "$d" && chmod 700 "$d"; }
  # Refuse to write through a symlink: this file is 0600 by intent, and following
  # a swapped symlink would leak its contents somewhere else entirely. Checked
  # BEFORE any write on purpose — `[[ -f ]]` below follows a symlink too (even
  # a DANGLING one, which `-f` reports false for, but which the header-write
  # below would then happily create AT THE TARGET before this refusal ever
  # ran). The refusal has to be the first thing that can touch the path.
  [[ -L "$TITLE_INDEX" ]] && { echo "claude-session: $TITLE_INDEX is a symlink — refusing to write the title cache" >&2; return 1; }
  # Write a fresh header when there is no file OR its first line isn't ours.
  # Both a 0-byte file (crash mid-write, disk full, `: >` truncation) and an
  # unrecognized version are REPLACEABLE, not merely "no header, so cold
  # forever": readers already treat anything under a mismatched/missing
  # header as unreadable whole (see _ti_load / _ti_lookup_window), so nothing
  # of value survives under it anyway — this heals the file the next time
  # anything writes to it instead of leaving it permanently dead.
  local hdr=""
  [[ -f "$TITLE_INDEX" ]] && hdr="$(head -1 "$TITLE_INDEX" 2>/dev/null || true)"
  if [[ ! -f "$TITLE_INDEX" || "$hdr" != "#v$TITLE_INDEX_VERSION "* ]]; then
    ( umask 077; printf '#v%s %s\n' "$TITLE_INDEX_VERSION" "$(date +%s)" > "$TITLE_INDEX" )
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$TITLE_INDEX"
}

# Full build. Written to a temp file in the SAME directory and moved into place, so
# a reader can never see a partial index and an interrupted build leaves the old
# one intact. No lock: `mv` is atomic, two concurrent builders means the loser's
# work is lost, and losing cache work costs a re-read and nothing else.
_ti_rebuild() {
  local d tmp acct dir i f m sz r rc=0
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
  # Verify the outcome, don't just trust `mv`'s exit status: if $TITLE_INDEX is
  # occupied by a directory, `mv "$tmp" "$TITLE_INDEX"` "succeeds" by nesting
  # $tmp INSIDE that directory — rc=0, but $TITLE_INDEX is still a directory
  # afterward, not the rebuilt file. `-f` on the destination path is the real
  # check: it is false in exactly that case, so it becomes a reported failure
  # instead of a silent no-op that later corrupts a JSON reply (a caller
  # running `awk`/`wc` on a directory next).
  if mv -f "$tmp" "$TITLE_INDEX" 2>/dev/null && [[ -f "$TITLE_INDEX" ]]; then
    rc=0
  else
    rm -f "$tmp"
    rc=1
  fi
  # Clear the trap on EVERY path, success or failure, before returning — not
  # just after a successful `mv`. `trap ... RETURN` is not scoped to this
  # function alone: left armed, it re-fires at the CALLER's own return, where
  # `tmp` (a `local` to THIS function) no longer exists, and `set -u` turns
  # that into "tmp: unbound variable" — an opaque abort of whatever called
  # this, not a clean `return 1`. Latent today (the one caller is top-level,
  # where there is no "caller's return" left to hit) but real for any future
  # in-function caller, and free to fix unconditionally.
  trap - RETURN
  return "$rc"
}

# TI_HITS/TI_MISSES are process-lifetime counters of actual index consults:
# `_ti_lookup` (single-key) and `_titles_window` (the window path every real
# caller uses) both increment them. `_ti_load` itself never touches either —
# loading the file isn't a lookup — so `_ti_stats` reports whatever this
# process's callers actually did, not a count from a code path nothing calls.
_ti_stats() { _ti_load; printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' \
  "$TI_STATE" "$TI_HITS" "$TI_MISSES" "$TI_ENTRIES" "$TI_DUPES" "$TI_SKIPPED" "$TI_STALE"; }

# Resolve a bounded window of sids: index first, transcript second, write back.
# THIS is the lazy fallback — the app calls it for the rows it is about to paint,
# so a cold cache costs one 8ms read per visible row instead of blocking a list.
#
# Deliberately does NOT call _ti_load. _ti_load builds an associative array of
# the WHOLE index (needed for doctor/_ti_stats' whole-file counts), and even
# with the per-line fork removed, just running the bash read loop over 6,810
# lines costs ~570ms before a single row is resolved — paid by a 1-sid window
# exactly as much as a 200-sid one. Instead: resolve every sid's (path, mtime,
# size) first (bounded by the window), hand the whole set to _ti_lookup_window
# for ONE awk pass over the index (see there), then do a second bounded pass
# using the (at most window-sized) hash of matches. Cost is now proportional
# to the window, never to the index.
#
# NO command substitution inside any per-sid or per-row loop below — that was
# the actual defect in an earlier version of this function: it called
# `_transcript_for_sid` (a `find` fork), `_file_mtime` (two more forks:
# `_compat_os` -> `uname`, then `stat`) and `wc -c`, ALL per requested sid, so
# a 100%-warm 50-sid window still cost 766ms and a 200-sid one 3936ms — both
# far over the 400ms poll budget this cache exists to hit. Every step below
# is either a single fork for the WHOLE window, or plain bash (parameter
# expansion, array/hash indexing, arithmetic) with zero forks at all.
_titles_window() {
  local acct_dir="$1"; shift
  local sid f m sz rows="" keys=""
  local -a req_sids=()
  for sid in "$@"; do
    [[ -z "$sid" ]] && continue
    req_sids+=("$sid")
  done

  # M12: `_ti_lookup_window`'s own contract (below) says "at most CHAT_LIMIT
  # rows" — make that true here, once, rather than leaving the window
  # unbounded. CHAT_LIMIT is bin/claude-session's `--limit-chats=` global
  # (default 200); falls back to that default if unset (e.g. this file
  # sourced standalone by a test).
  local _tw_limit="${CHAT_LIMIT:-200}"
  if (( ${#req_sids[@]} > _tw_limit )); then
    req_sids=("${req_sids[@]:0:_tw_limit}")
  fi

  # ---- 1. sid -> path for the WHOLE window, in one pass, zero forks --------
  # Every transcript that could match a requested sid lives at
  # "$acct_dir/projects/<encoded-cwd>/<sid>.jsonl" — the same depth-2 shape
  # _build_transfer_index (lib/ledger.sh) enumerates for the transfer picker.
  # This is NOT a call to that function: it additionally forks `_file_mtime`
  # (itself `_compat_os` -> `uname`, then `stat`) plus `basename`/`dirname`
  # PER TRANSCRIPT IN THE WHOLE ACCOUNT, to sort the picker by recency — a
  # cost this lookup has no use for (it doesn't care about ordering) and
  # cannot afford to import into a poll's hot path. One bash glob loop, with
  # the sid pulled out by parameter expansion, finds every requested sid in a
  # single pass with no process spawned at all.
  local -A want=() path_of=()
  for sid in "${req_sids[@]}"; do want["$sid"]=1; done
  if (( ${#want[@]} > 0 )); then
    local remaining=${#want[@]} base
    shopt -s nullglob
    for f in "$acct_dir"/projects/*/*.jsonl; do
      base="${f##*/}"; base="${base%.jsonl}"
      if [[ -n "${want[$base]:-}" ]]; then
        path_of["$base"]="$f"
        unset "want[$base]"
        remaining=$((remaining - 1))
        (( remaining == 0 )) && break
      fi
    done
  fi

  # ---- 2. mtime + size for the WHOLE window in ONE `stat`, not one per row --
  # A single `stat` call over every resolved path returns name, mtime and
  # size together — no separate `wc -c` needed at all, on either OS.
  local -a stat_files=()
  for sid in "${req_sids[@]}"; do
    [[ -n "${path_of[$sid]:-}" ]] && stat_files+=("${path_of[$sid]}")
  done
  local -A m_of=() sz_of=()
  if (( ${#stat_files[@]} > 0 )); then
    local sp sm ssz
    while IFS=$'\t' read -r sp sm ssz; do
      [[ -z "$sp" ]] && continue
      m_of["$sp"]="$sm"; sz_of["$sp"]="$ssz"
    done < <(
      case "$(_compat_os)" in
        darwin) stat -f $'%N\t%m\t%z' "${stat_files[@]}" 2>/dev/null ;;
        *)      stat -c $'%n\t%Y\t%s' "${stat_files[@]}" 2>/dev/null ;;
      esac
    )
  fi

  for sid in "${req_sids[@]}"; do
    f="${path_of[$sid]:-}"
    [[ -n "$f" ]] && keys+="$f"$'\t'"${m_of[$f]:-0}"$'\t'"${sz_of[$f]:-0}"$'\n'
  done

  # ---- 3. ONE awk fork for the whole window against the index --------------
  # (the "index is parsed once for the whole window" invariant) — not one
  # fork per row and not a full-index bash loop. The single `read` below
  # splits on the tab directly, same shape as _ti_load's fix (M11): no
  # herestring, which bash would implement with a temp file per matched row.
  local -A hit=()
  local p m2 sz2 src title
  if [[ -n "$keys" ]]; then
    while IFS=$'\t' read -r p m2 sz2 src title; do
      [[ -z "$p" ]] && continue
      hit["$p"$'\t'"$m2"$'\t'"$sz2"]="$src"$'\t'"$title"
    done < <(_ti_lookup_window "$keys")
  fi

  # ---- 4. build the rows: inline concatenation, never `$(...)` -------------
  # `resolved` memoizes by PATH (not by sid) across this loop: a sid repeated
  # in one window (or two concurrent polls hitting the same miss) used to read
  # its transcript and `_ti_put` its resolved row once PER OCCURRENCE — two
  # identical lines from one process, which `doctor` then reported as a
  # duplicate forever, until a rebuild. Recording the row the first time a
  # path is resolved and reusing it for every later occurrence in this same
  # window fixes both the double read and the false alarm.
  local -A resolved=()
  local r
  for sid in "${req_sids[@]}"; do
    f="${path_of[$sid]:-}"
    if [[ -z "$f" ]]; then
      rows+="$sid"$'\t'"unknown"$'\t'"none"$'\t'$'\n'; continue
    fi
    m="${m_of[$f]:-0}"; sz="${sz_of[$f]:-0}"
    r="${resolved[$f]:-}"
    if [[ -z "$r" ]]; then
      r="${hit["$f"$'\t'"$m"$'\t'"$sz"]:-}"
      if [[ -z "$r" ]]; then
        TI_MISSES=$((TI_MISSES + 1))
        r="$(_title_read "$f")"; _ti_put "$f" "$m" "$sz" "${r%%$'\t'*}" "${r#*$'\t'}" || true
      else
        TI_HITS=$((TI_HITS + 1))
      fi
      resolved["$f"]="$r"
    fi
    rows+="$sid"$'\t'"known"$'\t'"$r"$'\n'
  done
  jq -Rn --argjson sv "$JSON_SCHEMA_VERSION" \
    '{schemaVersion:$sv, items: [inputs | select(length>0) | split("\t")
      | {sessionId: .[0],
         title: {state: .[1], source: .[2], value: (if .[1]=="known" then .[3] else "" end)}}]}' <<<"$rows"
}
