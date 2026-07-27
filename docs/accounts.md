# Accounts

**Problem:** Claude Code keeps all of its state — credentials, settings,
session history, project transcripts — under one `CLAUDE_CONFIG_DIR`
(`~/.claude` by default). If you use Claude Code for more than one context
(a day job, a personal account, a client's account) you either share one
login across all of it, or you juggle `CLAUDE_CONFIG_DIR=... claude` by hand
every time and hope you remember which shell has which one exported.
`claude-session accounts` turns that into a small registry so each account
is a name, not an environment variable you have to remember.

## How isolation works

Each registered account gets its own `CLAUDE_CONFIG_DIR`, so its
credentials, settings, and chat history never mix with any other account's.
The **default account** is special: it is always `~/.claude`, needs no
`CLAUDE_CONFIG_DIR` override, and never appears in the registry file — it
exists implicitly, the same way plain `claude` has always worked.

Every other account is registered under a name (`work`, `personal`, whatever
you choose) and gets a config directory under `~/.claude-accounts/<name>/`
unless you point it elsewhere.

## Registry format

Accounts live in `~/.config/claude-helpers/accounts.conf` — bash-sourced,
one `account` call per line, re-read on every invocation:

```bash
# ~/.config/claude-helpers/accounts.conf
#
# Format: account <name> <config-dir> '<description>'
account work /home/you/.claude-accounts/work 'day job'
account personal /home/you/.claude-accounts/personal 'side projects'
```

Hand-editing is fine — it's just bash. Names must match `[a-zA-Z0-9_-]+`;
`default` is reserved and rejected if you try to register it.

## Commands

```bash
claude-session accounts add <name> [description]  # register + interactive /login
claude-session accounts ls                        # list registered accounts
claude-session accounts rm <name>                 # unregister (credentials kept on disk)
```

`accounts add` registers the name (creating the config dir and the registry
file if needed), then launches `claude` under it so you can run `/login`
interactively; `Ctrl-D` afterward finishes setup. `accounts rm` only edits
the registry — it deliberately leaves the credentials directory on disk and
prints the `rm -rf` command to run if you actually want to delete them, so
removing an account from the list can never silently destroy a chat history
you meant to keep.

## Using an account

Add `--account=<name>` to almost anything:

```bash
claude-session myproject --account=work        # session becomes myproject-claude-work
claude-session -- --version --account=work     # native pass-through under that account
claude-session transfer --to=work               # transfer subsystem, see docs/transfer-ledger.md
```

The tmux session name gets a `-<name>` suffix so the same project can have
one running session per account simultaneously without colliding.

## The per-(directory, account) dup-guard

Starting a session normally refuses to open a second Claude process for the
same project directory while one already holds the Remote Control bridge —
that guard is scoped to `(directory, account)`, not just directory. Two
different accounts can each have their own bridged session open in the same
project directory at the same time; that's treated as two independent
setups, not a duplicate. Two attempts under the *same* account in the *same*
directory still trip the guard exactly as they would with no accounts
involved at all. `--force` overrides it either way, and `claude-session
doctor` explains what it's seeing when it fires.

`ls`, `doctor`, `resume`, and `kill` all cover every registered account at
once — cards are tagged `[account]` unless it's the default one, so you get
one unified view instead of having to check each account separately.
