#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$0")/harness.sh"
setup_fake_home; trap teardown_fake_home EXIT
fail=0
export SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
export SCHED_DIR="$HOME/.config/claude-helpers/schedules"
. "$HELPERS_LIB_SRC/schedule.sh"

# timer compilation
assert_contains "$(_sched_timer_lines every 5h)" "OnUnitActiveSec=5h" "every → OnUnitActiveSec" || fail=1
assert_contains "$(_sched_timer_lines every 5h)" "OnActiveSec=" "every → first-fire OnActiveSec" || fail=1
assert_contains "$(_sched_timer_lines daily-at 08:00)" "OnCalendar=*-*-* 08:00:00" "daily-at → OnCalendar" || fail=1
assert_contains "$(_sched_timer_lines once '2026-07-23 09:00')" "OnCalendar=2026-07-23 09:00:00" "once → OnCalendar datetime" || fail=1

# first-fire anchor: explicit 3rd arg overrides OnActiveSec; default stays 1min
out="$(_sched_timer_lines every 5h 3h)"
assert_contains "$out" "OnActiveSec=3h" "every + first → OnActiveSec honors anchor" || fail=1
assert_contains "$out" "OnUnitActiveSec=5h" "every + first → OnUnitActiveSec still the repeat interval" || fail=1
assert_contains "$(_sched_timer_lines every 5h)" "OnActiveSec=1min" "every without first → OnActiveSec defaults to 1min" || fail=1

# unit files
_sched_write_units abc123 30m daily-at 08:00
svc="$SYSTEMD_USER_DIR/claude-schedule-abc123.service"
tmr="$SYSTEMD_USER_DIR/claude-schedule-abc123.timer"
assert_contains "$(cat "$svc")" "Type=oneshot" "service is oneshot" || fail=1
assert_contains "$(cat "$svc")" "TimeoutStartSec=30m" "service carries timeout" || fail=1
assert_contains "$(cat "$svc")" "ExecStart=%h/.local/bin/claude-session _schedule-run abc123" "service ExecStart runs the internal verb" || fail=1
assert_contains "$(cat "$tmr")" "OnCalendar=*-*-* 08:00:00" "timer carries the schedule" || fail=1
assert_contains "$(cat "$tmr")" "WantedBy=timers.target" "timer installs to timers.target" || fail=1

# unit files with a first-fire anchor
_sched_write_units def456 30m every 5h 2h
tmr2="$SYSTEMD_USER_DIR/claude-schedule-def456.timer"
assert_contains "$(cat "$tmr2")" "OnActiveSec=2h" "write_units passes the first-fire anchor through" || fail=1
exit "$fail"
