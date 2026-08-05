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
  # STRING down as an argument. chats needs the session-state scan; issues
  # and processes need both the scan AND one _doctor_warnings pass (which
  # itself consumes that same scan) to populate _DOCTOR_ISSUES — computed
  # once here and serialized to a string, since _DOCTOR_ISSUES (a bash array)
  # would be just as subshell-fragile as a memo if read back after the fact.
  local rows="" issues_tsv=""
  case ",$only," in
    *,chats,*|*,issues,*|*,processes,*) rows="$(_session_rows || true)" ;;
  esac
  case ",$only," in
    *,issues,*|*,processes,*)
      _DOCTOR_ISSUES=()
      _doctor_warnings "$rows" >/dev/null 2>&1 || true
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
        frag+="$(printf '"%s":%s' "$sec" "$(_json_section_processes "$issues_tsv")")" ;;
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

# ---- issues + processes sections -------------------------------------------
# Both read the SAME _DOCTOR_ISSUES rows bin/claude-session's _doctor_warnings
# built — one implementation (the checks themselves, refactored to append a
# structured row alongside their existing human-text printf), two renderings
# (the human `doctor` text, unchanged, and these two JSON sections). $1/$2 are
# passed in by _json_envelope, computed ONCE per invocation — _doctor_warnings
# forks the OS process table scan for checks (6)-(7), so re-running it once
# per section here would double that cost for nothing.
#
# Pure bash, no `jq` here — this used to ALSO shape the filtered rows into
# `{kind,severity,...}` objects via its own `jq -Rn`, and each section's own
# closing jq then took that array BACK in via `--argjson` just to wrap it in
# `{status,checksRun,...}` — two forks to do what one can, since jq can just
# as easily read these same tab-separated rows off stdin directly (exactly
# how _json_section_chats' own single closing jq already works). Splitting
# this into "filter" (bash) and "shape+wrap" (one jq, in each section below)
# cut the issues+processes half of a `doctor --json`/`_snapshot` call from 5
# jq forks to 2.
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

# $1 = the _DOCTOR_ISSUES rows. Checks (6)-(7) scan the OS process table
# directly and always run, with or without any Claude session — so this
# section is never "skipped", only ever ok with items:[] on a clean box.
_json_section_processes() {
  local issues_tsv="${1:-}"
  _json_skip_reset
  local filtered; filtered="$(_json_issues_rows_for "$issues_tsv" "orphan-process stuck-build")"
  jq -Rn --argjson skipped "$(_json_skips_json)" \
    '[inputs | select(length>0) | split("\t") | {
        kind: .[0], severity: .[1],
        # pid is a NUMBER, matching the chats runtime.pid field — a typed
        # consumer decodes "pid" the same way in every section. These are
        # OS/session pids, always numeric; empty or "-" stays null.
        pid: (if .[2]=="" or .[2]=="-" then null else (.[2]|tonumber) end),
        sessionId: (if .[3]=="" or .[3]=="-" then null else .[3] end),
        text: .[4]
      }] as $items
    | {status:"ok", checksRun:["orphan-process","stuck-build"], checksSkipped:$skipped,
       errors:[], items:$items}' \
    <<<"$filtered"
}

# ---- ledger section ----------------------------------------------------------
# Entrypoint dependencies read at call time only (lib/ledger.sh's own
# convention, applied here since this is the one place json.sh reads them):
# LEDGER_FILE, TRANSFER_LIMIT, _account_dir_or_default, _compat_os.
#
# One jq over $LEDGER_FILE producing the raw window — newest ts first, capped
# at TRANSFER_LIMIT (0 = unbounded, the same convention _build_transfer_index
# already uses for its own limit argument) — plus the FILE-WIDE undoOf set, so
# "already undone" stays correct even when the undo entry itself falls outside
# the window (it normally sorts near the top, but nothing guarantees that for
# a small --limit). Titles are neutralized for tab/newline the same way
# accounts' description field is: free text (a chat title) can carry either,
# and an embedded newline would otherwise split one entry into two "rows" for
# the TSV parse below — the exact hazard _json_section_accounts' own comment
# already documents for account descriptions. `join("\t")`, not `@tsv`: @tsv
# doubles a literal backslash in the title along with escaping the tab, which
# is not what a title that happens to contain a backslash should come out as.
#
# The renamed field: the ledger stores the entry's own timestamp as `ts`; this
# section reports it as `transferTs`, alongside `destMtime`, because those two
# instants are what every downstream divergence check actually compares — a
# bare `ts` next to `destMtime` invites the reader to guess which side is
# which.
_json_section_ledger() {
  _json_skip_reset
  if [[ ! -f "$LEDGER_FILE" ]]; then
    _json_skip "endpoints" "no ledger file yet"
    jq -n --argjson skipped "$(_json_skips_json)" \
      '{status:"ok", checksRun:["ledger","endpoints","divergence"], checksSkipped:$skipped,
        errors:[], limit:0, total:0, truncated:false, items:[]}'
    return 0
  fi

  local limit="${TRANSFER_LIMIT:-50}"
  [[ "$limit" =~ ^[0-9]+$ ]] || limit=50

  # First fork: the whole file, slurped once, so the undoOf set is computed
  # over EVERY entry while the window (what actually becomes `items`) is
  # capped at $limit. Line 1 of the output is the file's total entry count (a
  # bare integer, never a tab/newline); every line after that is one windowed
  # entry as a TSV row. `-s` (slurp) is why a genuinely malformed line fails
  # the WHOLE parse rather than silently dropping just that line — a corrupt
  # ledger is an error, not a gap.
  # `//` substitutes only for null/false, never an empty string, and — the
  # sharper hazard — tab is IFS *whitespace*, so a genuinely empty field
  # between two others is not just wrong, it SHIFTS every field after it one
  # slot left the moment bash `read` sees the resulting adjacent tabs as one
  # collapsed delimiter (measured: an all-null undoOf/redoOf on a fresh
  # move/copy entry landed its own isundone flag in the undoOf column and
  # pushed destExists/sourceExists/destMtime out of the row entirely). Every
  # field that can be null OR "" gets the same non-empty sentinel
  # _session_rows already uses for exactly this reason: "-", decoded back to
  # null (or, for title, back to "") in the closing jq below — never emitted
  # as a bare empty string into a tab-delimited row.
  local raw rc
  raw="$(jq -r -s --argjson limit "$limit" '
    . as $all
    | ($all | map(.undoOf) | map(select(. != null))) as $undone
    | ($all | sort_by(-.ts)) as $sorted
    | ( [ ($all|length) | tostring ]
        + [ (if $limit>0 then $sorted[0:$limit] else $sorted end)[]
            | [ .id, (.ts|tostring),
                (if (.sid // "")=="" then "-" else .sid end),
                (if (.title // "")=="" then "-" else (.title | gsub("[\t\n]"; " ")) end),
                .from, .to, .verb,
                (if (.undoOf // "")=="" then "-" else .undoOf end),
                (if (.redoOf // "")=="" then "-" else .redoOf end),
                (if (.id as $i | ($undone | index($i))) then "1" else "0" end)
              ] | join("\t")
          ]
      )[]
  ' "$LEDGER_FILE" 2>/dev/null)"; rc=$?

  local errors_json="[]"
  if (( rc != 0 )); then
    errors_json='["the ledger file could not be parsed as JSON — entries may be corrupted"]'
    raw=""
  fi

  local total=0 rows="" _first=1 _line
  while IFS= read -r _line; do
    if (( _first )); then
      [[ "$_line" =~ ^[0-9]+$ ]] && total="$_line"
      _first=0
      continue
    fi
    [[ -n "$_line" ]] && rows+="$_line"$'\n'
  done <<<"$raw"

  # Pass 1: resolve endpoints via a glob EXPANSION — bash's own readdir
  # matching, never a `find` fork (_build_transfer_index already established
  # that a per-file find/stat fork is the exact cost this module exists to
  # avoid). Account directories are resolved through _account_dir_or_default
  # once PER DISTINCT ACCOUNT NAME, memoized in ACCTDIR — not once per ledger
  # entry — because capturing that function's result through `$(...)` forks
  # regardless of the function body being fork-free, and ledger entries repeat
  # the same handful of account names far more often than they introduce a new
  # one. Destination paths that resolve are collected into stat_paths,
  # deferred to ONE batched `stat` after this loop (same shape as the chats
  # section's own leftover-stat batching above) instead of one `_file_mtime`
  # (its own stat fork) per entry.
  #
  # `shopt -s nullglob` is NOT optional here: without it, a glob that matches
  # nothing expands to its own unexpanded literal pattern string (one
  # element, asterisk and all) instead of zero elements — so `hits` reads as
  # non-empty and every endpoint looks like it exists, regardless of whether
  # a file is actually there. This is a global, process-wide shell option
  # (not scoped to this function), and `_json_section_ledger` can run as the
  # very first thing a process does (`--only=ledger`, or `transfer
  # log --json`) with no earlier section (chats' own transcript scan, via
  # _build_transfer_index) to have already turned it on — so it cannot be
  # left implicit here the way it can in a function only ever reached after
  # one of those.
  shopt -s nullglob
  local -A ACCTDIR=()
  local -a stage=() stat_paths=()
  local id ts sid title from to verb undoof redoof isundone
  while IFS=$'\t' read -r id ts sid title from to verb undoof redoof isundone; do
    [[ -n "$id" ]] || continue
    [[ -n "${ACCTDIR[$to]+x}" ]]   || ACCTDIR[$to]="$(_account_dir_or_default "$to")"
    [[ -n "${ACCTDIR[$from]+x}" ]] || ACCTDIR[$from]="$(_account_dir_or_default "$from")"
    local to_dir="${ACCTDIR[$to]}" from_dir="${ACCTDIR[$from]}"
    local -a hits=()
    local dest_exists=false src_exists=false dest_path=""
    if [[ -n "$sid" && "$sid" != "-" ]]; then
      hits=("$to_dir/projects"/*/"$sid.jsonl")
      if (( ${#hits[@]} > 0 )); then dest_exists=true; dest_path="${hits[0]}"; stat_paths+=("$dest_path"); fi
      hits=("$from_dir/projects"/*/"$sid.jsonl")
      (( ${#hits[@]} > 0 )) && src_exists=true
    fi
    local _tuple
    printf -v _tuple '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s' \
      "$id" "$ts" "$sid" "$title" "$from" "$to" "$verb" "$undoof" "$redoof" "$isundone" \
      "$dest_exists" "$src_exists" "$dest_path"
    stage+=("$_tuple")
  done <<<"$rows"

  local -A MTIME=()
  if (( ${#stat_paths[@]} > 0 )); then
    local sp sm
    while IFS=$'\t' read -r sp sm; do
      [[ -z "$sp" ]] && continue
      MTIME[$sp]="$sm"
    done < <(
      case "$(_compat_os)" in
        darwin) stat -f $'%N\t%m' "${stat_paths[@]}" 2>/dev/null ;;
        *)      stat -c $'%n\t%Y' "${stat_paths[@]}" 2>/dev/null ;;
      esac
    )
  fi

  # Pass 2: fold destMtime in and hand the whole window to ONE closing jq —
  # `printf -v`, not `final+="$(printf ...)"`, for the same reason
  # _json_section_chats' own row-build loop uses `-v`: capturing printf's own
  # stdout back into a variable forks a subshell per row for nothing.
  local final="" f
  for f in "${stage[@]+"${stage[@]}"}"; do
    IFS=$'\x1f' read -r id ts sid title from to verb undoof redoof isundone dest_exists src_exists dest_path <<<"$f"
    local dmt=""
    [[ -n "$dest_path" ]] && dmt="${MTIME[$dest_path]:-}"
    local _row
    printf -v _row '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
      "$id" "$ts" "$sid" "$title" "$from" "$to" "$verb" "$undoof" "$redoof" "$isundone" \
      "$dest_exists" "$src_exists" "$dmt"
    final+="$_row"$'\n'
  done

  jq -Rn --argjson skipped "$(_json_skips_json)" --argjson errors "$errors_json" \
        --argjson total "$total" --argjson limit "$limit" \
    '[inputs | select(length>0) | split("\t") | {
        id: .[0],
        sid: (if .[2]=="-" then null else .[2] end),
        title: (if .[3]=="-" then "" else .[3] end),
        from: .[4], to: .[5], verb: .[6],
        undoOf: (if .[7]=="-" then null else .[7] end),
        redoOf: (if .[8]=="-" then null else .[8] end),
        destExists: (.[10]=="true"),
        sourceExists: (.[11]=="true"),
        transferTs: (.[1]|tonumber),
        destMtime: (if .[12]=="" then null else (.[12]|tonumber) end),
        diverged: (.[10]=="true" and .[12]!="" and ((.[12]|tonumber) > ((.[1]|tonumber) + 2))),
        undoable: (.[10]=="true" and .[9]!="1")
      }] as $items
    # "error", not "ok": a ledger that failed to PARSE is a check that could
    # not run trustworthily, not a check that ran and happened to find
    # nothing — the same distinction the "unavailable never renders like
    # empty-ok" rule draws for schedules, one level up (section-wide instead
    # of per-host).
    | {status: (if ($errors|length) > 0 then "error" else "ok" end),
       checksRun:["ledger","endpoints","divergence"], checksSkipped:$skipped,
       errors:$errors, limit:$limit, total:$total, truncated:(($items|length) < $total), items:$items}' \
    <<<"$final"
}

# ---- schedules section --------------------------------------------------------
# systemd is the only backend today (launchd is a separate spec), so a host
# without a working `systemctl --user` cannot answer the question at all. That
# is `unavailable` with a reason — deliberately NOT an empty list, which reads
# as "no schedules" and is the exact failure mode the "unavailable must never
# render like empty-ok" rule forbids.
#
# Entrypoint dependencies read at call time only: SCHED_DIR, _compat_os.
_systemd_available() {
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl --user list-timers >/dev/null 2>&1
}

# One pass over $SCHED_DIR/*/meta (each meta sourced the same way
# cmd_schedule_ls already does — every consumed name re-declared `local`
# immediately before the source, so a field ONE schedule's meta omits can
# never leak the PREVIOUS schedule's value into its row), plus at most two
# batched `systemctl --user` calls for the whole section — never one per
# schedule:
#   - `list-timers --output=json` for nextFire/lastFire. Verified against a
#     real systemd (255): with JSON output the NEXT/LAST columns are raw usec
#     integers, not the locale-formatted date strings the plain-text table
#     renders — exactly the unambiguous instant this field needs to be, with
#     no date-parsing fork required at all.
#   - `show 'claude-schedule-*.timer' -p Id -p ActiveState` for unitState,
#     accepting the glob the same way `list-timers 'claude-schedule-*'`
#     already does elsewhere in this file's sibling module.
# Both are skipped entirely when there are no schedules to join them against.
#
# nextFire/lastFire are tri-state on purpose: a timer systemd does not list
# (or lists with no recorded last-trigger yet) yields {value:null,
# state:"unknown"} — never epoch 0, which would read as a real instant instead
# of "never observed".
#
# whenTz/tzSource/tzVerified and drift are honest unknowns in this build: the
# zone this schedule's clock time is anchored to, and what it would even mean
# to drift, are both later tasks (12 and 14 respectively). `pings` — how many
# times this schedule has actually fired — is the same kind of unknown: there
# is no counter for it yet (systemd's own timer state doesn't carry one, and
# computing it would mean a journalctl read this build does not do), so it is
# reported as null rather than guessed at or silently omitted.
_json_section_schedules() {
  _json_skip_reset
  if ! _systemd_available; then
    jq -n --arg p "$(_compat_os)" \
      '{status:"unavailable",
        reason:"systemctl --user is not available on this host, so schedules cannot be read",
        platform:$p, checksRun:[], checksSkipped:[], errors:[], items:[]}'
    return 0
  fi

  local rows="" d sid_dir
  shopt -s nullglob
  for sid_dir in "$SCHED_DIR"/*/; do
    [[ -f "$sid_dir/meta" ]] || continue
    d="$(basename "$sid_dir")"
    local target="" sid="" account="" mode="" model="" keepalive="" cwd="" timeout="" \
          when_kind="" when_val="" first="" created="" done=""
    # shellcheck disable=SC1091
    . "$sid_dir/meta" 2>/dev/null || true
    # Neutralize tab/newline defensively (meta values normally round-trip
    # through `printf %q`, but a hand-edited meta could still smuggle one in),
    # AND map a genuinely empty value to "-" — sid is legitimately empty for
    # target=="new" (no chat to name yet), and a hand-pruned or partially
    # written meta could leave any other field blank too. Every one of these
    # sits mid-row, so a bare empty value is the exact "tab is IFS whitespace"
    # hazard the ledger section above ran into: the run of two adjacent tabs
    # an empty field produces collapses into ONE delimiter under `read`,
    # shifting every field after it one slot left. "-" is the same non-empty
    # sentinel _session_rows already uses for this, decoded back to
    # null/empty in the closing jq below.
    local acct2="${account//$'\t'/ }"; acct2="${acct2//$'\n'/ }"; [[ -z "$acct2" ]] && acct2="-"
    local tgt2="${target//$'\t'/ }"; tgt2="${tgt2//$'\n'/ }"; [[ -z "$tgt2" ]] && tgt2="-"
    local sid2="${sid//$'\t'/ }"; sid2="${sid2//$'\n'/ }"; [[ -z "$sid2" ]] && sid2="-"
    local wk2="${when_kind//$'\t'/ }"; wk2="${wk2//$'\n'/ }"; [[ -z "$wk2" ]] && wk2="-"
    local wv2="${when_val//$'\t'/ }"; wv2="${wv2//$'\n'/ }"; [[ -z "$wv2" ]] && wv2="-"
    local md2="${mode//$'\t'/ }"; md2="${md2//$'\n'/ }"; [[ -z "$md2" ]] && md2="-"
    local cw2="${cwd//$'\t'/ }"; cw2="${cw2//$'\n'/ }"; [[ -z "$cw2" ]] && cw2="-"
    local to2="${timeout//$'\t'/ }"; to2="${to2//$'\n'/ }"; [[ -z "$to2" ]] && to2="-"
    local ka2="false"; [[ "${keepalive:-0}" == 1 ]] && ka2="true"
    local _row
    printf -v _row '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
      "$d" "$acct2" "$tgt2" "$sid2" "$wk2" "$wv2" "$ka2" "$md2" "$cw2" "$to2" "${created:-}"
    rows+="$_row"$'\n'
  done

  local timers_raw="[]" states_raw=""
  if [[ -n "$rows" ]]; then
    timers_raw="$(systemctl --user list-timers --output=json --no-pager 2>/dev/null)"
    if [[ "$timers_raw" != \[* ]]; then
      _json_skip "timers" "systemctl --user list-timers --output=json produced no usable data on this host — nextFire/lastFire are reported as unknown"
      timers_raw="[]"
    fi
    states_raw="$(systemctl --user show 'claude-schedule-*.timer' -p Id -p ActiveState --no-pager 2>/dev/null)"
  else
    _json_skip "timers" "no schedules to join fire times against"
  fi

  jq -Rn --argjson skipped "$(_json_skips_json)" --argjson timers "$timers_raw" --arg states "$states_raw" '
    ($timers | if type=="array" then . else [] end
      | map(select(.unit? and (.unit|test("^claude-schedule-.*\\.timer$"))))
      | map({key: (.unit | sub("^claude-schedule-";"") | sub("\\.timer$";"")),
             value: {next: (.next // null), last: (.last // null)}})
      | from_entries) as $fire
    | ($states
        | split("\n\n")
        | map(select(length>0))
        | map( split("\n") | map(select(length>0) | split("="))
               | map({(.[0]): (.[1:] | join("="))}) | add )
        | map(select(.Id != null))
        | map({key: (.Id | sub("^claude-schedule-";"") | sub("\\.timer$";"")), value: .ActiveState})
        | from_entries) as $states_by_id
    # "-" decodes to null for every meta-sourced field here, not just sid: a
    # well-formed schedule always has account/target/whenKind/whenVal/mode/
    # cwd/timeout populated, so "-" only ever shows up for a hand-edited or
    # partially-written meta — and null is the honest way to report that,
    # not the bash-internal placeholder itself.
    | [inputs | select(length>0) | split("\t") | . as $f | {
        id: $f[0],
        account: (if $f[1]=="-" then null else $f[1] end),
        target: (if $f[2]=="-" then null else $f[2] end),
        sid: (if $f[3]=="-" then null else $f[3] end),
        whenKind: (if $f[4]=="-" then null else $f[4] end),
        whenVal: (if $f[5]=="-" then null else $f[5] end),
        whenTz: null, tzSource: "none", tzVerified: false,
        pings: null,
        keepalive: ($f[6]=="true"),
        mode: (if $f[7]=="-" then null else $f[7] end),
        cwd: (if $f[8]=="-" then null else $f[8] end),
        timeout: (if $f[9]=="-" then null else $f[9] end),
        created: (if $f[10]=="" then null else ($f[10]|tonumber) end),
        nextFire: (
          ($fire[$f[0]].next) as $n
          | if ($n != null and $n > 0) then {value: ($n/1000000|floor), state:"known"}
            else {value:null, state:"unknown"} end
        ),
        lastFire: (
          ($fire[$f[0]].last) as $l
          | if ($l != null and $l > 0) then {value: ($l/1000000|floor), state:"known"}
            else {value:null, state:"unknown"} end
        ),
        unitState: ($states_by_id[$f[0]] // null),
        drift: {state:"unknown",
                reason:"work-window schedules and quota anchors are not in this build yet",
                actualStart:null, evidence:null}
      }] as $items
    | {status:"ok", checksRun:["schedules","timers"], checksSkipped:$skipped, errors:[], items:$items}
  ' <<<"$rows"
}
