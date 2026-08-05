#!/usr/bin/env bash
# The plan/apply/ack protocol, wired into `transfer`. Covers the split between
# --force (override ONE named guard), --yes (the human answered the [y/N]
# prompt, nothing more), and --ack=<digest> (the human confirmed THIS
# disclosed condition) — see lib/plan.sh's header for the full rationale.
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

# fixture: chat sid-x under `default`, second account `alpha`
fake_transcript "$HOME/.claude" "$PROJ" "sid-x" '{"type":"ai-title","aiTitle":"Chat X"}' >/dev/null

plan="$("$CS" transfer sid-x --to=alpha --move --json --dry-run 2>/dev/null </dev/null)"
assert_eq "$(jq -r '.mutation' <<<"$plan")" "transfer.move" "the plan names the mutation" || fail=1
assert_eq "$(jq -r '.schemaVersion' <<<"$plan")" "1" "the plan carries the schema version" || fail=1
# argv is an ARRAY, long flags only, --flag=value form, target resolved explicitly
jq -e '.argv|type=="array"' >/dev/null <<<"$plan" && echo "PASS: argv is an array" || fail=1
assert_contains "$(jq -r '.argv|join(" ")' <<<"$plan")" "--to=alpha" "argv uses --flag=value" || fail=1
assert_contains "$(jq -r '.argv|join(" ")' <<<"$plan")" "--from=default" "argv passes the resolved source" || fail=1
assert_not_contains "$(jq -r '.argv|join(" ")' <<<"$plan")" "--force" "a plain plan never carries --force" || fail=1
# a move discloses what is lost; a copy loses nothing
assert_contains "$(jq -r '.willLose|join(" ")' <<<"$plan")" "source copy" "a move discloses the lost source" || fail=1
assert_eq "$("$CS" transfer sid-x --to=alpha --json --dry-run </dev/null 2>/dev/null | jq -r '.willLose|length')" "0" \
  "a copy loses nothing" || fail=1
# --dry-run mutates nothing
assert_eq "$(ls "$HOME/.claude-alpha/projects" 2>/dev/null | wc -l | tr -d ' ')" "0" "--dry-run wrote nothing" || fail=1

# refusal: the never-clobber backstop is a first-class RESULT, not a crash
fake_transcript "$HOME/.claude-alpha" "$PROJ" "sid-x" '{"type":"ai-title","aiTitle":"dest"}' >/dev/null
p2="$("$CS" transfer sid-x --to=alpha --json --dry-run 2>/dev/null </dev/null)"
assert_eq "$(jq -r '.refusals|length' <<<"$p2")" "1" "an existing destination is a refusal" || fail=1
assert_contains "$(jq -r '.refusals[0].text' <<<"$p2")" "already exists" "the refusal says why" || fail=1
assert_contains "$(jq -r '.refusals[0].override' <<<"$p2")" "--force" "the refusal names the override that exists" || fail=1
# --yes DOES NOT imply --force: the backstop still holds
"$CS" transfer sid-x --to=alpha --yes </dev/null >/dev/null 2>&1
assert_eq "$?" "2" "--yes alone still refuses to clobber the destination" || fail=1
# the destination transcript was not overwritten by the refused attempt above
assert_contains "$(cat "$HOME/.claude-alpha/projects"/*/sid-x.jsonl 2>/dev/null)" "dest" \
  "the destination file was not overwritten" || fail=1

# confirmation + ack: a round-trip is disclosed, digested, and unacked --yes is refused
# (ledger seeded with alpha -> default, so default -> alpha is a round trip)
fake_transcript "$HOME/.claude-alpha" "$PROJ" "sid-y" '{"type":"ai-title","aiTitle":"Chat Y"}' >/dev/null
"$CS" transfer sid-y --to=default --from=alpha --move --plain </dev/null >/dev/null 2>&1
fake_transcript "$HOME/.claude-alpha" "$PROJ" "sid-z" '{"type":"ai-title","aiTitle":"Chat Z"}' >/dev/null
"$CS" transfer sid-z --to=default --from=alpha --move --plain </dev/null >/dev/null 2>&1

p3="$("$CS" transfer sid-y --to=alpha --json --dry-run 2>/dev/null </dev/null)"
d="$(jq -r '.confirmations[0].digest' <<<"$p3")"
[[ "$d" =~ ^[0-9a-f]{6}$ ]] && echo "PASS: the confirmation digest is 6 hex chars" || fail=1
assert_eq "$(jq -r '.confirmations[0].kind' <<<"$p3")" "round-trip" "the confirmation kind is named" || fail=1
"$CS" transfer sid-y --to=alpha --yes --json </dev/null >/dev/null 2>&1
assert_eq "$?" "3" "--yes without the ack exits 3" || fail=1
out="$("$CS" transfer sid-y --to=alpha --yes --json 2>/dev/null </dev/null)"
assert_eq "$(jq -r '.confirmations[0].digest' <<<"$out")" "$d" "exit 3 re-attaches the FRESH plan" || fail=1
"$CS" transfer sid-y --to=alpha --yes --ack="$d" </dev/null >/dev/null 2>&1
assert_eq "$?" "0" "--yes with the matching ack applies" || fail=1
# a stale digest is not an ack
"$CS" transfer sid-z --to=alpha --yes --ack=000000 </dev/null >/dev/null 2>&1
assert_eq "$?" "3" "a wrong digest does not satisfy a confirmation" || fail=1

# apply re-runs the guards: the plan is advisory, the guards are authoritative.
# Delete the source between plan and apply — apply must fail, not proceed, even
# though --yes --json is exactly the "trust the disclosed plan" combination.
fake_transcript "$HOME/.claude" "$PROJ" "sid-w" '{"type":"ai-title","aiTitle":"Chat W"}' >/dev/null
plan_w="$("$CS" transfer sid-w --to=alpha --json --dry-run 2>/dev/null </dev/null)"
assert_eq "$(jq -r '.mutation' <<<"$plan_w")" "transfer.copy" "sid-w plan builds cleanly before the source vanishes" || fail=1
rm -f "$HOME/.claude/projects"/*/sid-w.jsonl
out_w="$("$CS" transfer sid-w --to=alpha --yes --json </dev/null 2>&1)"; rc_w=$?
assert_eq "$rc_w" "1" "apply fails when the source vanished between plan and apply" || fail=1
assert_contains "$out_w" "no transcript" "apply's failure names the real reason, not a stale plan" || fail=1
assert_eq "$(find "$HOME/.claude-alpha/projects" -name 'sid-w.jsonl' 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "no partial write landed at the destination for sid-w" || fail=1

exit "$fail"
