#!/usr/bin/env bash
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
mkdir -p "$HOME/.claude-accounts/work" "$HOME/proj"

# (1) own verb wins: `doctor` is the SESSION doctor, not native claude
out="$("$CS" doctor 2>&1)"
assert_contains "$out" "all clear" "own-verb doctor stays the session doctor" || fail=1
assert_not_contains "$(cat "$CLAUDE_CALLS")" "argv: doctor" "own doctor never calls native claude" || fail=1

# (2) inline one-shot: `update` execs claude inline, no tmux
out="$("$CS" update 2>&1)"
assert_contains "$out" "ARGS: update" "update runs native claude inline" || fail=1
assert_not_contains "$(cat "$TMUX_CALLS")" "new-session" "inline update does not open tmux" || fail=1

# (3) inline honors --account (stripped from argv, sets CLAUDE_CONFIG_DIR)
out="$("$CS" update --account=work 2>&1)"
assert_contains "$out" "CFG: $HOME/.claude-accounts/work" "inline passes account config dir" || fail=1
assert_contains "$out" "ARGS: update" "account flag stripped from forwarded argv" || fail=1
assert_not_contains "$out" "account=work" "no leaked --account in argv" || fail=1

# (4) interactive native goes to tmux: `--resume <id>` (no -p)
: > "$TMUX_CALLS"
"$CS" --resume abc123 >/dev/null 2>&1 || true
tc="$(cat "$TMUX_CALLS")"
assert_contains "$tc" "new-session" "--resume opens a tmux session" || fail=1
assert_contains "$tc" "claude" "tmux command runs claude" || fail=1
assert_contains "$tc" "--resume" "tmux command carries --resume" || fail=1
assert_contains "$tc" "abc123" "tmux command carries the session id" || fail=1

# (5) interactive native + account: CLAUDE_CONFIG_DIR in the tmux command
: > "$TMUX_CALLS"
"$CS" --resume abc123 --account=work >/dev/null 2>&1 || true
assert_contains "$(cat "$TMUX_CALLS")" "CLAUDE_CONFIG_DIR=$HOME/.claude-accounts/work" "tmux native launch injects account dir" || fail=1

# (6) `-- doctor` forces native doctor (interactive → tmux) despite the name collision
: > "$TMUX_CALLS"
"$CS" -- doctor >/dev/null 2>&1 || true
assert_contains "$(cat "$TMUX_CALLS")" "doctor" "-- escape forces native doctor into tmux" || fail=1

# (7) `-p` forces inline even with --resume. `-p` is now consumed as PLAIN and
# re-injected into the native argv only when routing native, so it lands at the
# end — assert order-insensitively that it's inline and every token forwarded.
: > "$TMUX_CALLS"
out="$("$CS" --resume abc123 -p "hi there" 2>&1)"
assert_contains "$out" "ARGS:" "-p forces inline resume (runs claude inline)" || fail=1
assert_contains "$out" "--resume abc123" "inline resume forwards --resume + id" || fail=1
assert_contains "$out" "hi there" "inline resume forwards the prompt" || fail=1
assert_contains "$out" "-p" "inline resume forwards -p" || fail=1
assert_not_contains "$(cat "$TMUX_CALLS")" "new-session" "-p resume did not open tmux" || fail=1

# (7b) `-p` is --plain for own verbs, never leaks into own-verb dispatch
: > "$TMUX_CALLS"
"$CS" kill -p >/dev/null 2>&1 || true
assert_not_contains "$(cat "$TMUX_CALLS")" "kill-session" "kill -p is the plain kill picker, not tmux kill-session -t -p" || fail=1
: > "$CLAUDE_CALLS"
"$CS" -p ls >/dev/null 2>&1 || true
assert_not_contains "$(cat "$CLAUDE_CALLS")" "argv: ls" "-p ls stays the session ls, not native claude" || fail=1

# (8) normal launch still works (protects the _launch_native refactor)
: > "$TMUX_CALLS"
"$CS" proj >/dev/null 2>&1 || true
tc="$(cat "$TMUX_CALLS")"
assert_contains "$tc" "new-session" "plain project launch still opens tmux" || fail=1
assert_contains "$tc" "proj-claude" "plain launch names the session <proj>-claude" || fail=1

exit "$fail"
