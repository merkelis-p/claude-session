#!/usr/bin/env bash
# Regression test for the PERF-scan fix: `cmd_ls` used to call `_session_rows`
# three times (its own scan, plus one each via `_compute_pid_flags` and
# `_doctor_warnings`), and each of those scans re-forked `tmux list-panes` and
# a `ps` for owner_tmux's ancestry map on top. `_pid_ram_mb` added one more
# `ps` fork PER SESSION ROW. None of it is cacheable with a shell-variable
# memo: every call site invokes these functions inside `$(...)`, and a
# subshell's cache dies the instant that subshell exits (see _session_rows'
# own comment in bin/claude-session). The fix hoists one scan into the
# caller's shell and hands the result down as an argument instead.
#
# This test does not assert wall-clock time (machine-dependent) or watch
# `_session_rows`/`_doctor_warnings` calls directly (they're internal, and
# every other test in this suite treats the entrypoint as a black box) — it
# asserts what the redundancy actually costs: real forks of jq/ps/tmux for one
# `claude-session ls` invocation, counted via wrapper binaries placed at the
# front of PATH that record a call and then exec the real binary, so `ls`
# still produces correct output while being measured.
#
# Budget derivation for THIS fixture (3 accounts with sessions, 3 sessions
# each = 9 rows total):
#   jq   — one batched `jq -rs` call per account-with-sessions (_session_rows),
#          called ONCE per `ls` now instead of three times: expected 3.
#          Budget 4 (headroom of 1; the pre-fix code produced 9 — one scan
#          would already blow past this budget).
#   ps   — one for owner_tmux's ancestry map (_ot_load) + one for the RAM
#          batch (_ram_load), both loaded once per `ls`: expected 2.
#          Budget 3 (headroom of 1; the pre-fix code produced 3 (one per
#          redundant scan) + 9 (one per row's _pid_ram_mb) = 12).
#   tmux — one `tmux list-panes` call via _ot_load, loaded once per `ls`:
#          expected 1, budget 1 (no headroom — a second call directly means
#          _ot_load reloaded, i.e. _session_rows scanned again).
set -uo pipefail
. "$(dirname "$0")/harness.sh"
setup_fake_home
trap teardown_fake_home EXIT
fail=0

# setup_fake_home installs a minimal ui.sh stub whose `owner_tmux` is a
# hardcoded `return 1` (every other test in the suite wants that — deterministic
# output, no dependency on real host tmux state). That stub never calls tmux or
# ps at all, which would make a tmux/ps fork-count assertion here pass
# VACUOUSLY regardless of whether the redundant-scan fix is in place: zero
# calls either way. So for THIS test only, append the real _ot_load/owner_tmux
# implementation on top of the fake HOME's ui.sh copy (never touching the
# shipped lib) — bash function redefinition means the later (real) one wins.
# Extracted from the shipped source rather than restated here, same principle
# as test_session_fields.sh's _SESSION_JQ extraction: a hand copy would drift
# from the code it's meant to measure.
sed -n '/^_OT_LOADED=0$/,$p' "$HELPERS_LIB_SRC/ui.sh" >> "$HOME/.local/share/claude-helpers/ui.sh"
if ! grep -q '^owner_tmux() {$' "$HOME/.local/share/claude-helpers/ui.sh"; then
  echo "FAIL: setup — could not extract the real owner_tmux/_ot_load block from ui.sh; the tmux/ps budget checks would be vacuous" >&2
  exit 1
fi

# ---- fixture: 3 accounts (default + 2 registered), 3 sessions each -------
mkdir -p "$HOME/.config/claude-helpers"
cat > "$HOME/.config/claude-helpers/accounts.conf" <<EOF
account acctA $HOME/.claude-accounts/acctA 'Account A'
account acctB $HOME/.claude-accounts/acctB 'Account B'
EOF
mkdir -p "$HOME/.claude-accounts/acctA" "$HOME/.claude-accounts/acctB"

pids=()
for acct_dir in "$HOME/.claude" "$HOME/.claude-accounts/acctA" "$HOME/.claude-accounts/acctB"; do
  for n in 1 2 3; do
    proj="$HOME/proj-$(basename "$acct_dir")-$n"
    mkdir -p "$proj"
    pids+=("$(fake_session "$acct_dir" "$proj")")
  done
done

# ---- recording wrappers: record a call, then exec the REAL binary --------
# Captured BEFORE the stub dir goes on PATH, so the wrapper still calls the
# genuine jq/ps/tmux (this must be a working `ls`, not just a counter).
REAL_JQ="$(command -v jq)"
REAL_PS="$(command -v ps)"
REAL_TMUX="$(command -v tmux)"
[[ -n "$REAL_JQ" && -n "$REAL_PS" && -n "$REAL_TMUX" ]] \
  || { echo "FAIL: setup — could not resolve real jq/ps/tmux on PATH" >&2; exit 1; }

FORK_DIR="$TEST_HOME/.fork_counts"
mkdir -p "$FORK_DIR"
STUB_DIR="$TEST_HOME/fork-bin"
mkdir -p "$STUB_DIR"

install_counting_wrapper() {
  local name="$1" real="$2"
  cat > "$STUB_DIR/$name" <<WRAP
#!/usr/bin/env bash
echo x >> "$FORK_DIR/$name.count"
exec "$real" "\$@"
WRAP
  chmod +x "$STUB_DIR/$name"
}
install_counting_wrapper jq "$REAL_JQ"
install_counting_wrapper ps "$REAL_PS"
install_counting_wrapper tmux "$REAL_TMUX"
export PATH="$STUB_DIR:$PATH"

count_of() {
  local f="$FORK_DIR/$1.count"
  [[ -f "$f" ]] && wc -l < "$f" || echo 0
}

assert_le() {
  local actual="$1" budget="$2" label="$3"
  if (( actual > budget )); then
    echo "FAIL: $label — expected <= $budget, got $actual" >&2
    return 1
  fi
  echo "PASS: $label (got $actual, budget $budget)"
}

# ---- exercise: exactly one `ls` invocation --------------------------------
out="$("$CS" ls 2>&1)"

# Guard against vacuity: if `ls` produced no output (e.g. it crashed, or the
# fixture is wrong), every fork-count assertion below would trivially pass at
# 0 and prove nothing.
if [[ -z "$out" ]]; then
  echo "FAIL: setup — ls produced no output; fork-budget checks would be vacuous" >&2
  fail=1
else
  echo "PASS: ls produced output to measure (not a vacuous 0-fork run)"
fi
for p in "${pids[@]}"; do
  assert_contains "$out" "$p" "ls lists fixture pid $p (fixture is wired up)" || fail=1
done

jq_n="$(count_of jq)"
ps_n="$(count_of ps)"
tmux_n="$(count_of tmux)"

assert_le "$jq_n"   4 "ls forks jq at most once per account-with-sessions, not once per redundant scan" || fail=1
assert_le "$ps_n"   3 "ls forks ps at most twice total (ancestry map + RAM batch), not once per row/scan" || fail=1
assert_le "$tmux_n" 1 "ls forks tmux exactly once (one list-panes call), not once per redundant scan" || fail=1

# ---- exercise: exactly one `doctor` invocation ----------------------------
# `cmd_doctor` had its own, separate redundancy: `_doctor_warnings` scanned
# once, then the "all clear" branch scanned AGAIN just to print a count (see
# bin/claude-session:1149/1155 in the finding this test guards). Reset the
# counters so this budget is measured independently of the `ls` run above.
# No RAM batching here — `_ram_load`/_pid_ram_mb are never called from
# `doctor`, so its ps budget is exactly _ot_load's one ancestry-map call.
rm -f "$FORK_DIR"/*.count
out2="$("$CS" doctor 2>&1)"

if [[ -z "$out2" ]]; then
  echo "FAIL: setup — doctor produced no output; fork-budget checks would be vacuous" >&2
  fail=1
else
  echo "PASS: doctor produced output to measure (not a vacuous 0-fork run)"
fi
assert_contains "$out2" "all clear" "doctor: fixture has no warnings (sanity check on the fixture, not the fix)" || fail=1

jq2_n="$(count_of jq)"
ps2_n="$(count_of ps)"
tmux2_n="$(count_of tmux)"

assert_le "$jq2_n"   4 "doctor forks jq at most once per account-with-sessions, not once per redundant scan" || fail=1
assert_le "$ps2_n"   1 "doctor forks ps at most once (ancestry map only — doctor never loads the RAM batch)" || fail=1
assert_le "$tmux2_n" 1 "doctor forks tmux exactly once (one list-panes call), not once per redundant scan" || fail=1

exit "$fail"
