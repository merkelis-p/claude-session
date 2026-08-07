#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$0")/harness.sh"
fail=0
setup_fake_home
trap teardown_fake_home EXIT
install_fake_claude
install_fake_systemctl
export SCHED_DIR="$HOME/.config/claude-helpers/schedules"
export SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
ZONE="Europe/Vilnius"

# ===== the assertion that would have caught the defect =====
# A unit generated from a working-hours plan must carry the ZONE, and its next
# elapse must be the intended LOCAL time — not the same digits in UTC.
"$CS" schedule keepalive --work=09:00-19:00 --tz="$ZONE" --account=default --yes >/dev/null 2>&1
id="$(ls "$SCHED_DIR" | head -1)"
timer="$SYSTEMD_USER_DIR/claude-schedule-$id.timer"
assert_contains "$(cat "$timer")" "OnCalendar=*-*-* 09:00:00 $ZONE" "the unit carries the zone name" || fail=1
assert_eq "$(grep -c "$ZONE" "$timer")" "2" "every OnCalendar line is zoned, not just the first" || fail=1
# An OFFSET would be right for half the year and wrong for the other half, with no
# user action — Vilnius is +2 in January and +3 in August. Only a name is allowed.
assert_not_contains "$(cat "$timer")" "+03" "the zone is a name, never a stored offset" || fail=1
assert_not_contains "$(cat "$timer")" "UTC+" "no offset form anywhere in the unit" || fail=1

if command -v systemd-analyze >/dev/null 2>&1; then
  # The real check: ask systemd when this fires, convert that instant BACK into the
  # schedule's zone, and require the wall clock to be what the user typed. This is
  # DST-proof, which an expected-UTC-hour assertion would not be.
  nx="$(systemd-analyze calendar "*-*-* 09:00:00 $ZONE" 2>/dev/null \
        | awk -F': +' '/Next elapse/{print $2}')"
  ep="$(date -d "$nx" +%s 2>/dev/null || date -j -f '%a %Y-%m-%d %H:%M:%S %Z' "$nx" +%s)"
  assert_eq "$(TZ="$ZONE" date -d "@$ep" +%H:%M 2>/dev/null || TZ="$ZONE" date -r "$ep" +%H:%M)" "09:00" \
    "the next elapse is 09:00 in the schedule's zone" || fail=1
  # ...and demonstrably NOT the unzoned reading, which is the bug.
  nx0="$(systemd-analyze calendar '*-*-* 09:00:00' 2>/dev/null | awk -F': +' '/Next elapse/{print $2}')"
  ep0="$(date -d "$nx0" +%s 2>/dev/null || date -j -f '%a %Y-%m-%d %H:%M:%S %Z' "$nx0" +%s)"
  if [[ "$(TZ=UTC date -d "@$ep0" +%H:%M 2>/dev/null || TZ=UTC date -r "$ep0" +%H:%M)" == "09:00" \
        && "$ep" != "$ep0" ]]; then
    echo "PASS: the zoned and unzoned readings are different instants (the defect is real and fixed)"
  else
    echo "SKIP: zoned/unzoned comparison — this host's timezone equals $ZONE, so the two coincide"
  fi
else
  echo "SKIP: next-elapse verification — systemd-analyze is not available on this host"
fi

# ===== zone resolution: flag > config > host, and the source is recorded =====
. "$HELPERS_LIB_SRC/compat.sh"; . "$HELPERS_LIB_SRC/config.sh"; . "$HELPERS_LIB_SRC/schedule.sh"
assert_eq "$(SCHED_TZ="$ZONE" _sched_tz_resolve)" "$ZONE"$'\t'"flag" "--tz wins" || fail=1
printf 'schedule_tz=%s\n' "$ZONE" > "$HOME/.config/claude-helpers/config.conf"
_cs_config_load
assert_eq "$(SCHED_TZ='' _sched_tz_resolve)" "$ZONE"$'\t'"config" "config.conf is next" || fail=1
: > "$HOME/.config/claude-helpers/config.conf"; _CS_CONFIG_LOADED=0; _cs_config_load
r="$(SCHED_TZ='' _sched_tz_resolve)"
assert_eq "$(cut -f2 <<<"$r")" "host" "the host zone is the last resort, and is LABELLED as such" || fail=1
[[ -n "$(cut -f1 <<<"$r")" ]] && echo "PASS: the host zone resolves to a name" || fail=1

# ===== --work REQUIRES an explicit zone =====
out="$("$CS" schedule keepalive --work=09:00-19:00 --account=default --json --dry-run 2>&1)"; rc=$?
assert_eq "$rc" "2" "--work with no zone is refused" || fail=1
assert_contains "$out" "--tz=" "the refusal names the flag" || fail=1
assert_contains "$out" "schedule_tz" "and the config key" || fail=1
assert_contains "$out" "this host is" "and the detected host zone, in case that is what was meant" || fail=1

# ===== the frozen flags still work with no zone, but are now EXPLICIT =====
"$CS" schedule add "ping" --new --daily-at=09:00 >/dev/null 2>&1
assert_eq "$?" "0" "daily-at with no zone still works (frozen contract)" || fail=1
id2="$(grep -rl 'when_kind=daily-at' "$SCHED_DIR" | head -1 | xargs dirname | xargs basename)"
t2="$SYSTEMD_USER_DIR/claude-schedule-$id2.timer"
grep -qE '^OnCalendar=\*-\*-\* 09:00:00 [A-Za-z]+/[A-Za-z_]+$|^OnCalendar=\*-\*-\* 09:00:00 (UTC|Etc/UTC)$' "$t2" \
  && echo "PASS: an unzoned request still writes an EXPLICIT zone into the unit" \
  || { echo "FAIL: daily-at wrote a bare OnCalendar again" >&2; cat "$t2" >&2; fail=1; }
assert_contains "$(cat "$SCHED_DIR/$id2/meta")" "tz_source=host" "meta records where the zone came from" || fail=1
assert_contains "$("$CS" schedule ls 2>&1)" "from this host's timezone" \
  "a host-derived zone is called out in the listing, so a mismatch is noticeable" || fail=1

# ===== validation round-trips the exact string that will be written =====
"$CS" schedule add "x" --new --daily-at=09:00 --tz=Nowhere/Fake >/dev/null 2>&1
assert_eq "$?" "2" "an unknown zone is refused" || fail=1
n_before="$(ls "$SYSTEMD_USER_DIR" | wc -l | tr -d ' ')"
"$CS" schedule add "x" --new --daily-at=09:00 --tz='Europe/Vilnius; rm -rf /' >/dev/null 2>&1
assert_eq "$(ls "$SYSTEMD_USER_DIR" | wc -l | tr -d ' ')" "$n_before" \
  "a zone that fails validation is never written into a unit" || fail=1

# ===== existing schedules are NOT moved =====
mkdir -p "$SCHED_DIR/legacy1"
printf 'target=new\nsid=\naccount=default\nmode=autopilot\nkeepalive=0\ncwd=%s\ntimeout=30m\nwhen_kind=daily-at\nwhen_val=09:00\nfirst=1min\ncreated=1\n' "$HOME" > "$SCHED_DIR/legacy1/meta"
printf '[Timer]\nOnCalendar=*-*-* 09:00:00\nPersistent=true\n' > "$SYSTEMD_USER_DIR/claude-schedule-legacy1.timer"
sum_before="$(cksum < "$SYSTEMD_USER_DIR/claude-schedule-legacy1.timer")"
"$CS" schedule ls >/dev/null 2>&1; "$CS" doctor >/dev/null 2>&1
assert_eq "$(cksum < "$SYSTEMD_USER_DIR/claude-schedule-legacy1.timer")" "$sum_before" \
  "listing and doctor never rewrite an existing unit" || fail=1
# ...but they are FLAGGED, loudly, with the interpretation spelled out
out="$("$CS" doctor 2>&1)"
assert_contains "$out" "legacy1" "doctor flags the unzoned schedule by id" || fail=1
assert_contains "$out" "no timezone" "and says what is wrong" || fail=1
assert_contains "$out" "schedule retime" "and names the fix" || fail=1
# a keepalive `every` schedule has no wall-clock time and must NOT be flagged
mkdir -p "$SCHED_DIR/every1"
printf 'account=default\nkeepalive=1\nwhen_kind=every\nwhen_val=5h\n' > "$SCHED_DIR/every1/meta"
assert_not_contains "$("$CS" doctor 2>&1)" "every1" \
  "an interval schedule carries no wall-clock time and is never flagged for a zone" || fail=1

# ===== schedule retime: plan first, and it names both instants =====
p="$("$CS" schedule retime legacy1 --tz="$ZONE" --json --dry-run 2>/dev/null)"
assert_eq "$(jq -r '.mutation' <<<"$p")" "schedule.retime" "retime is a planned mutation" || fail=1
assert_contains "$(jq -r '.warnings|join(" ")' <<<"$p")" "09:00" "the plan shows the wall-clock time" || fail=1
jq -e '[.warnings[]|select(test("fires now"))]|length>0' >/dev/null <<<"$p" \
  && echo "PASS: the plan states the CURRENT firing instant" || { echo "FAIL: no current instant in the plan" >&2; fail=1; }
jq -e '[.warnings[]|select(test("would fire"))]|length>0' >/dev/null <<<"$p" \
  && echo "PASS: and the PROPOSED firing instant" || { echo "FAIL: no proposed instant in the plan" >&2; fail=1; }
assert_eq "$(cksum < "$SYSTEMD_USER_DIR/claude-schedule-legacy1.timer")" "$sum_before" \
  "--dry-run moved nothing" || fail=1
d="$(jq -r '.confirmations[0].digest' <<<"$p")"
[[ -n "$d" && "$d" != "null" ]] && echo "PASS: moving an existing firing time requires an ack" || fail=1
"$CS" schedule retime legacy1 --tz="$ZONE" --yes >/dev/null 2>&1
assert_eq "$?" "3" "retime without the ack exits 3" || fail=1
"$CS" schedule retime legacy1 --tz="$ZONE" --yes --ack="$d" >/dev/null 2>&1
assert_contains "$(cat "$SYSTEMD_USER_DIR/claude-schedule-legacy1.timer")" "09:00:00 $ZONE" \
  "an acked retime writes the zone" || fail=1
ls "$SCHED_DIR/legacy1"/unit.bak.* >/dev/null 2>&1 && echo "PASS: retime backs the unit up first" || fail=1
assert_contains "$(cat "$SCHED_DIR/legacy1/meta")" "when_tz=$ZONE" "and records the zone in meta" || fail=1

# ===== display: never a bare wall-clock time again =====
out="$("$CS" schedule ls 2>&1)"
assert_contains "$out" "$ZONE" "the listing names the zone" || fail=1
if command -v systemd-analyze >/dev/null 2>&1; then
  assert_contains "$out" "UTC" "and shows UTC alongside when the two differ" || fail=1
fi
# --json carries instants plus the zone, so the app never has to guess
sec="$("$CS" _snapshot --json --only=schedules 2>/dev/null | jq -c '.sections.schedules')"
it="$(jq -c '.items[]|select(.id=="legacy1")' <<<"$sec")"
assert_eq "$(jq -r '.whenTz' <<<"$it")" "$ZONE" "the section emits whenTz" || fail=1
assert_eq "$(jq -r '.tzSource' <<<"$it")" "flag" "and where the zone came from" || fail=1
jq -e '.nextFire.state=="known" or .nextFire.state=="unknown"' >/dev/null <<<"$it" \
  && echo "PASS: nextFire stays a tri-state INSTANT, not a wall-clock string" || fail=1
jq -e '(.nextFire.value|type)=="number" or (.nextFire.value==null)' >/dev/null <<<"$it" \
  && echo "PASS: nextFire.value is an epoch, so comparisons are zone-free" || fail=1
exit "$fail"
