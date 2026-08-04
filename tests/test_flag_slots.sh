#!/usr/bin/env bash
# Coverage for every flag slot the parser-barrier task opens beyond the three
# covered by test_json_flag.sh (--ack/--work/--reset-at). None of these have any
# behavior yet — this file only proves the parser opened the slot: consumed as an
# own flag rather than shifted into the positionals, and (for value flags) a hard
# error when the value is missing.
#
# WHY EVERY SLOT IS LISTED HERE, including ones nothing uses yet: the parser is a
# single `case` block that exactly one task may edit, so every later task assumes
# its slots already exist. The first version of this file asserted only the slots
# that had landed, which is a test written from the code instead of from the
# requirement — --sids, --tz, --rebuild and --keep were all missing, and the
# suite was green. The first task to need one would have had to re-open the
# barrier. A slot list that grows with the parser cannot catch an omission; this
# one is the requirement, so a missing slot fails here.
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

for f in --days --tz --place --only --sids --limit-chats; do
  if _flag_in_line "$f"; then
    echo "PASS: $f is in _CS_VALUE_FLAGS (space form will normalize)"
  else
    echo "FAIL: $f missing from _CS_VALUE_FLAGS — space form would fall through to positionals" >&2
    fail=1
  fi
done
# These are BOOLEAN slots: they must NOT be in the value-flags allowlist. That
# list makes the parser consume the NEXT token as the flag's value, which would
# eat a real positional, e.g. `copy --get somechat`.
for f in --get --keep --rebuild; do
  if _flag_in_line "$f"; then
    echo "FAIL: $f must not be a value flag (it is boolean)" >&2; fail=1
  else
    echo "PASS: $f is not in _CS_VALUE_FLAGS (correctly boolean)"
  fi
done

# ---- each new value flag: case arm exists and targets the documented variable
declare -A arm_pat=(
  [--days]='--days=\*\)[[:space:]]+SCHED_DAYS='
  [--tz]='--tz=\*\)[[:space:]]+SCHED_TZ='
  [--place]='--place=\*\)[[:space:]]+UI_PLACE='
  [--only]='--only=\*\)[[:space:]]+SNAP_ONLY='
  [--sids]='--sids=\*\)[[:space:]]+SNAP_SIDS='
  [--limit-chats]='--limit-chats=\*\)[[:space:]]+CHAT_LIMIT='
  [--get]='--get\)[[:space:]]+CLIP_GET=1'
  [--keep]='--keep\)[[:space:]]+CLIP_KEEP=1'
  [--rebuild]='--rebuild\)[[:space:]]+TI_REBUILD=1'
)
for f in "${!arm_pat[@]}"; do
  if grep -qE -e "${arm_pat[$f]}" "$CS"; then
    echo "PASS: $f case arm assigns its documented variable"
  else
    echo "FAIL: $f case arm missing or targets the wrong variable" >&2; fail=1
  fi
done

# Each slot must also be INITIALIZED. An unset value under `set -u` is not a
# quiet default — the first read of it aborts the whole script.
declare -A init_pat=(
  [SCHED_TZ]='SCHED_TZ=""'
  [SNAP_SIDS]='SNAP_SIDS=""'
  [CLIP_GET]='CLIP_GET=0'
  [CLIP_KEEP]='CLIP_KEEP=0'
  [TI_REBUILD]='TI_REBUILD=0'
)
for v in "${!init_pat[@]}"; do
  if grep -qF -e "${init_pat[$v]}" "$CS"; then
    echo "PASS: $v is initialized (set -u would abort on an unset read)"
  else
    echo "FAIL: $v is never initialized" >&2; fail=1
  fi
done

# The chats window default. 200, not 50: with the title index a window costs one
# pass over the index instead of one tail+jq per row, so it is bounded by
# row-building cost rather than I/O.
if grep -qE 'CHAT_LIMIT=200' "$CS"; then
  echo "PASS: CHAT_LIMIT defaults to 200"
else
  echo "FAIL: CHAT_LIMIT does not default to 200" >&2; fail=1
fi

# ---- behavioral: space form, equals form, missing value -> hard error
for f in --days --tz --place --only --sids --limit-chats; do
  "$CS" ls "$f" val >/dev/null 2>&1; assert_eq "$?" "0" "$f accepts the space form" || fail=1
  "$CS" ls "$f=val" >/dev/null 2>&1; assert_eq "$?" "0" "$f accepts the = form" || fail=1
  "$CS" ls "$f" >/dev/null 2>&1; assert_eq "$?" "2" "$f with no value is a hard error" || fail=1
done

# Booleans: no value to withhold; must not error and must not disturb dispatch of
# the verb, tested both before and after it on the command line.
for f in --get --keep --rebuild; do
  "$CS" "$f" ls >/dev/null 2>&1; assert_eq "$?" "0" "$f before the verb does not disturb dispatch" || fail=1
  "$CS" ls "$f" >/dev/null 2>&1; assert_eq "$?" "0" "$f after the verb is consumed cleanly" || fail=1
done

# ---- combined: every new slot from this task at once, still dispatches `ls`
# cleanly (the wrong-account bug class: one unconsumed flag shifts the verb).
out="$("$CS" ls --place=top --only=x --limit-chats=5 --days=Mon..Fri --tz=Europe/Vilnius \
        --sids=sid-a,sid-b --get --keep --rebuild 2>&1)"; rc=$?
assert_eq "$rc" "0" "ls with every new flag slot at once exits 0" || fail=1
assert_not_contains "$out" "no such dir" "combined new flags are not treated as positionals" || fail=1

exit "$fail"
