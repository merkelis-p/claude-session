#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$0")/harness.sh"
fail=0
setup_fake_home
trap teardown_fake_home EXIT
install_fake_claude
mkdir -p "$TEST_HOME/.claude-alpha"
printf 'account alpha ~/.claude-alpha "second account"\n' >> "$TEST_HOME/.config/claude-helpers/accounts.conf"
: > "$TEST_HOME/.claude-alpha/.credentials.json"
# "beta" is registered but its config dir is never created — the state a box
# is in right after `accounts add` is interrupted, or after the dir is deleted
# by hand. A missing directory must still produce a row, with credentials
# reported as false (a verified fact), never true and never simply dropped —
# rendering it as a working account, or silently omitting it, are the two
# failure modes this test guards against.
printf 'account beta /this/dir/does/not/exist "third account"\n' >> "$TEST_HOME/.config/claude-helpers/accounts.conf"

env_json() { FORCE_COLOR=1 "$CS" "$@" 2>/dev/null; }

# --- the envelope preamble -------------------------------------------------
doc="$(env_json _snapshot --json --only=accounts)"
jq -e . >/dev/null 2>&1 <<<"$doc" && echo "PASS: _snapshot emits valid JSON" \
  || { echo "FAIL: _snapshot did not emit valid JSON: $doc" >&2; fail=1; }
assert_eq "$(jq -r '.schemaVersion' <<<"$doc")" "1" "schemaVersion is 1" || fail=1
assert_eq "$(jq -r '.core.version' <<<"$doc")" "0.2.0" "core.version tracks VERSION" || fail=1
assert_eq "$(jq -r '.core.platform' <<<"$doc")" "$(uname -s | tr 'A-Z' 'a-z')" "core.platform" || fail=1
jq -e '.generatedAt|type=="number"' >/dev/null <<<"$doc" && echo "PASS: generatedAt is a number" \
  || { echo "FAIL: generatedAt not numeric" >&2; fail=1; }
jq -e '.elapsedMs|type=="number"' >/dev/null <<<"$doc" && echo "PASS: elapsedMs is a number" \
  || { echo "FAIL: elapsedMs not numeric" >&2; fail=1; }
# A clock we cannot read to millisecond resolution must SAY so rather than
# reporting a 0 that reads like "instant".
jq -e '.core.elapsedMsPrecision|test("^(ms|s)$")' >/dev/null <<<"$doc" \
  && echo "PASS: core.elapsedMsPrecision is declared" \
  || { echo "FAIL: elapsedMsPrecision missing" >&2; fail=1; }

# --- no ANSI, ever, even with FORCE_COLOR=1 -------------------------------
[[ "$doc" == *$'\033'* ]] && { echo "FAIL: envelope contains ANSI under FORCE_COLOR=1" >&2; fail=1; } \
  || echo "PASS: envelope contains no ANSI under FORCE_COLOR=1"

# --- --only is honored and validated -------------------------------------
assert_eq "$(jq -r '.sections|keys|join(",")' <<<"$doc")" "accounts" "--only=accounts emits only that section" || fail=1
"$CS" _snapshot --json --only=nope >/dev/null 2>&1; assert_eq "$?" "2" "--only rejects an unknown section" || fail=1
assert_eq "$(env_json _snapshot --json --only=meta | jq -r '.sections|length')" "0" \
  "--only=meta emits the preamble and no sections" || fail=1

# --- section contract ----------------------------------------------------
sec="$(jq -c '.sections.accounts' <<<"$doc")"
assert_eq "$(jq -r '.status' <<<"$sec")" "ok" "accounts.status is ok" || fail=1
jq -e '.checksRun|type=="array" and length>0' >/dev/null <<<"$sec" \
  && echo "PASS: accounts.checksRun is a non-empty array" \
  || { echo "FAIL: accounts.checksRun missing" >&2; fail=1; }
jq -e '.checksSkipped|type=="array"' >/dev/null <<<"$sec" && echo "PASS: accounts.checksSkipped present" \
  || { echo "FAIL: accounts.checksSkipped missing" >&2; fail=1; }
# Every skip carries a REASON. A skip with no reason is indistinguishable from
# a pass once it reaches a summary line, which is the whole failure mode here.
jq -e 'all(.checksSkipped[]; has("name") and (.reason|length>0))' >/dev/null <<<"$sec" \
  && echo "PASS: every checksSkipped entry has a name and a reason" \
  || { echo "FAIL: a checksSkipped entry lacks a reason" >&2; fail=1; }
jq -e '.errors|type=="array"' >/dev/null <<<"$sec" && echo "PASS: accounts.errors present" \
  || { echo "FAIL: accounts.errors missing" >&2; fail=1; }
# The quota anchor is not implemented yet, so it must appear as an explicit SKIP
# rather than be silently absent. This is the "explicit unknown" case at the
# section level: an unimplemented check reads as a named skip with a reason,
# never as a value that just isn't there.
assert_contains "$(jq -r '.checksSkipped[].name' <<<"$sec")" "quota-anchor" \
  "the unimplemented quota anchor is reported as a skipped check" || fail=1

# --- items ----------------------------------------------------------------
assert_eq "$(jq -r '.items|length' <<<"$sec")" "3" "accounts items = default + alpha + beta" || fail=1
assert_eq "$(jq -r '.items[0].name' <<<"$sec")" "default" "default account is first (matches _all_accounts)" || fail=1
assert_eq "$(jq -r '.items[1].name' <<<"$sec")" "alpha" "registered account follows" || fail=1
assert_eq "$(jq -r '.items[1].dir' <<<"$sec")" "$TEST_HOME/.claude-alpha" "account dir is absolute and tilde-expanded" || fail=1
assert_eq "$(jq -r '.items[1].credentials' <<<"$sec")" "true" "credentials reflects .credentials.json" || fail=1
assert_eq "$(jq -r '.items[0].credentials' <<<"$sec")" "false" "missing credentials is false, not absent" || fail=1
assert_eq "$(jq -r '.items[1].description' <<<"$sec")" "second account" "description comes from accounts.conf" || fail=1

# --- present / false / absent are three distinguishable states, not two ---
# The key itself must exist (never dropped), and its value must be the exact
# boolean false (never "", never "unknown", never the string "false").
jq -e '.items[0]|has("credentials")' >/dev/null <<<"$sec" \
  && echo "PASS: default account's credentials key is present (not absent)" \
  || { echo "FAIL: default account's credentials key is missing" >&2; fail=1; }
jq -e '.items[0].credentials == false' >/dev/null <<<"$sec" \
  && echo "PASS: default account's credentials is the JSON boolean false (not a string, not empty)" \
  || { echo "FAIL: default account's credentials is not the boolean false" >&2; fail=1; }

# --- a missing account directory: reported honestly, never as "working" ---
assert_eq "$(jq -r '.items[2].name' <<<"$sec")" "beta" "the account with a missing dir still appears (name)" || fail=1
assert_eq "$(jq -r '.items[2].dir' <<<"$sec")" "/this/dir/does/not/exist" "its configured (nonexistent) dir is reported, not hidden" || fail=1
assert_eq "$(jq -r '.items[2].credentials' <<<"$sec")" "false" \
  "a missing account directory never renders credentials as true" || fail=1
jq -e '.items[2]|has("credentials")' >/dev/null <<<"$sec" \
  && echo "PASS: the missing-dir account's credentials key is present, not dropped" \
  || { echo "FAIL: the missing-dir account was silently dropped from items" >&2; fail=1; }

# --- a description with an embedded tab/newline must not corrupt row
# alignment for ITSELF or for any account registered after it -------------
# accounts add's `printf %q` round-trips an ANSI-C-quoted control character
# straight back through the source step, so a hand-edited or once-escaped
# description CAN carry a literal tab or newline. A tab in the LAST field
# only truncates that one value (cosmetic) — the real hazard the codebase has
# already been bitten by twice (_SESSION_JQ's own comment) is a NEWLINE: the
# TSV rows here are newline-separated, so an embedded newline turns one
# account into two "rows" as far as jq's line-based `inputs` is concerned,
# inflating the item count with a garbage entry and, in the general case,
# shifting every account registered afterward. gamma's own tab is included
# too so both hazards are covered in one fixture; delta (registered right
# after) is the canary that would show a downstream shift.
printf 'account gamma /some/gamma/dir "desc\twith\ttab\nand a newline"\n' >> "$TEST_HOME/.config/claude-helpers/accounts.conf"
printf 'account delta ~/.claude-delta "fourth account"\n' >> "$TEST_HOME/.config/claude-helpers/accounts.conf"
doc2="$(env_json _snapshot --json --only=accounts)"
jq -e . >/dev/null 2>&1 <<<"$doc2" && echo "PASS: a tab/newline-bearing description still yields valid JSON" \
  || { echo "FAIL: a tab/newline-bearing description broke the JSON: $doc2" >&2; fail=1; }
sec2="$(jq -c '.sections.accounts' <<<"$doc2")"
assert_eq "$(jq -r '.items|length' <<<"$sec2")" "5" \
  "row count is default+alpha+beta+gamma+delta — no spurious extra item from gamma's embedded newline" || fail=1
assert_eq "$(jq -r '.items[3].name' <<<"$sec2")" "gamma" "gamma's own name field is intact" || fail=1
assert_eq "$(jq -r '.items[3].dir' <<<"$sec2")" "/some/gamma/dir" "gamma's dir is intact after the tab/newline-bearing description" || fail=1
assert_eq "$(jq -r '.items[3].description' <<<"$sec2")" "desc with tab and a newline" \
  "gamma's description has tab/newline neutralized to spaces, not truncated or split" || fail=1
# The canary: delta, registered right after gamma, must land as its own
# clean row — not merged into gamma's, not shifted, not missing.
assert_eq "$(jq -r '.items[4].name' <<<"$sec2")" "delta" "delta (registered right after gamma) is not shifted or swallowed" || fail=1
assert_eq "$(jq -r '.items[4].dir' <<<"$sec2")" "$TEST_HOME/.claude-delta" "delta's own dir is intact" || fail=1
assert_eq "$(jq -r '.items[4].description' <<<"$sec2")" "fourth account" "delta's own description is intact" || fail=1

# --- the public per-verb form is the same document, verbatim -------------
# Compared against doc2 (captured after the gamma fixture above), not doc —
# accounts.conf has 4 entries on disk by this point in the script, and
# `accounts ls --json` always reads the current registry.
pub="$(env_json accounts ls --json)"
assert_eq "$(jq -cS . <<<"$pub")" "$(jq -cS '.sections.accounts' <<<"$doc2")" \
  "accounts ls --json is byte-identical to the envelope's accounts section" || fail=1

# --- --json never prompts -------------------------------------------------
out="$(env_json accounts ls --json < /dev/null)"; assert_eq "$?" "0" "accounts ls --json needs no stdin" || fail=1

# --- --json is gated per-subcommand, not just per-verb --------------------
# _JSON_READY_VERBS covers the verb "accounts" as a whole; only `ls` actually
# emits JSON. Without a subcommand-level check, `accounts add --json` would
# pass the top-level guard and then silently run its ordinary interactive
# path, discarding the --json request instead of erroring on it.
"$CS" accounts add somename --json >/dev/null 2>&1; assert_eq "$?" "2" \
  "accounts add --json is a hard error, not a silently-ignored flag" || fail=1
"$CS" accounts rm alpha --json >/dev/null 2>&1; assert_eq "$?" "2" \
  "accounts rm --json is a hard error, not a silently-ignored flag" || fail=1

# --- the bash<->Go schema-version cross-check ------------------------------
# One cheap grep over both files catches every skew. Until tui/ exists there is
# nothing to compare, and that reports SKIP — never PASS.
gosrc="$(cd "$(dirname "$CS")/.." && pwd)/tui/cmd/claude-session-tui/main.go"
if [[ -f "$gosrc" ]]; then
  gomax="$(grep -oE 'schemaMax[[:space:]]*=[[:space:]]*"?[0-9]+' "$gosrc" | grep -oE '[0-9]+$' | head -1)"
  assert_eq "$gomax" "$(grep -E '^JSON_SCHEMA_VERSION=' "$CS" | cut -d= -f2)" \
    "Go schemaMax equals bash JSON_SCHEMA_VERSION" || fail=1
else
  echo "SKIP: bash<->Go schema-version cross-check — tui/cmd/claude-session-tui/main.go does not exist yet"
fi

# --- ledger: each entry joined against the CURRENT state of both endpoints ---
mkdir -p "$TEST_HOME/.config/claude-helpers"
printf '%s\n' '{"id":"7c78ba","ts":1753567500,"sid":"sid-x","title":"A chat","from":"default","to":"alpha","verb":"move","undoOf":null,"redoOf":null}' \
  > "$TEST_HOME/.config/claude-helpers/transfer-log.jsonl"
fake_transcript "$TEST_HOME/.claude-alpha" "$TEST_HOME/api" "sid-x" '{"type":"ai-title","aiTitle":"A chat"}' >/dev/null
led="$(env_json _snapshot --json --only=ledger | jq -c '.sections.ledger')"
assert_eq "$(jq -r '.items|length' <<<"$led")" "1" "ledger emits the entry" || fail=1
e="$(jq -c '.items[0]' <<<"$led")"
assert_eq "$(jq -r '.id' <<<"$e")" "7c78ba" "ledger id" || fail=1
assert_eq "$(jq -r '.verb' <<<"$e")" "move" "ledger verb" || fail=1
assert_eq "$(jq -r '.destExists' <<<"$e")" "true" "destExists is joined from disk" || fail=1
assert_eq "$(jq -r '.sourceExists' <<<"$e")" "false" "sourceExists is joined from disk" || fail=1
jq -e '.undoable|type=="boolean"' >/dev/null <<<"$e" && echo "PASS: undoable is a boolean" \
  || { echo "FAIL: undoable missing" >&2; fail=1; }
jq -e 'has("diverged")' >/dev/null <<<"$e" && echo "PASS: diverged is reported per entry" \
  || { echo "FAIL: diverged missing" >&2; fail=1; }
assert_eq "$(jq -cS . <<<"$(env_json transfer log --json)")" "$(jq -cS . <<<"$led")" \
  "transfer log --json is the ledger section verbatim" || fail=1

# --- ledger: a missing ledger file is ok/empty with a named skip, not a pass
# and not an error — the file was never written yet on a fresh box. ----------
noledger="$(LEDGER_FILE="$TEST_HOME/.config/claude-helpers/no-such-ledger.jsonl" \
  env_json _snapshot --json --only=ledger | jq -c '.sections.ledger')"
assert_eq "$(jq -r '.status' <<<"$noledger")" "ok" "a missing ledger file is still ok" || fail=1
assert_eq "$(jq -r '.items|length' <<<"$noledger")" "0" "a missing ledger file yields no items" || fail=1
assert_contains "$(jq -r '.checksSkipped[].name' <<<"$noledger")" "endpoints" \
  "a missing ledger file skips the endpoints check by name, not silently" || fail=1

# --- ledger: --json for anything but `log` is a hard error, not a silently-
# ignored flag — the same subcommand-level guard accounts add/rm already has.
"$CS" transfer undo --json >/dev/null 2>&1; assert_eq "$?" "2" \
  "transfer undo --json is a hard error, not a silently-ignored flag" || fail=1

# --- schedules: unavailable is NOT empty-ok ---------------------------------
mkdir -p "$TEST_HOME/nosystemd"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TEST_HOME/nosystemd/systemctl"; chmod +x "$TEST_HOME/nosystemd/systemctl"
un="$(PATH="$TEST_HOME/nosystemd:$PATH" env_json _snapshot --json --only=schedules | jq -c '.sections.schedules')"
assert_eq "$(jq -r '.status' <<<"$un")" "unavailable" "no systemctl --user means unavailable" || fail=1
assert_contains "$(jq -r '.reason' <<<"$un")" "systemctl" "the reason names what is missing" || fail=1
assert_eq "$(jq -r '.items|length' <<<"$un")" "0" "unavailable carries no items" || fail=1
install_fake_systemctl
ok="$(env_json _snapshot --json --only=schedules | jq -c '.sections.schedules')"
assert_eq "$(jq -r '.status' <<<"$ok")" "ok" "a working systemctl means ok" || fail=1
assert_eq "$(jq -r '.items|length' <<<"$ok")" "0" "ok with no schedules is an empty item list" || fail=1
[[ "$(jq -cS . <<<"$un")" != "$(jq -cS . <<<"$ok")" ]] \
  && echo "PASS: unavailable and empty-ok are different documents" \
  || { echo "FAIL: unavailable renders identically to empty-ok" >&2; fail=1; }
assert_eq "$(jq -r 'has("reason")' <<<"$ok")" "false" "empty-ok carries no reason field" || fail=1

# --- schedules: --json for anything but `ls` is a hard error ---------------
"$CS" schedule add "hi" --json >/dev/null 2>&1; assert_eq "$?" "2" \
  "schedule add --json is a hard error, not a silently-ignored flag" || fail=1

# --- schedules: `schedule ls --json` is the schedules section verbatim ----
pubsched="$(env_json schedule ls --json)"
assert_eq "$(jq -cS . <<<"$pubsched")" "$(jq -cS . <<<"$ok")" \
  "schedule ls --json is byte-identical to the envelope's schedules section" || fail=1

# --- the checked-in fixture corpus stays in sync with the emitters, and is
# scrubbed of anything that could identify the real machine it was captured
# on. The PII guard is deliberately GENERIC — no literal username, company,
# or account name from this maintainer's own box may ever appear in a public
# repo's committed test, or the guard itself becomes the leak it exists to
# prevent. It allows exactly one placeholder home, /home/u, and rejects every
# other /home/<name> path, plus any string shaped like a real session UUID
# (fixtures use plainly-synthetic ids like sid-full-1, never a genuine
# 8-4-4-4-12 hex UUID, so this pattern can reject the SHAPE outright instead
# of trying to guess "real" from "fake").
for f in full empty unavailable partial; do
  p="$(cd "$(dirname "$CS")/.." && pwd)/tests/fixtures/envelope/$f.json"
  if [[ -f "$p" ]]; then
    jq -e '.schemaVersion==1 and (.sections|type=="object")' >/dev/null < "$p" \
      && echo "PASS: fixture $f.json matches the envelope contract" \
      || { echo "FAIL: fixture $f.json does not match the envelope contract" >&2; fail=1; }
    bad_home="$(grep -oE '/home/[a-zA-Z0-9_-]+' "$p" | grep -vx '/home/u' || true)"
    bad_uuid="$(grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' "$p" || true)"
    if [[ -n "$bad_home" || -n "$bad_uuid" ]]; then
      echo "FAIL: fixture $f.json contains a personal path or a real-looking session id" >&2
      [[ -n "$bad_home" ]] && echo "  home path(s): $bad_home" >&2
      [[ -n "$bad_uuid" ]] && echo "  uuid-shaped id(s): $bad_uuid" >&2
      fail=1
    else
      echo "PASS: fixture $f.json is free of personal identifiers"
    fi
  else
    echo "FAIL: missing fixture tests/fixtures/envelope/$f.json" >&2; fail=1
  fi
done

exit "$fail"
