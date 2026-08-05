#!/usr/bin/env bash
# F1 regression guard: doctor used to report THREE different counts for one
# underlying state — the human "N issue(s) flagged" line counted PRINTED
# LINES (`wc -l` over _doctor_warnings' output: a summary line, a per-orphan
# detail line, and a "→ reap them" hint line each scored as their own
# "issue"), plain `doctor`'s exit status inherited that same wrong number,
# and `doctor --json` derived a DIFFERENT number straight from the
# _DOCTOR_ISSUES inventory (one entry per orphan pid, no decorative lines).
# Same state, three numbers. This file asserts all three agree — the human
# printed count, the human exit status, and the JSON issues+processes item
# count — on one fixture that produces more than one distinct issue, and
# again on a clean ("all clear") fixture producing zero.
set -uo pipefail
. "$(dirname "$0")/harness.sh"
setup_fake_home
trap teardown_fake_home EXIT
fail=0

# ---- fixture: 3 distinct problem instances, from two different checks -----
# Check (6): two orphaned dev processes (ppid=1, old dev-runner processes,
# same shape as test_doctor_orphans.sh's own fixture) — 2 issues, one per pid.
FIXTURE="$TEST_HOME/fake_ps_multi.txt"
cat > "$FIXTURE" <<'EOF'
400001 1 18000 5.0 node node /home/x/app1/node_modules/.bin/vite dev
400002 1 18000 5.0 node node /home/x/app2/node_modules/.bin/vite dev
EOF
export ORPHAN_PS_SRC="$FIXTURE"

# Check (1): the SAME sessionId held by two live processes — 1 issue (one
# per DUPLICATE GROUP, not one per pid — same session, two procs).
proj="$HOME/proj-dup"; mkdir -p "$proj"
fake_session "$HOME/.claude" "$proj" "" "dup-sid" >/dev/null
fake_session "$HOME/.claude" "$proj" "" "dup-sid" >/dev/null

EXPECT=3

# ---- human path: printed count and exit status must both equal 3 ----------
out="$("$CS" doctor 2>&1)"; human_rc=$?
printed="$(grep -oE '[0-9]+ issue\(s\) flagged' <<<"$out" | grep -oE '^[0-9]+' || true)"
assert_eq "$printed" "$EXPECT" \
  "doctor (human): printed count is the real distinct-issue count, not a line count" || fail=1
assert_eq "$human_rc" "$EXPECT" \
  "doctor (human): exit status equals the same real distinct-issue count" || fail=1

# ---- JSON path: issues+processes items must ALSO equal 3, matching the ----
# human path exactly (not merely self-consistent with its own exit code).
jdoc="$("$CS" doctor --json 2>/dev/null)"; json_rc=$?
json_n="$(jq -n --argjson d "$jdoc" \
  '($d.sections.issues.items // []) as $i | ($d.sections.processes.items // []) as $p | ($i|length) + ($p|length)' \
  2>/dev/null)"
assert_eq "$json_n" "$EXPECT" \
  "doctor --json: issues+processes item count is the real distinct-issue count" || fail=1
assert_eq "$json_rc" "$EXPECT" \
  "doctor --json: exit status equals the same real distinct-issue count" || fail=1

# ---- the actual cross-check: all three numbers, read three different ways,
# must be the SAME number for the SAME state (F1's core requirement).
assert_eq "$printed" "$json_n" \
  "doctor: human-printed count and JSON item count agree (same inventory, by construction)" || fail=1
assert_eq "$human_rc" "$json_rc" \
  "doctor: human exit status and JSON exit status agree (same inventory, by construction)" || fail=1

# ---- zero case: the same three numbers must all agree at 0 on a clean box -
unset ORPHAN_PS_SRC
teardown_fake_home
setup_fake_home
export ORPHAN_PS_SRC="$TEST_HOME/.fake_ps_empty"

out2="$("$CS" doctor 2>&1)"; human_rc2=$?
assert_contains "$out2" "all clear" "doctor (human, clean box): reports all clear" || fail=1
assert_eq "$human_rc2" "0" "doctor (human, clean box): exit status is 0" || fail=1

jdoc2="$("$CS" doctor --json 2>/dev/null)"; json_rc2=$?
json_n2="$(jq -n --argjson d "$jdoc2" \
  '($d.sections.issues.items // []) as $i | ($d.sections.processes.items // []) as $p | ($i|length) + ($p|length)' \
  2>/dev/null)"
assert_eq "$json_n2" "0" "doctor --json (clean box): issues+processes item count is 0" || fail=1
assert_eq "$json_rc2" "0" "doctor --json (clean box): exit status is 0" || fail=1
assert_eq "$human_rc2" "$json_rc2" \
  "doctor (clean box): human and JSON exit status agree at zero" || fail=1

exit "$fail"
