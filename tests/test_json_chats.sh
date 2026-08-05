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

# A live runtime whose sid has NO transcript on disk (VS Code, or a session file
# flushed before its transcript) must not leak "bad array subscript" — an empty
# associative-array index survives `${arr[$x]:-0}` as a stderr error. Capture
# stderr on its own and assert it is clean; the row must still appear (degraded,
# never dropped).
runtimeonly_pid="$(fake_session "$HOME/.claude" "$HOME/ghost" "session_NOFILE" "sid-nofile")"
noise="$(FORCE_COLOR=1 "$CS" _snapshot --json --only=chats 2>&1 >/dev/null)"
assert_not_contains "$noise" "bad array subscript" \
  "a runtime with no transcript leaks no stderr noise into the section" || fail=1
assert_not_contains "$noise" "unbound variable" \
  "and no unbound-variable error either" || fail=1
# and the ghost runtime is still represented, not silently dropped
ghost="$(FORCE_COLOR=1 "$CS" _snapshot --json --only=chats 2>/dev/null | jq -c '.sections.chats.items[]|select(.sessionId=="sid-nofile")')"
assert_eq "$(jq -r '.runtime.present' <<<"$ghost")" "true" "the transcript-less runtime is still shown" || fail=1
# clean up so the counts below (which expect exactly the three seeded chats) hold
rm -f "$HOME/.claude/sessions/$runtimeonly_pid.json"
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
# titlesIndex is WINDOW-scoped: `resolved` (rows served from the index this
# poll) and `pending` (misses this poll still owes `_titles --sids=`), NOT the
# cache's lifetime counters — those cost a whole-index read and belong to
# `doctor`, not to every poll. sid-live's title came from the index, so at
# least one row resolved.
jq -e '.titlesIndex|has("resolved") and has("pending")' >/dev/null <<<"$ch" \
  && echo "PASS: the section reports window-scoped resolved and pending counts" \
  || { echo "FAIL: titlesIndex carries no resolved/pending counts" >&2; fail=1; }
jq -e '.titlesIndex.resolved >= 1' >/dev/null <<<"$ch" \
  && echo "PASS: an indexed row is counted as resolved" \
  || { echo "FAIL: an indexed title did not increment resolved" >&2; fail=1; }
# The poll must NOT read the whole index for these counters. Count `head` forks
# over the index across a full section render: the coarse state check is one
# `head -1`; a regression back to _ti_stats/_ti_load would loop the whole file.
# (Proven by the O(total) latency the reviewer measured — this guards the shape.)
jq -e '.titlesIndex|has("entries")|not' >/dev/null <<<"$ch" \
  && echo "PASS: the poll does not emit whole-cache lifetime counters" \
  || { echo "FAIL: titlesIndex still carries a whole-cache 'entries' count — that needs an O(total) read" >&2; fail=1; }

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

# Provenance is a property of the CHAT, not of a live runtime: a transferred
# chat that is NOT currently running must still carry where it came from.
# sid-old-1 is transcript-only (no runtime). Record a transfer into this account
# for it, and assert the section surfaces it.
: > "$HOME/.config/claude-helpers/transfer-log.jsonl"
jq -cn '{id:"aaa111",ts:1785900000,sid:"sid-old-1",title:"Old one",from:"alpha",to:"default",verb:"move",undoOf:null,redoOf:null}' \
  >> "$HOME/.config/claude-helpers/transfer-log.jsonl"
docp="$(FORCE_COLOR=1 "$CS" _snapshot --json --only=chats 2>/dev/null)"
oldp="$(jq -c '.sections.chats.items[]|select(.sessionId=="sid-old-1")' <<<"$docp")"
assert_eq "$(jq -r '.runtime.present' <<<"$oldp")" "false" "the transferred chat is not running" || fail=1
assert_eq "$(jq -r '.provenance.kind' <<<"$oldp")" "transfer" \
  "a transcript-only chat still carries its transfer provenance (not gated on a live runtime)" || fail=1
assert_eq "$(jq -r '.provenance.from' <<<"$oldp")" "alpha" "provenance names where it came from" || fail=1
rm -f "$HOME/.config/claude-helpers/transfer-log.jsonl"
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

# ---- the poll cost must scale with the WINDOW, not the account -------------
# The whole windowed/indexed design exists so a poll on an account with
# thousands of transcripts stays cheap. Fork counts cannot see the way it
# regressed: pure-bash O(total) loops (a full-account row loop in
# _build_transfer_index, a whole-index read via _ti_stats) — no extra forks,
# just time proportional to transcript count.
#
# An absolute millisecond budget is machine-dependent and a loose one lets the
# regression through (the pre-fix code came in at ~1.1s for 5,000 transcripts,
# under any ceiling generous enough for a loaded runner). A RATIO is not
# machine-dependent: both points are measured on the same host moments apart,
# so load cancels. Window-bounded means the poll barely grows from a tiny
# account to a huge one; the pre-fix O(total) code grew ~12x over this range,
# the fixed code ~1.5x. Assert < 4x — clear of the fix's real ratio, nowhere
# near the regression's.
_poll_ms() {   # $1 = how many transcripts the account holds; returns via stdout
  local n="$1" dir="$HOME/.claude/projects" i d start ms best=""
  rm -rf "$dir"
  for (( i=0; i<n; i++ )); do
    d="$dir/$(printf 'proj-%d' $((i % 12)))"; mkdir -p "$d"
    printf '{"type":"user","text":"x"}\n' > "$d/scale-sid-$i.jsonl"
  done
  "$CS" _snapshot --json --only=chats >/dev/null 2>&1     # warm, not measured
  # Best of three: a load spike on a shared runner can only inflate a sample,
  # never deflate it, so the minimum is the reading least polluted by contention
  # — the honest measure of the code's own cost, and what keeps this ratio gate
  # from flaking under load rather than catching a real regression.
  local r
  for r in 1 2 3; do
    start=$(date +%s%N)
    "$CS" _snapshot --json --only=chats >/dev/null 2>&1
    ms=$(( ( $(date +%s%N) - start ) / 1000000 ))
    { [[ -z "$best" ]] || (( ms < best )); } && best=$ms
  done
  echo "$best"
}
scale_big="$(mktemp -d)"; export XDG_CACHE_HOME="$scale_big/cache"
small_ms="$(_poll_ms 200)"
big_ms="$(_poll_ms 5000)"
# Guard the denominator: on an unloaded box the 200-transcript poll can measure
# a few ms and make any ratio explode. Floor it so the ratio stays meaningful.
(( small_ms < 20 )) && small_ms=20
ratio_x10=$(( big_ms * 10 / small_ms ))
if (( ratio_x10 <= 40 )); then
  echo "PASS: chats poll is window-bounded — 200 vs 5000 transcripts ${small_ms}ms -> ${big_ms}ms (${ratio_x10}/10x <= 4.0x)"
else
  echo "FAIL: chats poll cost scales with the account, not the window — ${small_ms}ms -> ${big_ms}ms (${ratio_x10}/10x > 4.0x)" >&2
  fail=1
fi
rm -rf "$scale_big"
exit "$fail"
