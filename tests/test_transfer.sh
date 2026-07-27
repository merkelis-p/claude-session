#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$0")/harness.sh"
setup_fake_home
trap teardown_fake_home EXIT
fail=0

mkdir -p "$HOME/.config/claude-helpers"
cat > "$HOME/.config/claude-helpers/accounts.conf" <<EOF
account work $HOME/.claude-accounts/work 'Work account'
account personal $HOME/.claude-accounts/personal 'Second account'
EOF
mkdir -p "$HOME/.claude-accounts/work" "$HOME/.claude-accounts/personal"

SRC="$HOME/.claude-accounts/work"
DST="$HOME/.claude"
SLUG="-home-user-demo"
SID="aaaaaaaa-1111-2222-3333-444444444444"

# A transcript in the source account, plus its file-history sidecar.
seed_transcript() {
  local acct="$1" slug="$2" sid="$3"
  mkdir -p "$acct/projects/$slug" "$acct/file-history/$sid"
  printf '{"type":"ai-title","aiTitle":"Demo chat to transfer"}\n' > "$acct/projects/$slug/$sid.jsonl"
  printf 'edit-record\n' > "$acct/file-history/$sid/edit-1.json"
}
seed_transcript "$SRC" "$SLUG" "$SID"

# ---- validation ------------------------------------------------------------
out="$("$CS" transfer "$SID" 2>&1)"; rc=$?
assert_contains "$out" "--to" "transfer: --to is required" || fail=1
assert_eq "$rc" "2" "transfer: missing --to exits 2" || fail=1

out="$("$CS" transfer "$SID" --to=work --from=work 2>&1)"; rc=$?
assert_contains "$out" "must differ" "transfer: --to must differ from --from" || fail=1
assert_eq "$rc" "2" "transfer: same source and destination exits 2" || fail=1

out="$("$CS" transfer "$SID" --to=nosuchacct 2>&1)"; rc=$?
assert_contains "$out" "unknown account" "transfer: unknown --to rejected" || fail=1
assert_eq "$rc" "2" "transfer: unknown --to exits 2" || fail=1

out="$("$CS" transfer "$SID" --to=default --from=nosuchacct 2>&1)"; rc=$?
assert_contains "$out" "unknown account" "transfer: unknown --from rejected" || fail=1

out="$("$CS" transfer "does-not-exist" --to=default --from=work 2>&1)"; rc=$?
assert_contains "$out" "no transcript" "transfer: unknown sessionId reports no transcript" || fail=1
assert_eq "$rc" "1" "transfer: unknown sessionId exits 1" || fail=1

# ---- copy (the default) ----------------------------------------------------
out="$("$CS" transfer "$SID" --to=default --from=work 2>&1)"; rc=$?
assert_eq "$rc" "0" "transfer: copy succeeds" || fail=1
[[ -f "$DST/projects/$SLUG/$SID.jsonl" ]] \
  && echo "PASS: transfer: transcript landed in destination account" \
  || { echo "FAIL: transfer: transcript missing at $DST/projects/$SLUG/$SID.jsonl" >&2; fail=1; }
[[ -f "$DST/file-history/$SID/edit-1.json" ]] \
  && echo "PASS: transfer: file-history landed in destination account" \
  || { echo "FAIL: transfer: file-history missing at destination" >&2; fail=1; }
[[ -f "$SRC/projects/$SLUG/$SID.jsonl" ]] \
  && echo "PASS: transfer: copy leaves the source transcript intact" \
  || { echo "FAIL: transfer: copy destroyed the source transcript" >&2; fail=1; }
[[ -f "$SRC/file-history/$SID/edit-1.json" ]] \
  && echo "PASS: transfer: copy leaves the source file-history intact" \
  || { echo "FAIL: transfer: copy destroyed the source file-history" >&2; fail=1; }

# Destination path and the exact next step are both printed.
assert_contains "$out" ".claude/projects/$SLUG" "transfer: prints the destination project path" || fail=1
# The next-step hint must be ONE copy-pasteable command that opens a session
# under the destination account AND resumes this chat in it (native --resume
# pass-through) — not a multi-step "launch, then /resume inside Claude" dance.
# Destination here is `default`, so the hint omits a redundant --account=default.
assert_contains "$out" "claude-session --resume $SID" \
  "transfer: prints a single command that opens a session and resumes the chat" || fail=1
assert_not_contains "$out" "then /resume" \
  "transfer: no longer tells the user to run /resume as a separate step" || fail=1

# ---- overwrite guard -------------------------------------------------------
out="$("$CS" transfer "$SID" --to=default --from=work 2>&1)"; rc=$?
assert_contains "$out" "already exists" "transfer: refuses to overwrite an existing transcript" || fail=1
assert_contains "$out" "--force" "transfer: overwrite refusal names --force" || fail=1
assert_eq "$rc" "2" "transfer: overwrite refusal exits 2" || fail=1

printf 'stale\n' > "$DST/projects/$SLUG/$SID.jsonl"
out="$("$CS" transfer "$SID" --to=default --from=work --force 2>&1)"; rc=$?
assert_eq "$rc" "0" "transfer: --force overwrites" || fail=1
assert_contains "$(cat "$DST/projects/$SLUG/$SID.jsonl")" "Demo chat to transfer" \
  "transfer: --force actually replaced the destination transcript" || fail=1

# ---- move ------------------------------------------------------------------
SID2="bbbbbbbb-1111-2222-3333-444444444444"
seed_transcript "$SRC" "$SLUG" "$SID2"
out="$("$CS" transfer "$SID2" --to=personal --from=work --move 2>&1)"; rc=$?
assert_eq "$rc" "0" "transfer: --move succeeds" || fail=1
[[ -f "$HOME/.claude-accounts/personal/projects/$SLUG/$SID2.jsonl" ]] \
  && echo "PASS: transfer: --move lands the transcript at the destination" \
  || { echo "FAIL: transfer: --move did not land the transcript" >&2; fail=1; }
[[ ! -e "$SRC/projects/$SLUG/$SID2.jsonl" ]] \
  && echo "PASS: transfer: --move removes the source transcript" \
  || { echo "FAIL: transfer: --move left the source transcript behind" >&2; fail=1; }
[[ ! -e "$SRC/file-history/$SID2" ]] \
  && echo "PASS: transfer: --move removes the source file-history" \
  || { echo "FAIL: transfer: --move left the source file-history behind" >&2; fail=1; }

# ---- transcript with no file-history sidecar -------------------------------
SID3="cccccccc-1111-2222-3333-444444444444"
mkdir -p "$SRC/projects/$SLUG"
printf '{"type":"ai-title","aiTitle":"No history"}\n' > "$SRC/projects/$SLUG/$SID3.jsonl"
out="$("$CS" transfer "$SID3" --to=personal --from=work 2>&1)"; rc=$?
assert_eq "$rc" "0" "transfer: transcript without file-history still transfers" || fail=1
[[ -f "$HOME/.claude-accounts/personal/projects/$SLUG/$SID3.jsonl" ]] \
  && echo "PASS: transfer: no-file-history transcript landed" \
  || { echo "FAIL: transfer: no-file-history transcript missing" >&2; fail=1; }

# ---- picker needs a terminal ------------------------------------------------
out="$("$CS" transfer --to=default --from=work 2>&1 </dev/null)"; rc=$?
assert_contains "$out" "sessionId" "transfer: no-sessionId without a tty asks for an explicit sessionId" || fail=1

# ---- --limit validation -----------------------------------------------------
out="$("$CS" transfer --to=default --from=work --limit=abc 2>&1 </dev/null)"; rc=$?
assert_contains "$out" "--limit must be" "transfer: non-numeric --limit rejected" || fail=1
assert_eq "$rc" "2" "transfer: non-numeric --limit exits 2" || fail=1

# ---- empty source account ---------------------------------------------------
mkdir -p "$HOME/.claude-accounts/empty"
cat >> "$HOME/.config/claude-helpers/accounts.conf" <<EOF
account empty $HOME/.claude-accounts/empty 'Empty account'
EOF
out="$("$CS" transfer --to=default --from=empty 2>&1 </dev/null)"; rc=$?
assert_contains "$out" "no chats found" "transfer: empty source account reports no chats" || fail=1
assert_eq "$rc" "0" "transfer: empty source account is not an error" || fail=1

# ---- it is a pure data operation -------------------------------------------
# The design's load-bearing promise: transfer moves bytes, nothing else. Assert
# against the function body so a future edit that reaches for tmux trips this.
# cmd_transfer lives in ledger.sh (split out of the entrypoint) — inspect it there.
LEDGER_SRC="$HELPERS_LIB_SRC/ledger.sh"
body="$(awk '/^cmd_transfer\(\) \{/{c=1} c{print} c&&/^\}/{exit}' "$LEDGER_SRC")"
assert_contains "$body" "cmd_transfer" "transfer: located cmd_transfer body for inspection" || fail=1
assert_not_contains "$body" "tmux" "transfer: cmd_transfer never touches tmux" || fail=1
# Naming `claude-session kill` in the advisory text is intended; *performing* a
# kill is not. Match the operations, not the word.
assert_not_contains "$body" "kill-session" "transfer: cmd_transfer never kills a tmux session" || fail=1
assert_not_contains "$body" "kill -" "transfer: cmd_transfer never signals a process" || fail=1

exit "$fail"
