#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$0")/harness.sh"
fail=0
# $HELPERS_LIB_SRC (resolved by harness.sh next to $CS) rather than a bare
# "$(dirname "$0")/.." guess: the latter matches the flat live-install layout
# (tests/ under the same dir as compat.sh) but not the packaged repo's sibling
# bin/lib/tests layout, where tests/.. is the repo root, not lib/.
# shellcheck source=/dev/null
. "$HELPERS_LIB_SRC/compat.sh"

# --- process wrappers (branch-free) ---
_proc_alive "$$" && echo "PASS: _proc_alive true for self" || { echo "FAIL: _proc_alive self" >&2; fail=1; }
sleep 0.1 & p=$!; wait "$p" 2>/dev/null
_proc_alive "$p" && { echo "FAIL: _proc_alive true for reaped pid" >&2; fail=1; } || echo "PASS: _proc_alive false for dead pid"
c="$(_proc_comm "$$")"; [[ -n "$c" ]] && echo "PASS: _proc_comm non-empty ($c)" || { echo "FAIL: _proc_comm empty" >&2; fail=1; }
a="$(_proc_args "$$")"; [[ -n "$a" ]] && echo "PASS: _proc_args non-empty" || { echo "FAIL: _proc_args empty" >&2; fail=1; }
u="$(_proc_owner_uid "$$")"; assert_eq "$u" "$(id -u)" "_proc_owner_uid matches id -u" || fail=1
e="$(_proc_elapsed_s "$$")"; [[ "$e" =~ ^[0-9]+$ ]] && echo "PASS: _proc_elapsed_s numeric ($e)" || { echo "FAIL: _proc_elapsed_s not numeric: $e" >&2; fail=1; }

# etime parser: exercise every shape
assert_eq "$(_etime_to_s '05')"          "5"       "_etime_to_s ss" || fail=1
assert_eq "$(_etime_to_s '01:05')"       "65"      "_etime_to_s mm:ss" || fail=1
assert_eq "$(_etime_to_s '02:01:05')"    "7265"    "_etime_to_s hh:mm:ss" || fail=1
assert_eq "$(_etime_to_s '1-02:01:05')"  "93665"   "_etime_to_s dd-hh:mm:ss" || fail=1

# --- _proc_table shape: 6 tab-separated fields, numeric pid/ppid/etimes ---
row="$(_proc_table | head -1)"
n="$(awk -F'\t' '{print NF}' <<<"$row")"; assert_eq "$n" "6" "_proc_table emits 6 TSV fields" || fail=1
awk -F'\t' '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ {ok=1} END{exit !ok}' <<<"$row" \
  && echo "PASS: _proc_table pid/ppid/etimes numeric" || { echo "FAIL: _proc_table numeric fields" >&2; fail=1; }
# Capture first, then match: `_proc_table | grep -q` races under `pipefail` —
# grep exits on the first match, the producer's next write dies with SIGPIPE, and
# pipefail reports that as failure even though the match was found.
_pt="$(_proc_table)"
grep -q "^$$"$'\t' <<<"$_pt" && echo "PASS: _proc_table contains self" || { echo "FAIL: _proc_table missing self" >&2; fail=1; }

# --- file mtime ---
t="$(mktemp)"; touch "$t"; m="$(_file_mtime "$t")"
[[ "$m" =~ ^[0-9]+$ ]] && (( m > 0 )) && echo "PASS: _file_mtime numeric" || { echo "FAIL: _file_mtime: $m" >&2; fail=1; }
(( m >= $(date +%s) - 10 )) && echo "PASS: _file_mtime is recent" || { echo "FAIL: _file_mtime stale" >&2; fail=1; }
_file_mtime "$t.nope" 2>/dev/null && { echo "FAIL: _file_mtime succeeded on missing file" >&2; fail=1; } || echo "PASS: _file_mtime fails loudly on missing file"
rm -f "$t"

# --- date wrappers ---
now="$(date +%s)"
h="$(_epoch_to_human "$now" '+%Y-%m-%d')"; assert_eq "$h" "$(date -d "@$now" '+%Y-%m-%d' 2>/dev/null || date -r "$now" '+%Y-%m-%d')" "_epoch_to_human matches native" || fail=1
back="$(_parse_datetime "$(_epoch_to_human "$now" '+%Y-%m-%d %H:%M:%S')")"
assert_eq "$back" "$now" "_parse_datetime round-trips _epoch_to_human" || fail=1
nc="$(_next_clock_epoch '03:30')"
[[ "$nc" =~ ^[0-9]+$ ]] && (( nc > now && nc <= now + 86400 )) && echo "PASS: _next_clock_epoch within 24h future" || { echo "FAIL: _next_clock_epoch: $nc" >&2; fail=1; }
_parse_datetime 'not a date' 2>/dev/null && { echo "FAIL: _parse_datetime accepted garbage" >&2; fail=1; } || echo "PASS: _parse_datetime rejects garbage"

# --- readlink -f equivalent ---
d="$(mktemp -d)"; echo x > "$d/real"; ln -s "$d/real" "$d/l1"; ln -s "$d/l1" "$d/l2"
assert_eq "$(_readlink_f "$d/l2")" "$d/real" "_readlink_f resolves a symlink chain" || fail=1
rm -rf "$d"

# --- reverse lines (tac replacement) ---
assert_eq "$(printf 'a\nb\nc\n' | _reverse_lines | tr '\n' ' ')" "c b a " "_reverse_lines reverses" || fail=1

# --- os detection honors override (lets the suite drive the macOS branch) ---
assert_eq "$(CLAUDE_COMPAT_OS=darwin _compat_os)" "darwin" "_compat_os honors CLAUDE_COMPAT_OS" || fail=1
assert_eq "$(CLAUDE_COMPAT_OS=linux  _compat_os)" "linux"  "_compat_os honors linux override" || fail=1

# --- darwin-branch argument shapes, exercised on this Linux host via recording
# stat/date stubs on PATH (no real macOS needed). CLAUDE_COMPAT_OS drives which
# branch compat.sh takes; the stub just records argv so we can assert on it. ---
STUB_BIN="$(mktemp -d)"
STAT_CALLS="$STUB_BIN/.stat_calls"; : > "$STAT_CALLS"
DATE_CALLS="$STUB_BIN/.date_calls"; : > "$DATE_CALLS"

cat > "$STUB_BIN/stat" <<'STAT_STUB'
#!/usr/bin/env bash
echo "$@" >> "${STAT_CALLS:?}"
echo 1700000000
STAT_STUB
chmod +x "$STUB_BIN/stat"

cat > "$STUB_BIN/date" <<'DATE_STUB'
#!/usr/bin/env bash
echo "$@" >> "${DATE_CALLS:?}"
case "$*" in
  *+%s*) echo 1700000000 ;;
  *)     echo 2023-11-14 ;;
esac
DATE_STUB
chmod +x "$STUB_BIN/date"

f_stub="$STUB_BIN/f"; touch "$f_stub"

: > "$STAT_CALLS"; : > "$DATE_CALLS"
( export PATH="$STUB_BIN:$PATH" STAT_CALLS DATE_CALLS CLAUDE_COMPAT_OS=darwin
  _file_mtime "$f_stub" >/dev/null
  _epoch_to_human 1700000000 '+%Y-%m-%d' >/dev/null
  _parse_datetime '2023-11-14 10:00:00' >/dev/null
)
assert_contains "$(cat "$STAT_CALLS")" "-f %m" "darwin: _file_mtime invokes BSD stat -f %m" || fail=1
assert_contains "$(cat "$DATE_CALLS")" "-r 1700000000" "darwin: _epoch_to_human invokes BSD date -r <epoch>" || fail=1
assert_contains "$(cat "$DATE_CALLS")" "-j -f" "darwin: _parse_datetime invokes BSD date -j -f ..." || fail=1

: > "$STAT_CALLS"; : > "$DATE_CALLS"
( export PATH="$STUB_BIN:$PATH" STAT_CALLS DATE_CALLS CLAUDE_COMPAT_OS=linux
  _file_mtime "$f_stub" >/dev/null
  _epoch_to_human 1700000000 '+%Y-%m-%d' >/dev/null
  _parse_datetime '2023-11-14 10:00:00' >/dev/null
)
assert_contains "$(cat "$STAT_CALLS")" "-c %Y" "linux: _file_mtime still invokes GNU stat -c %Y" || fail=1
assert_contains "$(cat "$DATE_CALLS")" "-d @1700000000" "linux: _epoch_to_human still invokes GNU date -d" || fail=1
assert_contains "$(cat "$DATE_CALLS")" "-d 2023-11-14 10:00:00" "linux: _parse_datetime still invokes GNU date -d" || fail=1

rm -rf "$STUB_BIN"

exit "$fail"
