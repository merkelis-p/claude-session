#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$0")/harness.sh"
fail=0
setup_fake_home
trap teardown_fake_home EXIT
install_fake_claude

# Fixture: an idle-looking orphan (ppid=1, node, 0% CPU) whose grandchild is a
# busy `codex exec`. Fields: pid ppid etimes pcpu comm args...
# NOTE (deviation from task-5-brief.md's literal Step 1 text): the brief's
# root row used args="claude shell wrapper" — that string is what _short_cmd
# DISPLAYS for a claude shell-snapshot wrapper (its special case: any args
# containing "shell-snapshots" renders as the literal label "claude shell
# wrapper"), not what a real `ps` row for one looks like. _orphan_rows only
# admits a ppid=1 row whose args match _ORPHAN_DEV_PATTERN or contain the
# substring "shell-snapshots" — "claude shell wrapper" matches neither, so
# the brief's literal fixture is silently filtered out before this section
# ever sees it (confirmed: the pid is simply absent from `.items[]`,
# regardless of this task's changes). Using a realistic shell-snapshots args
# string here (same convention tests/test_doctor_orphans.sh's own fixture
# already uses) is what actually exercises the scenario the brief describes.
cat > "$TEST_HOME/ps.src" <<'PS'
901163 1 141660 0.0 node claude shell-snapshots wrapper
901200 901163 141000 0.0 bash bash run.sh
901233 901200 140000 41.2 codex codex exec
901999 1 141660 0.0 node npm run dev
PS
export ORPHAN_PS_SRC="$TEST_HOME/ps.src"

doc="$(FORCE_COLOR=1 "$CS" _snapshot --json --only=processes 2>/dev/null)"
jq -e . >/dev/null 2>&1 <<<"$doc" || { echo "FAIL: invalid JSON: $doc" >&2; exit 1; }
[[ "$doc" == *$'\033'* ]] && { echo "FAIL: processes emitted ANSI" >&2; fail=1; } \
  || echo "PASS: processes emits no ANSI under FORCE_COLOR=1"
p="$(jq -c '.sections.processes' <<<"$doc")"
assert_eq "$(jq -r '.status' <<<"$p")" "ok" "processes.status is ok" || fail=1

busy="$(jq -c '.items[]|select(.pid==901163)' <<<"$p")"
assert_eq "$(jq -r '.activity.state' <<<"$busy")" "active" "a busy grandchild makes the orphan active" || fail=1
assert_eq "$(jq -r '.reapable' <<<"$busy")" "false" "an active orphan is not reapable" || fail=1
assert_eq "$(jq -r '.reapBlockedBy' <<<"$busy")" "active-subtree" "the block reason is named" || fail=1
assert_contains "$(jq -r '.activity.reason' <<<"$busy")" "codex exec" "the reason names the busy process" || fail=1
# The subtree is what lets the UI show WHY a reap will skip it.
assert_eq "$(jq -r '.activity.subtree|length' <<<"$busy")" "3" "the whole subtree is emitted" || fail=1
assert_contains "$(jq -r '[.activity.subtree[].cmd]|join(" ")' <<<"$busy")" "codex exec" \
  "the subtree includes the busy descendant's cmd" || fail=1
jq -e '[.activity.subtree[]|select(.pcpu>40)]|length==1' >/dev/null <<<"$busy" \
  && echo "PASS: subtree carries per-process pcpu" \
  || { echo "FAIL: subtree pcpu missing" >&2; fail=1; }

idle="$(jq -c '.items[]|select(.pid==901999)' <<<"$p")"
assert_eq "$(jq -r '.activity.state' <<<"$idle")" "idle" "a genuinely idle orphan is idle" || fail=1
assert_eq "$(jq -r '.reapable' <<<"$idle")" "true" "an idle orphan is reapable" || fail=1
assert_eq "$(jq -r '.class' <<<"$idle")" "orphan" "class distinguishes orphan from stuck-build" || fail=1
# The subtree must be emitted on the IDLE path too — it is the reapable, most
# common case, and it is exactly where the empty-reason field between two tabs
# collapses under `IFS=$'\t' read` (tab is IFS whitespace, so `idle\t\t<sub>`
# merges the two tabs and drops the subtree into reason). A regression there
# reappears as reason="<raw \x1f string>" and subtree=[].
assert_eq "$(jq -r '.activity.subtree|length' <<<"$idle")" "1" \
  "an idle orphan still emits its examined subtree (the empty reason must not collapse the column)" || fail=1
assert_eq "$(jq -r '.activity.reason' <<<"$idle")" "null" \
  "an idle orphan has no reason (null), not a mangled subtree string" || fail=1
assert_contains "$(jq -r '[.activity.subtree[].cmd]|join(" ")' <<<"$idle")" "npm run dev" \
  "and the subtree carries the examined process's cmd, not a raw delimiter blob" || fail=1

# One `ps` snapshot for the whole section: _orphan_activity must not re-read it
# per orphan. Counted with a wrapper ahead of PATH.
mkdir -p "$TEST_HOME/count"
cat > "$TEST_HOME/count/ps" <<'EOF'
#!/usr/bin/env bash
echo x >> "$PS_COUNT"; exec /bin/ps "$@"
EOF
chmod +x "$TEST_HOME/count/ps"
export PS_COUNT="$TEST_HOME/.ps_count"; : > "$PS_COUNT"
PATH="$TEST_HOME/count:$PATH" "$CS" _snapshot --json --only=processes >/dev/null 2>&1
n="$(wc -l < "$PS_COUNT" | tr -d ' ')"
(( n <= 4 )) && echo "PASS: processes section forks ps <= 4 times (actual $n)" \
  || { echo "FAIL: processes forked ps $n times — _orphan_activity is re-snapshotting" >&2; fail=1; }

# An empty process table is "nothing to check", which is a SKIP, not a pass.
: > "$TEST_HOME/ps.empty"; ORPHAN_PS_SRC="$TEST_HOME/ps.empty" \
  "$CS" _snapshot --json --only=processes 2>/dev/null | jq -c '.sections.processes' > "$TEST_HOME/empty.json"
assert_eq "$(jq -r '.items|length' < "$TEST_HOME/empty.json")" "0" "no orphans means no items" || fail=1
assert_contains "$(jq -r '.checksSkipped[].name' < "$TEST_HOME/empty.json")" "orphans" \
  "an unreadable/empty process table reports a skipped check, not a clean pass" || fail=1

# The reap path still refuses non-interactively without an explicit override.
"$CS" doctor --reap >/dev/null 2>&1; assert_eq "$?" "2" "doctor --reap still refuses with no TTY" || fail=1

# =============================================================================
# Step 4b: the safety defect. A spinning `*:build` process reads busy CPU (so
# the orphan-activity check called it "active") while _stuck_build_rows calls
# the exact same pid "hung" (running past the 600s threshold) — --reap then
# skipped it forever and --force did not help, because the idle/active split
# happened before FORCE was ever consulted. This block is the fixture-based
# demonstration that the fix actually closes that gap: a spinning build (no
# I/O progress) is "suspect" and --force CAN override it; a build that is
# genuinely still writing stays "active" and is NEVER overridable, no matter
# --force.
#
# $ORPHAN_IO_SRC holds pid<TAB>sample1<TAB>sample2 — read in place of a real
# /proc/<pid>/io probe (and its ~400ms sleep), exactly like $ORPHAN_PS_SRC
# replaces `ps`. Same fixture-pid-collision hazard as everywhere else in this
# suite: these pids are arbitrary numbers, never touched by a real kill.
# =============================================================================

# ---- suspect vs active classification (JSON) -------------------------------
# Both rows are old enough (900s > the 600s threshold) and equally busy
# (33.4% CPU) and match *:build, so they are indistinguishable by CPU or age
# alone — exactly the shape that made the two doctor checks contradict each
# other. Only the I/O sample tells them apart.
cat > "$TEST_HOME/ps.spin.txt" <<'PS'
910001 1 900 33.4 node node /home/u/app/node_modules/.bin/medusa plugin:build
910002 1 900 33.4 node node /home/u/app2/node_modules/.bin/medusa plugin:build
PS
export ORPHAN_PS_SRC="$TEST_HOME/ps.spin.txt"
printf '910001\t1000\t1000\n910002\t1000\t5000\n' > "$TEST_HOME/io.spin.txt"
export ORPHAN_IO_SRC="$TEST_HOME/io.spin.txt"

doc="$("$CS" _snapshot --json --only=processes 2>/dev/null)"
spin="$(jq -c '.sections.processes.items[]|select(.pid==910001 and .class=="stuck-build")' <<<"$doc")"
prog="$(jq -c '.sections.processes.items[]|select(.pid==910002 and .class=="stuck-build")' <<<"$doc")"

assert_eq "$(jq -r '.activity.state' <<<"$spin")" "suspect" \
  "CPU-busy + past the stuck threshold + no I/O movement is 'suspect', not 'active'" || fail=1
assert_eq "$(jq -r '.reapable' <<<"$spin")" "false" "suspect is never auto-reapable" || fail=1
assert_eq "$(jq -r '.reapBlockedBy' <<<"$spin")" "suspect-no-progress" "the guard is named suspect-no-progress" || fail=1
assert_contains "$(jq -r '.activity.reason' <<<"$spin")" "no I/O progress" \
  "the reason cites the actual evidence (no I/O progress)" || fail=1
assert_contains "$(jq -r '.activity.reason' <<<"$spin")" "appears hung" \
  "the wording is a suspicion (appears hung), never an assertion of fact" || fail=1
assert_not_contains "$(jq -r '.activity.reason' <<<"$spin")" "is hung" \
  "never asserts the process IS hung — a CPU-bound phase can be quiet too" || fail=1

assert_eq "$(jq -r '.activity.state' <<<"$prog")" "active" \
  "the SAME CPU/age profile with I/O counters that moved stays active" || fail=1
assert_eq "$(jq -r '.reapable' <<<"$prog")" "false" || fail=1
assert_eq "$(jq -r '.reapBlockedBy' <<<"$prog")" "active-subtree" \
  "a genuinely progressing build is blocked by active-subtree, not suspect-no-progress" || fail=1

# CLAUDE_COMPAT_OS is irrelevant here: $ORPHAN_IO_SRC replaces the probe
# end-to-end, so forcing a non-Linux host must not change the verdict —
# proving the fixture, not the OS, is what drives the classification.
doc2="$(CLAUDE_COMPAT_OS=darwin "$CS" _snapshot --json --only=processes 2>/dev/null)"
spin2="$(jq -c '.sections.processes.items[]|select(.pid==910001 and .class=="stuck-build")' <<<"$doc2")"
assert_eq "$(jq -r '.activity.state' <<<"$spin2")" "suspect" \
  "\$ORPHAN_IO_SRC overrides the OS check — the fixture wins on any host" || fail=1

# ---- the age guard: no-progress alone is not enough ------------------------
# The exact same no-progress I/O reading, but the process is younger than the
# 600s stuck threshold — must stay active. Confirms "suspect" requires ALL
# THREE conditions, not just CPU-busy + no I/O movement.
cat > "$TEST_HOME/ps.young_spin.txt" <<'PS'
910031 1 500 33.4 node node /home/u/app/node_modules/.bin/medusa plugin:build
PS
export ORPHAN_PS_SRC="$TEST_HOME/ps.young_spin.txt"
printf '910031\t1000\t1000\n' > "$TEST_HOME/io.young_spin.txt"
export ORPHAN_IO_SRC="$TEST_HOME/io.young_spin.txt"
doc="$("$CS" _snapshot --json --only=processes 2>/dev/null)"
young="$(jq -c '.sections.processes.items[]|select(.pid==910031 and .class=="orphan")' <<<"$doc")"
assert_eq "$(jq -r '.activity.state' <<<"$young")" "active" \
  "younger than the 600s threshold stays active no matter what I/O looks like" || fail=1

# ---- one real descendant keeps the whole subtree active --------------------
# root (idle) -> mid (old, busy, no I/O progress: a suspect CANDIDATE on its
# own) -> leaf (young, busy: unambiguously active). --reap kills the WHOLE
# subtree, so the leaf's real work must keep the ENTIRE subtree active, not
# just itself — reaping the root would still destroy the leaf's work.
cat > "$TEST_HOME/ps.mixed_subtree.txt" <<'PS'
920001 1 900 0.0 node node wrapper.js
920002 920001 900 33.4 node node /home/u/app/node_modules/.bin/medusa plugin:build
920003 920002 100 5.0 node node /home/u/app/node_modules/.bin/medusa plugin:build
PS
export ORPHAN_PS_SRC="$TEST_HOME/ps.mixed_subtree.txt"
printf '920002\t1000\t1000\n' > "$TEST_HOME/io.mixed_subtree.txt"
export ORPHAN_IO_SRC="$TEST_HOME/io.mixed_subtree.txt"
doc="$("$CS" _snapshot --json --only=processes 2>/dev/null)"
root="$(jq -c '.sections.processes.items[]|select(.pid==920001 and .class=="orphan")' <<<"$doc")"
assert_eq "$(jq -r '.activity.state' <<<"$root")" "active" \
  "one genuinely active descendant keeps the whole subtree active, even though another descendant alone would read suspect" || fail=1
assert_eq "$(jq -r '.activity.subtree|length' <<<"$root")" "3" "the full 3-process subtree is still reported" || fail=1

# ---- doctor --reap: suspect is skipped by default, never a refusal ---------
# Distinct from "everything active": a table with only a suspect orphan is
# not a hard refusal (exit 2 is reserved for "would kill something without
# confirmation") — nothing IS reapable without --force, so this exits 0 and
# says so, naming the exact flag that unblocks it.
cat > "$TEST_HOME/ps.suspect_only.txt" <<'PS'
910011 1 900 33.4 node node /home/u/app/node_modules/.bin/medusa plugin:build
PS
export ORPHAN_PS_SRC="$TEST_HOME/ps.suspect_only.txt"
printf '910011\t1000\t1000\n' > "$TEST_HOME/io.suspect_only.txt"
export ORPHAN_IO_SRC="$TEST_HOME/io.suspect_only.txt"
out="$("$CS" doctor --reap 2>&1 </dev/null)"; rc=$?
assert_eq "$rc" "0" "a suspect-only orphan set is not a hard refusal (nothing to confirm without --force)" || fail=1
assert_contains "$out" "suspected-hung" "the message names it a suspicion, not a confirmed hang" || fail=1
assert_contains "$out" "--force" "the message names the override flag" || fail=1
assert_not_contains "$out" "would reap" "nothing is reaped without --force" || fail=1

# ---- doctor --reap --force: suspect is overridden, active never is ---------
# Fixture mode is ALWAYS a dry run (see _do_reap's own CRITICAL SAFETY
# comment) — this never issues a real kill even under --force.
cat > "$TEST_HOME/ps.combo.txt" <<'PS'
910021 1 900 33.4 node node /home/u/app/node_modules/.bin/medusa plugin:build
910022 1 900 33.4 node node /home/u/app2/node_modules/.bin/medusa plugin:build
PS
export ORPHAN_PS_SRC="$TEST_HOME/ps.combo.txt"
printf '910021\t1000\t1000\n910022\t1000\t5000\n' > "$TEST_HOME/io.combo.txt"
export ORPHAN_IO_SRC="$TEST_HOME/io.combo.txt"

out="$("$CS" doctor --reap --force 2>&1 </dev/null)"; rc=$?
assert_eq "$rc" "0" "doctor --reap --force (fixture): exits 0" || fail=1
assert_contains "$out" "[dry-run]" "doctor --reap --force (fixture): still a dry run" || fail=1
assert_contains "$out" "would reap pid 910021 — forced past a suspected-hung guard" \
  "--force overrides the guard for the suspect pid, and says so" || fail=1
assert_not_contains "$out" "would reap pid 910022" \
  "a genuinely active build is NEVER overridable, even with --force — this is the asymmetry that must hold" || fail=1
assert_contains "$out" "would skip pid 910022" \
  "the active pid is listed as skipped instead" || fail=1

# Without --force, the same combo fixture: still nothing reaped (the suspect
# pid needs --force; the active pid is never reapable at all).
out="$("$CS" doctor --reap 2>&1 </dev/null)"; rc=$?
assert_eq "$rc" "0" "same combo fixture without --force: still not a hard refusal" || fail=1
assert_not_contains "$out" "would reap" "nothing reaped without --force" || fail=1
assert_contains "$out" "suspected-hung" "names the suspect pid's need for --force" || fail=1

exit "$fail"
