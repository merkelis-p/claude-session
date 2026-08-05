#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$0")/harness.sh"
fail=0
setup_fake_home
trap teardown_fake_home EXIT
install_fake_claude

# One live runtime with a matching transcript, plus two transcript-only chats.
pid="$(fake_session "$HOME/.claude" "$HOME/api" "session_01AB" "sid-live")"
fake_transcript "$HOME/.claude" "$HOME/api" "sid-live" \
  '{"type":"custom-title","customTitle":"Fix the retry handler"}' >/dev/null
fake_transcript "$HOME/.claude" "$HOME/api" "sid-old-1" '{"type":"ai-title","aiTitle":"Old one"}' >/dev/null
fake_transcript "$HOME/.claude" "$HOME/web" "sid-old-2" '{"type":"last-prompt","lastPrompt":"hi"}' >/dev/null

doc="$(FORCE_COLOR=1 "$CS" _snapshot --json --only=chats,issues 2>/dev/null)"
jq -e . >/dev/null 2>&1 <<<"$doc" || { echo "FAIL: invalid JSON: $doc" >&2; exit 1; }
[[ "$doc" == *$'\033'* ]] && { echo "FAIL: chats/issues emitted ANSI" >&2; fail=1; } \
  || echo "PASS: chats/issues emit no ANSI under FORCE_COLOR=1"
ch="$(jq -c '.sections.chats' <<<"$doc")"

# Chats are TRANSCRIPTS, not runtimes: all three appear.
assert_eq "$(jq -r '.items|length' <<<"$ch")" "3" "chats lists transcripts, not just live runtimes" || fail=1
assert_eq "$(jq -r '.total' <<<"$ch")" "3" "chats.total counts past the window" || fail=1
assert_eq "$(jq -r '.truncated' <<<"$ch")" "false" "chats.truncated is false when the window covers everything" || fail=1
# CHAT_LIMIT's real default is 200 (--limit-chats=, set in bin/claude-session's
# flag-slot block) — not 50. A window default of 50 predates that slot landing.
assert_eq "$(jq -r '.limit' <<<"$ch")" "200" "chats.limit declares the window (CHAT_LIMIT default)" || fail=1

live="$(jq -c '.items[] | select(.sessionId=="sid-live")' <<<"$ch")"
assert_eq "$(jq -r '.runtime.present' <<<"$live")" "true" "the live chat has a runtime" || fail=1
assert_eq "$(jq -r '.runtime.pid' <<<"$live")" "$pid" "runtime.pid is the session-state pid" || fail=1
assert_eq "$(jq -r '.runtime.alive' <<<"$live")" "true" "runtime.alive is a boolean, from _proc_alive" || fail=1
assert_eq "$(jq -r '.account' <<<"$live")" "default" "account is named, never inferred by the reader" || fail=1
assert_eq "$(jq -r '.transcriptPathSource' <<<"$live")" "sid-match" "an id match is labelled sid-match" || fail=1
# Titles come from the index, never from an inline read — including for the row
# that has a live runtime. Warm the index first, then assert the hit.
"$CS" _titles --json --account=default --sids=sid-live >/dev/null 2>&1
doc="$(FORCE_COLOR=1 "$CS" _snapshot --json --only=chats,issues 2>/dev/null)"
ch="$(jq -c '.sections.chats' <<<"$doc")"
live="$(jq -c '.items[] | select(.sessionId=="sid-live")' <<<"$ch")"
assert_eq "$(jq -r '.title.state' <<<"$live")" "known" "an indexed title is served from the index" || fail=1
assert_eq "$(jq -r '.title.value' <<<"$live")" "Fix the retry handler" "custom-title wins" || fail=1
assert_eq "$(jq -r '.title.source' <<<"$live")" "custom-title" "title.source names the precedence hit" || fail=1
assert_eq "$(jq -r '.titlesIndex.state' <<<"$ch")" "warm" "the section reports the index state" || fail=1
jq -e '.titlesIndex|has("hits") and has("misses")' >/dev/null <<<"$ch" \
  && echo "PASS: the section reports index hits and misses" \
  || { echo "FAIL: titlesIndex carries no hit/miss counts" >&2; fail=1; }

# Tri-state, not zero: RSS for a pid the process table did not report.
jq -e '.runtime.rss.state|test("^(known|unknown)$")' >/dev/null <<<"$live" \
  && echo "PASS: runtime.rss carries a state" \
  || { echo "FAIL: runtime.rss has no state" >&2; fail=1; }

# Transcript-only chats: no runtime, and a title that says it was not read.
old="$(jq -c '.items[] | select(.sessionId=="sid-old-1")' <<<"$ch")"
assert_eq "$(jq -r '.runtime.present' <<<"$old")" "false" "a transcript-only chat has no runtime" || fail=1
assert_eq "$(jq -r '.title.state' <<<"$old")" "unknown" "a title not in the index is unknown, never empty" || fail=1
assert_eq "$(jq -r '.title.value' <<<"$old")" "" "an unknown title carries no fabricated value" || fail=1
assert_not_contains "$(jq -r '.title.value' <<<"$old")" "(untitled)" \
  "a miss is NEVER rendered as an untitled chat" || fail=1
assert_contains "$(jq -r '.checksSkipped[].name' <<<"$ch")" "titles-window" \
  "titles not in the index are reported as a skipped check, with the pending count" || fail=1
jq -e '.titlesIndex.pending > 0' >/dev/null <<<"$ch" \
  && echo "PASS: the section counts how many titles are still unresolved" \
  || { echo "FAIL: titlesIndex.pending missing" >&2; fail=1; }

# The section must not resolve titles itself, at any window size: counted.
mkdir -p "$TEST_HOME/count"; real="$(command -v tail)"
printf '#!/usr/bin/env bash\necho x >> "$FORKS/tail"\nexec %s "$@"\n' "$real" > "$TEST_HOME/count/tail"
chmod +x "$TEST_HOME/count/tail"; export FORKS="$TEST_HOME/forks"; mkdir -p "$FORKS"; : > "$FORKS/tail"
PATH="$TEST_HOME/count:$PATH" "$CS" _snapshot --json --only=chats >/dev/null 2>&1
assert_eq "$(wc -l < "$FORKS/tail" | tr -d ' ')" "0" \
  "the chats section reads no transcript, so its cost is independent of chat count" || fail=1

# Criticality: a session file with no sessionId degrades its row, never drops it.
jq '.sessionId=null' "$HOME/.claude/sessions/$pid.json" > "$HOME/.claude/sessions/$pid.json.tmp" \
  && mv "$HOME/.claude/sessions/$pid.json.tmp" "$HOME/.claude/sessions/$pid.json"
doc2="$(FORCE_COLOR=1 "$CS" _snapshot --json --only=chats 2>/dev/null)"
ch2="$(jq -c '.sections.chats' <<<"$doc2")"
assert_eq "$(jq -r '.degraded' <<<"$ch2")" "1" "a row missing a critical field is counted as degraded" || fail=1
jq -e '[.items[]|select(.degraded==true)]|length==1' >/dev/null <<<"$ch2" \
  && echo "PASS: the degraded row is present and marked, not dropped" \
  || { echo "FAIL: the degraded row was dropped or unmarked" >&2; fail=1; }
assert_contains "$(jq -r '[.items[]|select(.degraded==true).degradedReason]|join(" ")' <<<"$ch2")" "sessionId" \
  "the degraded row names the field that could not be resolved" || fail=1

# issues: the five session checks, per row, with severity and text.
iss="$(jq -c '.sections.issues' <<<"$doc")"
jq -e '.items|type=="array"' >/dev/null <<<"$iss" && echo "PASS: issues.items is an array" \
  || { echo "FAIL: issues.items missing" >&2; fail=1; }
jq -e '.checksRun|index("stale") != null' >/dev/null <<<"$iss" \
  && echo "PASS: issues.checksRun names the stale check" \
  || { echo "FAIL: issues.checksRun does not name its checks" >&2; fail=1; }

# doctor --json is the same two sections plus processes, and its EXIT CODE is
# still the issue count — the frozen contract (docs/doctor-orphans.md).
"$CS" doctor --json >/dev/null 2>&1; drc=$?
n="$("$CS" doctor --json 2>/dev/null | jq '[.sections.issues.items[], .sections.processes.items[]]|length')"
assert_eq "$drc" "$n" "doctor --json exit code still equals the issue count" || fail=1

# The upstream-field check: an unknown field in a session file is reported, not ignored.
jq '. + {brandNewUpstreamField: 1}' "$HOME/.claude/sessions/$pid.json" > "$HOME/.claude/sessions/$pid.json.t" \
  && mv "$HOME/.claude/sessions/$pid.json.t" "$HOME/.claude/sessions/$pid.json"
assert_contains "$("$CS" doctor 2>&1)" "brandNewUpstreamField" \
  "doctor reports an unknown upstream session-state field" || fail=1
exit "$fail"
