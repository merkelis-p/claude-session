#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$0")/harness.sh"
setup_fake_home
trap teardown_fake_home EXIT
fail=0

# ---- fixture: hand-written fake `ps -eo pid=,ppid=,etimes=,pcpu=,comm=,args=`
# table (real field order: pid ppid etimes pcpu comm args…). No real processes
# are touched — _orphan_rows reads this via $ORPHAN_PS_SRC instead of `ps`.
FIXTURE="$TEST_HOME/fake_ps_orphans.txt"
cat > "$FIXTURE" <<'EOF'
100001 1 18268 26.8 node node /home/x/backend/node_modules/.bin/medusa plugin:build
100002 1 18300 26.5 node node /home/x/backend/node_modules/.bin/medusa plugin:build
100003 1 18350 27.1 node node /home/x/backend/node_modules/.bin/medusa plugin:build
100004 1 599521 0.0 npmrundev npm run dev
100005 1 87372 0.1 bash /bin/bash -c source /home/x/.claude-accounts/work/shell-snapshots/snapshot-bash-123.sh
100006 12345 999999 0.0 node node /home/y/app/node_modules/.bin/vite dev
100007 1 60 0.0 node node /home/z/app/server.js
100008 1 400 0.0 postgres postgres
100009 1 400 0.0 tmux: server tmux new-session -d -s foo -c /home/x/foo npm run dev
100010 1 400 0.0 sshd sshd: alice@pts/3
100011 1 400 0.0 earlyoom /usr/bin/earlyoom -r 3600 -m 6 -s 15
100012 1 400 0.0 dockerd /usr/bin/dockerd -H fd://
100013 999 1200 5.0 node node /home/build/backend/node_modules/.bin/medusa plugin:build
EOF

export ORPHAN_PS_SRC="$FIXTURE"

# ---- detection (check 6) ----------------------------------------------------
out="$("$CS" doctor 2>&1)"

assert_contains "$out" "5 orphaned dev process" \
  "doctor: flags the 5 orphans (3 builds + npm + shell wrapper)" || fail=1
assert_contains "$out" "plugin:build" "doctor: mentions plugin:build" || fail=1
assert_contains "$out" "100001" "doctor: shows a pid from the fixture" || fail=1
assert_contains "$out" "--reap" "doctor: hints at --reap" || fail=1

assert_not_contains "$out" "postgres" "doctor: never flags postgres" || fail=1
assert_not_contains "$out" "sshd" "doctor: never flags sshd" || fail=1
assert_not_contains "$out" "dockerd" "doctor: never flags dockerd" || fail=1
assert_not_contains "$out" "earlyoom" "doctor: never flags earlyoom" || fail=1
assert_not_contains "$out" "100006" "doctor: never flags the non-orphan (live parent) node process" || fail=1
assert_not_contains "$out" "100007" "doctor: never flags the young orphan (under the 300s floor)" || fail=1

# ---- check (7): stuck build, any parentage ----------------------------------
assert_contains "$out" "stuck" "doctor: check (7) mentions a stuck build" || fail=1
assert_contains "$out" "hung" "doctor: check (7) notes a build this long is hung" || fail=1

# ---- --reap without --force, non-interactively: must refuse, never kill -----
out="$("$CS" doctor --reap 2>&1 </dev/null)"; rc=$?
assert_eq "$rc" "2" "doctor --reap: non-interactive refusal exits 2" || fail=1
assert_contains "$out" "--force" "doctor --reap: refusal names --force" || fail=1
assert_not_contains "$out" "reaped " "doctor --reap: refusal never attempts a kill" || fail=1

# ---- no orphans: zero false positives, no behavior change on a clean system -
CLEAN="$TEST_HOME/fake_ps_clean.txt"
cat > "$CLEAN" <<'EOF'
200001 12345 999999 0.0 node node /home/y/app/node_modules/.bin/vite dev
200002 1 400 0.0 postgres postgres
200003 1 400 0.0 tmux: server tmux new-session -d -s bar -c /home/x/bar npm run dev
200004 1 400 0.0 sshd sshd: alice@pts/4
200005 1 400 0.0 earlyoom /usr/bin/earlyoom -r 3600 -m 6 -s 15
200006 1 400 0.0 dockerd /usr/bin/dockerd -H fd://
EOF
export ORPHAN_PS_SRC="$CLEAN"
out="$("$CS" doctor 2>&1)"
assert_contains "$out" "all clear" \
  "doctor: clean system (protected/non-orphan procs only) still reports all clear" || fail=1
assert_not_contains "$out" "orphaned dev process" \
  "doctor: clean system never prints an orphan warning" || fail=1

# ---- activity-aware reap: an orphan's SUBTREE can still be doing real work --
# A live near-miss on this box: an orphaned `claude` shell wrapper reads 0.0%
# CPU, but its grandchild (a `codex exec` job) is actively working. --reap
# kills the whole subtree, so judging the root pid alone would destroy that
# job. Kept in its OWN fixture file (not FIXTURE above) so the "5 orphans"
# assertions earlier in this file stay honest — none of these pids are part
# of that count.
ACTIVITY="$TEST_HOME/fake_ps_activity.txt"
cat > "$ACTIVITY" <<'EOF'
100020 1 900 0.0 bash /bin/bash -c source /home/x/.claude/shell-snapshots/snapshot-bash-9.sh
100021 100020 890 0.0 bash bash ./run.sh job
100022 100021 880 1.3 codex codex exec -m gpt-5.6-sol
100030 1 90000 0.0 npmrundev npm run dev
100031 100030 89990 0.0 sh sh -c tsx watch src/server.ts
EOF
export ORPHAN_PS_SRC="$ACTIVITY"

out="$("$CS" doctor 2>&1)"

# 100020 (root, 0.0% CPU) must be marked active because of its codex
# grandchild (100022, 1.3% CPU) — check the text on/after its detail line.
after_100020="$(awk '/pid 100020/{f=1} f' <<<"$out")"
assert_contains "$after_100020" "active:" \
  "doctor: marks the busy-subtree orphan (100020) active" || fail=1
assert_contains "$after_100020" "codex" \
  "doctor: names the codex descendant as the reason" || fail=1
assert_contains "$after_100020" "reap will skip" \
  "doctor: notes reap will skip the active orphan" || fail=1

assert_contains "$out" "[reapable]" \
  "doctor: marks the fully-idle orphan (100030, npm run dev) reapable" || fail=1

assert_contains "$out" "reapable" "doctor: summary distinguishes reapable count" || fail=1
assert_contains "$out" "busy" "doctor: summary distinguishes busy count" || fail=1

# ---- --reap --force in fixture mode: MUST be a dry run, must kill nothing ---
# Never let this become a real kill: $ORPHAN_PS_SRC fixture pids (100020,
# 100030, …) are arbitrary numbers that could collide with REAL live pids on
# whatever host runs this test.
out="$("$CS" doctor --reap --force 2>&1 </dev/null)"; rc=$?
assert_eq "$rc" "0" "doctor --reap --force (fixture): exits 0" || fail=1
assert_contains "$out" "[dry-run]" "doctor --reap --force (fixture): prints dry-run marker" || fail=1
assert_contains "$out" "would reap pid 100030" \
  "doctor --reap --force (fixture): names the idle pid as would-be-killed" || fail=1
assert_not_contains "$out" "would reap pid 100020" \
  "doctor --reap --force (fixture): never lists the active orphan as would-be-killed" || fail=1
assert_contains "$out" "would skip pid 100020" \
  "doctor --reap --force (fixture): lists the active orphan as skipped instead" || fail=1

# ---- exit status IS the issue count (docs/doctor-orphans.md, "Exit status") ---
# The whole point of that contract is `claude-session doctor; echo $?` in a
# monitoring loop, with no output parsing. cmd_doctor used to fall off its own
# end, so the status came from the last command to run (box_bottom) and was
# ALWAYS 0 — a monitor read "all clear" while the box above printed six issues.
# Asserting the two agree is what makes the contract checkable: comparing the
# code against the printed "N issue(s) flagged" line means a future change
# cannot move one without the other.
export ORPHAN_PS_SRC="$FIXTURE"
out="$("$CS" doctor 2>&1)"; rc=$?
printed="$(grep -oE '[0-9]+ issue\(s\) flagged' <<<"$out" | grep -oE '^[0-9]+' || true)"
if [[ -n "$printed" ]]; then
  assert_eq "$rc" "$printed" "doctor's exit status equals the issue count it printed" || fail=1
  # Guard against the assertion above passing for the wrong reason: if the
  # fixture ever stopped producing issues, 0 == 0 would "pass" while proving
  # nothing about a non-zero count.
  if (( printed > 0 )); then
    echo "PASS: the fixture produced $printed issue(s), so a non-zero status was actually exercised"
  else
    echo "FAIL: fixture produced no issues — the exit-status check could only compare 0 to 0" >&2; fail=1
  fi
else
  # "all clear" is the other half of the same contract, not an untested case.
  assert_contains "$out" "all clear" "no issue count printed, so doctor must have said all clear" || fail=1
  assert_eq "$rc" "0" "doctor exits 0 when it reports all clear" || fail=1
fi

exit "$fail"
