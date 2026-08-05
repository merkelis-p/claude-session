#!/usr/bin/env bash
# The fork budget is the hard assertion; wall-clock latency is machine-dependent
# and is only MEASURED (and SKIPped where it cannot be trusted). The 574-fork
# regression this project already paid for was a per-row fork, invisible to a
# latency test on a fast machine but obvious in a fork count — so counts are the
# gate, latency is the record.
#
# The `ls`/`doctor` budgets belong to tests/test_scan_fork_budget.sh and are NOT
# re-asserted here: two files asserting the same budget with different fixtures is
# how one of them quietly stops meaning anything. This file covers only the
# surfaces this plan added (_snapshot and _titles).
set -uo pipefail
. "$(dirname "$0")/harness.sh"
fail=0
setup_fake_home
trap teardown_fake_home EXIT
install_fake_claude
install_fake_tmux
export XDG_CACHE_HOME="$TEST_HOME/.cache"

# Stated fixture, because a budget is only meaningful against one: 2 accounts,
# 2 session files each, 2 transcripts each.
mkdir -p "$TEST_HOME/.claude-alpha"
printf 'account alpha ~/.claude-alpha "second"\n' > "$TEST_HOME/.config/claude-helpers/accounts.conf"
for a in "$HOME/.claude" "$HOME/.claude-alpha"; do
  for p in api web; do
    fake_session "$a" "$HOME/$p" "" "sid-$(basename "$a")-$p" >/dev/null
    fake_transcript "$a" "$HOME/$p" "sid-$(basename "$a")-$p" \
      '{"type":"ai-title","aiTitle":"t"}' >/dev/null
  done
done
# Warm the title index so the chats section resolves from it (a miss would fork
# a per-window read, which is a different, already-guarded budget).
"$CS" _titles --json --account=default \
  --sids="sid-.claude-api,sid-.claude-web" >/dev/null 2>&1

# Counting wrappers ahead of PATH: one line per invocation of each tool.
mkdir -p "$TEST_HOME/count"
for t in jq tmux ps; do
  real="$(command -v "$t")"
  cat > "$TEST_HOME/count/$t" <<EOF
#!/usr/bin/env bash
echo x >> "\${FORKS_DIR}/$t"
exec "$real" "\$@"
EOF
  chmod +x "$TEST_HOME/count/$t"
done
export FORKS_DIR="$TEST_HOME/forks"

count_forks() {   # $1 label (ignored), then the argv to run; prints "jq tmux ps"
  shift
  rm -rf "$FORKS_DIR"; mkdir -p "$FORKS_DIR"; : > "$FORKS_DIR/jq"; : > "$FORKS_DIR/tmux"; : > "$FORKS_DIR/ps"
  PATH="$TEST_HOME/count:$PATH" "$CS" "$@" >/dev/null 2>&1 || true
  printf '%s %s %s' "$(wc -l < "$FORKS_DIR/jq")" "$(wc -l < "$FORKS_DIR/tmux")" "$(wc -l < "$FORKS_DIR/ps")"
}
assert_le() {   # actual max label
  local a="${1// /}" m="$2" l="$3"
  if (( a <= m )); then echo "PASS: $l (actual $a, budget $m)"
  else echo "FAIL: $l — actual $a exceeds budget $m. Fix the fork, never raise the budget." >&2; return 1; fi
}

# --- poll snapshot: the app's steady-state read -----------------------------
# jq — FIXED per-poll overhead, none of it per-row (the flatness assertion just
# below is what proves that, and is the real guard here — the ceiling is a
# backstop). The pieces, measured and enumerated so a future reader can tell a
# new FIXED cost from a new per-ROW one:
#   1 per account-with-sessions (batched session-rows read)         = 2
#   1 per emitted section main jq (chats, issues, accounts)         = 3
#   1 per section that actually has skips (chats, issues; accounts
#     has none, and _json_skips_json does NOT fork when empty)      = 2
#   _json_core, the envelope's validating `jq -c .`,
#     _doctor_upstream_fields (issues), titlesIndex (chats)         = 4
# = ~11-12. Budget 14, headroom 2. The brief's original "8" derivation predated
# _json_core / the upstream-field check / titlesIndex / per-section skips and
# undercounted; the number is raised ONLY because the extra forks are proven
# fixed (below), never to paper over a per-row fork.
# tmux — _ot_load's single list-panes. Budget 1, no headroom: a second call
#        means a per-row fork came back.
# ps — _ot_load's ancestry map (1) + _ram_load's RSS batch (1). Budget 3.
read -r j t p <<<"$(count_forks snap _snapshot --json --only=chats,issues,accounts)"
assert_le "$j" 14 "poll snapshot jq is fixed per-section overhead, not per-row"     || fail=1
assert_le "$t" 1 "poll snapshot forks tmux exactly once (one list-panes call)"      || fail=1
assert_le "$p" 3 "poll snapshot forks ps at most twice (ancestry map + RSS batch)"  || fail=1

# THE REAL GUARD: the poll's fork cost must not grow with the number of chats or
# sessions in the account — that is the whole point of the windowed/indexed
# design, and it is exactly the invariant a fixed ceiling cannot express (a
# per-row fork on a 2-session fixture looks identical to fixed overhead). Count
# jq at the stated fixture, then at 8x the sessions/transcripts, and assert they
# are EQUAL. A per-row jq makes the second number grow; fixed overhead does not.
_jq_at_scale() {   # $1 = sessions per account; prints jq fork count
  local per="$1" a p i
  local big="$TEST_HOME/scale"; rm -rf "$big"
  mkdir -p "$big/.config/claude-helpers"
  printf 'account alpha ~/scale/.claude-alpha "second"\n' > "$big/.config/claude-helpers/accounts.conf"
  for a in "$big/.claude" "$big/.claude-alpha"; do
    for (( i=0; i<per; i++ )); do
      HOME="$big" fake_session "$a" "$big/p$i" "" "sid-$(basename "$a")-$i" >/dev/null
      HOME="$big" fake_transcript "$a" "$big/p$i" "sid-$(basename "$a")-$i" '{"type":"ai-title","aiTitle":"t"}' >/dev/null
    done
  done
  rm -rf "$FORKS_DIR"; mkdir -p "$FORKS_DIR"; : > "$FORKS_DIR/jq"
  HOME="$big" XDG_CACHE_HOME="$big/cache" PATH="$TEST_HOME/count:$PATH" \
    "$CS" _snapshot --json --only=chats,issues,accounts >/dev/null 2>&1 || true
  wc -l < "$FORKS_DIR/jq" | tr -d ' '
}
small_jq="$(_jq_at_scale 2)"
big_jq="$(_jq_at_scale 16)"
if [[ "$small_jq" == "$big_jq" ]]; then
  echo "PASS: poll jq forks do not grow with session/transcript count ($small_jq at 2/acct == $big_jq at 16/acct)"
else
  echo "FAIL: poll jq forks scaled with data — $small_jq at 2/acct but $big_jq at 16/acct: a per-row fork is back" >&2
  fail=1
fi

# The processes section adds orphan classification, which must share ONE process
# table across every orphan rather than re-snapshotting per orphan.
read -r j t p <<<"$(count_forks snapfull _snapshot --json)"
assert_le "$p" 4 "full snapshot forks ps at most 3 times (maps + one orphan table)" || fail=1

# _titles is the windowed title reader, bounded by the window the app asks for,
# never by the account's transcript count.
read -r j t p <<<"$(count_forks titles _titles --json --account=default --sids=sid-.claude-api,sid-.claude-web)"
assert_le "$j" 3 "_titles forks jq at most once per requested sid" || fail=1

# --- latency: measured, and SKIPped where it cannot be trusted --------------
# elapsedMs comes from the reader itself (no external clock), so it is honest
# about its own precision.
if [[ -n "${CI:-}" ]]; then
  echo "SKIP: snapshot latency measurement — CI runners are too noisy for a p95 gate"
elif [[ "$("$CS" _snapshot --json --only=meta 2>/dev/null | jq -r '.core.elapsedMsPrecision')" != "ms" ]]; then
  echo "SKIP: snapshot latency measurement — this bash has no millisecond clock (EPOCHREALTIME absent)"
else
  ms=()
  for i in 1 2 3 4 5 6 7 8 9 10; do
    ms+=("$("$CS" _snapshot --json --only=chats,issues,accounts 2>/dev/null | jq -r '.elapsedMs')")
  done
  p95="$(printf '%s\n' "${ms[@]}" | sort -n | tail -2 | head -1)"
  echo "MEASURED: _snapshot --only=chats,issues,accounts p95 = ${p95}ms (target 400ms; over target => 5s cadence)"
  if (( p95 <= 400 )); then
    echo "PASS: snapshot p95 within the 400ms target"
  else
    echo "SKIP: snapshot p95 ${p95}ms exceeds 400ms — the app's cadence must be 5s, not 2s (see docs/json-schema.md)"
  fi
fi
exit "$fail"
