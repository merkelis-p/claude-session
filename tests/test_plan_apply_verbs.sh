#!/usr/bin/env bash
# The plan/apply/ack protocol (lib/plan.sh, Task 9), extended to every OTHER
# mutating verb: kill, doctor --reap, transfer undo/redo/prune, accounts rm,
# schedule rm. Same rule everywhere — --dry-run always answers with a plan,
# --yes never implies --force, and the safety wording comes from bash, not
# from a special case per verb.
set -uo pipefail
. "$(dirname "$0")/harness.sh"
setup_fake_home
trap teardown_fake_home EXIT
fail=0

mkdir -p "$HOME/.config/claude-helpers"
cat > "$HOME/.config/claude-helpers/accounts.conf" <<EOF
account alpha $HOME/.claude-alpha 'Second account'
EOF
mkdir -p "$HOME/.claude-alpha"
export LEDGER_FILE="$HOME/.config/claude-helpers/transfer-log.jsonl"
PROJ="$HOME/api"
ENC_PROJ="$(sed 's#[/._]#-#g' <<<"$PROJ")"

# ---- reap: the confirmation counts what will be SKIPPED and why, per pid --
# Fixture: one genuinely idle orphan (reapable) and two busy ones (never
# reapable, regardless of confirmation level) — one of the busy pids is
# 901163, checked below by exact pid so this is not a vacuous "some pid".
REAP_FIXTURE="$TEST_HOME/fake_ps_reap.txt"
cat > "$REAP_FIXTURE" <<'EOF'
100004 1 599521 0.0 npmrundev npm run dev
100001 1 18268 26.8 node node /home/x/backend/node_modules/.bin/medusa plugin:build
901163 1 18268 26.8 node node /home/x/backend/node_modules/.bin/medusa plugin:build
EOF
export ORPHAN_PS_SRC="$REAP_FIXTURE"

p="$("$CS" doctor --reap --json --dry-run 2>/dev/null </dev/null)"
assert_eq "$(jq -r '.mutation' <<<"$p")" "doctor.reap" "reap plan names the mutation" || fail=1
assert_contains "$(jq -r '.warnings|join(" ")' <<<"$p")" "2 skipped" "the plan states how many are skipped" || fail=1
assert_contains "$(jq -r '.warnings|join(" ")' <<<"$p")" "active work in subtree" "and why" || fail=1
jq -e '[.effects[]|select(.kind=="kill")]|length==1' >/dev/null <<<"$p" \
  && echo "PASS: only the reapable pid appears as an effect" || fail=1
assert_not_contains "$(jq -r '.argv|join(" ")' <<<"$p")" "--force" "reap's plan does not smuggle in --force" || fail=1
# There is no "reap all": the plan can never list an active orphan as an effect.
jq -e '[.effects[]|select(.path=="901163")]|length==0' >/dev/null <<<"$p" \
  && echo "PASS: an active orphan is never an effect, at any confirmation level" || fail=1
# ...and never even with --force explicitly passed: --force is honored only
# when the caller actually typed it, but it must never smuggle a "reap all"
# into the disclosed effects either.
pf="$("$CS" doctor --reap --force --json --dry-run 2>/dev/null </dev/null)"
jq -e '[.effects[]|select(.path=="901163")]|length==0' >/dev/null <<<"$pf" \
  && echo "PASS: --force does not turn the active orphan into an effect either" || fail=1
assert_contains "$(jq -r '.argv|join(" ")' <<<"$pf")" "--force" \
  "--force IS reflected in argv when the caller actually passed it" || fail=1

# ---- undo: divergence arrives as a CONFIRMATION with both mtimes, never a
# blanket --force. Seeded directly (like test_json.sh does) so the ledger's
# `ts` is fixed far in the past — the destination transcript created just now
# is naturally "newer than the transfer" without any mtime surgery.
printf '%s\n' '{"id":"7c78ba","ts":1753567500,"sid":"sid-u","title":"Undo Me","from":"default","to":"alpha","verb":"move","undoOf":null,"redoOf":null}' \
  > "$LEDGER_FILE"
fake_transcript "$HOME/.claude-alpha" "$PROJ" "sid-u" '{"type":"ai-title","aiTitle":"Undo Me"}' >/dev/null

pu="$("$CS" transfer undo 7c78ba --json --dry-run 2>/dev/null </dev/null)"
assert_eq "$(jq -r '.mutation' <<<"$pu")" "transfer.undo" "undo plan names the mutation" || fail=1
assert_eq "$(jq -r '.confirmations[0].kind' <<<"$pu")" "divergence" "divergence is a confirmation" || fail=1
assert_contains "$(jq -r '.confirmations[0].text' <<<"$pu")" "discards that newer copy" "the wording states the cost" || fail=1
jq -e '.confirmations[0].text|test("[0-9]{4}-[0-9]{2}-[0-9]{2}")' >/dev/null <<<"$pu" \
  && echo "PASS: the divergence confirmation shows both mtimes" || fail=1
# both timestamps, not just one: the transfer's own (fixed, 2025) and the
# destination's (today) must both appear as YYYY-MM-DD dates.
n_dates="$(jq -r '.confirmations[0].text' <<<"$pu" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | sort -u | wc -l | tr -d ' ')"
assert_eq "$n_dates" "2" "the two disclosed dates actually differ (transfer date vs destination date)" || fail=1
# The real apply (unacked --yes exits 3; the matching ack applies) is
# deferred to the very end of this file, on purpose: it actually moves
# sid-u's destination copy back to the source, and the enumeration loop
# below still needs ledger entry 7c78ba's destination copy (under alpha) to
# exist so `transfer undo 7c78ba --dry-run` keeps answering with a plan
# instead of "already gone?".

# ---- kill / accounts rm / schedule rm: each discloses what is lost --------
assert_contains "$("$CS" kill api-claude --json --dry-run 2>/dev/null | jq -r '.willLose|join(" ")')" "unsaved" \
  "kill discloses the runtime loss" || fail=1
assert_contains "$("$CS" kill api-claude --json --dry-run 2>/dev/null | jq -r '.mutation')" "kill.session" \
  "kill plan names the mutation" || fail=1

assert_contains "$("$CS" accounts rm alpha --json --dry-run 2>/dev/null | jq -r '.willLose|join(" ")')" "registry entry" \
  "accounts rm discloses the registry loss" || fail=1
awarn="$("$CS" accounts rm alpha --json --dry-run 2>/dev/null | jq -r '.warnings|join(" ")')"
assert_contains "$awarn" "rm -rf" \
  "accounts rm still refuses to delete the credential dir and says so" || fail=1
assert_contains "$awarn" "$HOME/.claude-alpha" "the warning names the actual credential dir it does not touch" || fail=1
# the credential dir really is untouched by a --dry-run plan
test -d "$HOME/.claude-alpha"; assert_eq "$?" "0" "accounts rm --dry-run left the credential dir in place" || fail=1
# ...and the registry entry is still there too — --dry-run mutated nothing
assert_contains "$(cat "$HOME/.config/claude-helpers/accounts.conf")" "account alpha" \
  "accounts rm --dry-run left the registry entry in place" || fail=1

assert_contains "$("$CS" schedule rm 111111 --json --dry-run 2>/dev/null | jq -r '.effects|map(.path)|join(" ")')" ".timer" \
  "schedule rm lists both unit files as effects" || fail=1
assert_contains "$("$CS" schedule rm 111111 --json --dry-run 2>/dev/null | jq -r '.warnings|join(" ")')" "journal" \
  "schedule rm warns the journal history goes with it" || fail=1

# ---- every mutating verb answers --dry-run, enumerated so a new verb cannot
# skip the protocol.
fake_transcript "$HOME/.claude" "$PROJ" "sid-x" '{"type":"ai-title","aiTitle":"Chat X"}' >/dev/null
for v in "transfer sid-x --to=alpha" "transfer undo 7c78ba" "transfer redo 7c78ba" \
         "transfer prune" "kill api-claude" "doctor --reap" "accounts rm alpha" "schedule rm 111111"; do
  # shellcheck disable=SC2086
  out="$("$CS" $v --json --dry-run 2>/dev/null </dev/null)"
  jq -e '.mutation and (.argv|type=="array") and (.willLose|type=="array")' >/dev/null <<<"$out" \
    && echo "PASS: '$v --json --dry-run' emits a plan" \
    || { echo "FAIL: '$v --json --dry-run' emitted no plan" >&2; fail=1; }
done

# ---- undo, applied for real: unacked --yes exits 3 (re-attaching the FRESH
# plan, exactly like transfer.move/copy), and the matching ack applies. Held
# until here — everything above still needed entry 7c78ba's destination copy
# to exist under alpha.
"$CS" transfer undo 7c78ba --yes --json </dev/null >/dev/null 2>&1
assert_eq "$?" "3" "undo: --yes without the ack exits 3" || fail=1
pu2="$("$CS" transfer undo 7c78ba --json --dry-run 2>/dev/null </dev/null)"
d="$(jq -r '.confirmations[0].digest' <<<"$pu2")"
"$CS" transfer undo 7c78ba --yes --ack="$d" </dev/null >/dev/null 2>&1
assert_eq "$?" "0" "undo: --yes with the matching ack applies" || fail=1
test -f "$HOME/.claude/projects/$ENC_PROJ/sid-u.jsonl"; assert_eq "$?" "0" "undo actually landed the chat back at the source" || fail=1

# ---- --yes never implies --force: the credential dir still isn't deleted,
# and the registry entry IS actually removed this time (no confirmation was
# ever registered for accounts.rm, so --yes alone is enough — same rule as
# reap/prune above: --yes stands in for "a human agreed", nothing more).
"$CS" accounts rm alpha --yes --json </dev/null >/dev/null 2>&1
assert_eq "$?" "0" "accounts rm --yes (no pending confirmation) applies" || fail=1
test -d "$HOME/.claude-alpha"; assert_eq "$?" "0" "accounts rm --yes still never deletes the credential dir" || fail=1
assert_not_contains "$(cat "$HOME/.config/claude-helpers/accounts.conf")" "account alpha " \
  "accounts rm --yes did remove the registry entry" || fail=1

exit "$fail"
