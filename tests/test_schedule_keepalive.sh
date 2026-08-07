#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$0")/harness.sh"
setup_fake_home; trap teardown_fake_home EXIT
fail=0
export SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
export SCHED_DIR="$HOME/.config/claude-helpers/schedules"
install_fake_systemctl
install_recording_claude
# stub the entrypoint helpers schedule.sh calls
_account_dir_or_default() { local n="${1:-default}"; [[ "$n" == default ]] && echo "$HOME/.claude" || echo "$HOME/.claude-accounts/$n"; }
_account_config_dir() { local n="$1"; [[ "$n" == default ]] && printf '' || { echo "$HOME/.claude-accounts/$n"; }; }
_all_accounts() {
  printf 'default\t%s\n' "$HOME/.claude"
  printf 'work\t%s\n' "$HOME/.claude-accounts/work"
  printf 'personal\t%s\n' "$HOME/.claude-accounts/personal"
}
. "$HELPERS_LIB_SRC/schedule.sh"

# count schedule dirs currently in SCHED_DIR
_sched_count() { shopt -s nullglob; local d n=0; for d in "$SCHED_DIR"/*/; do n=$((n+1)); done; echo "$n"; }

# ---- single-account: creates exactly one schedule ----
ACCOUNT=work cmd_schedule_keepalive >/dev/null 2>&1
assert_eq "$(_sched_count)" "1" "single-account keepalive creates exactly one schedule" || fail=1

id_work=""
for d in "$SCHED_DIR"/*/; do id_work="$(basename "$d")"; done
meta_work="$(cat "$SCHED_DIR/$id_work/meta")"
assert_contains "$meta_work" "target=new" "keepalive schedule targets --new" || fail=1
assert_contains "$meta_work" "when_kind=every" "keepalive schedule is an every-schedule" || fail=1
assert_contains "$meta_work" "when_val=5h" "keepalive schedule defaults to 5h" || fail=1
assert_contains "$meta_work" "account=work" "keepalive schedule tagged with account" || fail=1
assert_contains "$meta_work" "mode=plan" "keepalive schedule uses plan mode" || fail=1
assert_contains "$meta_work" "model=haiku" "keepalive schedule uses haiku model" || fail=1
assert_contains "$meta_work" "keepalive=1" "keepalive schedule is tagged keepalive=1" || fail=1
assert_eq "$(cat "$SCHED_DIR/$id_work/prompt.txt")" "hi" "keepalive prompt is 'hi'" || fail=1

# ---- run: invokes claude stub correctly ----
: > "$CLAUDE_CALLS"
cmd_schedule_run "$id_work" >/dev/null 2>&1
cc="$(cat "$CLAUDE_CALLS")"
assert_contains "$cc" "--model haiku" "run passes --model haiku" || fail=1
assert_contains "$cc" "--session-id" "run mints a new session (target=new)" || fail=1
assert_contains "$cc" "-p hi" "run passes the prompt with -p" || fail=1
assert_contains "$cc" "--permission-mode plan" "run maps plan mode to --permission-mode plan" || fail=1
assert_contains "$cc" "cfg:$HOME/.claude-accounts/work" "run injects the work account config dir" || fail=1

# ---- idempotency: a second call for the same account creates nothing new ----
before="$(_sched_count)"
out2="$(ACCOUNT=work cmd_schedule_keepalive 2>&1)"
after="$(_sched_count)"
assert_eq "$after" "$before" "second keepalive call for same account creates no new schedule" || fail=1
assert_contains "$out2" "skipping" "second keepalive call prints a skip message" || fail=1

# ---- all-accounts: fresh SCHED_DIR, expect exactly 3 (one per stubbed account) ----
rm -rf "$SCHED_DIR"; mkdir -p "$SCHED_DIR"
SCHED_ALL_ACCOUNTS=1 cmd_schedule_keepalive >/dev/null 2>&1
assert_eq "$(_sched_count)" "3" "all-accounts keepalive creates one schedule per account" || fail=1

# ---- custom interval ----
rm -rf "$SCHED_DIR"; mkdir -p "$SCHED_DIR"
SCHED_WHEN_KIND=every SCHED_WHEN_VAL=4h ACCOUNT=solo cmd_schedule_keepalive >/dev/null 2>&1
id_solo=""
for d in "$SCHED_DIR"/*/; do id_solo="$(basename "$d")"; done
assert_contains "$(cat "$SCHED_DIR/$id_solo/meta")" "when_val=4h" "custom interval is honored" || fail=1

# ---- first-fire anchor: --in ----
rm -rf "$SCHED_DIR"; mkdir -p "$SCHED_DIR"
SCHED_IN=3h ACCOUNT=work cmd_schedule_keepalive >/dev/null 2>&1
id_in=""
for d in "$SCHED_DIR"/*/; do id_in="$(basename "$d")"; done
assert_contains "$(cat "$SCHED_DIR/$id_in/meta")" "first=3h" "SCHED_IN anchor recorded in meta" || fail=1
assert_contains "$(cat "$SYSTEMD_USER_DIR/claude-schedule-$id_in.timer")" "OnActiveSec=3h" "SCHED_IN anchor reflected in the timer" || fail=1
SCHED_IN=""

# ---- default keepalive (no anchor) has first=1min ----
rm -rf "$SCHED_DIR"; mkdir -p "$SCHED_DIR"
ACCOUNT=noanchor cmd_schedule_keepalive >/dev/null 2>&1
id_def=""
for d in "$SCHED_DIR"/*/; do id_def="$(basename "$d")"; done
assert_contains "$(cat "$SCHED_DIR/$id_def/meta")" "first=1min" "default keepalive (no anchor) has first=1min" || fail=1

# ---- first-fire anchor: --at (clock-relative; only shape/bounds are asserted) ----
rm -rf "$SCHED_DIR"; mkdir -p "$SCHED_DIR"
SCHED_AT=23:59 ACCOUNT=solo cmd_schedule_keepalive >/dev/null 2>&1
id_at=""
for d in "$SCHED_DIR"/*/; do id_at="$(basename "$d")"; done
first_at="$(sed -n 's/^first=//p' "$SCHED_DIR/$id_at/meta")"
[[ "$first_at" =~ ^[0-9]+s$ ]]; assert_eq "$?" "0" "SCHED_AT anchor resolves to an Ns value" || fail=1
secs_at="${first_at%s}"
[[ "$secs_at" -gt 0 && "$secs_at" -le 86400 ]]; assert_eq "$?" "0" "SCHED_AT anchor falls within the next 24h" || fail=1
SCHED_AT=""

# ---- --work: a work-window keepalive instead of an interval one ----------
# This is the feature the shipped defect (bare OnCalendar) actually mattered
# for: a working day typed as 09:00-19:00 has to land at 09:00-19:00 in the
# user's OWN day, never in whatever zone the host happens to be in. --work
# requires an explicit zone (decision #2) — SCHED_TZ is set here exactly like
# a real `--tz=` flag would set it.
rm -rf "$SCHED_DIR"; mkdir -p "$SCHED_DIR"
ZONE="Europe/Vilnius"
SCHED_WORK="09:00-19:00" SCHED_TZ="$ZONE" ACCOUNT=zoned cmd_schedule_keepalive >/dev/null 2>&1
id_work_zoned=""
for d in "$SCHED_DIR"/*/; do id_work_zoned="$(basename "$d")"; done
meta_wz="$(cat "$SCHED_DIR/$id_work_zoned/meta")"
assert_contains "$meta_wz" "when_kind=work-window" "--work switches the keepalive to a work-window schedule" || fail=1
assert_contains "$meta_wz" "when_val=09:00-19:00" "the window is recorded verbatim" || fail=1
assert_contains "$meta_wz" "when_tz=$ZONE" "the resolved zone is recorded in meta" || fail=1
assert_contains "$meta_wz" "tz_source=flag" "--tz was explicit, so the source is 'flag', not 'host'" || fail=1
tmr_wz="$SYSTEMD_USER_DIR/claude-schedule-$id_work_zoned.timer"
assert_contains "$(cat "$tmr_wz")" "OnCalendar=*-*-* 09:00:00 $ZONE" "the window's START is a zoned OnCalendar line" || fail=1
assert_contains "$(cat "$tmr_wz")" "OnCalendar=*-*-* 19:00:00 $ZONE" "the window's END is ALSO a zoned OnCalendar line" || fail=1
assert_eq "$(grep -c "$ZONE" "$tmr_wz")" "2" "both OnCalendar lines are zoned — this is the actual fix, not just one of them" || fail=1
SCHED_WORK=""; SCHED_TZ=""

exit "$fail"
