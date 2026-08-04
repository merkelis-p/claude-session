# shellcheck shell=bash
# titles.sh — transcript → title / preview resolution for claude-session.
# Sourced by claude-session after ui.sh. Defines functions only; the entrypoint
# helpers these call at runtime (none currently) are available by dispatch time.

# (cwd, account config dir) -> its projects directory (Claude encodes /, ., _ as '-').
_proj_dir_for_cwd() {
  local cwd="$1" acct_dir="${2:-$HOME/.claude}"
  [[ -z "$cwd" || "$cwd" == "-" ]] && return
  printf '%s/projects/%s' "$acct_dir" "$(sed 's#[/._]#-#g' <<<"$cwd")"
}

# sessionIds currently owned by a live session-state file for one account (one per line).
_live_sids() {
  local acct_dir="${1:-$HOME/.claude}"
  shopt -s nullglob
  local -a files=("$acct_dir/sessions"/*.json)
  # nullglob makes this empty when there are no session files, and `jq` with no
  # file arguments reads STDIN — which would hang every caller.
  (( ${#files[@]} )) || return 0
  # One jq for all files instead of one per file. This was the single largest
  # cost in `claude-session ls`: 154 of the 188 remaining jq forks, because the
  # function is itself called several times per listing. Batching is what fixes
  # it — memoizing would not, since every caller invokes this inside `$(...)`,
  # and a cache built in that subshell dies with it.
  jq -rs '.[] | .sessionId // empty' "${files[@]}" 2>/dev/null && return 0
  # `jq -s` is all-or-nothing, so one torn write by Claude Code would blank the
  # whole account. Degrade to per-file so only the bad file is lost.
  local f
  for f in "${files[@]}"; do
    jq -r '.sessionId // empty' "$f" 2>/dev/null || true
  done
}

# Map a Claude sessionId -> its transcript .jsonl under <account>/projects/*/.
# Falls back to the newest transcript in the session's cwd that ISN'T owned by
# another live session — this recovers VS Code chats, whose live session-state
# sessionId differs from the transcript filename (the extension rotates the id),
# without ever stealing a CLI session's transcript.
_transcript_for_sid() {
  local sid="$1" cwd="${2:-}" acct_dir="${3:-$HOME/.claude}" hit dir live jf base
  if [[ -n "$sid" && "$sid" != "-" ]]; then
    # `|| true`: find gets SIGPIPE when head closes the pipe -> non-zero under pipefail.
    hit="$(find "$acct_dir/projects" -maxdepth 2 -name "$sid.jsonl" 2>/dev/null | head -1 || true)"
    if [[ -n "$hit" ]]; then echo "$hit"; return 0; fi
  fi
  dir="$(_proj_dir_for_cwd "$cwd" "$acct_dir")"
  [[ -n "$dir" && -d "$dir" ]] || return 0
  live="$(_live_sids "$acct_dir" || true)"
  while IFS= read -r jf; do
    [[ -z "$jf" ]] && continue
    base="$(basename "$jf" .jsonl)"
    if ! grep -qxF "$base" <<<"$live"; then echo "$jf"; return 0; fi  # not owned by a live session
  done < <(ls -t "$dir"/*.jsonl 2>/dev/null || true)
  return 0
}

# Human chat name: newest custom-title, else newest ai-title, else newest
# last-prompt, else "(untitled)". Delegates to _title_for_file for the one
# precedence implementation.
_title_for_sid() {
  local sid="$1" cwd="${2:-}" acct_dir="${3:-$HOME/.claude}" file
  file="$(_transcript_for_sid "$sid" "$cwd" "$acct_dir")"
  [[ -z "$file" ]] && { echo "(no transcript)"; return; }
  _title_for_file "$file"
}

# Rich preview for a sessionId: title, id, last prompt, last ~60 text turns.
_preview_for_sid() {
  local sid="$1" cwd="${2:-}" acct_dir="${3:-$HOME/.claude}" file title lastp width
  file="$(_transcript_for_sid "$sid" "$cwd" "$acct_dir")"
  if [[ -z "$file" ]]; then echo "(no transcript found for $sid)"; return; fi
  width="${FZF_PREVIEW_COLUMNS:-${COLUMNS:-100}}"
  local custom auto
  custom="$(grep '"type":"custom-title"' "$file" 2>/dev/null | tail -1 | jq -r '.customTitle // empty' 2>/dev/null || true)"
  auto="$(grep '"type":"ai-title"' "$file" 2>/dev/null | tail -1 | jq -r '.aiTitle // empty' 2>/dev/null || true)"
  title="${custom:-$auto}"
  lastp="$(grep '"type":"last-prompt"' "$file" 2>/dev/null | tail -1 | jq -r '.lastPrompt // empty' 2>/dev/null || true)"
  printf '%b%s%b\n' "$BOLD" "${title:-(untitled)}" "$N"
  printf '%b%s%b\n' "$DIM" "$sid" "$N"
  [[ -n "$custom" && -n "$auto" && "$custom" != "$auto" ]] && printf '%bauto:%b %s\n' "$DIM" "$N" "$auto"
  [[ -n "$lastp" ]] && printf '%b▸ last:%b %s\n' "$C" "$N" "$(truncate_str "$lastp" 240)"
  printf '%b──────────────── recent ────────────────%b\n' "$DIM" "$N"
  jq -r 'select(.type=="user" or .type=="assistant")
         | (.message.role // .type) as $r
         | (if (.message.content|type)=="string" then .message.content
            else ([.message.content[]? | select(.type=="text") | .text] | join("\n")) end) as $t
         | select($t != null and ($t|length) > 0)
         | (if $r=="user" then "[36m▌you[0m  " else "[33m▌claude[0m  " end) + $t' \
        "$file" 2>/dev/null \
    | tail -n 60 | fold -s -w "$width" || true
}

# Title straight from a known transcript path — skips the sessionId->file `find`
# that _title_for_sid does, which matters when listing every chat in an account.
# ai-title / last-prompt records are appended at the END of a transcript, so
# scanning the last 256KB finds them without reading multi-MB files whole (the
# default account is ~1.1GB across ~2200 transcripts). Verified tail-agrees-with-
# full-scan on 200 real transcripts, 200/200. Falls back to a full scan if the
# tail turns up nothing, so an oddly-shaped transcript still gets a title. The
# custom-title record was added later and shares the same end-of-file tail-scan
# shape as ai-title/last-prompt, so the 200/200 figure predates it but the same
# reasoning covers it.
_title_for_file() {
  local file="$1" chunk t
  [[ -f "$file" ]] || { echo "(no transcript)"; return; }
  chunk="$(tail -c 262144 "$file" 2>/dev/null || true)"
  t="$(grep '"type":"custom-title"' <<<"$chunk" | tail -1 | jq -r '.customTitle // empty' 2>/dev/null || true)"
  [[ -z "$t" ]] && t="$(grep '"type":"ai-title"' <<<"$chunk" | tail -1 | jq -r '.aiTitle // empty' 2>/dev/null || true)"
  [[ -z "$t" ]] && t="$(grep '"type":"last-prompt"' <<<"$chunk" | tail -1 | jq -r '.lastPrompt // empty' 2>/dev/null || true)"
  if [[ -z "$t" ]]; then
    t="$(grep '"type":"custom-title"' "$file" 2>/dev/null | tail -1 | jq -r '.customTitle // empty' 2>/dev/null || true)"
    [[ -z "$t" ]] && t="$(grep '"type":"ai-title"' "$file" 2>/dev/null | tail -1 | jq -r '.aiTitle // empty' 2>/dev/null || true)"
    [[ -z "$t" ]] && t="$(grep '"type":"last-prompt"' "$file" 2>/dev/null | tail -1 | jq -r '.lastPrompt // empty' 2>/dev/null || true)"
  fi
  echo "${t:-(untitled)}"
}

# Best-effort cwd recorded inside a transcript — the encoded project dir name is
# lossy (/, . and _ all become '-'), so read the real path back out of the file.
_cwd_in_transcript() {
  local file="$1" c
  c="$(head -200 "$file" 2>/dev/null | jq -r 'select(.cwd) | .cwd' 2>/dev/null | head -1 || true)"
  printf '%s' "$c"
}
