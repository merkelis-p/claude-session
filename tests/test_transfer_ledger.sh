#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$0")/harness.sh"
setup_fake_home
trap teardown_fake_home EXIT
fail=0

mkdir -p "$HOME/.config/claude-helpers"
cat > "$HOME/.config/claude-helpers/accounts.conf" <<EOF
account work $HOME/.claude-accounts/work ''
EOF
mkdir -p "$HOME/.claude-accounts/work"
export LEDGER_FILE="$HOME/.config/claude-helpers/transfer-log.jsonl"
PROJ="$HOME/proj"; mkdir -p "$PROJ"
# The on-disk project slug is the cwd with /._  -> -. Under the harness's fake
# (mktemp-based) $HOME this is NOT "-home-proj" (that only holds for a real
# /home/<user> $HOME) — compute it for real so the path assertions below check
# the actual landing spot instead of coincidentally matching a wrong literal.
ENC_PROJ="$(sed 's#[/._]#-#g' <<<"$PROJ")"

mk_src() { # sid title  -> a transcript in the work account
  fake_transcript "$HOME/.claude-accounts/work" "$PROJ" "$1" \
    "{\"cwd\":\"$PROJ\"}" "{\"type\":\"ai-title\",\"aiTitle\":\"$2\"}" >/dev/null
}

# (1) move writes a ledger entry and removes the source
mk_src sid-move "Movable Chat"
"$CS" transfer sid-move --to=default --from=work --move --plain >/dev/null 2>&1
assert_contains "$(cat "$LEDGER_FILE")" '"sid":"sid-move"' "move logged to ledger" || fail=1
test -f "$HOME/.claude/projects/$ENC_PROJ/sid-move.jsonl"; assert_eq "$?" "0" "dest transcript present after move" || fail=1
test -e "$HOME/.claude-accounts/work/projects/$ENC_PROJ/sid-move.jsonl"; assert_eq "$?" "1" "source gone after move" || fail=1

# (2) transfer log shows it
out="$("$CS" transfer log 2>&1)"
assert_contains "$out" "work → default" "log renders direction" || fail=1
assert_contains "$out" "Movable Chat" "log renders title" || fail=1

# (3) durability: an unwritable ledger aborts the move, source intact
mk_src sid-dur "Durable"
( export LEDGER_FILE="$HOME/.claude/is-a-file/log.jsonl"; : > "$HOME/.claude/is-a-file" 2>/dev/null; \
  touch "$HOME/.claude/is-a-file"; "$CS" transfer sid-dur --to=default --from=work --move --plain ) >/dev/null 2>&1
test -e "$HOME/.claude-accounts/work/projects/$ENC_PROJ/sid-dur.jsonl"; assert_eq "$?" "0" "source intact when ledger write fails" || fail=1

# (4) duplicate guard refuses re-copy without --force
mk_src sid-dup "Dup"
"$CS" transfer sid-dup --to=default --from=work --plain >/dev/null 2>&1   # copy #1
err="$("$CS" transfer sid-dup --to=default --from=work --plain 2>&1)"      # copy #2
assert_contains "$err" "refusing to duplicate" "duplicate re-copy refused without --force" || fail=1

# (5) undo reverses a move (restores to source)
mk_src sid-undo "Undoable"
"$CS" transfer sid-undo --to=default --from=work --move --plain >/dev/null 2>&1
"$CS" transfer undo sid-undo --force >/dev/null 2>&1
test -f "$HOME/.claude-accounts/work/projects/$ENC_PROJ/sid-undo.jsonl"; assert_eq "$?" "0" "undo restores the moved chat to source" || fail=1
test -e "$HOME/.claude/projects/$ENC_PROJ/sid-undo.jsonl"; assert_eq "$?" "1" "undo removes the dest copy" || fail=1

# (5b) closed hole: after a copy, pruning its ledger entry must NOT reopen the
# never-clobber invariant. Use a sid with no file-history so that (untouched)
# check can't mask this — this is testing the ledger/backstop path specifically.
mk_src sid-hole "Hole"
"$CS" transfer sid-hole --to=default --from=work --plain >/dev/null 2>&1
hid="$(jq -r 'select(.sid=="sid-hole")|.id' "$LEDGER_FILE" | tail -1)"
"$CS" transfer prune "$hid" --force >/dev/null 2>&1
dst_hole="$HOME/.claude/projects/$ENC_PROJ/sid-hole.jsonl"
before="$(cat "$dst_hole")"
err="$("$CS" transfer sid-hole --to=default --from=work --plain 2>&1)"; rc=$?
assert_contains "$err" "already exists" "post-prune re-copy without --force is refused" || fail=1
[[ "$rc" -ne 0 ]]; assert_eq "$?" "0" "post-prune re-copy without --force exits non-zero" || fail=1
after="$(cat "$dst_hole")"
[[ "$after" == "$before" ]]; assert_eq "$?" "0" "post-prune re-copy without --force leaves dst transcript unchanged" || fail=1

# (6) prune removes a ledger record but not chat data
mk_src sid-prune "Prunable"
"$CS" transfer sid-prune --to=default --from=work --plain >/dev/null 2>&1
pid_line="$(jq -r 'select(.sid=="sid-prune")|.id' "$LEDGER_FILE" | tail -1)"
"$CS" transfer prune "$pid_line" --force >/dev/null 2>&1
assert_not_contains "$(cat "$LEDGER_FILE")" '"sid":"sid-prune"' "prune drops the ledger record" || fail=1
test -f "$HOME/.claude/projects/$ENC_PROJ/sid-prune.jsonl"; assert_eq "$?" "0" "prune leaves chat data untouched" || fail=1

# (7) badge: a transferred-in live session shows the '⇄ from' badge in ls
mk_src sid-badge "Badged"
"$CS" transfer sid-badge --to=default --from=work --move --plain >/dev/null 2>&1
fake_session "$HOME/.claude" "$PROJ" "" "sid-badge" >/dev/null
out="$("$CS" ls 2>&1)"
assert_contains "$out" "from work" "ls badges a transferred-in live session" || fail=1

# (8) a non-transferred live session gets no badge
fake_session "$HOME/.claude" "$PROJ" "" "sid-plain" >/dev/null
fake_transcript "$HOME/.claude" "$PROJ" "sid-plain" '{"type":"ai-title","aiTitle":"Plain"}' >/dev/null
card="$(awk '/sid-plain|Plain/{c=1} c{print} c&&/^$/{exit}' <<<"$out")"
assert_not_contains "$("$CS" ls 2>&1 | awk '/Plain/{print}')" "from work" "non-transferred session is not badged" || fail=1

# (9) redo re-applies a logged transfer (move) after undo
mk_src sid-redo "Redoable"
"$CS" transfer sid-redo --to=default --from=work --move --plain >/dev/null 2>&1
rid="$(jq -r 'select(.sid=="sid-redo")|.id' "$LEDGER_FILE" | tail -1)"
"$CS" transfer undo sid-redo --force >/dev/null 2>&1
test -f "$HOME/.claude-accounts/work/projects/$ENC_PROJ/sid-redo.jsonl"; assert_eq "$?" "0" "redo setup: undo restores chat to work" || fail=1
test -e "$HOME/.claude/projects/$ENC_PROJ/sid-redo.jsonl"; assert_eq "$?" "1" "redo setup: undo removes dest copy" || fail=1
"$CS" transfer redo "$rid" --force >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "redo exits 0" || fail=1
test -f "$HOME/.claude/projects/$ENC_PROJ/sid-redo.jsonl"; assert_eq "$?" "0" "redo lands the chat back at the default account" || fail=1
test -e "$HOME/.claude-accounts/work/projects/$ENC_PROJ/sid-redo.jsonl"; assert_eq "$?" "1" "redo removes it from the work account again" || fail=1
jq -e 'select(.redoOf != null)' "$LEDGER_FILE" >/dev/null 2>&1; assert_eq "$?" "0" "ledger records a redoOf entry" || fail=1

exit "$fail"
