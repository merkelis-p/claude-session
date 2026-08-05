# shellcheck shell=bash
# json.sh — the ONE machine-readable surface. Every `--json` document and the
# internal `_snapshot` envelope are built here, from the same section emitters,
# so the CLI's human rendering and the app cannot disagree about a judgement.
#
# FORK DISCIPLINE: one `jq` per SECTION, never per row. Sections build a TSV
# stream in-shell and hand it to a single `jq -Rn` that splits and shapes it.
# The 574-fork shape this project has already fixed twice came from per-row
# forks; a fork-budget test guards `ls`/`doctor` the same way — this module
# follows the identical rule so it never reopens that class of regression.
#
# NO ANSI, EVER. Nothing here calls box_* or interpolates a color variable.
# tests/test_json.sh runs every emitter under FORCE_COLOR=1 and greps for \033.
#
# Sourced by the entrypoint after schedule.sh (last in the current chain).
# Standalone-testable: its only entrypoint dependencies (_all_accounts,
# ACCT_DESC, _account_dir_or_default, CLAUDE_HELPERS_LIB, VERSION,
# JSON_SCHEMA_VERSION, JSON_OUT) are read at call time, not at source time —
# same convention ledger.sh/schedule.sh already document for their own
# entrypoint dependencies.

# Uses compat.sh's _compat_os. The entrypoint already sources compat.sh before
# this file, but tests may source this file standalone — pull in the sibling
# compat.sh (same directory as this file) when that hasn't happened yet, so
# _compat_os is never silently missing (same guard shape as ledger.sh/schedule.sh).
if ! command -v _compat_os >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/compat.sh"
fi

JSON_SECTIONS_ALL="accounts chats issues processes ledger schedules"

# Milliseconds since the epoch. bash 5 has EPOCHREALTIME (no fork); bash 4 has
# no sub-second clock, so it degrades to whole seconds and DECLARES that in
# core.elapsedMsPrecision — an elapsedMs of 0 that means "cannot measure" must
# never read like a 0 that means "instant".
_JSON_MS_PRECISION="s"
[[ -n "${EPOCHREALTIME:-}" ]] && _JSON_MS_PRECISION="ms"
_epoch_ms() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    # EPOCHREALTIME is always SSSSSSSSSS.FFFFFF (6-digit, zero-padded
    # fraction), so the first 3 digits of the fraction are milliseconds —
    # no fork needed (the brief's cut-based version forked a subprocess for
    # something bash substring expansion already does).
    # Separate `local` statements, not `local r=X s=$r`: under `set -u`, all
    # RHS expansions in one `local` command are evaluated in the OUTER scope
    # before any of the new bindings take effect, so a later value referring
    # to an earlier name in the same statement sees it as still unset there.
    local r="${EPOCHREALTIME/,/.}"
    local s="${r%%.*}"
    local f="${r#*.}"
    printf '%s%s' "$s" "${f:0:3}"
  else
    printf '%s000' "$(date +%s)"
  fi
}
JSON_T0="$(_epoch_ms)"

# --- checksSkipped accumulation ---------------------------------------------
# Every section that performs checks reports both what it ran and what it
# skipped, with a reason per skip. A skip reads exactly like a pass in a green
# summary, so the skip has to be a value in the document, not an omission —
# the same principle tests/run-tests.sh already applies to the test runner's
# own SKIP lines.
_JSON_SKIP_NAMES=(); _JSON_SKIP_REASONS=()
_json_skip_reset() { _JSON_SKIP_NAMES=(); _JSON_SKIP_REASONS=(); }
_json_skip() { _JSON_SKIP_NAMES+=("$1"); _JSON_SKIP_REASONS+=("$2"); }
_json_skips_json() {
  local i out=""
  for i in "${!_JSON_SKIP_NAMES[@]}"; do
    [[ -n "$out" ]] && out+=$'\n'
    out+="$(printf '%s\t%s' "${_JSON_SKIP_NAMES[$i]}" "${_JSON_SKIP_REASONS[$i]}")"
  done
  [[ -z "$out" ]] && { printf '[]'; return 0; }
  jq -Rn '[inputs | split("\t") | {name: .[0], reason: .[1]}]' <<<"$out"
}

_json_core() {
  jq -n --arg v "$VERSION" --arg p "$(_compat_os)" --arg b "${BASH_VERSION:-unknown}" \
        --arg lib "$CLAUDE_HELPERS_LIB" --arg prec "$_JSON_MS_PRECISION" \
    '{version:$v, platform:$p, bash:$b, lib:$lib, elapsedMsPrecision:$prec}'
}

# Compose the envelope. $1 = comma-separated section list; "meta" selects the
# preamble only. The final `jq -c .` is not cosmetic: it is the guarantee that
# a malformed or not-yet-implemented section (an undefined _json_section_*
# for a name still listed in JSON_SECTIONS_ALL) can never leave this function
# as a half-valid document — it fails the JSON parse and is reported as the
# internal error below, not emitted as truncated JSON.
_json_envelope() {
  local only="${1:-}" sec frag=""
  [[ -z "$only" ]] && only="${JSON_SECTIONS_ALL// /,}"

  # One scan per invocation, in THIS shell, handed to every consumer as an
  # argument. Deliberately not a memo: every _json_section_* call below runs
  # inside its own `$(...)` (the frag+="$(...)" below), and a shell-variable
  # cache assigned INSIDE one of those dies with that subshell the instant it
  # exits — the only thing that actually works is computing the scan here,
  # in _json_envelope's own (non-subshell) frame, and passing the resulting
  # STRING down as an argument. chats and issues need the session-state scan
  # (_session_rows); processes needs the OS-process-table scan
  # (_ps_snapshot_rows) instead — it has no Claude-session dependency at all,
  # unlike the OLD processes section this replaces, which only ever re-served
  # _DOCTOR_ISSUES text. issues ALSO needs one _doctor_warnings pass (which
  # itself consumes both scans) to populate _DOCTOR_ISSUES — computed once
  # here and serialized to a string, since _DOCTOR_ISSUES (a bash array)
  # would be just as subshell-fragile as a memo if read back after the fact.
  # $ps_rows is handed to _doctor_warnings too (its own optional $2), so
  # issues and processes are built from the exact SAME snapshot rather than
  # two independent `ps` reads a live process could exit between — the same
  # "cannot disagree by construction" guarantee cmd_doctor's own comment
  # documents for _DOCTOR_ISSUES now also holds across this real/fixture scan.
  local rows="" issues_tsv="" ps_rows=""
  case ",$only," in
    *,chats,*|*,issues,*) rows="$(_session_rows || true)" ;;
  esac
  case ",$only," in
    *,issues,*|*,processes,*) ps_rows="$(_ps_snapshot_rows || true)" ;;
  esac
  case ",$only," in
    *,issues,*)
      _DOCTOR_ISSUES=()
      _doctor_warnings "$rows" "$ps_rows" >/dev/null 2>&1 || true
      issues_tsv="$(printf '%s\n' "${_DOCTOR_ISSUES[@]+"${_DOCTOR_ISSUES[@]}"}")"
      ;;
  esac

  for sec in ${only//,/ }; do
    case "$sec" in
      meta) continue ;;
      chats)
        [[ -n "$frag" ]] && frag+=","
        frag+="$(printf '"%s":%s' "$sec" "$(_json_section_chats "$rows")")" ;;
      issues)
        [[ -n "$frag" ]] && frag+=","
        frag+="$(printf '"%s":%s' "$sec" "$(_json_section_issues "$rows" "$issues_tsv")")" ;;
      processes)
        [[ -n "$frag" ]] && frag+=","
        frag+="$(printf '"%s":%s' "$sec" "$(_json_section_processes "$ps_rows")")" ;;
      accounts|ledger|schedules)
        [[ -n "$frag" ]] && frag+=","
        frag+="$(printf '"%s":%s' "$sec" "$("_json_section_$sec")")" ;;
      *) echo "claude-session _snapshot: unknown --only section '$sec' (valid: meta ${JSON_SECTIONS_ALL})" >&2
         return 2 ;;
    esac
  done
  # Inlined _epoch_ms body, not `"$(_epoch_ms)"`: capturing ANY command's
  # output via `$(...)` forks a subshell regardless of whether the command
  # itself forks — same cost as the `date +%s` this replaced. Doing the
  # EPOCHREALTIME substring extraction directly in THIS shell (exactly
  # _epoch_ms's own body, inlined) is what actually avoids the fork; calling
  # the function instead of inlining it would not have. One `date +%s` fork
  # remains only on bash<5 (no EPOCHREALTIME), same fallback _epoch_ms uses.
  local _now_ms
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    local _r="${EPOCHREALTIME/,/.}"
    local _s="${_r%%.*}"
    local _f="${_r#*.}"
    _now_ms="${_s}${_f:0:3}"
  else
    _now_ms="$(date +%s)000"
  fi
  printf '{"schemaVersion":%s,"generatedAt":%s,"elapsedMs":%s,"core":%s,"sections":{%s}}' \
    "$JSON_SCHEMA_VERSION" "${_now_ms%???}" "$(( _now_ms - JSON_T0 ))" "$(_json_core)" "$frag" \
    | jq -c . \
    || { echo "claude-session: internal error — an emitter produced invalid JSON" >&2; return 1; }
}

# The `_snapshot` verb's body: one envelope, so one poll cycle is one process
# and the account/ps/tmux snapshots happen once for all sections. Requires
# --json — there is no human rendering of an envelope and there will not be
# one.
cmd_snapshot() {
  (( JSON_OUT == 1 )) || { echo "claude-session _snapshot: requires --json" >&2; exit 2; }
  _json_envelope "$SNAP_ONLY"
}

# ---- accounts section -------------------------------------------------------
# One row per account, in _all_accounts order (synthetic "default" first, then
# registry order) so the app's pane order matches the CLI's listing order.
#
# `credentials` mirrors cmd_accounts_ls's single criterion (.credentials.json
# present) rather than inventing a second opinion about what "logged in"
# means. Account resolution goes entirely through _all_accounts/ACCT_DESC —
# the one place that reads accounts.conf — so this never becomes a second,
# independent parser of that file (accounts.conf is bash source, not data;
# a second reader is how a chat ends up filed under the wrong account).
#
# A registered account whose config dir was never created (never logged in,
# or hand-removed) still gets a row: credentials is false — a verified fact,
# not a guess — never true and never simply absent. Dropping the row instead
# would let a broken account look like it was never registered at all, which
# is its own way of rendering "missing" as if it were fine.
_json_section_accounts() {
  _json_skip_reset
  # The quota anchor has no storage in this build. An absent field would be
  # indistinguishable from "no anchor set", so it is reported as a check that
  # did not run, not omitted.
  _json_skip "quota-anchor" "quota.conf support is not in this build yet"
  local rows="" name dir
  while IFS=$'\t' read -r name dir; do
    local desc="${ACCT_DESC[$name]:-}"
    # A hand-edited accounts.conf description (or, in principle, a dir) could
    # carry a literal tab/newline — accounts add's `printf %q` round-trips one
    # straight back through the source step. That would not make the JSON
    # invalid (jq still escapes quotes/backslashes fine downstream) but it
    # WOULD shift the TSV row boundary this loop depends on, the exact bug
    # class _SESSION_JQ's own comment already documents twice over. Neutralize
    # before packing the row, not after.
    desc="${desc//$'\t'/ }"; desc="${desc//$'\n'/ }"
    local sdir="${dir//$'\t'/ }"; sdir="${sdir//$'\n'/ }"
    rows+="$(printf '%s\t%s\t%s\t%s' "$name" "$sdir" \
      "$( [[ -f "$dir/.credentials.json" ]] && echo true || echo false )" \
      "$desc")"$'\n'
  done < <(_all_accounts)
  local items
  items="$(jq -Rn '[inputs | select(length>0) | split("\t")
    | {name: .[0], dir: .[1], credentials: (.[2]=="true"), description: .[3]}]' <<<"$rows")"
  jq -n --argjson items "$items" --argjson skipped "$(_json_skips_json)" \
    '{status:"ok", checksRun:["registry","credentials"], checksSkipped:$skipped,
      errors:[], items:$items}'
}

# ---- chats section -----------------------------------------------------------
# Entrypoint dependencies read at call time only (same convention as this
# file's own header comment): _session_rows, _compute_pid_flags,
# PID_FLAG_TEXT, _ram_load, _RAM_KB_CACHE, _all_accounts, _build_transfer_index/
# TR_*, _transcript_for_sid, _ledger_provenance_load/
# XFER_BADGE, _ti_lookup_window, _ti_stats, CHAT_LIMIT, _compat_os.

# RSS in MB, or the literal string "unknown". _pid_ram_mb (bin/claude-session)
# returns 0 for a pid the map does not have, and 0 MB reads exactly like
# "verified zero RAM" — indistinguishable from "we could not look", which is
# the whole reason the tri-state fields exist. Reads _RAM_KB_CACHE, the map
# _ram_load already built for this invocation — never a second `ps`.
#
# Pure bash arithmetic (round-to-nearest via +512 before integer division),
# deliberately NOT the awk one-liner an earlier draft of this comment used:
# _json_section_chats calls this up to CHAT_LIMIT (200) times, once per row,
# and an awk fork per row is exactly the cost class this project has already
# paid for four times (lib/titleindex.sh's own history: a per-line `awk`
# inside _ti_load's read loop, and a subshell-memoization bug in
# _titles_window, are two of the four). Calling this via `$(...)` per row
# still forks once per row (unavoidable while the contract is "print a
# value"), but that fork execs nothing, so it costs a fraction of what an
# external-process fork (awk/tail/jq/find) costs.
_rss_get() {
  _ram_load
  local kb="${_RAM_KB_CACHE[$1]:-}"
  [[ -z "$kb" ]] && { printf 'unknown'; return 0; }
  printf '%d' $(( (kb + 512) / 1024 ))
}

# sid -> transcript path for one account, from ONE enumeration pass (the
# existing bounded _build_transfer_index, reused verbatim). Rows whose sid is
# absent here fall back to _transcript_for_sid (the VS Code case, or a
# session-state file that has lost its sessionId) — the emitted
# transcriptPathSource distinguishes the two: a cwd fallback is a guess and
# the app renders it as one.
declare -A _SIDPATH=() _SIDMETA=()
_sid_transcript_map() {
  local acct_dir="$1" limit="${2:-$CHAT_LIMIT}" i
  _build_transfer_index "$acct_dir" "$limit"
  for (( i=1; i<=TR_COUNT; i++ )); do
    local p="${TR_PROJDIR[$i]}/${TR_SID[$i]}.jsonl"
    _SIDPATH[${TR_SID[$i]}]="$p"
    # mtime+size came free from the index build's own stat — carry them keyed by
    # path so the section does not stat these files a second time for the
    # title-index key. Fallback paths (not in the index) still get statted below.
    _SIDMETA[$p]="${TR_MTIME[$i]}"$'\t'"${TR_SIZE[$i]}"
  done
}

# The titlesIndex object, WINDOW-SCOPED on purpose. It carries only what this
# poll can act on: how many of the window's rows resolved from the index
# (`resolved`), how many missed and still need `_titles --sids=` (`pending`),
# and a COARSE presence state.
#
# It deliberately does NOT call _ti_stats/_ti_load. Those read the entire
# append-only index — one line per transcript, growing without compaction — in
# a bash loop, measured at ~206ms on a 2,200-line index and ~760ms at 6,810.
# That is O(total transcripts) on a path that must stay O(window): reading the
# whole cache here to report lifetime `entries/dupes/stale` reintroduced the
# exact cost the windowed design exists to avoid, right next to the window
# lookup (_ti_lookup_window) that was written to avoid it. The whole-cache
# health numbers still exist — `doctor`'s title-index check (8) computes them,
# where an O(total) read once per manual `doctor` run is fine and a per-poll
# read is not.
#
# `state` is derived from the header line alone (one `head -1`), never a full
# parse: present-with-a-valid-header is "warm", anything else "cold". The
# stale/corrupt distinction belongs to check (8), which does the full read.
_json_titles_index_stats() {
  local pending="${1:-0}" resolved="${2:-0}" state="cold"
  if [[ -r "$TITLE_INDEX" ]]; then
    local hdr; hdr="$(head -1 "$TITLE_INDEX" 2>/dev/null || true)"
    [[ "$hdr" == "#v$TITLE_INDEX_VERSION "* ]] && state="warm"
  fi
  jq -n --arg st "$state" --argjson r "$resolved" --argjson p "$pending" \
    '{state:$st, resolved:$r, pending:$p}'
}

CHAT_CRITICAL_FIELDS="sessionId account accountDir transcriptPath runtime.pid runtime.alive"

# $1 = the one _session_rows result for THIS invocation, passed in by
# _json_envelope — never re-scanned (see _json_envelope's own comment for why
# a shell-variable memo cannot substitute for hoisting the one real scan).
#
# Titles come from _ti_lookup_window (the batched index lookup) and nothing
# else — never _title_read/_title_for_file. That is what keeps this
# section's cost independent of the account's transcript count (6,810 on the
# reference host); tests/test_json_chats.sh counts `tail` forks to prove it
# never regresses. A miss increments `pending` and is reported as
# title.state:"unknown" with an empty value — resolving it is the app's job
# (`_titles --sids=`), not this poll's.
_json_section_chats() {
  local src_rows="${1:-}"
  _json_skip_reset
  _ledger_provenance_load
  _ram_load
  _compute_pid_flags "$src_rows"
  local total=0 degraded=0 pending=0 resolved=0 rows=""
  local acct dir

  while IFS=$'\t' read -r acct dir; do
    [[ -n "$acct" ]] || continue
    _SIDPATH=(); _SIDMETA=()
    _sid_transcript_map "$dir" "$CHAT_LIMIT"
    total=$(( total + TR_TOTAL ))

    # Runtime rows for THIS account, keyed by sid, from the ONE shared scan
    # (parallel arrays, not a packed-string tuple: cheaper to read back, and
    # there is nothing here that needs to cross a subshell boundary as a
    # single value). A row whose session-state file has lost its sessionId
    # (upstream corruption — the exact case the criticality test exercises)
    # is kept under the literal key "-": dropping it would hide a live
    # process; keeping it as its own (degraded) row is what "never dropped,
    # degraded and say why" means in practice.
    local -A RT_TMUX=() RT_PID=() RT_CWD=() RT_ENTRY=() RT_STATUS=() RT_BID=() RT_UPD=() RT_ALIVE=()
    local rt_tmux rt_pid rt_cwd rt_entry rt_status rt_sid rt_bid rt_upd rt_alive rt_acct
    while IFS=$'\t' read -r rt_tmux rt_pid rt_cwd rt_entry rt_status rt_sid rt_bid rt_upd rt_alive rt_acct; do
      [[ -n "$rt_tmux" ]] || continue
      [[ "$rt_acct" == "$acct" ]] || continue
      local rk="$rt_sid"; [[ -z "$rk" || "$rk" == "-" ]] && rk="-"
      RT_TMUX[$rk]="$rt_tmux"; RT_PID[$rk]="$rt_pid"; RT_CWD[$rk]="$rt_cwd"
      RT_ENTRY[$rk]="$rt_entry"; RT_STATUS[$rk]="$rt_status"; RT_BID[$rk]="$rt_bid"
      RT_UPD[$rk]="$rt_upd"; RT_ALIVE[$rk]="$rt_alive"
    done <<<"$src_rows"

    # sids to process: every indexed transcript, plus any live runtime the
    # index scan didn't already cover.
    local -a sids=("${!_SIDPATH[@]}")
    local k
    for k in "${!RT_TMUX[@]}"; do
      [[ -n "${_SIDPATH[$k]:-}" ]] || sids+=("$k")
    done

    # Resolve path/source for whatever _SIDPATH didn't cover. Bounded by the
    # (normally tiny) set of live runtimes the index scan missed —
    # _transcript_for_sid's own `find` fork is one per SUCH row, never one
    # per row in the whole window.
    local -A path_of=() src_of=()
    for k in "${!_SIDPATH[@]}"; do path_of[$k]="${_SIDPATH[$k]}"; src_of[$k]="sid-match"; done
    for k in "${sids[@]}"; do
      [[ -n "${path_of[$k]:-}" ]] && continue
      local fp=""
      fp="$(_transcript_for_sid "$k" "${RT_CWD[$k]:-}" "$dir" || true)"
      if [[ -n "$fp" ]]; then path_of[$k]="$fp"; src_of[$k]="cwd-fallback"
      else src_of[$k]=""; fi
    done

    # mtime+size for every resolved path. The window's bulk (everything the
    # index build enumerated) already carries (mtime,size) from that build's
    # own stat — seed from _SIDMETA and stat ONLY the leftover: fallback paths
    # resolved via _transcript_for_sid, which the index did not cover and which
    # are normally a tiny handful (VS Code, or a session-state file that lost
    # its sessionId). This is still ONE stat call, now over that small set
    # instead of a full duplicate pass over all 200 window files (~50ms saved).
    local -A m_of=() sz_of=()
    local -a stat_files=()
    for k in "${sids[@]}"; do
      local pk="${path_of[$k]:-}"
      [[ -n "$pk" ]] || continue
      local meta="${_SIDMETA[$pk]:-}"
      if [[ -n "$meta" ]]; then
        m_of[$pk]="${meta%%$'\t'*}"; sz_of[$pk]="${meta#*$'\t'}"
      else
        stat_files+=("$pk")
      fi
    done
    if (( ${#stat_files[@]} > 0 )); then
      local sp sm ssz
      while IFS=$'\t' read -r sp sm ssz; do
        [[ -z "$sp" ]] && continue
        m_of[$sp]="$sm"; sz_of[$sp]="$ssz"
      done < <(
        case "$(_compat_os)" in
          darwin) stat -f $'%N\t%m\t%z' "${stat_files[@]}" 2>/dev/null ;;
          *)      stat -c $'%n\t%Y\t%s' "${stat_files[@]}" 2>/dev/null ;;
        esac
      )
    fi

    # Batched title lookup: ONE awk pass over the index for this account's
    # whole window (_ti_lookup_window) — never _title_read/_title_for_file.
    local keys=""
    for k in "${sids[@]}"; do
      local fp="${path_of[$k]:-}"
      [[ -n "$fp" ]] && keys+="$fp"$'\t'"${m_of[$fp]:-0}"$'\t'"${sz_of[$fp]:-0}"$'\n'
    done
    local -A hit=()
    if [[ -n "$keys" ]]; then
      local hp hm hs hsrc htitle
      while IFS=$'\t' read -r hp hm hs hsrc htitle; do
        [[ -z "$hp" ]] && continue
        hit["$hp"$'\t'"$hm"$'\t'"$hs"]="$hsrc"$'\x1f'"$htitle"
      done < <(_ti_lookup_window "$keys")
    fi

    # Build rows. Inline concatenation and parameter expansion only — no
    # per-row jq, no per-row herestring, and the one per-row `$(...)` this
    # loop uses (_rss_get, a pure-bash function) forks nothing external. cwd
    # comes from the runtime record only, never a per-row transcript read —
    # see the field's own comment below for why.
    for k in "${sids[@]}"; do
      local fp="${path_of[$k]:-}" psrc="${src_of[$k]:-}"
      # Only index m_of/sz_of when fp is non-empty: `${m_of[""]}` is an empty
      # associative-array subscript, which bash reports as "bad array subscript"
      # on stderr even with a `:-0` default — a live runtime whose sid has no
      # transcript on disk (VS Code, or a not-yet-flushed session) hits exactly
      # that, leaking non-JSON noise into a `2>&1` caller's stream once per row.
      local m="0" sz="0"
      [[ -n "$fp" ]] && { m="${m_of[$fp]:-0}"; sz="${sz_of[$fp]:-0}"; }
      local tstate="unknown" tsource="none" tvalue=""
      if [[ -n "$fp" ]]; then
        local hv="${hit["$fp"$'\t'"$m"$'\t'"$sz"]:-}"
        if [[ -n "$hv" ]]; then
          tstate="known"; tsource="${hv%%$'\x1f'*}"; tvalue="${hv#*$'\x1f'}"
          resolved=$((resolved+1))
        else
          pending=$((pending+1))
        fi
      fi

      local present="false" rpid="" rtmux="" rentry="" rstatus="" rbid="" rupd="" ralive=""
      if [[ -n "${RT_TMUX[$k]:-}" ]]; then
        present="true"
        rpid="${RT_PID[$k]:-}"; rtmux="${RT_TMUX[$k]:-}"; rentry="${RT_ENTRY[$k]:-}"
        rstatus="${RT_STATUS[$k]:-}"; rbid="${RT_BID[$k]:-}"; rupd="${RT_UPD[$k]:-}"; ralive="${RT_ALIVE[$k]:-}"
      fi

      # cwd comes from the runtime record ONLY, never from the transcript.
      # _cwd_in_transcript (titles.sh) reads the file (head + jq — the exact
      # per-row-fork shape this project is done paying for): a transcript-
      # only chat's cwd stays null rather than costing this section a read
      # per row, exactly like an unindexed title stays "unknown" rather than
      # costing a read. Measured: with the read enabled, a 195-row window of
      # transcript-only chats (no live cwd to source) went from ~150ms to
      # ~4.7s — nearly all of it this one per-row fork pair.
      local cwd="${RT_CWD[$k]:-}"

      local attachable="false"
      [[ "$present" == "true" && "$rtmux" != "(detached)" && "$rtmux" != "(vscode)" ]] && attachable="true"

      local ageSec=""
      if [[ "$present" == "true" && "$rupd" =~ ^[0-9]+$ && "$rupd" != "0" ]]; then
        ageSec=$(( $(date +%s) - rupd/1000 ))
      fi

      local rssv="" rsss="unknown"
      if [[ "$present" == "true" && -n "$rpid" && "$rpid" != "-" ]]; then
        local r; r="$(_rss_get "$rpid")"
        [[ "$r" =~ ^[0-9]+$ ]] && { rssv="$r"; rsss="known"; }
      fi

      # Provenance is a property of the CHAT (its transfer history in the
      # ledger), keyed by sid#account independent of whether it is running now —
      # so it is NOT gated on `present`. A transferred chat that has since been
      # closed still carries where it came from; gating on a live runtime
      # silently dropped that ledger fact for exactly the transcript-only rows a
      # chats list is mostly made of. `$k` is the sid for a normal row (a
      # sessionId-less runtime row keys on "-", which no ledger entry uses).
      local prov=""
      if [[ -n "$k" && "$k" != "-" ]]; then
        local pv="${XFER_BADGE["$k#$acct"]:-}"
        [[ -n "$pv" ]] && prov="transfer"$'\x1f'"${pv%%|*}"$'\x1f'"${pv#*|}"
      fi

      # Flags: the SAME per-pid classification `ls` already renders
      # (_compute_pid_flags/PID_FLAG_TEXT), never a second implementation.
      # Its text is ANSI under an interactive `ls`, but --json always runs
      # with NO_COLOR=1 (the entrypoint's own JSON_OUT branch), so by the
      # time this section runs, $Y/$R/$N are already blank — the stored
      # text is plain, no separate stripping needed.
      local flags=""
      if [[ "$present" == "true" && -n "$rpid" ]]; then
        local flagtxt="${PID_FLAG_TEXT[$rpid]:-}"
        if [[ -n "$flagtxt" ]]; then
          local ftok first=1 fsev ftext
          for ftok in $flagtxt; do
            fsev="warning"; ftext="$ftok"
            case "$ftok" in
              stale)     fsev="error";   ftext="pid gone" ;;
              duplicate) ftext="duplicate RC bridge in this project" ;;
              stalled)   ftext="waiting 5+ minutes — phone approval may be lost" ;;
            esac
            (( first )) || flags+=$'\x1e'
            flags+="$ftok"$'\x1f'"$fsev"$'\x1f'"$ftext"
            first=0
          done
        fi
      fi

      # Criticality (spec §6.7): a row that cannot resolve a critical field is
      # emitted with degraded:true and a degradedReason naming the field —
      # NEVER dropped. runtime.pid/runtime.alive are only critical when a
      # runtime is actually present: a transcript-only chat has no runtime by
      # design, and that absence is not degradation.
      local sid_out="$k"
      local degrow=0 reasons=""
      [[ -z "$sid_out" || "$sid_out" == "-" ]] && { degrow=1; reasons+="sessionId "; }
      [[ -z "$acct" ]] && { degrow=1; reasons+="account "; }
      [[ -z "$dir" ]] && { degrow=1; reasons+="accountDir "; }
      [[ -z "$fp" ]] && { degrow=1; reasons+="transcriptPath "; }
      if [[ "$present" == "true" ]]; then
        [[ -z "$rpid" || "$rpid" == "-" ]] && { degrow=1; reasons+="runtime.pid "; }
        [[ "$ralive" != "0" && "$ralive" != "1" ]] && { degrow=1; reasons+="runtime.alive "; }
      fi
      (( degrow )) && degraded=$((degraded+1))
      reasons="${reasons% }"

      local aliveout=""; [[ "$present" == "true" ]] && aliveout="$ralive"

      # `printf -v`, not `rows+="$(printf ...)"` : the latter forks a subshell
      # PER ROW just to capture printf's own stdout back into a variable —
      # exactly the per-row-fork hazard this module's header warns about, and
      # measured here: 200 of these turned a 400ms-budget window into ~3.5s
      # by themselves, on top of everything else. `-v` writes straight into
      # the variable with no fork at all.
      local _row
      printf -v _row '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
        "$sid_out" "$acct" "$dir" "$fp" "$psrc" \
        "$tvalue" "$tstate" "$tsource" \
        "$cwd" "$m" \
        "$present" "$rpid" "$rtmux" "$attachable" "$rentry" "$rstatus" "$ageSec" "$rssv" "$rsss" "$rbid" "$aliveout" \
        "$flags" "$prov" \
        "$degrow" "$reasons"
      rows+="$_row"$'\n'
    done
  done < <(_all_accounts)

  # Emitted only after the rows are counted: a skip has to carry a real
  # number, and "0 pending" is not a skip at all.
  (( pending > 0 )) && _json_skip "titles-window" \
    "$pending title(s) are not in the index — fetch them with: claude-session _titles --json --sids=<csv>"

  # ONE jq process for the whole section, fed via stdin -- never split into a
  # first call that builds `items` and a second `--argjson items "$items"`
  # that hands it back in on the COMMAND LINE. That second shape is not just
  # a needless extra fork: past ~128KB (Linux's per-argument MAX_ARG_STRLEN,
  # independent of the ~2MB total ARG_MAX `getconf` reports) `execve` fails
  # outright with E2BIG ("Argument list too long") -- measured here at 200
  # real rows (items ~157KB), which reliably exceeds it. Building the whole
  # envelope fragment in the SAME jq invocation that parses `$rows` means the
  # per-row payload only ever travels through a pipe, which has no such limit.
  jq -Rn --argjson skipped "$(_json_skips_json)" \
        --argjson total "$total" --argjson limit "$CHAT_LIMIT" --argjson degraded "$degraded" \
        --argjson idx "$(_json_titles_index_stats "$pending" "$resolved")" \
    '[inputs | select(length>0) | split("\t") | {
        sessionId: (if .[0]=="" or .[0]=="-" then null else .[0] end),
        account: .[1],
        accountDir: .[2],
        transcriptPath: (if .[3]=="" then null else .[3] end),
        transcriptPathSource: .[4],
        title: {value: .[5], state: .[6], source: .[7]},
        cwd: (if .[8]=="" then null else .[8] end),
        mtime: (if .[9]=="" then null else (.[9]|tonumber) end),
        runtime: {
          present: (.[10]=="true"),
          pid: (if .[11]=="" or .[11]=="-" then null else (.[11]|tonumber) end),
          tmux: (if .[12]=="" then null else .[12] end),
          attachable: (.[13]=="true"),
          entrypoint: (if .[14]=="" then null else .[14] end),
          status: (if .[15]=="" then null else .[15] end),
          statusAgeSec: (if .[16]=="" then null else (.[16]|tonumber) end),
          rss: {value: (if .[17]=="" then null else (.[17]|tonumber) end), state: .[18]},
          bridgeSessionId: (if .[19]=="" or .[19]=="-" then null else .[19] end),
          alive: (if .[20]=="" then null else (.[20]=="1") end)
        },
        flags: (if .[21]=="" then [] else
            (.[21] | split("") | map(select(length>0) | split("")
              | {kind:.[0], severity:.[1], text:.[2]}))
          end),
        provenance: (if .[22]=="" then null else
            (.[22] | split("") | {kind:.[0], from:.[1], ts:(.[2]|tonumber)})
          end),
        degraded: (.[23]=="1"),
        degradedReason: (if .[24]=="" then null else .[24] end)
      }] as $items
    | {status: (if $degraded>0 then "partial" else "ok" end),
       checksRun:["transcripts","runtime","provenance","titles-index"], checksSkipped:$skipped,
       errors:[], limit:$limit, total:$total, truncated:(($items|length) < $total),
       degraded:$degraded, titlesIndex:$idx, items:$items}' <<<"$rows"
}

# ---- issues section ---------------------------------------------------------
# Reads the SAME _DOCTOR_ISSUES rows bin/claude-session's _doctor_warnings
# built — one implementation (the checks themselves, refactored to append a
# structured row alongside their existing human-text printf), two renderings
# (the human `doctor` text, unchanged, and this JSON section). $1/$2 are
# passed in by _json_envelope, computed ONCE per invocation.
#
# Pure bash, no `jq` here — this used to ALSO shape the filtered rows into
# `{kind,severity,...}` objects via its own `jq -Rn`, and the section's own
# closing jq then took that array BACK in via `--argjson` just to wrap it in
# `{status,checksRun,...}` — two forks to do what one can, since jq can just
# as easily read these same tab-separated rows off stdin directly (exactly
# how _json_section_chats' own single closing jq already works). Splitting
# this into "filter" (bash) and "shape+wrap" (one jq, below) cut this
# section's half of a `doctor --json`/`_snapshot` call from jq forks to one.
#
# The processes section below no longer shares this _DOCTOR_ISSUES-text
# implementation (see its own header comment for why) — this bash filter and
# its jq shaping now serve issues alone.
_json_issues_rows_for() {
  local tsv="$1" want=" $2 " rows=""
  local kind sev pid sid text
  while IFS=$'\t' read -r kind sev pid sid text; do
    [[ -z "$kind" ]] && continue
    case "$want" in *" $kind "*) ;; *) continue ;; esac
    # Inline concatenation, not `$(printf ...)`: the fields are already
    # exactly what's being re-joined, so there is nothing for printf to do
    # here that a fork would be worth paying for.
    rows+="$kind"$'\t'"$sev"$'\t'"$pid"$'\t'"$sid"$'\t'"$text"$'\n'
  done <<<"$tsv"
  printf '%s' "$rows"
}

# $1 = _session_rows output for this invocation (to tell "ran, found nothing"
# apart from "nothing to check" — see below); $2 = the _DOCTOR_ISSUES rows.
#
# Covers checks (1)-(5) AND (8)-(9): every _DOCTOR_ISSUES kind that isn't one
# of processes' two (orphan-process, stuck-build — checks 6-7, OS-process-table
# scans that always run). Title-index health (8) and upstream schema drift (9)
# used to feed neither JSON section at all — bin/claude-session's own
# _doctor_warnings comment called that out as an undercount risk, since a
# monitor trusting doctor's exit status would never learn its title index
# degraded. They run unconditionally (not gated on $rows having any session to
# look at), so their items/checksRun entries are never part of the
# no-sessions skip below — only checks (1)-(5) are.
_json_section_issues() {
  local rows="${1:-}" issues_tsv="${2:-}"
  _json_skip_reset
  local session_checknames="same-chat-twice rc-bridge-shared duplicate-bridge stalled stale"
  local always_checknames="title-index upstream-field"
  local checknames="$session_checknames $always_checknames"
  if [[ -z "$rows" ]]; then
    # Checks (1)-(5) inspect Claude session-state files (_doctor_warnings'
    # own guard: `if [[ -n "$rows" ]]`) — with none to check, every one of
    # them is a check that did not run, not a check that ran and passed.
    local c
    for c in $session_checknames; do _json_skip "$c" "no Claude session-state files to check"; done
  fi
  # ONE jq for the whole section: filtered TSV rows in via stdin, checknames
  # in via --arg (split inside jq — no separate fork just to turn a
  # space-joined string into a JSON array), skip list in via --argjson.
  local filtered; filtered="$(_json_issues_rows_for "$issues_tsv" "$checknames")"
  jq -Rn --argjson skipped "$(_json_skips_json)" --arg cr "$checknames" \
    '[inputs | select(length>0) | split("\t") | {
        kind: .[0], severity: .[1],
        # pid is a NUMBER, matching the chats runtime.pid field — a typed
        # consumer decodes "pid" the same way in every section. These are
        # OS/session pids, always numeric; empty or "-" stays null.
        pid: (if .[2]=="" or .[2]=="-" then null else (.[2]|tonumber) end),
        sessionId: (if .[3]=="" or .[3]=="-" then null else .[3] end),
        text: .[4]
      }] as $items
    | {status:"ok", checksRun:($cr|split(" ")), checksSkipped:$skipped, errors:[], items:$items}' \
    <<<"$filtered"
}

# ---- processes section ------------------------------------------------------
# Unlike issues (above), this does NOT read _DOCTOR_ISSUES text — it drives
# _orphan_rows/_stuck_build_rows/_orphan_activity directly off ONE
# _ps_snapshot_rows table ($1, computed once by _json_envelope and shared
# with _doctor_warnings — see that function's own header), so the Processes
# place gets the SAME structured fields (pid, elapsedSec, class, a real
# activity.subtree, …) that bin/claude-session's own doctor checks (6)-(7)
# reason from, not a re-serialization of their human text. Checks (6)-(7)
# scan the OS process table directly and always run, with or without any
# Claude session — so this section is never "skipped" for lack of sessions,
# only ever ok with items:[] on a clean box. An EMPTY/unreadable process
# table is different: that is "nothing was checked", not "checked and
# clean", so it is its own checksSkipped entry, never a silent clean pass.
#
# One row per _orphan_rows pid (class "orphan") and one row per
# _stuck_build_rows pid (class "stuck-build") — the SAME two scans
# _doctor_warnings' checks (6)-(7) run, so this section's item count can
# never drift from the issues section's orphan-process/stuck-build count
# (cmd_doctor's own JSON exit-status math sums both): a pid matching BOTH
# scans (the exact shape of the 2026-08-03 finding — an orphaned build that
# is also a stuck build) gets two items, one per class, exactly as
# _doctor_warnings' two independent _di_add calls already would.
#
# reapable is true only for state=="idle" — "suspect" is NEVER auto-reaped
# (see _orphan_activity's own header for why a no-progress sample is a
# suspicion, not a confirmed hang), which is why it reads reapable:false
# same as "active" despite being overridable with --force. reapBlockedBy
# names WHICH guard is blocking a reap, for a UI that wants to render the
# --force affordance only where it actually applies.
_json_section_processes() {
  local ps_rows="${1:-}"
  _json_skip_reset
  local rows=""
  if [[ -z "$ps_rows" ]]; then
    _json_skip "orphans" "the process table was empty or unreadable"
  else
    # pid -> ppid, built ONCE in-shell (no fork) from the same table: orphan
    # rows are ppid==1 by definition (_orphan_rows' own filter), but a stuck
    # build can have any parent ("regardless of parentage" is that check's
    # whole point), so its row alone doesn't carry ppid — this is the only
    # other place that needs it.
    local -A _jp_ppid=()
    local jp_pid jp_ppid jp_rest
    while IFS=$'\t' read -r jp_pid jp_ppid jp_rest; do
      [[ -z "$jp_pid" ]] && continue
      _jp_ppid[$jp_pid]="$jp_ppid"
    done <<<"$ps_rows"

    local orphan_rows stuck_rows
    orphan_rows="$(_orphan_rows "$ps_rows" || true)"
    stuck_rows="$(_stuck_build_rows "$ps_rows" || true)"

    local pid etimes pcpu comm args act state reason subtree cmd reapable blockedby _row
    if [[ -n "$orphan_rows" ]]; then
      while IFS=$'\t' read -r pid etimes pcpu comm args; do
        [[ -z "$pid" ]] && continue
        act="$(_orphan_activity "$pid" "$ps_rows")"
        IFS=$'\t' read -r state reason subtree <<<"$act"
        cmd="$(_short_cmd "$args")"
        case "$state" in
          idle)    reapable="true";  blockedby="" ;;
          active)  reapable="false"; blockedby="active-subtree" ;;
          suspect) reapable="false"; blockedby="suspect-no-progress" ;;
          *)       reapable="false"; blockedby="" ;;
        esac
        printf -v _row '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
          "$pid" "${_jp_ppid[$pid]:-1}" "$etimes" "$pcpu" "$comm" "$cmd" "$args" "orphan" \
          "$state" "$reason" "$subtree" "$reapable" "$blockedby"
        rows+="$_row"$'\n'
      done <<<"$orphan_rows"
    fi
    if [[ -n "$stuck_rows" ]]; then
      while IFS=$'\t' read -r pid etimes pcpu comm args; do
        [[ -z "$pid" ]] && continue
        act="$(_orphan_activity "$pid" "$ps_rows")"
        IFS=$'\t' read -r state reason subtree <<<"$act"
        cmd="$(_short_cmd "$args")"
        case "$state" in
          idle)    reapable="true";  blockedby="" ;;
          active)  reapable="false"; blockedby="active-subtree" ;;
          suspect) reapable="false"; blockedby="suspect-no-progress" ;;
          *)       reapable="false"; blockedby="" ;;
        esac
        printf -v _row '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
          "$pid" "${_jp_ppid[$pid]:-}" "$etimes" "$pcpu" "$comm" "$cmd" "$args" "stuck-build" \
          "$state" "$reason" "$subtree" "$reapable" "$blockedby"
        rows+="$_row"$'\n'
      done <<<"$stuck_rows"
    fi
  fi

  # ONE jq for the whole section: the TSV rows in via stdin, the subtree's
  # own \x1e/\x1f sub-delimiters in via --arg (never embedded as literal
  # bytes in the jq program text, so this stays legible/greppable) — the
  # same tri-level-delimiter shape _json_section_chats' own flags field
  # already uses, applied here to a per-item array instead of a per-item enum.
  jq -Rn --argjson skipped "$(_json_skips_json)" --arg RS $'\x1e' --arg US $'\x1f' \
    '[inputs | select(length>0) | split("\t") | {
        pid: (.[0]|tonumber),
        ppid: (if .[1]=="" or .[1]=="-" then null else (.[1]|tonumber) end),
        elapsedSec: (.[2]|tonumber),
        pcpu: (.[3]|tonumber),
        comm: .[4],
        cmd: .[5],
        argsFull: .[6],
        class: .[7],
        activity: {
          state: .[8],
          reason: (if .[9]=="" then null else .[9] end),
          subtree: (
            if .[10]=="" then [] else
              (.[10] | split($RS) | map(select(length>0) | split($US)
                | {pid:(.[0]|tonumber), cmd:.[1], pcpu:(.[2]|tonumber)}))
            end
          )
        },
        reapable: (.[11]=="true"),
        reapBlockedBy: (if .[12]=="" then null else .[12] end)
      }] as $items
    | {status:"ok", checksRun:["orphans","stuck-builds"], checksSkipped:$skipped,
       errors:[], items:$items}' \
    <<<"$rows"
}
