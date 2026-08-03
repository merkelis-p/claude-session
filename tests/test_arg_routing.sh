#!/usr/bin/env bash
# Regression tests for two argument-routing bugs that both failed SILENTLY —
# the suite was fully green while each was live, which is exactly why they
# survived. Both were reported from real use, not found by testing.
set -uo pipefail
. "$(dirname "$0")/harness.sh"
setup_fake_home; trap teardown_fake_home EXIT
fail=0
install_fake_tmux
install_recording_claude
mkdir -p "$HOME/.config/claude-helpers"
cat > "$HOME/.config/claude-helpers/accounts.conf" <<EOF
account work $HOME/.claude-accounts/work ''
EOF
mkdir -p "$HOME/.claude-accounts/work"

# ---------------------------------------------------------------------------
# BUG 1: our options were matched only as `--flag=value`. `--account work`
# fell through to the positional bucket, so the session launched under the
# DEFAULT account while the user believed they were on `work`, and the stray
# `--account` was forwarded to claude, which has no such flag. Wrong-account
# launches move chats to the wrong place, so this is data safety, not polish.
# ---------------------------------------------------------------------------

: > "$CLAUDE_CALLS"
out_eq="$("$CS" --account=work update 2>&1)"
: > "$CLAUDE_CALLS"
out_sp="$("$CS" --account work update 2>&1)"

assert_contains "$out_sp" "CFG: $HOME/.claude-accounts/work" \
  "space form --account sets the account config dir" || fail=1
assert_contains "$out_eq" "CFG: $HOME/.claude-accounts/work" \
  "= form --account still sets the account config dir" || fail=1

# The whole point: the two spellings must be indistinguishable.
cfg_eq="$(grep -o 'CFG: .*' <<<"$out_eq" | head -1)"
cfg_sp="$(grep -o 'CFG: .*' <<<"$out_sp" | head -1)"
assert_eq "$cfg_sp" "$cfg_eq" "both --account spellings resolve identically" || fail=1

# ...and the flag must never leak through to claude in either spelling.
assert_not_contains "$out_sp" "ARGS: --account" \
  "space form --account is consumed, not forwarded to claude" || fail=1
assert_not_contains "$out_sp" "ARGS: update work" \
  "the account VALUE is not forwarded as a positional either" || fail=1

# A value-taking option with nothing after it must fail loudly. Previously it
# became a positional and the account was silently dropped.
out_missing="$("$CS" --account 2>&1)"; rc_missing=$?
assert_eq "$rc_missing" "2" "--account with no value exits non-zero" || fail=1
assert_contains "$out_missing" "requires a value" \
  "--account with no value explains itself" || fail=1

# Claude's OWN value flags must stay untouched — the normalizer is an explicit
# allowlist precisely so `--model opus` is not eaten as one of ours.
: > "$CLAUDE_CALLS"
out_model="$("$CS" update --model opus 2>&1)"
assert_contains "$out_model" "ARGS: update --model opus" \
  "claude's own --model and its value pass through verbatim" || fail=1

# ---------------------------------------------------------------------------
# BUG 2: the tmux session name is the cwd basename, and when a session of that
# name already existed the code called _enter_session, which execs — silently
# discarding every native argument. Asking to resume one chat dropped you into
# whatever chat happened to be open in that directory.
# ---------------------------------------------------------------------------

SID="dddddddd-1111-2222-3333-555555555555"

# The session name is derived from the CWD basename, so the test must run from
# a known directory. Deriving it from $HOME instead let two of the assertions
# below pass vacuously: TMUX_EXISTING never matched the real session name, so
# "did not attach to the pre-existing session" was trivially true because there
# was no pre-existing session at all.
mkdir -p "$HOME/proj"
cd "$HOME/proj" || exit 1
sess="proj-claude"

# Baseline: with no pre-existing session the sid is delivered.
: > "$TMUX_CALLS"
TMUX_EXISTING="" "$CS" --resume "$SID" >/dev/null 2>&1 || true
calls_fresh="$(tr '\037\036' ' \n' < "$TMUX_CALLS")"
assert_contains "$calls_fresh" "$SID" "fresh session delivers --resume <sid>" || fail=1
assert_contains "$calls_fresh" "$sess" "fresh session is named after the cwd" || fail=1

# The regression: same request, but a session of that name is already running.
: > "$TMUX_CALLS"
out_busy="$(TMUX_EXISTING="$sess" "$CS" --resume "$SID" 2>&1)" || true
calls_busy="$(tr '\037\036' ' \n' < "$TMUX_CALLS")"

# Guard the guard: prove the collision actually happened this time, otherwise
# the assertions below are vacuous again.
assert_contains "$calls_busy" "has-session -t $sess" \
  "the collision path was actually exercised" || fail=1

assert_contains "$calls_busy" "$SID" \
  "an existing session no longer swallows --resume <sid>" || fail=1
assert_contains "$calls_busy" "new-session" \
  "the request gets its own session instead of attaching elsewhere" || fail=1
# Check the attach TARGET exactly. A substring test is wrong here: the new
# session is named "$sess-2", so "attach -t $sess" is a prefix of the correct
# call and assert_not_contains would fire on a passing implementation.
attach_target="$(grep -oE "attach -t [^ ]+" <<<"$calls_busy" | head -1 | awk '{print $3}')"
assert_eq "$attach_target" "$sess-2" \
  "attaches to the NEW session, not the pre-existing one" || fail=1

# Diverting the request is only acceptable if the user is TOLD.
assert_contains "$out_busy" "already running" \
  "the name collision is reported, not hidden" || fail=1
assert_contains "$out_busy" "$sess" \
  "the message names the session that was already running" || fail=1

exit "$fail"
