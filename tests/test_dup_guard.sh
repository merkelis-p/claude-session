#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$0")/harness.sh"
setup_fake_home
cleanup() {
  teardown_fake_home
  tmux kill-session -t zz-dup-test-claude-work 2>/dev/null || true
  tmux kill-session -t zz-dup-test2-claude 2>/dev/null || true
  tmux kill-session -t zz-dup-test-defaulteq-claude 2>/dev/null || true
}
trap cleanup EXIT
fail=0

mkdir -p "$HOME/.config/claude-helpers"
cat > "$HOME/.config/claude-helpers/accounts.conf" <<EOF
account work $HOME/.claude-accounts/work 'Work account'
EOF
mkdir -p "$HOME/.claude-accounts/work"

PROJDIR="$HOME/zz-dup-test"
mkdir -p "$PROJDIR"
fake_session "$HOME/.claude" "$PROJDIR" "bridge-default-1" >/dev/null

install_fake_claude "#!/usr/bin/env bash
sleep 300"

out="$(cd "$PROJDIR" && "$CS" 2>&1)"; rc=$?
assert_eq "$rc" "2" "same account, same dir: refused (exit 2)" || fail=1
assert_contains "$out" "refusing to start" "same account, same dir: refusal message shown" || fail=1

( cd "$PROJDIR" && "$CS" --account=work </dev/null >/tmp/cs-work-out.$$ 2>&1 & )
sleep 1
out2="$(cat /tmp/cs-work-out.$$ 2>/dev/null)"
assert_contains "$out2" "starting 'zz-dup-test-claude-work'" \
  "different account, same dir: guard does not refuse, session naming is <project>-claude-<account>" || fail=1
rm -f "/tmp/cs-work-out.$$"

out3="$(cd "$PROJDIR" && "$CS" --account=nope 2>&1)"; rc3=$?
assert_eq "$rc3" "2" "unknown --account name is rejected (exit 2)" || fail=1
assert_contains "$out3" "unknown account 'nope'" "unknown --account name error message" || fail=1

# --- Regression: no accounts.conf + no --account= must behave byte-for-byte
# like before this task — in particular, never leak "(account:" into the
# refusal message just because $ACCOUNT happens to be empty/unset.
mv "$HOME/.config/claude-helpers/accounts.conf" "$HOME/.config/claude-helpers/accounts.conf.bak"
PROJDIR2="$HOME/zz-dup-test2"
mkdir -p "$PROJDIR2"
fake_session "$HOME/.claude" "$PROJDIR2" "bridge-default-2" >/dev/null

out4="$(cd "$PROJDIR2" && "$CS" 2>&1)"; rc4=$?
assert_eq "$rc4" "2" "no accounts.conf, no --account=: dup-guard still refuses (exit 2)" || fail=1
assert_not_contains "$out4" "(account:" "no accounts.conf, no --account=: refusal message has no '(account:' leak" || fail=1
mv "$HOME/.config/claude-helpers/accounts.conf.bak" "$HOME/.config/claude-helpers/accounts.conf"

# --- Regression: --account=default must be identical to omitting --account=
# entirely (same project, same tmux session name, same "starting" log line).
PROJDIR5="$HOME/zz-dup-test-defaulteq"
mkdir -p "$PROJDIR5"

( cd "$PROJDIR5" && "$CS" </dev/null >/tmp/cs-omit-out.$$ 2>&1 & )
sleep 1
tmux kill-session -t zz-dup-test-defaulteq-claude 2>/dev/null || true
out_omit="$(grep '^claude-session: starting' /tmp/cs-omit-out.$$ 2>/dev/null)"
rm -f "/tmp/cs-omit-out.$$"

( cd "$PROJDIR5" && "$CS" --account=default </dev/null >/tmp/cs-explicit-out.$$ 2>&1 & )
sleep 1
tmux kill-session -t zz-dup-test-defaulteq-claude 2>/dev/null || true
out_explicit="$(grep '^claude-session: starting' /tmp/cs-explicit-out.$$ 2>/dev/null)"
rm -f "/tmp/cs-explicit-out.$$"

assert_eq "$out_explicit" "$out_omit" "--account=default and omitted --account= produce byte-identical 'starting' log line" || fail=1
assert_not_contains "$out_omit" "(account:" "omitted --account=: no '(account:' leak in starting log" || fail=1
assert_not_contains "$out_explicit" "(account:" "--account=default: no '(account:' leak in starting log" || fail=1

exit "$fail"
