#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$0")/harness.sh"
setup_fake_home
trap teardown_fake_home EXIT
fail=0

PROJ="$HOME/proj-a"; mkdir -p "$PROJ"

# (1) custom-title beats ai-title beats last-prompt
p1="$(fake_session "$HOME/.claude" "$PROJ" "" "sid-custom")"
fake_transcript "$HOME/.claude" "$PROJ" "sid-custom" \
  '{"type":"last-prompt","lastPrompt":"do the thing"}' \
  '{"type":"ai-title","aiTitle":"Auto Generated Name"}' \
  '{"type":"custom-title","customTitle":"My Real Name","sessionId":"sid-custom"}' >/dev/null
out="$("$CS" ls 2>&1)"
assert_contains "$out" "My Real Name" "ls shows the custom title" || fail=1
assert_not_contains "$out" "Auto Generated Name" "ls hides the ai-title when a custom one exists" || fail=1

# (2) ai-title used when no custom-title
p2="$(fake_session "$HOME/.claude" "$PROJ" "" "sid-ai")"
fake_transcript "$HOME/.claude" "$PROJ" "sid-ai" \
  '{"type":"last-prompt","lastPrompt":"prompt only"}' \
  '{"type":"ai-title","aiTitle":"Only Auto"}' >/dev/null
out="$("$CS" ls 2>&1)"
assert_contains "$out" "Only Auto" "ls falls back to ai-title" || fail=1

# (3) last-prompt used when neither title exists
p3="$(fake_session "$HOME/.claude" "$PROJ" "" "sid-last")"
fake_transcript "$HOME/.claude" "$PROJ" "sid-last" \
  '{"type":"last-prompt","lastPrompt":"just a prompt"}' >/dev/null
out="$("$CS" ls 2>&1)"
assert_contains "$out" "just a prompt" "ls falls back to last-prompt" || fail=1

# (4) preview shows the custom name AND the auto: line
prev="$("$CS" _preview sid-custom "$PROJ" default 2>&1)"
assert_contains "$prev" "My Real Name" "preview heading is the custom name" || fail=1
assert_contains "$prev" "auto: Auto Generated Name" "preview also shows the auto title" || fail=1

# (5) preview for an ai-only chat shows no 'auto:' line
prev2="$("$CS" _preview sid-ai "$PROJ" default 2>&1)"
assert_not_contains "$prev2" "auto:" "no redundant auto: line when there is no custom title" || fail=1

exit "$fail"
