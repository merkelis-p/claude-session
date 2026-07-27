# claude-session

Claude Code sessions die the moment your SSH connection, VS Code tunnel, or
phone browser tab drops. `claude-session` runs Claude Code inside `tmux`
instead, so the process keeps going no matter what disconnects — any client
(laptop, phone, a new SSH hop) reattaches to the exact same running chat. On
top of that durable anchor it adds the things that come up once you're
running more than one Claude session at a time: **multiple isolated
accounts**, **chat transfer between accounts with an audited ledger**,
**prompt scheduling** so Claude can run unattended on a timer, and a
**`doctor`** view that catches stuck sessions and — the reason it exists —
orphaned dev processes quietly burning CPU after a session got killed.

Version **0.1.0** — pre-1.0. The interface is stabilizing but may still
change; pin a commit if you need stability.

## `ls` at a glance

`claude-session ls` prints every session across every registered account as
boxed cards — pid, RAM, working directory, the chat's actual title (not a
UUID), Remote Control status, and how long ago it last updated:

```
╭─ Claude sessions ────────────────────────────────────────────────────────────╮
│ [1] ● myproject-claude  pid 12345  310MB  ~/myproject                        │
│     Add pagination to the search endpoint                                    │
│   entry cli           status idle                       RC ✓ 01AB2c3D4e5F…   │
│   updated 12m ago                                                             │
│                                                                                │
│ [2] ● api-service-claude-2  pid 12987  284MB  ~/api-service                   │
│     Debug flaky webhook retries   ⇄ from personal · Jul20                    │
│   entry cli           status busy                       RC ✓ 01Gh6I7j8K9L…    │
│   updated 2h ago                                                              │
│                                                                                │
│ [3] ● website-claude-work  pid 14210  256MB  ~/website  [work]                │
│     Rework the pricing page copy                                             │
│   entry cli           status waiting:approval            RC ✓ 01Mn2O3p4Q5R…   │
│   updated 6m ago                                                             │
╰────────────────────────────────────────────────────────────────────────────────╯
⚠ 1 warning(s) — run: claude-session doctor
```

Each card's second line is the chat's real title, resolved from the
transcript (custom title, else Claude's auto-title, else the last prompt).
The small `⇄ from personal · Jul20` badge means this chat arrived via
`transfer` — the ledger remembers where from. `[work]` tags a session running
under a non-default account. The `⚠ 1 warning(s)` footer is a hint to run
`claude-session doctor` (see [docs/doctor-orphans.md](docs/doctor-orphans.md)).

## 60-second quickstart

```bash
# from inside any project directory
claude-session                 # attach to (or start) <project>-claude

# from anywhere
claude-session myproject       # attach to (or start) myproject-claude
claude-session myproject new   # a second, independently-numbered session
claude-session ls              # list every session, every account
claude-session resume          # interactive picker (fzf if installed)
claude-session doctor          # health check: dupes, stalls, orphans, stuck builds
```

Detach from tmux as usual (`Ctrl-b d`); the Claude process keeps running.
Reattach later from any client with the same command.

## Install

```bash
git clone https://github.com/merkelis-p/claude-session.git
cd claude-session
./install.sh                   # installs to ~/.local by default
```

or the one-liner:

```bash
curl -fsSL https://raw.githubusercontent.com/<you>/claude-session/main/install.sh | bash
```

`install.sh` detects your platform, checks for `bash` 4+, `tmux`, `jq`, and
the other required tools, then copies (or `--link`s, for development)
`bin/` and `share/claude-helpers/` into `--prefix` (default `~/.local`) and
the man page into `<prefix>/share/man/man1/`. Run `./install.sh -h` for every
flag, or `./install.sh --dry-run` to preview without touching anything.
`./uninstall.sh` removes the installed files but never touches your account
registry, transfer ledger, or schedules unless you pass `--purge`.

## Command table

| Command | Purpose |
|---|---|
| `claude-session [project] [new\|N]` | Attach to (or start) a numbered session for a project |
| `claude-session ls` | List every session, every account — no picker |
| `claude-session resume` | Interactive picker: open or preview a chat |
| `claude-session doctor [--reap] [--force]` | Find dupes, stalls, stale files, orphaned dev processes, stuck builds; `--reap` cleans up orphans |
| `claude-session kill [session]` | Interactive multi-kill (shows RAM), or a direct `tmux kill-session` shortcut |
| `claude-session accounts add\|ls\|rm <name>` | Register, list, or unregister an isolated Claude Code account |
| `claude-session transfer [sid] --to=<acct> [--from=] [--move] [--launch]` | Copy or move one chat's on-disk state between accounts |
| `claude-session transfer log\|undo\|redo\|prune` | Inspect and reverse entries in the transfer ledger |
| `claude-session schedule add <prompt> ...` | Schedule a prompt to run later or on a timer |
| `claude-session schedule ls\|log\|rm\|run\|keepalive` | Manage scheduled prompts |
| `claude-session -- <args>` | Force native `claude` pass-through (e.g. `-- doctor` to reach Claude's own `doctor`, not ours) |
| `claude-session --version` | Print `claude-session`'s own version, platform, bash version, and lib dir |
| `claude-session -- --version` | Print Claude Code's own version instead |

Unrecognized arguments are forwarded to the real `claude` binary automatically
(inline for one-shot verbs like `update`/`mcp`, in tmux for interactive ones
like `--resume`) — `--` just forces that routing when a verb would otherwise
clash with one of `claude-session`'s own (`doctor` being the obvious one).

## Key flags

| Flag | Meaning |
|---|---|
| `--account=NAME` | Run under a registered account's isolated config dir instead of the default one |
| `--plain` / `-p` | Force non-interactive mode — no picker, even for `resume` |
| `--force` / `-f` | Override the "already RC-bridged" guard, or (for `transfer`) allow overwriting the destination |
| `--move` | `transfer`: remove the source copy instead of keeping it |
| `--launch` | `transfer`: reopen the moved/copied chat, resumed, under the destination account |
| `--reap` | `doctor`: kill the orphaned dev processes it found |
| `--all-accounts` | `schedule keepalive`: create the keepalive schedule for every registered account, not just one |
| `--version` | Print `claude-session`'s own version (see above) |

Full flag reference: `man claude-session`.

## Platform support

| Platform | Status |
|---|---|
| Linux (bash 5, glibc/procps/GNU coreutils) | Full support — this is the primary target |
| macOS (with `brew install bash` for bash 5+) | Full support for sessions, accounts, transfer, and doctor; the **scheduler is not yet implemented on macOS** (systemd only for now — see [docs/scheduler.md](docs/scheduler.md)) |

macOS ships bash 3.2 as `/bin/bash`, which cannot run this tool at all
(`declare -A` requires bash 4+) — install a current bash first. See
[docs/platforms.md](docs/platforms.md) for the full prerequisite list and the
compatibility-wrapper table.

## Configuration files

| Path | Purpose |
|---|---|
| `~/.config/claude-helpers/accounts.conf` | Registered account list (bash-sourced) |
| `~/.config/claude-helpers/transfer-log.jsonl` | The transfer ledger (append-only) |
| `~/.config/claude-helpers/schedules/<id>/` | One directory per scheduled prompt (`meta`, `prompt.txt`) |
| `~/.config/systemd/user/claude-schedule-*.{service,timer}` | Generated systemd units backing each schedule (Linux) |
| `<CLAUDE_CONFIG_DIR>/sessions/*.json` | Live session state Claude Code itself writes per process |
| `<CLAUDE_CONFIG_DIR>/projects/*/*.jsonl` | Chat transcripts (what `transfer` moves) |

`<CLAUDE_CONFIG_DIR>` defaults to `~/.claude` for the default account, or the
directory registered for a named account (see
[docs/accounts.md](docs/accounts.md)).

## Documentation

- [docs/accounts.md](docs/accounts.md) — multiple isolated Claude Code accounts
- [docs/transfer-ledger.md](docs/transfer-ledger.md) — moving chats between accounts, safely
- [docs/scheduler.md](docs/scheduler.md) — running prompts on a timer
- [docs/keepalive.md](docs/keepalive.md) — keeping the 5-hour usage window warm
- [docs/doctor-orphans.md](docs/doctor-orphans.md) — health checks and orphan cleanup
- [docs/troubleshooting.md](docs/troubleshooting.md) — symptom → cause → fix
- [docs/platforms.md](docs/platforms.md) — Linux/macOS support matrix and prerequisites

See also: `man claude-session` (or `man -l man/claude-session.1` from a
checkout) for the complete reference.

## License

MIT — see [LICENSE](LICENSE).
