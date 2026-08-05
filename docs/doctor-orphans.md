# Doctor and orphan detection

**Problem:** a long-running Claude Code setup accumulates failure modes
that are invisible from any single session — two processes silently holding
the same chat, a phone approval that never arrived, a `tmux` session whose
`claude` already exited, and — the sharpest one — child processes a killed
session leaves behind that never stop on their own and quietly eat CPU for
days. `claude-session doctor` is a single command that checks for all of
them at once.

## The five session checks

These read the live Claude session-state JSON files (`sessions/*.json`
under each account's config dir), so they only have something to say when
at least one session is known:

1. **Same chat open twice** — two different processes (pids) both hold the
   same `sessionId`. A true duplicate: the exact same conversation opened
   in two places.
2. **Same RC bridge held by two procs** — two processes both hold the same
   `bridgeSessionId` (Remote Control bridge). Whichever one didn't start the
   bridge is just mirroring text, with no ability to approve anything.
3. **Partial-bridge duplicates** — multiple processes share the same
   `(cwd, account)` but only some are RC-bridged. Different accounts
   sharing the same directory are excluded on purpose — that's two
   legitimate independent setups, not a conflict.
4. **Stalled "waiting" status** — a session has been sitting in a
   `waiting:*` status for 5+ minutes. Usually means a phone approval got
   lost.
5. **Stale session files** — the session's pid no longer exists but its
   state file is still there. Harmless on its own, just noted.

## Orphaned dev processes (the reason `doctor` exists)

Killing a `tmux` session or a `claude` process does **not** kill its
children — they get reparented to init (`ppid=1`) and keep running forever
unless something else stops them. This is invisible to every one of the
five checks above, because none of them look at the OS process table at
all — they only read Claude's own session-state files.

This was not a hypothetical: a batch of killed sessions once left several
`plugin:build` and `npm run dev` process trees running unattended for
hours, well past the point any human was watching them, driving sustained
CPU load on a small VPS with none of it visible in `claude-session ls`.
Check (6) exists specifically because of that incident.

**Check (6)** scans the whole process table (not just Claude-related pids)
for processes matching a dev-runner pattern (`node`, `npm`, `vite`,
`webpack`, `plugin:build`, and similar), older than 5 minutes, with
`ppid=1`, owned by you, and not matching a protected daemon list (`tmux`,
`sshd`, `postgres`, `dockerd`, etc. — deliberately generous prefix matching,
since accidentally killing a real daemon is far worse than leaving one dev
process alive a little longer).

**Check (7)** looks for any process whose command line contains a
`*:build` subcommand and has been running more than 10 minutes, regardless
of its parent — a plugin or package build takes seconds; one running that
long is hung, whether or not its parent process is still alive.

## Orphan ≠ dead weight

An orphan can read 0.0% CPU on the exact pid `doctor` found and still be
doing real work several levels down its process tree — a `claude`
shell-snapshot wrapper spawning `bash run.sh` spawning an active `codex exec`
that's writing logs right now, for example. Judging only the root pid would
silently destroy that job. So before anything is shown or reaped, `doctor`
walks the **entire descendant subtree** of each orphan
(`_orphan_activity`) and classifies the whole thing as `active` if any
process in it is CPU-busy (≥0.5%) or matches a known long-running-work
pattern (`codex`, `pytest`, `cargo`, `docker build`, `npm run build`, and
similar). A false "active" only costs a delayed reap; a false "idle" would
destroy real work — so the check is deliberately conservative in the
"active" direction.

`doctor`'s output marks every orphan it finds with `[reapable]` or an
"active — reap will skip it" note, so you know before running `--reap`
exactly what it will and won't touch:

```
⚠ 2 orphaned dev process(es) (ppid=1), 0.0% CPU total — 1 reapable, 1 busy (parents died)
    pid 901163  39h21m  0.0%  claude shell wrapper  [reapable]
    pid 812004  6h02m   0.0%  bash run.sh
        ↳ active: codex exec (long-running job) — reap will skip it
    → reap them: claude-session doctor --reap
```

## `--reap`

```bash
claude-session doctor --reap            # interactive confirm before killing anything
claude-session doctor --reap --force    # unattended (e.g. from a cron job or CI)
```

`--reap` re-verifies each candidate immediately before killing it (a parent
could have reappeared, or the pid could already be gone), sends `SIGTERM`
to the whole subtree, waits, then `SIGKILL`s anything still alive. It never
touches pid 1 or itself.

An orphan's subtree is classified `idle`, `active`, or `suspect`:

- **`active`** — a descendant is doing real work (busy CPU, or a known
  long-running command). Skipped and reported, never killed, **regardless of
  `--force`**: a genuinely working build or agent run must not be destroyed by
  an unattended reap. `--force` cannot override this.
- **`suspect`** — a `*:build` (or other CPU-busy) process that is past the
  "this has run too long" threshold **and** has made no measurable I/O progress
  across a short sample (Linux only, via `/proc/<pid>/io`; on other platforms
  the probe is skipped and the process stays `active`). It *appears* hung but is
  not proven so — a CPU-bound phase such as type-checking can be legitimately
  quiet — so it is **never auto-reaped**. This is the one case `--force`
  overrides: with `--force` a `suspect` subtree is killed, giving you a guarded
  path to clear a spinning build that would otherwise be immortal to the reaper.
- **`idle`** — nothing is running under it. Reaped after the interactive confirm,
  or immediately under `--force`.

So `--force` removes the interactive confirmation for `idle` orphans and,
additionally, overrides the guard for `suspect` ones — but it never touches a
genuinely `active` subtree.

Without a TTY and without `--force`, `--reap` refuses outright (exit status
2) rather than silently doing nothing or silently proceeding — there is no
safe default for "should I kill processes with no one watching," so it asks
explicitly.

## Exit status

`doctor` (without `--reap`) exits with the number of issues it found — `0`
means "all clear." This makes `claude-session doctor; echo $?` usable
directly in scripts or a keepalive-adjacent monitoring loop without parsing
its human-readable output.
