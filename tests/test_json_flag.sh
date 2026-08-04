#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$0")/harness.sh"
fail=0
setup_fake_home
trap teardown_fake_home EXIT
install_recording_claude

# (1) --json is an OWN flag: it must never reach native claude.
"$CS" ls --json >/dev/null 2>&1 || true
assert_eq "$(wc -l < "$CLAUDE_CALLS" | tr -d ' ')" "0" "ls --json never routes to native claude" || fail=1
"$CS" --json >/dev/null 2>&1 || true
assert_eq "$(wc -l < "$CLAUDE_CALLS" | tr -d ' ')" "0" "bare --json never routes to native claude" || fail=1

# (2) ...and Claude's own --json stays reachable, exactly like --version's resolution.
"$CS" -- --json >/dev/null 2>&1 || true
assert_contains "$(cat "$CLAUDE_CALLS")" "argv: --json" "claude-session -- --json reaches native claude" || fail=1

# (3) --json on a verb with no emitter yet is a HARD ERROR, never the human
#     rendering. Printing box-drawn text in answer to --json would be a
#     silently-wrong answer, which this tool never gives.
out="$("$CS" ls --json 2>&1)"; rc=$?
assert_eq "$rc" "2" "--json without an emitter exits 2" || fail=1
assert_contains "$out" "--json is not available" "--json without an emitter says so" || fail=1

# (4) version + schema constants
assert_contains "$("$CS" --version 2>&1)" "claude-session 0.2.0" "--version reports 0.2.0" || fail=1
sv="$(grep -E '^JSON_SCHEMA_VERSION=' "$CS" | head -1 | cut -d= -f2)"
[[ "$sv" =~ ^[0-9]+$ ]] && echo "PASS: JSON_SCHEMA_VERSION is an integer ($sv)" \
  || { echo "FAIL: JSON_SCHEMA_VERSION missing or not an integer: [$sv]" >&2; fail=1; }

# (5) the new flags are consumed as own flags, not shifted into the positionals
#     (the wrong-account bug class: an unconsumed flag became a project name).
out="$("$CS" ls --dry-run --yes --ack=deadbe 2>&1)"; rc=$?
assert_eq "$rc" "0" "ls with --dry-run/--yes/--ack= exits 0" || fail=1
assert_not_contains "$out" "no such dir" "new flags are not treated as positionals" || fail=1

# (6) value-taking own flags accept the space form and refuse a missing value
"$CS" ls --ack deadbe >/dev/null 2>&1; assert_eq "$?" "0" "--ack accepts the space form" || fail=1
"$CS" ls --ack >/dev/null 2>&1; assert_eq "$?" "2" "--ack with no value is a hard error" || fail=1
"$CS" ls --work >/dev/null 2>&1; assert_eq "$?" "2" "--work with no value is a hard error" || fail=1
"$CS" ls --reset-at >/dev/null 2>&1; assert_eq "$?" "2" "--reset-at with no value is a hard error" || fail=1

# (7) CS_NONINTERACTIVE makes every TTY-gated prompt behave as if there is no TTY.
( . "$HELPERS_LIB_SRC/compat.sh"; CS_NONINTERACTIVE=1 _cs_interactive ) \
  && { echo "FAIL: _cs_interactive true under CS_NONINTERACTIVE=1" >&2; fail=1; } \
  || echo "PASS: _cs_interactive false under CS_NONINTERACTIVE=1"
( . "$HELPERS_LIB_SRC/compat.sh"; CS_NONINTERACTIVE=0 _cs_interactive </dev/null ) \
  && { echo "FAIL: _cs_interactive true with stdin not a TTY" >&2; fail=1; } \
  || echo "PASS: _cs_interactive false when stdin is not a TTY"
grep -qE '\[\[ ! -t 0' "$HELPERS_LIB_SRC/ledger.sh" \
  && { echo "FAIL: ledger.sh still tests -t 0 directly instead of _cs_interactive" >&2; fail=1; } \
  || echo "PASS: ledger.sh routes interactivity through _cs_interactive"

# (8) --json implies no color, even under FORCE_COLOR=1 (§6.6 is enforced from
#     the first task, so no emitter can ever be written against a colored base).
out="$(FORCE_COLOR=1 "$CS" ls --json 2>&1 || true)"
[[ "$out" == *$'\033'* ]] && { echo "FAIL: --json path emitted ANSI under FORCE_COLOR=1" >&2; fail=1; } \
  || echo "PASS: --json path emits no ANSI under FORCE_COLOR=1"

exit "$fail"
