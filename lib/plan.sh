# shellcheck shell=bash
# plan.sh — the plan/apply/ack protocol (spec §7.2).
#
# WHY: the app (a Go TUI, tasks elsewhere in this repo) owns the terminal and
# execs claude-session as a child with no TTY, so a `[y/N]` prompt on stdin
# would just hang forever. The naive fix — always pass --force — would
# silently disarm every guard --force happens to override, including ones the
# app never meant to bypass (see lib/ledger.sh's cmd_transfer/_ledger_guard,
# where --force overrides the duplicate guard, the round-trip guard, AND the
# never-clobber backstop all at once). This module gives the non-interactive
# path a narrower vocabulary:
#   --force        override this ONE named guard (unchanged meaning)
#   --yes          the human answered the [y/N] prompt — nothing more
#   --ack=<digest> the human confirmed this specific disclosed condition
#
# Two phases, both going through the SAME verb and the SAME guards:
#   plan:   claude-session transfer <sid> --to=work --move --json --dry-run
#   apply:  claude-session transfer <sid> --to=work --move --yes --ack=a91f3c
#
# THE PLAN IS ADVISORY; THE GUARDS ARE AUTHORITATIVE. Apply re-runs every
# check inside the verb exactly as the CLI does — nothing here replaces a
# guard, short-circuits one, or remembers a decision across processes. The
# plan exists so the safety WORDING has one source (bash), not two.
#
# The interactive TTY path is untouched by any of this: a human at a real
# terminal still gets the `[y/N]` prompt exactly as before. This machinery is
# for `! _cs_interactive` only.
#
# Sourced by the entrypoint last (after json.sh). Standalone-testable: its
# only entrypoint dependencies (JSON_OUT, JSON_SCHEMA_VERSION, ACK_DIGESTS)
# are read at call time, same convention as ledger.sh/schedule.sh/json.sh.
if ! command -v _sha256 >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/compat.sh"
fi

# ---- builder globals --------------------------------------------------------
# One in-progress plan at a time (a verb builds its own, then flushes it) —
# no nesting, no stack. _plan_reset clears every array so a stale entry from
# an earlier call in the same process can never leak into this one.
PLAN_MUTATION=""
PLAN_ARGV=()
PLAN_TARGET="null"
PLAN_EFFECT_KIND=(); PLAN_EFFECT_PATH=()
PLAN_WILL_LOSE=()
PLAN_CONFIRM_KIND=(); PLAN_CONFIRM_DIGEST=(); PLAN_CONFIRM_TEXT=()
PLAN_REFUSE_CODE=(); PLAN_REFUSE_TEXT=(); PLAN_REFUSE_OVERRIDE=()
PLAN_WARN=()

_plan_reset() {
  PLAN_MUTATION="$1"
  PLAN_ARGV=()
  PLAN_TARGET="null"
  PLAN_EFFECT_KIND=(); PLAN_EFFECT_PATH=()
  PLAN_WILL_LOSE=()
  PLAN_CONFIRM_KIND=(); PLAN_CONFIRM_DIGEST=(); PLAN_CONFIRM_TEXT=()
  PLAN_REFUSE_CODE=(); PLAN_REFUSE_TEXT=(); PLAN_REFUSE_OVERRIDE=()
  PLAN_WARN=()
}

# argv is an ARRAY, long flags only, --flag=value form, with the source
# resolved explicitly (--from=<resolved>). A plain plan never carries --force:
# --force is only ever added by a human typing it themselves.
_plan_argv() { PLAN_ARGV+=("$@"); }

_plan_target() {
  local account="$1" sid="$2" title="$3" dest="$4"
  PLAN_TARGET="$(jq -n --arg a "$account" --arg s "$sid" --arg t "$title" --arg d "$dest" \
    '{account:$a, sid:$s, title:$t, dest:$d}')"
}

_plan_effect() { PLAN_EFFECT_KIND+=("$1"); PLAN_EFFECT_PATH+=("$2"); }

# A move discloses what is lost; a copy loses nothing (never called for one).
_plan_will_lose() { PLAN_WILL_LOSE+=("$1"); }

_plan_warn() { PLAN_WARN+=("$1"); }

# A hard refusal: only the NAMED override (usually --force) can bypass it —
# never an --ack. Args: code text override.
_plan_refuse() { PLAN_REFUSE_CODE+=("$1"); PLAN_REFUSE_TEXT+=("$2"); PLAN_REFUSE_OVERRIDE+=("$3"); }

# The plan document (spec §7.2). Two phases:
#   plan:   claude-session transfer <sid> --to=work --move --json --dry-run
#   apply:  claude-session transfer <sid> --to=work --move --yes --ack=a91f3c
#
# THE PLAN IS ADVISORY; THE GUARDS ARE AUTHORITATIVE. Apply re-runs every check
# inside the verb exactly as the CLI does. The plan exists so the WORDING comes
# from bash — one source of truth for the safety copy too, not just the logic.
_plan_digest() { printf '%s\n%s' "$1" "$2" | _sha256 | cut -c1-6; }

_plan_confirm() {
  local kind="$1" text="$2" d
  d="$(_plan_digest "$kind" "$text")" || exit 1
  PLAN_CONFIRM_KIND+=("$kind"); PLAN_CONFIRM_TEXT+=("$text"); PLAN_CONFIRM_DIGEST+=("$d")
}

# Refuse --yes when a computed confirmation was not acked. Exit 3 with the FRESH
# plan attached: that closes the plan->apply race and makes "confirm without
# disclosure" unrepresentable rather than merely discouraged.
#
# The `${arr[@]+"${!arr[@]}"}` shape below (existence-test on the VALUES,
# expand the INDICES) is deliberate, not a typo: `${!arr[@]+word}` — testing
# existence on the indices pseudo-parameter itself — does NOT do what it
# looks like. bash parses the `!` together with the trailing `+word` as
# indirect expansion of `arr[@]`'s *value*, not as an existence test on
# `!arr[@]`, so with a non-empty array it tries to indirectly dereference a
# variable literally named after the array's joined contents (e.g. the digest
# string itself) and dies with "invalid variable name" — verified against
# this shell (bash 5.2): non-empty PLAN_CONFIRM_DIGEST reliably reproduces it.
# Testing existence on the array's values instead (`${arr[@]+...}`) sidesteps
# that parse and still safely yields nothing when the array is unset/empty.
_plan_require_acks() {
  local i d missing=0
  for i in ${PLAN_CONFIRM_DIGEST[@]+"${!PLAN_CONFIRM_DIGEST[@]}"}; do
    d="${PLAN_CONFIRM_DIGEST[$i]}"
    case ",${ACK_DIGESTS}," in *",$d,"*) ;; *) missing=1 ;; esac
  done
  (( missing == 0 )) && return 0
  if (( JSON_OUT == 1 )); then
    _plan_flush
  else
    echo "claude-session: this action discloses a condition you have not acknowledged:" >&2
    for i in ${PLAN_CONFIRM_TEXT[@]+"${!PLAN_CONFIRM_TEXT[@]}"}; do
      printf '  [%s] %s\n' "${PLAN_CONFIRM_DIGEST[$i]}" "${PLAN_CONFIRM_TEXT[$i]}" >&2
    done
    echo "  re-run with --ack=<digest> (comma-separate several)" >&2
  fi
  exit 3
}

# ---- array -> JSON, one `jq -Rn` each (lib/json.sh's tab-stream pattern) ----
# All three take ARRAY NAMES (not expansions) and resolve them indirectly via
# `eval`, matching how _plan_flush calls them below. Indirection is done one
# scalar (`${#name[@]}`, `${name[$i]}`) at a time rather than a single
# `${!name[@]}`/`local -n` pass: bash before 4.4 raises "unbound variable"
# under `set -u` when a DECLARED-BUT-EMPTY array is expanded with [@], and
# `local -n` needs bash 4.3 — this codebase's floor is bash >= 4 (see
# bin/claude-session's own version gate), so neither is safe to rely on here.
# A tab is IFS whitespace: these build jq's input themselves and let jq's
# `split("\t")` do the splitting, never an `IFS=$'\t' read` loop, so an empty
# middle field can never collapse into its neighbor.
_plan_arr() {
  local _name="$1" _rows="" _v _cnt _i
  eval "_cnt=\${#${_name}[@]}"
  for (( _i=0; _i<_cnt; _i++ )); do
    eval "_v=\${${_name}[$_i]}"
    _v="${_v//$'\t'/ }"; _v="${_v//$'\n'/ }"
    _rows+="$_v"$'\n'
  done
  jq -Rn '[inputs | select(length>0)]' <<<"$_rows"
}

_plan_pairs() {
  local _an="$1" _bn="$2" _ka="$3" _kb="$4" _rows="" _cnt _i _a _b
  eval "_cnt=\${#${_an}[@]}"
  for (( _i=0; _i<_cnt; _i++ )); do
    eval "_a=\${${_an}[$_i]}"
    eval "_b=\${${_bn}[$_i]:-}"
    _a="${_a//$'\t'/ }"; _a="${_a//$'\n'/ }"
    _b="${_b//$'\t'/ }"; _b="${_b//$'\n'/ }"
    _rows+="$_a"$'\t'"$_b"$'\n'
  done
  jq -Rn --arg ka "$_ka" --arg kb "$_kb" \
    '[inputs | select(length>0) | split("\t") | {($ka): .[0], ($kb): .[1]}]' <<<"$_rows"
}

_plan_triples() {
  local _an="$1" _bn="$2" _cn="$3" _ka="$4" _kb="$5" _kc="$6" _rows="" _cnt _i _a _b _c
  eval "_cnt=\${#${_an}[@]}"
  for (( _i=0; _i<_cnt; _i++ )); do
    eval "_a=\${${_an}[$_i]}"
    eval "_b=\${${_bn}[$_i]:-}"
    eval "_c=\${${_cn}[$_i]:-}"
    _a="${_a//$'\t'/ }"; _a="${_a//$'\n'/ }"
    _b="${_b//$'\t'/ }"; _b="${_b//$'\n'/ }"
    _c="${_c//$'\t'/ }"; _c="${_c//$'\n'/ }"
    _rows+="$_a"$'\t'"$_b"$'\t'"$_c"$'\n'
  done
  jq -Rn --arg ka "$_ka" --arg kb "$_kb" --arg kc "$_kc" \
    '[inputs | select(length>0) | split("\t") | {($ka): .[0], ($kb): .[1], ($kc): .[2]}]' <<<"$_rows"
}

# One jq, at the end, so the document is valid by construction.
_plan_flush() {
  jq -n --arg m "$PLAN_MUTATION" --argjson sv "$JSON_SCHEMA_VERSION" \
     --argjson argv "$(_plan_arr PLAN_ARGV)" --argjson target "$PLAN_TARGET" \
     --argjson effects "$(_plan_pairs PLAN_EFFECT_KIND PLAN_EFFECT_PATH kind path)" \
     --argjson lose "$(_plan_arr PLAN_WILL_LOSE)" \
     --argjson conf "$(_plan_triples PLAN_CONFIRM_KIND PLAN_CONFIRM_DIGEST PLAN_CONFIRM_TEXT kind digest text)" \
     --argjson ref "$(_plan_triples PLAN_REFUSE_CODE PLAN_REFUSE_TEXT PLAN_REFUSE_OVERRIDE code text override)" \
     --argjson warn "$(_plan_arr PLAN_WARN)" \
     '{schemaVersion:$sv, mutation:$m, argv:$argv, target:$target, effects:$effects,
       willLose:$lose, confirmations:$conf, refusals:$ref, warnings:$warn}'
}
