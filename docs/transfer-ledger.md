# Transfer and the ledger

**Problem:** once you have more than one account (see
[accounts.md](accounts.md)), you eventually start a chat under the wrong
one — or need to hand a chat off from a personal account to a work account,
or back. Claude Code has no built-in way to move a conversation between
config directories. `claude-session transfer` does that on disk, and every
move is recorded in an append-only ledger so it can be inspected, undone, or
redone later — nothing about it is a one-way, unrecorded operation.

## What moves

A chat is two things on disk, both under the account's `CLAUDE_CONFIG_DIR`:

```
projects/<encoded-cwd>/<sessionId>.jsonl   the transcript (required for --resume)
file-history/<sessionId>/                  its file-edit history (optional)
```

`transfer` copies (or, with `--move`, moves) both to the same relative path
under the destination account. The transcript alone is enough for
`claude --resume` to work — a missing file-history directory is not an
error, just a smaller transfer.

**`transfer` is a pure data operation.** It never touches tmux, never kills
a running process, and never launches Claude on its own (`--launch` is the
one exception — see below). Retiring the source session afterward is a
separate, deliberate `claude-session kill`.

## Basic usage

```bash
claude-session transfer --to=work                       # pick a chat interactively from the default account
claude-session transfer <sessionId> --to=work            # transfer a specific chat, by id
claude-session transfer <sessionId> --to=work --from=personal
claude-session transfer <sessionId> --to=work --move      # move instead of copy
claude-session transfer <sessionId> --to=work --launch    # transfer, then reopen it resumed under work
```

Omitting the session id opens a picker over the source account's chats
across every project (50 most recent by default; `--limit=0` shows all,
`--limit=N` any other cap). The picker uses `fzf` if it's installed, with a
live preview of the chat's title and recent turns; otherwise a plain numbered
menu with `p<N>` to preview.

## The ledger

Every completed transfer, undo, and redo appends one JSON line to
`~/.config/claude-helpers/transfer-log.jsonl` (override with `LEDGER_FILE`):

```json
{"id":"7c78ba","ts":1753567500,"sid":"dbb7ea9b-...","title":"Fix the retry handler",
 "from":"work","to":"default","verb":"copy","undoOf":null,"redoOf":null}
```

The record is written **before** the source file is touched — the
"durability gate": if the ledger write fails, `transfer` aborts and nothing
on disk has changed. This ordering exists specifically so a half-completed
transfer can never happen silently.

```bash
claude-session transfer log                              # recent history
claude-session transfer log --from=work --to=default      # filter by account pair
claude-session transfer log --sid=dbb7ea9b --limit=10      # filter by chat / cap rows
claude-session transfer undo                              # reverse the most recent transfer
claude-session transfer undo <sid-or-id>                  # reverse a specific one
claude-session transfer redo <id>                          # re-apply a logged transfer
claude-session transfer prune <id>                          # drop a ledger record (chat data untouched)
```

`undo` reverses a `move` by moving the file back, or reverses a `copy` by
deleting the destination copy — either way it writes its own new ledger
entry rather than erasing history. `prune` only removes the ledger's
record of an entry; it never touches the chat data itself, so pruning is
safe bookkeeping, not data deletion.

## Guards

Three independent checks run before anything is written, so re-running the
same `transfer` by habit (or by muscle memory after a `--move`) doesn't
quietly clobber something:

- **Duplicate guard** — if the ledger already shows this same chat
  transferred to this same destination, `transfer` refuses and tells you
  when the prior transfer happened. `--force` overrides it.
- **Round-trip guard** — if the ledger shows the chat came from the
  destination account originally (A → B, now B → A again), `transfer` asks
  for interactive confirmation (or refuses outright on a non-interactive
  stdin, where there's no one to ask) rather than silently bouncing it back.
- **Never-clobber backstop** — regardless of what the ledger does or
  doesn't know (a pruned entry, a manually-placed file, no ledger yet at
  all), `transfer` refuses to overwrite an existing destination transcript
  without `--force`. This is the backstop that holds even when the smarter,
  ledger-aware guards above have nothing to say.

## The `⇄ from` badge

`ls` and `resume` tag any chat that arrived via `transfer` with a small
badge, resolved from the ledger's newest inbound record for that
`(sessionId, account)` pair:

```
myproject-claude  pid 12345  310MB  ~/myproject
Chat title here   ⇄ from personal · Jul26
```

It's provenance, not a guess — the badge only appears because the ledger
recorded the move, so it always names the actual source account and date.

## `--move` and `--launch` together

`--move --launch` is the "I'm done with this account, hand it off" pattern:
it moves both the transcript and file-history, then immediately reopens the
chat resumed under the destination account (skipping the extra
`claude-session <project> --resume <sid>` step). The source session, if one
is still running in tmux, is left alone — closing it out is still a
separate `claude-session kill`, by design, since `transfer` never touches
tmux itself.
