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
mkdir -p "$HOME/.claude-accounts/work"
export LEDGER_FILE="$HOME/.config/claude-helpers/transfer-log.jsonl"
PROJ="$HOME/proj"; mkdir -p "$PROJ"
# The on-disk project slug is the cwd with /._  -> -. Under the harness's fake
# (mktemp-based) $HOME this is NOT "-home-proj" (that only holds for a real
# /home/<user> $HOME) — compute it for real so the path assertion below checks
# the actual landing spot instead of coincidentally matching a wrong literal.
ENC_PROJ="$(sed 's#[/._]#-#g' <<<"$PROJ")"
# a source chat in work, with a cwd record so relaunch knows where to open
fake_transcript "$HOME/.claude-accounts/work" "$PROJ" "sid-mv" \
  "{\"cwd\":\"$PROJ\"}" '{"type":"ai-title","aiTitle":"Movable"}' >/dev/null

# move + launch → data moves AND tmux resumes it under the destination (default) account
: > "$TMUX_CALLS"
"$CS" transfer sid-mv --to=default --from=work --move --launch --plain >/dev/null 2>&1 || true
assert_contains "$(cat "$LEDGER_FILE")" '"sid":"sid-mv"' "move+launch still records the ledger entry" || fail=1
test -f "$HOME/.claude/projects/$ENC_PROJ/sid-mv.jsonl"; assert_eq "$?" "0" "chat moved to destination" || fail=1
tc="$(cat "$TMUX_CALLS")"
assert_contains "$tc" "new-session" "--launch opens a tmux session" || fail=1
assert_contains "$tc" "claude" "--launch runs claude" || fail=1
assert_contains "$tc" "--resume" "--launch resumes the chat" || fail=1
assert_contains "$tc" "sid-mv" "--launch resumes the moved sid" || fail=1
assert_contains "$tc" "$PROJ" "--launch opens in the chat's cwd" || fail=1

# move to a NON-default account → CLAUDE_CONFIG_DIR present in the tmux command
mkdir -p "$HOME/.claude/projects/-home-proj2"
PROJ2="$HOME/proj2"; mkdir -p "$PROJ2"
fake_transcript "$HOME/.claude" "$PROJ2" "sid-mv2" "{\"cwd\":\"$PROJ2\"}" '{"type":"ai-title","aiTitle":"Two"}' >/dev/null
: > "$TMUX_CALLS"
"$CS" transfer sid-mv2 --to=work --from=default --move --launch --plain >/dev/null 2>&1 || true
assert_contains "$(cat "$TMUX_CALLS")" "CLAUDE_CONFIG_DIR=$HOME/.claude-accounts/work" "--launch under an account injects its config dir" || fail=1

# dup-guard: destination session already exists → --launch refuses to start a second
: > "$TMUX_CALLS"
fake_transcript "$HOME/.claude-accounts/work" "$PROJ" "sid-mv3" "{\"cwd\":\"$PROJ\"}" '{"type":"ai-title","aiTitle":"Three"}' >/dev/null
export TMUX_EXISTING="proj-claude"
out="$("$CS" transfer sid-mv3 --to=default --from=work --move --launch --plain 2>&1)" || true
assert_contains "$out" "already exists" "--launch respects an existing destination session" || fail=1
unset TMUX_EXISTING
exit "$fail"
