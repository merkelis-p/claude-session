#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$0")/harness.sh"
fail=0

# This is a smoke test against the REAL process table — not the $ORPHAN_PS_SRC
# fixture every other test uses. The fixture tests exercise the parsing logic
# with pre-canned input; they cannot catch a broken real-`ps` invocation
# (wrong flags, wrong field order, a GNU-only option on a BSD host, etc.) —
# that is exactly the gap that let blocker 5 hide. Deliberately do NOT set
# ORPHAN_PS_SRC (and unset it defensively in case it leaked from the caller's
# environment).
unset ORPHAN_PS_SRC

# ---- _proc_table itself, against the real `ps` -----------------------------
# shellcheck source=/dev/null
. "$HELPERS_LIB_SRC/compat.sh"
_pt="$(_proc_table)"

n_rows="$(grep -c '' <<<"$_pt")"
[[ "$n_rows" -ge 5 ]]
assert_eq "$?" "0" "_proc_table returns a plausible number of rows on the real host ($n_rows)" || fail=1

bad_fields="$(awk -F'\t' 'NF!=6{c++} END{print c+0}' <<<"$_pt")"
assert_eq "$bad_fields" "0" "_proc_table: every one of $n_rows rows has exactly 6 TSV fields" || fail=1

bad_numeric="$(awk -F'\t' '$1!~/^[0-9]+$/ || $2!~/^[0-9]+$/ || $3!~/^[0-9]+$/ {c++} END{print c+0}' <<<"$_pt")"
assert_eq "$bad_numeric" "0" "_proc_table: pid/ppid/etimes are numeric on every row" || fail=1

# Capture first, then match: `_proc_table | grep -q` races under `pipefail` —
# grep exits on the first match, the producer's next write dies with SIGPIPE,
# and pipefail reports that as failure even though the match was found. Match
# against the already-captured variable instead (same fix used in
# test_compat.sh, and the same hazard this project has been bitten by before).
grep -q "^$$"$'\t' <<<"$_pt" \
  && echo "PASS: _proc_table contains the current shell's own pid ($$)" \
  || { echo "FAIL: _proc_table missing self ($$)" >&2; fail=1; }

# The specific blocker-5 shape: `ps comm=` can contain spaces (tmux renames
# itself "tmux: server"), which shifts every field after it unless comm is
# handled as the variable-width LAST column of its own `ps` call. Find a real
# row with an embedded space in comm and check it survived intact — still 6
# fields, pid/ppid/etimes still numeric — rather than being truncated or
# shifting subsequent fields. Skip visibly (not silently, not a failure) if no
# such process happens to exist on this host right now.
spaced_row="$(awk -F'\t' '$5 ~ / / {print; exit}' <<<"$_pt")"
if [[ -n "$spaced_row" ]]; then
  sr_fields="$(awk -F'\t' '{print NF}' <<<"$spaced_row")"
  sr_ok=1
  [[ "$sr_fields" == "6" ]] || sr_ok=0
  awk -F'\t' '$1~/^[0-9]+$/ && $2~/^[0-9]+$/ && $3~/^[0-9]+$/ {exit 0} {exit 1}' <<<"$spaced_row" || sr_ok=0
  sr_comm="$(awk -F'\t' '{print $5}' <<<"$spaced_row")"
  if [[ "$sr_ok" == "1" ]]; then
    echo "PASS: _proc_table preserves a spaced comm intact (\"$sr_comm\") without corrupting other fields"
  else
    echo "FAIL: _proc_table corrupted a spaced-comm row: $spaced_row" >&2
    fail=1
  fi
else
  echo "SKIP: no process with a space in its comm exists on this host right now — cannot verify spaced-comm preservation"
fi

# ---- end-to-end: $CS itself against the real process table ----------------
# Deliberately not calling setup_fake_home: this test wants the real $HOME,
# real accounts, real tmux sessions — the actual environment `doctor`/`ls`
# run against day to day, not a hermetic fixture.
out="$("$CS" doctor 2>&1)"; ec=$?
# This used to assert `ec == 0`, which quietly encoded a BUG as the expectation:
# cmd_doctor fell off its own end, so its status was always 0 regardless of what
# it found, and 0 therefore proved nothing about whether the run succeeded. What
# this check actually wants is "doctor ran to completion against the real process
# table rather than dying", so compare its status against the count it printed —
# the documented contract (docs/doctor-orphans.md, "Exit status"). A real crash
# shows up as a status that does NOT match the printed count, which is what a
# bash error (1), a usage error (2) or a missing command (127) would produce.
printed="$(grep -oE '[0-9]+ issue\(s\) flagged' <<<"$out" | grep -oE '^[0-9]+' || true)"
[[ -n "$printed" ]] || printed=0
assert_eq "$ec" "$printed" "doctor's status matches its own issue count against the real process table" || fail=1
assert_contains "$out" "Doctor" "doctor renders its box against real ps" || fail=1
assert_not_contains "$out" "invalid option" "no getopt errors from a GNU-only ps invocation" || fail=1
assert_not_contains "$out" "illegal option" "no BSD getopt errors either" || fail=1
assert_not_contains "$out" "No such file or directory" "no /proc-style path errors" || fail=1

# ls must see live sessions as alive, not all stale — a broken liveness check
# (e.g. _proc_alive wired to the wrong pid column) would silently mark every
# session dead instead of erroring, which is exactly the kind of failure a
# fixture test cannot see.
ls_out="$("$CS" ls 2>&1)"
if grep -qE 'pid [0-9]+' <<<"$ls_out"; then
  n_stale="$(grep -c 'stale' <<<"$ls_out" || true)"
  n_rows_ls="$(grep -cE 'pid [0-9]+' <<<"$ls_out" || true)"
  [[ "$n_stale" -lt "$n_rows_ls" ]] \
    && echo "PASS: ls does not mark every live session stale ($n_stale/$n_rows_ls)" \
    || { echo "FAIL: ls marked all $n_rows_ls sessions stale — liveness check is broken" >&2; fail=1; }
else
  # SKIP, not PASS: no sessions means the liveness check was never exercised.
  echo "SKIP: ls reported no sessions — liveness check not exercised on this host"
fi

# Any orphan row the real path produces must have a numeric age and a pid.
orph="$(sed -n '/orphaned dev/,/reap them/p' <<<"$out" | grep -oE 'pid [0-9]+ +[0-9]+[hm]' || true)"
if [[ -n "$orph" ]]; then
  echo "PASS: real-ps orphan rows are well formed"
else
  # A check that had nothing to check is a SKIP, not a PASS. Reporting "vacuously
  # holds" as a pass inflates the suite's green count with an assertion that
  # cannot fail — and on a host with no orphans it would keep reading green even
  # if the orphan formatter were completely broken.
  echo "SKIP: no orphans on this host — orphan-row formatting not exercised"
fi

exit "$fail"
