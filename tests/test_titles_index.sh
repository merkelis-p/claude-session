#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$0")/harness.sh"
fail=0
setup_fake_home
trap teardown_fake_home EXIT
install_fake_claude
export XDG_CACHE_HOME="$TEST_HOME/.cache"
IDX="$XDG_CACHE_HOME/claude-helpers/titles.tsv"

# Probe lib/titleindex.sh's primitives directly, in a subshell (so TITLE_INDEX/
# _TI/_TI_LOADED never leak into this test's own shell). The JSON "chats" list
# that will eventually surface TI_STATE to the app as `titlesIndex.state` is a
# later task — lib/json.sh's JSON_SECTIONS_ALL already lists "chats" as a
# placeholder with no `_json_section_chats` emitter behind it yet, and calling
# `_snapshot --only=chats` today correctly fails closed ("internal error"),
# per _json_envelope's own documented contract for a not-yet-implemented
# section. This task supplies the cache and the `_titles` verb the future
# chats emitter will read; it does not build that emitter. See the report for
# the full rationale.
_ti_probe_state() {
  ( TITLE_INDEX="$IDX"; . "$HELPERS_LIB_SRC/titleindex.sh"; _ti_load; printf '%s' "$TI_STATE" )
}
_ti_probe_lookup() {  # path mtime size -> "source\ttitle" on a hit; empty + rc=1 on a miss
  ( TITLE_INDEX="$IDX"; . "$HELPERS_LIB_SRC/titleindex.sh"; _ti_lookup "$1" "$2" "$3" )
}

t1="$(fake_transcript "$HOME/.claude" "$HOME/api" "sid-a" '{"type":"custom-title","customTitle":"Fix the retry handler"}')"
t2="$(fake_transcript "$HOME/.claude" "$HOME/api" "sid-b" '{"type":"ai-title","aiTitle":"Rework pricing"}')"
t3="$(fake_transcript "$HOME/.claude" "$HOME/web" "sid-c" '{"type":"user","text":"no title record here"}')"

# --- a cold index NEVER builds itself in front of a caller ------------------
"$CS" ls --json >/dev/null 2>&1 || true
[[ -f "$IDX" ]] && { echo "FAIL: a snapshot built the index synchronously" >&2; fail=1; } \
  || echo "PASS: a cold index is not built by a listing path"
assert_eq "$(_ti_probe_state)" "cold" "a cold index reports itself as cold" || fail=1
# A MISS and an UNTITLED CHAT must not render the same. Rendering them
# identically is the vacuous-pass mistake in another costume.
m1="$(stat -c %Y "$t1" 2>/dev/null || stat -f %m "$t1")"
sz1="$(wc -c < "$t1" | tr -d ' ')"
if _ti_probe_lookup "$t1" "$m1" "$sz1" >/dev/null; then
  echo "FAIL: an unresolved title reported a hit before anything ever wrote the index" >&2; fail=1
else
  echo "PASS: an unresolved title is a miss"
fi
assert_eq "$(_ti_probe_lookup "$t1" "$m1" "$sz1")" "" "a miss carries no fabricated value" || fail=1

# --- the lazy fallback resolves a window and writes back --------------------
tw="$("$CS" _titles --json --account=default --sids=sid-a,sid-b,sid-c 2>/dev/null)"
assert_eq "$(jq -r '.items[]|select(.sessionId=="sid-a").title.value' <<<"$tw")" "Fix the retry handler" \
  "custom-title wins" || fail=1
assert_eq "$(jq -r '.items[]|select(.sessionId=="sid-b").title.source' <<<"$tw")" "ai-title" \
  "ai-title is the second precedence step" || fail=1
# A transcript with no title record is KNOWN and untitled — not a miss.
assert_eq "$(jq -r '.items[]|select(.sessionId=="sid-c").title.state' <<<"$tw")" "known" \
  "a genuinely untitled chat is known, not unknown" || fail=1
assert_eq "$(jq -r '.items[]|select(.sessionId=="sid-c").title.source' <<<"$tw")" "none" \
  "and its source is none" || fail=1
assert_eq "$(jq -r '.items[]|select(.sessionId=="sid-c").title.value' <<<"$tw")" "(untitled)" \
  "and its value is the literal (untitled)" || fail=1
[[ -f "$IDX" ]] && echo "PASS: the fallback writes what it resolved back into the index" || fail=1
assert_eq "$(stat -c %a "$IDX" 2>/dev/null || stat -f %Lp "$IDX")" "600" \
  "the index is 0600 — it holds titles taken from the user's prompts" || fail=1
assert_eq "$(stat -c %a "$(dirname "$IDX")" 2>/dev/null || stat -f %Lp "$(dirname "$IDX")")" "700" \
  "its directory is 0700" || fail=1
assert_contains "$(head -1 "$IDX")" "#v1" "the index carries a version header" || fail=1

# --- a hit costs no file read: counted, not assumed -------------------------
mkdir -p "$TEST_HOME/count"
for t in tail jq awk; do
  real="$(command -v "$t")"
  printf '#!/usr/bin/env bash\necho x >> "$FORKS/%s"\nexec %s "$@"\n' "$t" "$real" > "$TEST_HOME/count/$t"
  chmod +x "$TEST_HOME/count/$t"
done
export FORKS="$TEST_HOME/forks"; mkdir -p "$FORKS"; : > "$FORKS/tail"; : > "$FORKS/jq"; : > "$FORKS/awk"
PATH="$TEST_HOME/count:$PATH" "$CS" _titles --json --account=default --sids=sid-a,sid-b >/dev/null 2>&1
assert_eq "$(wc -l < "$FORKS/tail" | tr -d ' ')" "0" "an index hit reads no transcript at all" || fail=1
# The index must be parsed ONCE for the whole window, not once per row. A cache
# assigned inside `$(...)` dies with the subshell — _titles_window's own loop
# calls `_ti_lookup` inside `$(...)` for every row, so `_ti_load` has to be
# primed once in _titles_window's OWN frame (a parent the subshells fork FROM)
# or every row would re-fork awk and re-parse the whole index from scratch.
assert_eq "$(wc -l < "$FORKS/awk" | tr -d ' ')" "1" \
  "the index is parsed once for the whole window, not once per row" || fail=1

# --- one jq per transcript on a miss (the 18ms -> 8ms batching) -------------
: > "$FORKS/tail"; : > "$FORKS/jq"
t4="$(fake_transcript "$HOME/.claude" "$HOME/api" "sid-d" '{"type":"last-prompt","lastPrompt":"hello"}')"
PATH="$TEST_HOME/count:$PATH" "$CS" _titles --json --account=default --sids=sid-d >/dev/null 2>&1
assert_eq "$(wc -l < "$FORKS/tail" | tr -d ' ')" "1" "a miss forks tail exactly once" || fail=1
n="$(wc -l < "$FORKS/jq" | tr -d ' ')"
(( n <= 2 )) && echo "PASS: a miss forks jq at most twice (read + document assembly), got $n" \
  || { echo "FAIL: a miss forked jq $n times — the three field reads were not batched" >&2; fail=1; }

# --- invalidation: path + mtime + size, all three ---------------------------
"$CS" _titles --json --account=default --sids=sid-a >/dev/null 2>&1     # warm
before="$(grep -c . "$IDX")"
printf '%s\n' '{"type":"custom-title","customTitle":"Renamed"}' >> "$t1"   # size AND mtime change
assert_eq "$("$CS" _titles --json --account=default --sids=sid-a | jq -r '.items[0].title.value')" "Renamed" \
  "an appended title record invalidates the entry" || fail=1
touch -d '2030-01-01' "$t2" 2>/dev/null || touch -t 203001010000 "$t2"     # mtime only
assert_eq "$("$CS" _titles --json --account=default --sids=sid-b | jq -r '.items[0].title.state')" "known" \
  "an mtime-only change re-reads rather than serving a stale title" || fail=1

# --- a stale entry is never served -----------------------------------------
# Hand-forge an entry whose title disagrees with the file at the recorded key.
printf '%s\t%s\t%s\t%s\t%s\n' "$t3" "$(stat -c %Y "$t3" 2>/dev/null || stat -f %m "$t3")" "999999" \
  "custom-title" "WRONG" >> "$IDX"
assert_not_contains "$("$CS" _titles --json --account=default --sids=sid-c)" "WRONG" \
  "a size mismatch means the entry is not served" || fail=1

# --- corrupt / partial / unknown-version handling --------------------------
printf 'garbage line with no tabs\n' >> "$IDX"
printf '%s\tnotanumber\t12\tai-title\tx\n' "$t3" >> "$IDX"
out="$("$CS" doctor 2>&1)"
assert_contains "$out" "title index" "doctor reports an unhealthy index" || fail=1
assert_contains "$out" "2 unreadable line" "and counts the lines it skipped" || fail=1
assert_not_contains "$("$CS" _titles --json --account=default --sids=sid-c)" "notanumber" \
  "a malformed line is skipped, never parsed loosely" || fail=1
printf '#v99 0\n' > "$IDX"
assert_eq "$(_ti_probe_state)" "cold" \
  "an unknown index version is ignored whole, never partially trusted" || fail=1
ls "$(dirname "$IDX")"/titles.tsv.tmp* >/dev/null 2>&1 \
  && { echo "FAIL: a temp file was left behind" >&2; fail=1; } \
  || echo "PASS: no partially-written temp file survives"

# --- a title containing a tab or newline cannot shift a field --------------
t5="$(fake_transcript "$HOME/.claude" "$HOME/api" "sid-e" \
  '{"type":"custom-title","customTitle":"tab\there and\nnewline"}')"
v="$("$CS" _titles --json --account=default --sids=sid-e | jq -r '.items[0].title.value')"
assert_eq "$v" "tab here and newline" "tabs and newlines are squashed before the index sees them" || fail=1
assert_eq "$(awk -F'\t' 'NR>1{print NF}' "$IDX" | sort -u | tr -d '\n')" "5" \
  "every index line has exactly 5 fields" || fail=1

# --- a truncated first line (tail cut mid-record) is tolerated -------------
big="$(fake_transcript "$HOME/.claude" "$HOME/api" "sid-f" '{"type":"ai-title","aiTitle":"Tail me"}')"
python3 - "$big" <<'PY' 2>/dev/null || printf '%s\n' "$(head -c 300000 /dev/zero | tr '\0' 'x')" >> "$big"
import sys; f=sys.argv[1]
pad='{"type":"user","text":"'+('y'*300000)+'"}\n'
data=open(f).read(); open(f,'w').write(pad+data)
PY
assert_eq "$("$CS" _titles --json --account=default --sids=sid-f | jq -r '.items[0].title.value')" "Tail me" \
  "a record cut in half by the tail window does not break the read" || fail=1

# --- an explicit rebuild is the ONLY way the whole set gets built ----------
rm -f "$IDX"
"$CS" _titles --json --rebuild >/dev/null 2>&1
assert_eq "$?" "0" "--rebuild exits 0" || fail=1
n="$(awk 'NR>1' "$IDX" | wc -l | tr -d ' ')"
(( n >= 6 )) && echo "PASS: --rebuild indexed every fixture transcript ($n)" \
  || { echo "FAIL: --rebuild indexed only $n entries" >&2; fail=1; }
assert_eq "$(_ti_probe_state)" "warm" \
  "a full index reports warm" || fail=1

# --- regression: window cost must scale with the WINDOW, not the INDEX -----
# Before this fix, `_titles_window` primed a FULL `_ti_load` unconditionally —
# a bash `while read` loop over the WHOLE index, with a `$(...)` fork PER LINE
# inside it (`k="$(_ti_key ...)"`) — so a 1-sid window paid for every line in
# the index no matter how few rows it actually asked for. Measured on the
# reference host, via the real CLI in a hermetic fake HOME (same shape as
# this fixture, scaled up):
#   index with 2 lines,    1-sid window:      89 ms
#   index with 6812 lines, 1-sid window:  10 971 ms
# 6,810 entries is that host's actual transcript count — the normal case, not
# a corner. After this fix (one awk pass over the index, keyed to only the
# requested window; see lib/titleindex.sh's _ti_lookup_window), the same
# 6,810-line measurement is ~70ms — about two orders of magnitude under the
# budget below, which is deliberate: the ceiling has to absorb a loaded CI
# runner without the fixed cost getting anywhere near it. Wall-clock
# assertions flake, so the budget is picked wide (2000ms) — the pre-fix code
# still misses it by ~5x, which is not a close call either way.
#
# Build the large index by APPENDING synthetic lines to the index this test
# already warmed via --rebuild above (real fixture titles at the front, so a
# correctness check rides along for free) — no real paths/session ids, per
# repo policy; s-N is synthetic.
awk 'BEGIN{for(i=1;i<=5200;i++) printf "/home/u/p/s-%d.jsonl\t%d\t%d\tnone\t(untitled)\n", i, 1700000000+i, 100+i}' >> "$IDX"
idx_lines="$(awk 'NR>1' "$IDX" | wc -l | tr -d ' ')"
if (( idx_lines >= 5000 )); then
  echo "PASS: the regression fixture index has $idx_lines lines (>= 5000)"
else
  echo "FAIL: setup — synthetic index only has $idx_lines lines, need >= 5000" >&2; fail=1
fi

_now_ms() {   # no fork on bash 5 (EPOCHREALTIME); degrades to whole seconds on bash 4
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    # Separate `local` statements: under `set -u`, RHS expansions in ONE
    # `local` command are evaluated in the OUTER scope before any of the new
    # bindings take effect (see lib/json.sh's _epoch_ms for the same note) —
    # `r` would read as unbound there on its first-ever call.
    local r="${EPOCHREALTIME/,/.}"
    local s="${r%%.*}"
    local f="${r#*.}"
    printf '%s' "$(( 10#$s * 1000 + 10#${f:0:3} ))"
  else
    printf '%s' "$(( $(date +%s) * 1000 ))"
  fi
}
t_start="$(_now_ms)"
big_out="$("$CS" _titles --json --account=default --sids=sid-a 2>&1)"
elapsed=$(( $(_now_ms) - t_start ))
# sid-a's transcript ($t1) had a "Renamed" custom-title record appended to it
# in the invalidation section above, so that's its current, correct title —
# NOT the original "Fix the retry handler" fixture text.
assert_eq "$(jq -r '.items[0].title.value' <<<"$big_out" 2>/dev/null)" "Renamed" \
  "a 1-sid window still resolves the right title against a $idx_lines-line index" || fail=1
if (( elapsed <= 2000 )); then
  echo "PASS: a 1-sid window against a $idx_lines-line index completes within budget (${elapsed}ms <= 2000ms budget)"
else
  echo "FAIL: a 1-sid window against a $idx_lines-line index took ${elapsed}ms — budget is 2000ms" >&2
  fail=1
fi
exit "$fail"
