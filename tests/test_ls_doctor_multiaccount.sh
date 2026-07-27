#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$0")/harness.sh"
setup_fake_home
trap teardown_fake_home EXIT
fail=0

mkdir -p "$HOME/.config/claude-helpers"
cat > "$HOME/.config/claude-helpers/accounts.conf" <<EOF
account work $HOME/.claude-accounts/work 'Work account'
EOF
mkdir -p "$HOME/.claude-accounts/work"

PROJDIR="$HOME/proj-a"
mkdir -p "$PROJDIR"
pid_default="$(fake_session "$HOME/.claude" "$PROJDIR" "bridge-default-1")"
pid_work="$(fake_session "$HOME/.claude-accounts/work" "$PROJDIR" "bridge-work-1")"

out="$("$CS" ls 2>&1)"
assert_contains "$out" "$pid_default" "ls shows the default-account session" || fail=1
assert_contains "$out" "$pid_work" "ls shows the work-account session" || fail=1
assert_contains "$out" "[work]" "ls tags the work-account row" || fail=1
assert_not_contains "$out" "[default]" "ls never tags the default-account row" || fail=1

out="$("$CS" doctor 2>&1)"
assert_contains "$out" "all clear" \
  "doctor: two different accounts bridged in the same dir is NOT a duplicate" || fail=1

# Now add a second default-account session in the SAME dir, only one bridged —
# the pre-existing duplicate-RC detection must still fire for same-account dupes.
pid_default2="$(fake_session "$HOME/.claude" "$PROJDIR" "")"
out="$("$CS" doctor 2>&1)"
assert_contains "$out" "others mirror text, no approvals" \
  "doctor: same account, same dir, only one bridged IS still flagged" || fail=1
assert_not_contains "$out" "[default]" "doctor: default-account duplicate warning never shows an account tag" || fail=1

# This session's bridgeSessionId is "" (empty string, not null/missing) — jq's
# `// "-"` doesn't coalesce an actual empty string, so _session_rows used to
# emit a genuinely empty middle field, which bash `read` (IFS=$'\t') collapses
# together with its neighboring tab, shifting every field after it left by one.
# That corrupted `alive`/`account` for exactly this row: it showed up as a
# mangled "stale" with an empty "[]" account tag instead of a live "duplicate"
# in the default account. Confirm `ls` gets this row right.
out="$("$CS" ls 2>&1)"
assert_contains "$out" "$pid_default2" "ls shows the second default-account (empty-bridge) session" || fail=1
card="$(awk -v pid="$pid_default2" '
  index($0, pid) { capture=1 }
  capture { print }
  capture && /^$/ { exit }
' <<<"$out")"
assert_contains "$card" "duplicate" \
  "ls: empty-bridge session is flagged duplicate (not corrupted to stale)" || fail=1
assert_not_contains "$card" "stale" \
  "ls: empty-bridge session is NOT mislabeled stale" || fail=1
assert_not_contains "$card" "[]" \
  "ls: empty-bridge session never shows a mangled empty account tag" || fail=1

exit "$fail"
