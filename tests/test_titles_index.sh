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
_ti_probe_state() {  # optional $1 = index path to probe (default: $IDX)
  ( TITLE_INDEX="${1:-$IDX}"; . "$HELPERS_LIB_SRC/titleindex.sh"; _ti_load; printf '%s' "$TI_STATE" )
}
_ti_probe_lookup() {  # path mtime size -> "source\ttitle" on a hit; empty + rc=1 on a miss
  ( TITLE_INDEX="$IDX"; . "$HELPERS_LIB_SRC/titleindex.sh"; _ti_lookup "$1" "$2" "$3" )
}

t1="$(fake_transcript "$HOME/.claude" "$HOME/api" "sid-a" '{"type":"custom-title","customTitle":"Fix the retry handler"}')"
t2="$(fake_transcript "$HOME/.claude" "$HOME/api" "sid-b" '{"type":"ai-title","aiTitle":"Rework pricing"}')"
t3="$(fake_transcript "$HOME/.claude" "$HOME/web" "sid-c" '{"type":"user","text":"no title record here"}')"

# --- a cold index NEVER builds itself in front of a caller ------------------
# `ls --json` is rejected by `_json_guard` before ANY listing code runs (--json
# isn't in `_JSON_READY_VERBS` for `ls`), so it exits 2 without ever reaching
# `cmd_ls` — checking the index against THAT command would pass vacuously even
# if `cmd_ls` built the index eagerly, since `cmd_ls` never runs. Use a plain
# `ls` (no --json) against a real, live-looking session instead: that DOES
# reach `cmd_ls`, which calls `_title_for_sid` -> `_title_for_file` for every
# row — the actual title-lookup path a listing uses, and it never calls
# `_ti_put`.
fake_session "$HOME/.claude" "$HOME/api" "" "sid-a" >/dev/null
out_ls_cold="$("$CS" ls 2>&1)"
assert_contains "$out_ls_cold" "Fix the retry handler" \
  "setup: the cold-index ls check reaches real listing output, not a vacuous exit" || fail=1
[[ -f "$IDX" ]] && { echo "FAIL: a listing built the index synchronously" >&2; fail=1; } \
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
# The index must be parsed ONCE for the whole window, not once per row — the
# single `_ti_lookup_window` awk fork, never a per-sid or per-matched-row fork.
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
after="$(grep -c . "$IDX")"
assert_eq "$(( after > before ))" "1" \
  "an invalidated entry appends a fresh line rather than rewriting in place (later line wins)" || fail=1
touch -d '2030-01-01' "$t2" 2>/dev/null || touch -t 203001010000 "$t2"     # mtime only
assert_eq "$("$CS" _titles --json --account=default --sids=sid-b | jq -r '.items[0].title.state')" "known" \
  "an mtime-only change re-reads rather than serving a stale title" || fail=1

# --- a stale entry is never served -----------------------------------------
# Hand-forge an entry whose title disagrees with the file at the recorded key.
printf '%s\t%s\t%s\t%s\t%s\n' "$t3" "$(stat -c %Y "$t3" 2>/dev/null || stat -f %m "$t3")" "999999" \
  "custom-title" "WRONG" >> "$IDX"
assert_not_contains "$("$CS" _titles --json --account=default --sids=sid-c)" "WRONG" \
  "a size mismatch means the entry is not served" || fail=1

# --- a title containing a tab or newline cannot shift a field --------------
# Deliberately BEFORE the corrupt/partial/unknown-version section below: that
# section ends by truncating $IDX to a bare `#v99 0` header, so a field-count
# check placed after it (as this used to be) only ever sees the ONE data line
# written since — never exercising the invariant across the several
# genuinely-`_ti_put`-written lines already sitting in the index at this
# point (sid-a x2, sid-b x2, sid-c's hand-forged line, sid-d).
t5="$(fake_transcript "$HOME/.claude" "$HOME/api" "sid-e" \
  '{"type":"custom-title","customTitle":"tab\there and\nnewline"}')"
v="$("$CS" _titles --json --account=default --sids=sid-e | jq -r '.items[0].title.value')"
assert_eq "$v" "tab here and newline" "tabs and newlines are squashed before the index sees them" || fail=1
nf_lines="$(awk -F'\t' 'NR>1{print NF}' "$IDX" | sort -u)"
nf_count="$(awk 'NR>1' "$IDX" | wc -l | tr -d ' ')"
(( nf_count >= 5 )) && echo "PASS: the field-count check inspects $nf_count real data lines, not just one" \
  || { echo "FAIL: setup — only $nf_count data lines present, the check would be too weak" >&2; fail=1; }
assert_eq "$(tr -d '\n' <<<"$nf_lines")" "5" "every index line has exactly 5 fields" || fail=1

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

# --- C3: an index that is present but unreadable heals, and is reported ----
# A 0-byte index (crash mid-write, disk full, a manual `: >` truncation) used
# to never get a header written either: `_ti_put`'s header write only fired
# `if [[ ! -f "$TITLE_INDEX" ]]` — true only for a MISSING file, false for a
# 0-byte or unknown-version one that already exists. So it stayed cold
# forever, every poll re-read every transcript in the window, and `doctor`
# said nothing (rc=0, no output) about a cache that could never hit.
: > "$IDX"
out_c3_doctor="$("$CS" doctor 2>&1)"
assert_contains "$out_c3_doctor" "present but unreadable/cold" \
  "doctor reports a present-but-header-less index as an issue, not silently" || fail=1
"$CS" _titles --json --account=default --sids=sid-a,sid-b >/dev/null 2>&1   # poll 1: heals + resolves
"$CS" _titles --json --account=default --sids=sid-a,sid-b >/dev/null 2>&1   # poll 2: same window, should be warm now
assert_contains "$(head -1 "$IDX")" "#v1" \
  "the first write after a 0-byte truncation heals the version header" || fail=1
lines_c3="$(awk 'NR>1' "$IDX" | wc -l | tr -d ' ')"
assert_eq "$lines_c3" "2" \
  "once healed, polling the SAME window twice appends once per sid, not once per poll" || fail=1
assert_eq "$(_ti_probe_state)" "warm" "and the healed index now reports warm" || fail=1

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
# Moved here from right after the `#v99 0` truncation above: at that point in
# the ORIGINAL test, `_ti_rebuild`'s `mktemp` had never once been invoked
# (its only call site is the `--rebuild` line just above), so the check ran
# before anything had ever created a temp file and could not have caught a
# leftover one. Re-check it here, right after a real rebuild.
ls "$(dirname "$IDX")"/titles.tsv.tmp* >/dev/null 2>&1 \
  && { echo "FAIL: a temp file was left behind after a successful rebuild" >&2; fail=1; } \
  || echo "PASS: no partially-written temp file survives a successful rebuild"

# --- M9 / M10: a rebuild that fails leaves no trap armed and reports failure
# Two independent failure shapes, both against an ISOLATED cache path (never
# $IDX — this must not disturb any state the sections above/below rely on).
IDX_FAIL="$TEST_HOME/.cache_fail/claude-helpers/titles.tsv"
mkdir -p "$(dirname "$IDX_FAIL")"

# (a) M10: the destination is occupied by a directory. `mv` "succeeds" by
# nesting the temp file INSIDE it, so the real check has to be "is the
# destination now a regular file", not "did mv exit 0".
mkdir -p "$IDX_FAIL"
out_m10="$( ( TITLE_INDEX="$IDX_FAIL"
  . "$HELPERS_LIB_SRC/compat.sh"; . "$HELPERS_LIB_SRC/titles.sh"
  . "$HELPERS_LIB_SRC/ledger.sh"; . "$HELPERS_LIB_SRC/titleindex.sh"
  _all_accounts() { printf 'default\t%s\n' "$HOME/.claude"; }   # normally bin/claude-session's own
  _ti_rebuild; printf 'rc=%d\n' "$?"
) 2>&1 )"
assert_contains "$out_m10" "rc=1" \
  "a rebuild that lands on an occupied directory reports failure, not a false rc=0" || fail=1
rm -rf "$IDX_FAIL"

# (b) M9: the trap must not re-fire at an IN-FUNCTION CALLER's own return,
# where `local tmp` no longer exists — under `set -u` that aborts the whole
# shell (verified independently: a bare `trap ... RETURN` left armed across a
# failed inner return DOES re-fire at the next function's return and DOES
# kill a non-interactive shell on the resulting unbound-variable error). Force
# `mv` itself to fail (a stub on PATH, not a permission trick — portable and
# deterministic) and call `_ti_rebuild` from inside a wrapper function, so
# there is a real "caller's return" for a leftover trap to hit.
mkdir -p "$TEST_HOME/failmv"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TEST_HOME/failmv/mv"
chmod +x "$TEST_HOME/failmv/mv"
out_m9="$( ( set -u
  export PATH="$TEST_HOME/failmv:$PATH"
  TITLE_INDEX="$IDX_FAIL"
  . "$HELPERS_LIB_SRC/compat.sh"; . "$HELPERS_LIB_SRC/titles.sh"
  . "$HELPERS_LIB_SRC/ledger.sh"; . "$HELPERS_LIB_SRC/titleindex.sh"
  _all_accounts() { printf 'default\t%s\n' "$HOME/.claude"; }   # normally bin/claude-session's own
  _outer_caller() {
    _ti_rebuild
    printf 'rebuild_rc=%d\n' "$?"
    return 0
  }
  _outer_caller
  printf 'outer_rc=%d\n' "$?"
) 2>&1 )"
assert_contains "$out_m9" "rebuild_rc=1" "a rebuild with a failing mv reports rc=1" || fail=1
assert_contains "$out_m9" "outer_rc=0" \
  "the trap is cleared on the failure path too, so the CALLER's own return completes normally" || fail=1
assert_not_contains "$out_m9" "unbound variable" \
  "a failed rebuild never aborts an in-function caller with 'tmp: unbound variable'" || fail=1

# --- I6: the symlink refusal must run BEFORE any write, not after ----------
# `[[ ! -f ]]` follows a symlink, and reports false (as if the file were
# "missing") for a DANGLING one — so the header-write that used to precede
# the `-L` check would create the symlink's TARGET, and only then print the
# refusal. Checked here with a dangling symlink specifically, since that is
# the case `-f` cannot see through.
mkdir -p "$TEST_HOME/.cache_sym"
IDX_SYM_TARGET="$TEST_HOME/.cache_sym/never-created.tsv"
IDX_SYM="$TEST_HOME/.cache_sym/titles.tsv"
ln -s "$IDX_SYM_TARGET" "$IDX_SYM"
out_sym="$( ( TITLE_INDEX="$IDX_SYM"
  . "$HELPERS_LIB_SRC/compat.sh"; . "$HELPERS_LIB_SRC/titles.sh"
  . "$HELPERS_LIB_SRC/ledger.sh"; . "$HELPERS_LIB_SRC/titleindex.sh"
  _ti_put "/x" "1" "2" "none" "t"; printf 'rc=%d\n' "$?"
) 2>&1 )"
assert_contains "$out_sym" "refusing to write" "a dangling symlink at the index path is refused" || fail=1
assert_contains "$out_sym" "rc=1" "...and _ti_put reports failure" || fail=1
[[ -e "$IDX_SYM_TARGET" ]] \
  && { echo "FAIL: the dangling symlink's target was created before the refusal" >&2; fail=1; } \
  || echo "PASS: the symlink's target is never created — refused before any write"

# --- I5: TI_HITS/TI_MISSES are live counters fed by the real window path ---
# Before this fix, only `_ti_lookup` (single-key) touched these — and nothing
# in production calls it; `_titles_window` (what every real caller uses) went
# through `_ti_lookup_window` without ever touching TI_HITS/TI_MISSES. A
# window that served nothing but hits still reported "hits:0" — a counter
# that never ran, reported as zero, the same failure shape as a check that
# never ran reporting PASS.
out_i5="$( ( TITLE_INDEX="$IDX"; JSON_SCHEMA_VERSION=1
  . "$HELPERS_LIB_SRC/compat.sh"; . "$HELPERS_LIB_SRC/titles.sh"
  . "$HELPERS_LIB_SRC/ledger.sh"; . "$HELPERS_LIB_SRC/titleindex.sh"
  _titles_window "$HOME/.claude" sid-a sid-d >/dev/null   # both already warm from earlier sections
  _ti_stats
) )"
i5_hits="$(cut -f2 <<<"$out_i5")"
assert_eq "$i5_hits" "2" \
  "_ti_stats' hits counter reflects real window hits (sid-a, sid-d), not a dead zero" || fail=1

# --- C2: a backslash in a title must not be doubled by @tsv ----------------
# `@tsv` escapes `\t \n \r` AND a literal backslash (by doubling it); the
# gsub just above it in `_title_pick_jq` only ever touches the first three,
# so backslash was the one character `@tsv` alone was left to mangle — and it
# reaches `_title_for_file`, which feeds the transfer ledger: persistent user
# data, not a cache.
t7="$(fake_transcript "$HOME/.claude" "$HOME/api" "sid-h" \
  '{"type":"custom-title","customTitle":"C:\\Users\\me path"}')"
v_bs="$("$CS" _titles --json --account=default --sids=sid-h | jq -r '.items[0].title.value')"
assert_eq "$v_bs" 'C:\Users\me path' \
  "a backslash in a title survives exactly once, not doubled" || fail=1

# --- I8: a sid repeated in one window is read and written exactly once -----
: > "$FORKS/tail"
t8="$(fake_transcript "$HOME/.claude" "$HOME/api" "sid-g" '{"type":"last-prompt","lastPrompt":"once only"}')"
before_g="$(awk 'NR>1' "$IDX" | wc -l | tr -d ' ')"
PATH="$TEST_HOME/count:$PATH" "$CS" _titles --json --account=default --sids=sid-g,sid-g >/dev/null 2>&1
assert_eq "$(wc -l < "$FORKS/tail" | tr -d ' ')" "1" \
  "a sid repeated in one window reads its transcript exactly once" || fail=1
after_g="$(awk 'NR>1' "$IDX" | wc -l | tr -d ' ')"
assert_eq "$((after_g - before_g))" "1" \
  "and _ti_put is called exactly once for it, not once per occurrence" || fail=1
out_doc_i8="$("$CS" doctor 2>&1)"
assert_not_contains "$out_doc_i8" "duplicate line" \
  "so doctor never sees a self-inflicted duplicate from one window's own repeat" || fail=1

# --- I4: the stale threshold needs hysteresis AND an absolute floor --------
# Same reasoning as the header comment in lib/titleindex.sh: `stale > live`
# (the old rule) is reached the moment the average path has >=2 versions —
# ordinary day-to-day use of a handful of chats gets there in a few polls and
# never clears. The new rule needs BOTH: stale >= 300 (an absolute floor —
# small accounts never trip on volume alone) AND stale > 3x live (dead weight
# has to dominate, not merely exist). Each case below writes a FRESH isolated
# index: `paths` distinct synthetic transcript paths, each appearing `reps`
# times with a different (mtime,size) each time — the first `reps-1` of each
# are stale (a later, different-keyed line for the same path exists), the
# last is live. stale = paths*(reps-1), live = paths.
IDX_I4="$TEST_HOME/.cache_i4/claude-helpers/titles.tsv"
mkdir -p "$(dirname "$IDX_I4")"
_i4_case() {
  local paths="$1" reps="$2" p r
  printf '#v1 %s\n' "$(date +%s)" > "$IDX_I4"
  for ((p=0; p<paths; p++)); do
    for ((r=0; r<reps; r++)); do
      printf '/home/u/stale/case-%d.jsonl\t%d\t%d\tnone\t(untitled)\n' "$p" "$((1700000000+r))" "$((100+r))"
    done
  done >> "$IDX_I4"
}
_i4_case 5 3      # stale=10  live=5   -> old rule (10>5) would flag stale; new rule needs stale>=300
assert_eq "$(_ti_probe_state "$IDX_I4")" "warm" \
  "stale=10/live=5 (old rule's 'chronic within 3 polls' case) stays warm under the floor" || fail=1
_i4_case 175 3    # stale=350 live=175 -> floor met (350>=300) but multiple NOT met (350 <= 175*3=525)
assert_eq "$(_ti_probe_state "$IDX_I4")" "warm" \
  "stale=350/live=175 clears the floor alone but not the 3x multiple, and stays warm" || fail=1
_i4_case 50 9     # stale=400 live=50  -> both floor (400>=300) and multiple (400>150) met
assert_eq "$(_ti_probe_state "$IDX_I4")" "stale" \
  "stale=400/live=50 clears both the floor and the 3x multiple, and reports stale" || fail=1

# --- M14: a header-only (zero-entry) index is cold, not an over-claimed warm
# "warm" for a cache that cannot hit a single row is the same over-claim as a
# PASS for a check that never ran.
IDX_M14="$TEST_HOME/.cache_m14/claude-helpers/titles.tsv"
mkdir -p "$(dirname "$IDX_M14")"
printf '#v1 %s\n' "$(date +%s)" > "$IDX_M14"
assert_eq "$(_ti_probe_state "$IDX_M14")" "cold" \
  "a header-only index with zero entries reports cold, not warm" || fail=1

# --- M12: the window is bounded by CHAT_LIMIT, not unbounded ---------------
sids_over=""
for ((i=0; i<205; i++)); do sids_over+="cap-sid-$i,"; done
sids_over="${sids_over%,}"
out_cap="$("$CS" _titles --json --account=default --sids="$sids_over" 2>/dev/null)"
assert_eq "$(jq '.items | length' <<<"$out_cap")" "200" \
  "a window requesting more than CHAT_LIMIT (default 200) sids is capped at 200" || fail=1

# --- M13: a sid containing a glob character must not be shell-expanded ----
# `${SNAP_SIDS//,/ }` unquoted (the old dispatch line) is word-split AND
# glob-expanded — this string comes straight off a `--sids=` CLI flag, so a
# requested "sid" of `evil-*` would expand against files in the CURRENT
# WORKING DIRECTORY before `_titles_window` ever saw it, silently replacing
# one requested (nonsense) sid with whatever real filename happened to match.
mkdir -p "$TEST_HOME/glob-cwd"
touch "$TEST_HOME/glob-cwd/evil-decoy.jsonl"
out_m13="$( cd "$TEST_HOME/glob-cwd" && "$CS" _titles --json --account=default --sids='evil-*' 2>/dev/null )"
assert_eq "$(jq '.items | length' <<<"$out_m13")" "1" \
  "a sid containing '*' is not glob-expanded into multiple requested sids" || fail=1
assert_eq "$(jq -r '.items[0].sessionId' <<<"$out_m13")" "evil-*" \
  "...the literal sid string reaches _titles_window unchanged" || fail=1
assert_eq "$(jq -r '.items[0].title.state' <<<"$out_m13")" "unknown" \
  "...and resolves to a genuine miss, never some unrelated decoy file's title" || fail=1

# --- regression: window cost must scale with the WINDOW, not the INDEX -----
# Before the C1 fix, `_titles_window`'s per-sid loop ran FOUR command
# substitutions per requested sid even when the index was 100% warm:
# `_transcript_for_sid` (a `find` fork), `_file_mtime` (itself `_compat_os`
# -> `uname`, then `stat`) and `wc -c` — plus a `rows+="$(printf ...)"` fork
# per row in the second loop. Measured via the real CLI in a hermetic fake
# HOME, index 100% warm (zero transcript reads, one awk fork), account with
# 6,810 real transcript files (the reference host's actual count):
#   1 sid:    54 ms
#   50 sids:  766 ms   (budget: 400ms)
#   200 sids: 3936 ms  (budget: 400ms)
# After the fix (sid->path resolved for the whole window in one glob pass,
# mtime+size for the whole window in one `stat` call, rows built with inline
# concatenation — see lib/titleindex.sh's _titles_window), the same
# measurement:
#   1 sid:    53-63 ms
#   50 sids:  126-134 ms
#   200 sids: 184-189 ms
# comfortably inside the 400ms poll budget with an order of magnitude to
# spare. This fixture is much smaller than 6,810 real transcripts, so the
# assertions below use wide budgets (CI-noise headroom) that are still well
# under the pre-fix numbers above — a regression back to per-row forking
# would blow through them, a correctly-scaling implementation will not.
#
# Separately, an enlarged INDEX (not account) — this test already warmed
# $IDX via --rebuild above (real fixture titles at the front, so a
# correctness check rides along for free); append 5,200 synthetic lines
# (s-N is synthetic, no real paths/session ids, per repo policy) — exercises
# _ti_lookup_window's own "one awk pass over the index" cost independent of
# the window/account-size cost above.
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

# 50-sid and 200-sid (CHAT_LIMIT's default) windows against real transcripts —
# the shape C1 was actually about: warm-window latency scaling with the
# WINDOW, not the account. A throwaway warm-up pass resolves every sid into
# the index (real cache-miss cost, not measured); the SECOND pass measures a
# 100%-warm window, exactly as the finding's own methodology does.
_make_window_sids() {  # prefix count acct_dir cwd -> prints "sid1,sid2,..." and creates fixtures
  local prefix="$1" count="$2" acct_dir="$3" cwd="$4" i sids=""
  for ((i=0; i<count; i++)); do
    fake_transcript "$acct_dir" "$cwd" "$prefix-$i" '{"type":"last-prompt","lastPrompt":"w"}' >/dev/null
    sids+="$prefix-$i,"
  done
  printf '%s' "${sids%,}"
}
sids_50="$(_make_window_sids sid-w 50 "$HOME/.claude" "$HOME/winproj50")"
sids_200="$(_make_window_sids sid-x 200 "$HOME/.claude" "$HOME/winproj200")"

"$CS" _titles --json --account=default --sids="$sids_50"  >/dev/null 2>&1   # warm-up
"$CS" _titles --json --account=default --sids="$sids_200" >/dev/null 2>&1   # warm-up

t0_50="$(_now_ms)"; "$CS" _titles --json --account=default --sids="$sids_50" >/dev/null 2>&1; e50=$(( $(_now_ms) - t0_50 ))
if (( e50 <= 600 )); then
  echo "PASS: a warm 50-sid window completes within budget (${e50}ms <= 600ms; pre-fix was 766ms)"
else
  echo "FAIL: a warm 50-sid window took ${e50}ms — budget is 600ms (pre-fix was 766ms)" >&2
  fail=1
fi

t0_200="$(_now_ms)"; "$CS" _titles --json --account=default --sids="$sids_200" >/dev/null 2>&1; e200=$(( $(_now_ms) - t0_200 ))
if (( e200 <= 900 )); then
  echo "PASS: a warm 200-sid (CHAT_LIMIT default) window completes within budget (${e200}ms <= 900ms; pre-fix was 3936ms)"
else
  echo "FAIL: a warm 200-sid window took ${e200}ms — budget is 900ms (pre-fix was 3936ms)" >&2
  fail=1
fi

exit "$fail"
