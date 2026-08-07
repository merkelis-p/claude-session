#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$0")/harness.sh"
setup_fake_home; trap teardown_fake_home EXIT
fail=0
export SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
export SCHED_DIR="$HOME/.config/claude-helpers/schedules"
install_fake_systemctl
install_recording_claude
# stub the one entrypoint helper schedule.sh calls
_account_dir_or_default() { local n="${1:-default}"; [[ "$n" == default ]] && echo "$HOME/.claude" || echo "$HOME/.claude-accounts/$n"; }
_account_config_dir() { local n="$1"; [[ "$n" == default ]] && printf '' || { echo "$HOME/.claude-accounts/$n"; }; }
. "$HELPERS_LIB_SRC/schedule.sh"
PROJ="$HOME/proj"; mkdir -p "$PROJ"

# add: existing chat, every 5h, work account, autopilot
SCHED_CHAT="sid-xyz"; SCHED_NEW=0; SCHED_WHEN_KIND=every; SCHED_WHEN_VAL=5h
ACCOUNT=work; CLAUDE_MODE=autopilot; SCHED_CWD="$PROJ"; SCHED_TIMEOUT=20m
out="$(cmd_schedule_add "check the CI and summarize")"
id="$(sed -n 's/.*scheduled .\([0-9a-f]\{6\}\).*/\1/p' <<<"$out")"
[[ -n "$id" ]]; assert_eq "$?" "0" "add prints a schedule id" || fail=1
assert_contains "$(cat "$SCHED_DIR/$id/prompt.txt")" "check the CI and summarize" "prompt stored verbatim" || fail=1
assert_contains "$(cat "$SCHED_DIR/$id/meta")" "sid=sid-xyz" "meta records the target sid" || fail=1
test -f "$SYSTEMD_USER_DIR/claude-schedule-$id.timer"; assert_eq "$?" "0" "timer unit written" || fail=1
assert_contains "$(cat "$SYSTEMCTL_CALLS")" "daemon-reload" "add reloads systemd" || fail=1
assert_contains "$(cat "$SYSTEMCTL_CALLS")" "enable --now claude-schedule-$id.timer" "add enables the timer" || fail=1
# `every` is a duration (OnActiveSec/OnUnitActiveSec), not a calendar time — it
# has no zone to resolve, and must not get one just because every OTHER
# wall-clock kind now does.
assert_not_contains "$(cat "$SCHED_DIR/$id/meta")" "when_tz=" "an every-schedule's meta carries no when_tz — it has no wall-clock time to zone" || fail=1

# run (existing chat): claude --resume sid -p PROMPT --permission-mode acceptEdits, right cfg + cwd
cmd_schedule_run "$id" >/dev/null 2>&1
cc="$(cat "$CLAUDE_CALLS")"
assert_contains "$cc" "--resume sid-xyz" "run resumes the target chat" || fail=1
assert_contains "$cc" "-p check the CI and summarize" "run passes the prompt with -p" || fail=1
assert_contains "$cc" "--permission-mode acceptEdits" "autopilot maps to acceptEdits" || fail=1
assert_contains "$cc" "cfg:$HOME/.claude-accounts/work" "run injects the account config dir" || fail=1
assert_contains "$cc" "cwd:$PROJ" "run executes in the schedule cwd" || fail=1

# add --new + plan mode → run uses --session-id and plan
: > "$CLAUDE_CALLS"
SCHED_CHAT=""; SCHED_NEW=1; SCHED_WHEN_KIND=daily-at; SCHED_WHEN_VAL=08:00; ACCOUNT=default; CLAUDE_MODE=plan
out="$(cmd_schedule_add "daily standup")"; id2="$(sed -n 's/.*scheduled .\([0-9a-f]\{6\}\).*/\1/p' <<<"$out")"
cmd_schedule_run "$id2" >/dev/null 2>&1
cc="$(cat "$CLAUDE_CALLS")"
assert_contains "$cc" "--session-id" "new-chat run mints a session id" || fail=1
assert_contains "$cc" "--permission-mode plan" "plan mode maps to plan" || fail=1
[[ "$cc" =~ --session-id\ [0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12} ]]
assert_eq "$?" "0" "new-chat run's session id is UUID-shaped" || fail=1

# Shipped defect this task fixes: a daily-at add with no --tz used to write a
# bare `OnCalendar=*-*-* 08:00:00` (read in whatever zone the SYSTEM happens to
# be in). It now ALWAYS resolves a zone (falling back to the host as a last
# resort — decision #2, the frozen contract keeps working unzoned) and writes
# it explicitly into the unit and into meta, which is the actual fix.
grep -qE '^OnCalendar=\*-\*-\* 08:00:00 [A-Za-z]+(/[A-Za-z_]+)?$' "$SYSTEMD_USER_DIR/claude-schedule-$id2.timer" \
  && echo "PASS: a daily-at add with no --tz still writes an EXPLICIT zone into the unit (not bare digits)" \
  || { echo "FAIL: daily-at wrote a bare OnCalendar with no zone" >&2; cat "$SYSTEMD_USER_DIR/claude-schedule-$id2.timer" >&2; fail=1; }
assert_contains "$(cat "$SCHED_DIR/$id2/meta")" "tz_source=host" \
  "with no --tz/config, the resolved zone is recorded as coming from the host" || fail=1

# once → run self-disables the timer, and (regression for the meta-sourcing
# bug) does not abort under set -e even with a spaced when_val/cwd.
: > "$SYSTEMCTL_CALLS"; : > "$CLAUDE_CALLS"
SCHED_PROJ_SPACED="$HOME/My Proj"; mkdir -p "$SCHED_PROJ_SPACED"
SCHED_CHAT="sid-1"; SCHED_NEW=0; SCHED_WHEN_KIND=once; SCHED_WHEN_VAL="2026-07-23 09:00"
ACCOUNT=default; CLAUDE_MODE=autopilot; SCHED_CWD="$SCHED_PROJ_SPACED"
out="$(cmd_schedule_add "one off")"; id3="$(sed -n 's/.*scheduled .\([0-9a-f]\{6\}\).*/\1/p' <<<"$out")"
( set -e; cmd_schedule_run "$id3" ) >/dev/null 2>&1; rc_once=$?
assert_eq "$rc_once" "0" "once run does not abort under set -e (meta sourcing is whitespace-safe)" || fail=1
assert_contains "$(cat "$CLAUDE_CALLS")" "--resume sid-1" "once run actually invokes claude" || fail=1
assert_contains "$(cat "$CLAUDE_CALLS")" "cwd:$SCHED_PROJ_SPACED" "once run executes in the spaced cwd" || fail=1
assert_contains "$(cat "$SYSTEMCTL_CALLS")" "disable --now claude-schedule-$id3.timer" "one-time run self-disables" || fail=1
# `once` is the other frozen-contract kind (§3.1) — same fix as daily-at above:
# no --tz still resolves and writes an explicit zone, never a bare datetime.
assert_contains "$(cat "$SYSTEMD_USER_DIR/claude-schedule-$id3.timer")" "OnCalendar=2026-07-23 09:00:00 " \
  "a once add with no --tz also writes an explicit zone (trailing space before the zone name proves something follows the bare digits)" || fail=1
assert_contains "$(cat "$SCHED_DIR/$id3/meta")" "when_tz=" "once records the resolved zone in meta too" || fail=1
unset SCHED_CWD

# rm: removes units + metadata + disables
: > "$SYSTEMCTL_CALLS"
cmd_schedule_rm "$id" >/dev/null 2>&1
test -e "$SCHED_DIR/$id"; assert_eq "$?" "1" "rm deletes metadata" || fail=1
test -e "$SYSTEMD_USER_DIR/claude-schedule-$id.timer"; assert_eq "$?" "1" "rm deletes the timer unit" || fail=1
assert_contains "$(cat "$SYSTEMCTL_CALLS")" "disable --now claude-schedule-$id.timer" "rm disables the timer" || fail=1

# validation: mutually exclusive target, missing when
SCHED_CHAT="a"; SCHED_NEW=1
( cmd_schedule_add "x" ) >/dev/null 2>&1; assert_eq "$?" "2" "chat+new is rejected" || fail=1
SCHED_CHAT=""; SCHED_NEW=1; SCHED_WHEN_KIND=""
( cmd_schedule_add "x" ) >/dev/null 2>&1; assert_eq "$?" "2" "missing when is rejected" || fail=1

# a FAILING scheduled run still logs + self-disables (once) instead of aborting under set -e
install_fake_claude 'exit 7'   # claude now fails
: > "$SYSTEMCTL_CALLS"
SCHED_CHAT="sid-fail"; SCHED_NEW=0; SCHED_WHEN_KIND=once; SCHED_WHEN_VAL="2026-07-24 10:00"; ACCOUNT=default; CLAUDE_MODE=autopilot; SCHED_CWD="$HOME"
out="$(cmd_schedule_add "will fail")"; id_fail="$(sed -n 's/.*scheduled .\([0-9a-f]\{6\}\).*/\1/p' <<<"$out")"
rc_fail=0; ( set -e; cmd_schedule_run "$id_fail" ) >/dev/null 2>&1 || rc_fail=$?
assert_eq "$rc_fail" "7" "failed scheduled run propagates the claude exit code (not an early set -e abort)" || fail=1
assert_contains "$(cat "$SYSTEMCTL_CALLS")" "disable --now claude-schedule-$id_fail.timer" "failed once-run still self-disables" || fail=1

exit "$fail"
