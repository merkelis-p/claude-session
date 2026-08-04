#!/usr/bin/env bash
# Coverage for every flag slot Task 1 of the claude-session TUI plan opens
# beyond the three the brief walks through explicitly (--ack/--work/--reset-at,
# already covered by test_json_flag.sh): --place/--only/--limit-chats from the
# brief's step 4, plus --days/--get, the two slots added on top of the brief
# for the keepalive weekday planner (Task 12) and the forthcoming `copy --get`
# verb. None of these have any behavior yet — this file only proves the
# parser opened the slot: consumed as an own flag rather than shifted into the
# positionals, and (for value flags) a hard error when the value is missing.
set -uo pipefail
. "$(dirname "$0")/harness.sh"
fail=0
setup_fake_home
trap teardown_fake_home EXIT
install_recording_claude
# If --get ever regressed into a value flag (see the "not a value flag" check
# below), `--get ls` would consume "ls" as its value, leave no verb, and fall
# through to the real launch path — which calls tmux for real. Stub it so a
# regression here fails loudly instead of quietly poking the host's tmux.
install_fake_tmux

# ---- static shape: mirror the runtime matcher's own space-bounded membership
# test, so a flag that is merely a SUBSTRING of another (--limit vs
# --limit-chats) cannot produce a false pass the way a naive string-contains
# check would.
value_flags_line="$(grep -E '^_CS_VALUE_FLAGS=' "$CS" | head -1)"
_flag_in_line() { [[ "$value_flags_line" == *" $1 "* ]]; }

for f in --days --place --only --limit-chats; do
  if _flag_in_line "$f"; then
    echo "PASS: $f is in _CS_VALUE_FLAGS (space form will normalize)"
  else
    echo "FAIL: $f missing from _CS_VALUE_FLAGS — space form would fall through to positionals" >&2
    fail=1
  fi
done
# --get is a BOOLEAN slot: it must NOT be in the value-flags allowlist. That
# list makes the parser consume the NEXT token as this flag's value, which
# would eat a real positional, e.g. `copy --get somechat`.
if _flag_in_line --get; then
  echo "FAIL: --get must not be a value flag (it is boolean)" >&2; fail=1
else
  echo "PASS: --get is not in _CS_VALUE_FLAGS (correctly boolean)"
fi

# ---- each new value flag: case arm exists and targets the documented variable
declare -A arm_pat=(
  [--days]='--days=\*\)[[:space:]]+SCHED_DAYS='
  [--place]='--place=\*\)[[:space:]]+UI_PLACE='
  [--only]='--only=\*\)[[:space:]]+SNAP_ONLY='
  [--limit-chats]='--limit-chats=\*\)[[:space:]]+CHAT_LIMIT='
)
for f in "${!arm_pat[@]}"; do
  if grep -qE -e "${arm_pat[$f]}" "$CS"; then
    echo "PASS: $f case arm assigns its documented variable"
  else
    echo "FAIL: $f case arm missing or targets the wrong variable" >&2; fail=1
  fi
done
if grep -qE '^[[:space:]]*--get\)[[:space:]]*COPY_GET=1' "$CS"; then
  echo "PASS: --get case arm assigns COPY_GET"
else
  echo "FAIL: --get case arm missing or targets the wrong variable" >&2; fail=1
fi

# ---- behavioral: space form, equals form, missing value -> hard error
for f in --days --place --only --limit-chats; do
  "$CS" ls "$f" val >/dev/null 2>&1; assert_eq "$?" "0" "$f accepts the space form" || fail=1
  "$CS" ls "$f=val" >/dev/null 2>&1; assert_eq "$?" "0" "$f accepts the = form" || fail=1
  "$CS" ls "$f" >/dev/null 2>&1; assert_eq "$?" "2" "$f with no value is a hard error" || fail=1
done

# --get: boolean, no value to withhold; must not error and must not disturb
# dispatch of the verb, tested both before and after it on the command line.
"$CS" --get ls >/dev/null 2>&1; assert_eq "$?" "0" "--get before the verb does not disturb dispatch" || fail=1
"$CS" ls --get >/dev/null 2>&1; assert_eq "$?" "0" "--get after the verb is consumed cleanly" || fail=1

# ---- combined: every new slot from this task at once, still dispatches `ls`
# cleanly (the wrong-account bug class: one unconsumed flag shifts the verb).
out="$("$CS" ls --place=top --only=x --limit-chats=5 --days=Mon..Fri --get 2>&1)"; rc=$?
assert_eq "$rc" "0" "ls with every new flag slot at once exits 0" || fail=1
assert_not_contains "$out" "no such dir" "combined new flags are not treated as positionals" || fail=1

exit "$fail"
