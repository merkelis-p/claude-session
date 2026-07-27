#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$0")/harness.sh"
setup_fake_home
trap teardown_fake_home EXIT
fail=0

out="$("$CS" accounts ls 2>&1)"
assert_contains "$out" "default" "accounts ls shows the default account" || fail=1

install_fake_claude
out="$("$CS" accounts add work "Work account" 2>&1)"
assert_contains "$out" "registered account 'work'" "accounts add registers work" || fail=1
assert_contains "$out" "fake claude ran, CLAUDE_CONFIG_DIR=$HOME/.claude-accounts/work" \
  "accounts add launches claude under the new CLAUDE_CONFIG_DIR" || fail=1

conf="$HOME/.config/claude-helpers/accounts.conf"
[[ -f "$conf" ]] || { echo "FAIL: accounts.conf was not created"; fail=1; }
assert_contains "$(cat "$conf" 2>/dev/null)" "account work" "accounts.conf has a work entry" || fail=1

out="$("$CS" accounts ls 2>&1)"
assert_contains "$out" "work" "accounts ls shows work after registering" || fail=1

out="$("$CS" accounts add work 2>&1)"
assert_contains "$out" "fake claude ran" "accounts add re-runs login for an already-registered name" || fail=1
lines_with_work="$(grep -c '^account work ' "$conf" 2>/dev/null || true)"
assert_eq "$lines_with_work" "1" "accounts.conf still has exactly one work entry (idempotent)" || fail=1

out="$("$CS" accounts add "bad name" 2>&1)"; rc=$?
assert_eq "$rc" "2" "accounts add rejects a name with a space (exit 2)" || fail=1

out="$("$CS" accounts add default 2>&1)"; rc=$?
assert_eq "$rc" "2" "accounts add rejects the reserved name 'default' (exit 2)" || fail=1

out="$("$CS" accounts rm default 2>&1)"; rc=$?
assert_eq "$rc" "2" "accounts rm refuses to remove the default account (exit 2)" || fail=1

out="$("$CS" accounts rm work 2>&1)"
assert_contains "$out" "unregistered 'work'" "accounts rm unregisters work" || fail=1
out="$("$CS" accounts ls 2>&1)"
assert_not_contains "$out" "work" "accounts ls no longer lists work after rm" || fail=1
[[ -d "$HOME/.claude-accounts/work" ]] || { echo "FAIL: config dir must survive accounts rm"; fail=1; }

# --- bug fix 1: `rm` must not silently abort under `set -e` when the only
# surviving grep result is empty (a hand-edited accounts.conf with no header,
# just a single bare `account` line for the entry being removed).
printf "account solo /some/solo/dir 'desc'\n" > "$conf"
out="$("$CS" accounts rm solo 2>&1)"; rc=$?
assert_eq "$rc" "0" "accounts rm exits 0 on a header-less single-line accounts.conf (bug fix 1)" || fail=1
assert_not_contains "$(cat "$conf" 2>/dev/null)" "account solo" \
  "accounts.conf no longer has the solo entry after rm (bug fix 1)" || fail=1

# --- bug fix 2: re-running `add` on an already-registered account must reuse
# ITS registered config dir (which may be a hand-edited custom path), not
# recompute the default $HOME/.claude-accounts/<name> path.
custom_dir="$HOME/custom-account-dir"
mkdir -p "$custom_dir"
printf "account custom %s 'Custom acct'\n" "$custom_dir" > "$conf"
out="$("$CS" accounts add custom 2>&1)"
assert_contains "$out" "fake claude ran, CLAUDE_CONFIG_DIR=$custom_dir" \
  "accounts add re-login uses the registered custom dir (bug fix 2)" || fail=1
assert_not_contains "$out" "CLAUDE_CONFIG_DIR=$HOME/.claude-accounts/custom" \
  "accounts add re-login does not fall back to the default-path dir (bug fix 2)" || fail=1

# --- fix round 2: a hand-edited accounts.conf line with a regex-metacharacter
# name (e.g. `account "a(b" ...`) must be (a) rejected by the loader so it
# never reaches ACCT_NAMES/the grep in cmd_accounts_rm (loader-validation fix),
# and (b) even if it somehow did, cmd_accounts_rm must not let a grep exit>=2
# corrupt accounts.conf via the `mv` (grep_rc fix). Together: the registry
# must survive intact — header and the legitimate `work` entry untouched.
cat > "$conf" <<'HEADER'
# ~/.config/claude-helpers/accounts.conf
#
# Registry of extra Claude Code accounts, each with its own isolated
# CLAUDE_CONFIG_DIR (credentials, settings, session history, project data).
# The default account (plain ~/.claude) always exists and needs no entry
# here. Managed by `claude-session accounts add/ls/rm` — hand-editable too.
#
# Format: account <name> <config-dir> '<description>'
HEADER
printf 'account work /some/work/dir %s\n' "$(printf '%q' 'Work account')" >> "$conf"
printf 'account "a(b" /some/dir %s\n' "$(printf '%q' 'desc')" >> "$conf"

out_stdout="$("$CS" accounts ls 2>/dev/null)"
assert_not_contains "$out_stdout" "a(b" \
  "malformed regex-metacharacter account name hidden from accounts ls (fix round 2, loader validation)" || fail=1

out="$("$CS" accounts rm "a(b" 2>&1)"; rc=$?
assert_eq "$rc" "2" \
  "accounts rm rejects the malformed hand-edited name as unknown, doesn't crash (fix round 2)" || fail=1
assert_contains "$(cat "$conf" 2>/dev/null)" "account work" \
  "accounts.conf still has the work entry after handling a malformed name (fix round 2, grep_rc fix)" || fail=1
assert_contains "$(cat "$conf" 2>/dev/null)" "# ~/.config/claude-helpers/accounts.conf" \
  "accounts.conf header survives a malformed hand-edited entry (fix round 2, grep_rc fix)" || fail=1

exit "$fail"
