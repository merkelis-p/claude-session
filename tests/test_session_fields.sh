#!/usr/bin/env bash
# The session-field emitter's one invariant: NO FIELD IS EVER EMPTY.
#
# Tab is IFS whitespace, so bash collapses a run of tabs into a single
# delimiter. One empty field therefore shifts every later field left, and the
# damage is silent and plausible-looking: the sessionId column showed a
# timestamp, liveness flipped, and titles were read from the wrong chat.
#
# This bit twice in one sitting. First on a MISSING field (`// "-"` fixed it),
# then on a field written as an EMPTY STRING — because jq's `//` substitutes for
# null and false but passes "" straight through. Hence the `def d` guard, and
# hence this test: it asserts the invariant directly instead of trusting that
# each new field remembers to defend itself.
set -uo pipefail
. "$(dirname "$0")/harness.sh"
setup_fake_home; trap teardown_fake_home EXIT
fail=0
install_fake_tmux
mkdir -p "$HOME/.config/claude-helpers"
: > "$HOME/.config/claude-helpers/accounts.conf"

acct="$HOME/.claude"
mkdir -p "$acct/sessions"

# A live pid so the row is rendered as alive rather than filtered as stale.
sleep 300 >/dev/null 2>&1 & live_pid=$!
echo "$live_pid" >> "$TEST_HOME/.fake_pids"

SID="eeeeeeee-1111-2222-3333-666666666666"

# The hostile shapes, all of which occur in real files: a field written as an
# empty string, a field absent entirely, and a null.
cat > "$acct/sessions/$live_pid.json" <<EOF
{
  "pid": $live_pid,
  "cwd": "$HOME/proj",
  "entrypoint": "cli",
  "status": "idle",
  "sessionId": "$SID",
  "bridgeSessionId": "",
  "waitingFor": null,
  "statusUpdatedAt": 1785802242563
}
EOF
mkdir -p "$HOME/proj"

out="$("$CS" ls 2>&1)"

# The sessionId must appear in the id column — this is what broke: a shifted row
# put statusUpdatedAt here instead, and it looked like a plausible id.
# NOTE: the `ls` id column shows bridgeSessionId, not sessionId, so an empty
# bridge legitimately shows nothing there. The sessionId is checked at the
# emitter level below instead of guessed at from the rendering.
assert_not_contains "$out" "1785802242563" \
  "the updatedAt timestamp never leaks into a text column" || fail=1

# Liveness must not flip. A shifted row moved the alive flag out of position and
# the session rendered as dead while its process was running.
assert_contains "$out" "pid $live_pid" "the live session is listed" || fail=1
assert_not_contains "$out" "stale" "a live session with sparse fields is not called stale" || fail=1

# The cwd column must hold the cwd and nothing appended — a shifted row rendered
# "/home/u/proj  []" because the next field landed inside it.
assert_contains "$out" "$(short_home "$HOME/proj")" "cwd renders as itself" || fail=1
assert_not_contains "$out" "proj  []" "no adjacent field bleeds into cwd" || fail=1

# ---- the invariant itself, asserted on the emitter ------------------------
# Rendering assertions above can only catch shifts that happen to be visible.
# Check the contract directly: every emitted field is non-empty, and the field
# count is exactly what the consumer reads.
# Take the emitter program from the SHIPPED source rather than restating it here:
# a copy in the test would drift from the code it is meant to protect. `eval` of
# the real assignment avoids hand-editing quotes out of the extracted text (an
# earlier attempt stripped the last character of every line and silently yielded
# an empty program — which made the "no field is empty" check below pass on zero
# rows).
eval "$(sed -n "/^_SESSION_JQ=/,/@tsv'\$/p" "$CS")"
[[ -n "${_SESSION_JQ:-}" ]] \
  && echo "PASS: the emitter program was extracted from the shipped source" \
  || { echo "FAIL: could not extract _SESSION_JQ — the checks below would be vacuous" >&2; fail=1; }

rows="$(jq -rs ".[] | $_SESSION_JQ" "$acct/sessions/$live_pid.json" 2>/dev/null)"

# Guard against vacuity: every assertion below is trivially true on no rows.
[[ -n "$rows" ]] \
  && echo "PASS: the emitter produced at least one row to check" \
  || { echo "FAIL: emitter produced no rows — the field checks would be vacuous" >&2; fail=1; }

nf="$(awk -F'\t' '{print NF; exit}' <<<"$rows")"
assert_eq "$nf" "8" "the emitter produces exactly the 8 fields the reader consumes" || fail=1

empties="$(awk -F'\t' '{for (i = 1; i <= NF; i++) if ($i == "") c++} END {print c+0}' <<<"$rows")"
assert_eq "$empties" "0" "no emitted field is ever empty (tab-collapse invariant)" || fail=1

# And prove the reader agrees: parsing the row back must land the sid in slot 6.
IFS=$'\t' read -r _p _c _e _s _w r_sid _b _u <<<"$(head -1 <<<"$rows")"
assert_eq "$r_sid" "$SID" "field 6 parses back as the sessionId" || fail=1

exit "$fail"
