#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$0")/harness.sh"
setup_fake_home; trap teardown_fake_home EXIT
fail=0
export SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
export SCHED_DIR="$HOME/.config/claude-helpers/schedules"
. "$HELPERS_LIB_SRC/compat.sh"; . "$HELPERS_LIB_SRC/config.sh"; . "$HELPERS_LIB_SRC/schedule.sh"
ZONE="Europe/Vilnius"

# timer compilation
assert_contains "$(_sched_timer_lines every 5h)" "OnUnitActiveSec=5h" "every → OnUnitActiveSec" || fail=1
assert_contains "$(_sched_timer_lines every 5h)" "OnActiveSec=" "every → first-fire OnActiveSec" || fail=1

# Shipped defect this task fixes: an OnCalendar with no zone is read in the
# SYSTEM zone. _sched_timer_lines' 5th arg is the resolved zone, and every real
# caller (cmd_schedule_add, _sched_retime) always passes one — the bare
# no-zone form below only still exists because a handful of direct low-level
# callers (this file included) exercise the formatter without going through
# zone resolution at all; it must never be what an actual schedule gets
# written with, which is exactly what the zoned assertions right after it
# pin down.
assert_contains "$(_sched_timer_lines daily-at 08:00)" "OnCalendar=*-*-* 08:00:00" "daily-at with no zone arg → bare OnCalendar (low-level formatter only; no real caller does this)" || fail=1
assert_contains "$(_sched_timer_lines once '2026-07-23 09:00')" "OnCalendar=2026-07-23 09:00:00" "once with no zone arg → bare OnCalendar datetime (ditto)" || fail=1

# The actual fix: pass the resolved zone (arg 5) and it lands on the
# OnCalendar line, as a NAME — never an offset, never left off.
assert_eq "$(_sched_timer_lines daily-at 08:00 "" "" "$ZONE")" "$(printf 'OnCalendar=*-*-* 08:00:00 %s\nPersistent=true\n' "$ZONE")" \
  "daily-at + zone → the exact zoned OnCalendar line, nothing else different" || fail=1
assert_contains "$(_sched_timer_lines once '2026-07-23 09:00' "" "" "$ZONE")" "OnCalendar=2026-07-23 09:00:00 $ZONE" \
  "once + zone → OnCalendar datetime carries the zone" || fail=1
assert_not_contains "$(_sched_timer_lines daily-at 08:00 "" "" "$ZONE")" "+02" "the zone is the NAME, never a stored offset" || fail=1

# work-window (--work): TWO OnCalendar lines (start and end of the window),
# and per decision #4/the test file's own header comment, EVERY line is
# zoned — not just the first one a casual grep might catch.
wout="$(_sched_timer_lines work-window 09:00-19:00 "" "" "$ZONE")"
assert_contains "$wout" "OnCalendar=*-*-* 09:00:00 $ZONE" "work-window → the START of the window is a zoned OnCalendar line" || fail=1
assert_contains "$wout" "OnCalendar=*-*-* 19:00:00 $ZONE" "work-window → the END of the window is ALSO a zoned OnCalendar line" || fail=1
assert_eq "$(grep -c "$ZONE" <<<"$wout")" "2" "work-window: both OnCalendar lines are zoned, not just the first" || fail=1

# --days (an optional day-of-week filter) prefixes the date wildcard; the
# zone still lands at the end of the same line.
assert_contains "$(_sched_timer_lines daily-at 08:00 "" "Mon..Fri" "$ZONE")" "OnCalendar=Mon..Fri *-*-* 08:00:00 $ZONE" \
  "an optional day-of-week filter composes with the zone" || fail=1

# first-fire anchor: explicit 3rd arg overrides OnActiveSec; default stays 1min
out="$(_sched_timer_lines every 5h 3h)"
assert_contains "$out" "OnActiveSec=3h" "every + first → OnActiveSec honors anchor" || fail=1
assert_contains "$out" "OnUnitActiveSec=5h" "every + first → OnUnitActiveSec still the repeat interval" || fail=1
assert_contains "$(_sched_timer_lines every 5h)" "OnActiveSec=1min" "every without first → OnActiveSec defaults to 1min" || fail=1

# unit files — written WITH a resolved zone, the shape every real caller uses.
_sched_write_units abc123 30m daily-at 08:00 "" "" "$ZONE"
svc="$SYSTEMD_USER_DIR/claude-schedule-abc123.service"
tmr="$SYSTEMD_USER_DIR/claude-schedule-abc123.timer"
assert_contains "$(cat "$svc")" "Type=oneshot" "service is oneshot" || fail=1
assert_contains "$(cat "$svc")" "TimeoutStartSec=30m" "service carries timeout" || fail=1
assert_contains "$(cat "$svc")" "ExecStart=%h/.local/bin/claude-session _schedule-run abc123" "service ExecStart runs the internal verb" || fail=1
assert_contains "$(cat "$tmr")" "OnCalendar=*-*-* 08:00:00 $ZONE" "timer carries the schedule, zoned" || fail=1
assert_contains "$(cat "$tmr")" "WantedBy=timers.target" "timer installs to timers.target" || fail=1

# unit files with a first-fire anchor
_sched_write_units def456 30m every 5h 2h
tmr2="$SYSTEMD_USER_DIR/claude-schedule-def456.timer"
assert_contains "$(cat "$tmr2")" "OnActiveSec=2h" "write_units passes the first-fire anchor through" || fail=1
exit "$fail"
