#!/usr/bin/env bash
# Width handling in ui.sh. There was no coverage here at all, which is how a
# box that visibly came apart on any long row shipped: box_line padded short
# content but never truncated long content, so the closing border was pushed
# past the frame edge.
#
# Sources the REAL ui.sh, not the harness stub (the stub replaces box_line with
# a plain echo, so it cannot see any of this).
set -uo pipefail
. "$(dirname "$0")/harness.sh"
fail=0
# shellcheck source=/dev/null
NO_COLOR=1 UI_W=40 . "$HELPERS_LIB_SRC/ui.sh"
UI_W=40

# Visible width of a rendered line, with ANSI stripped and Unicode counted as
# characters rather than bytes.
_w() { LC_ALL=C.UTF-8 awk '{ gsub(/\033\[[0-9;]*m/, ""); print length($0) }' <<<"$1"; }

# ---- short content still pads to exactly UI_W ------------------------------
assert_eq "$(_w "$(box_line "short")")" "40" "short line pads to UI_W" || fail=1

# ---- long content truncates instead of overflowing -------------------------
long="$(printf 'x%.0s' $(seq 1 200))"
out_long="$(box_line "$long")"
assert_eq "$(_w "$out_long")" "40" "a 200-char line is truncated to UI_W" || fail=1
[[ "$out_long" == *"…"* ]] \
  && echo "PASS: truncation is marked with an ellipsis" \
  || { echo "FAIL: truncated line has no ellipsis marker" >&2; fail=1; }

# The border must still close the line. This is the actual reported symptom:
# the trailing │ ended up past the frame.
[[ "$out_long" == *"│" ]] \
  && echo "PASS: the closing border is still the last character" \
  || { echo "FAIL: closing border missing or displaced" >&2; fail=1; }

# ---- boundary: exactly-fitting content must NOT be truncated ---------------
exact="$(printf 'y%.0s' $(seq 1 36))"      # UI_W - 4 == the inner width
out_exact="$(box_line "$exact")"
assert_eq "$(_w "$out_exact")" "40" "exactly-fitting content still renders at UI_W" || fail=1
[[ "$out_exact" != *"…"* ]] \
  && echo "PASS: exactly-fitting content is left intact (no needless ellipsis)" \
  || { echo "FAIL: content that fits was truncated anyway" >&2; fail=1; }

# ---- UTF-8 is counted as characters, not bytes -----------------------------
# Each of these is 3 bytes but 1 column. Counting bytes would truncate at a
# third of the real width and could cut mid-codepoint.
utf="$(printf '→%.0s' $(seq 1 100))"
out_utf="$(box_line "$utf")"
assert_eq "$(_w "$out_utf")" "40" "multibyte content truncates on character count" || fail=1

# ---- ANSI escapes are not charged against the width budget ----------------
# A colored line and a plain line with the same visible text must truncate to
# the same visible width; and the escapes must never be cut mid-sequence,
# which would leave the terminal stuck in that color.
plain="$(printf 'z%.0s' $(seq 1 100))"
colored="$(printf '\033[31mz\033[0m%.0s' $(seq 1 100))"
w_plain="$(_w "$(box_line "$plain")")"
w_colored="$(_w "$(box_line "$colored")")"
assert_eq "$w_colored" "$w_plain" "color does not change the truncation width" || fail=1
out_colored="$(box_line "$colored")"
[[ "$out_colored" != *$'\033'  && "$out_colored" != *$'\033['* || "$out_colored" == *$'\033[0m'* ]] \
  && echo "PASS: no dangling escape at the end of a truncated colored line" \
  || { echo "FAIL: truncated colored line ends mid-escape" >&2; fail=1; }

# ---- box_kv delegates to box_line, so it inherits the fix -----------------
out_kv="$(box_kv "key" "$long")"
assert_eq "$(_w "$out_kv")" "40" "box_kv also stays inside the frame" || fail=1

# ---- _vtrunc directly ------------------------------------------------------
assert_eq "$(_w "$(_vtrunc "$long" 10)")" "10" "_vtrunc honors an explicit max" || fail=1
# Content that already fits comes back byte-for-byte: no ellipsis, because
# nothing was cut. (Both this expectation and the implementation were wrong the
# first time — _vtrunc ellipsized unconditionally.)
assert_eq "$(_vtrunc "abc" 10)" "abc" "_vtrunc leaves fitting content untouched" || fail=1
assert_eq "$(_vtrunc "abcdef" 3)" "ab…" "_vtrunc reserves one column for the ellipsis" || fail=1

exit "$fail"
