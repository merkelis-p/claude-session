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
  for sec in ${only//,/ }; do
    case "$sec" in
      meta) continue ;;
      accounts|chats|issues|processes|ledger|schedules)
        [[ -n "$frag" ]] && frag+=","
        frag+="$(printf '"%s":%s' "$sec" "$("_json_section_$sec")")" ;;
      *) echo "claude-session _snapshot: unknown --only section '$sec' (valid: meta ${JSON_SECTIONS_ALL})" >&2
         return 2 ;;
    esac
  done
  printf '{"schemaVersion":%s,"generatedAt":%s,"elapsedMs":%s,"core":%s,"sections":{%s}}' \
    "$JSON_SCHEMA_VERSION" "$(date +%s)" "$(( $(_epoch_ms) - JSON_T0 ))" "$(_json_core)" "$frag" \
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
