# Keepalive

**Problem:** Claude Code accounts on a subscription plan get a rolling
5-hour usage window; once it starts, it starts, whether or not you're
actively using it. If a window resets at, say, 4am while you're asleep and
you don't touch Claude again until mid-morning, the window you actually
want (the one covering your working hours) hasn't started yet — you're
effectively wasting the first chunk of it. `schedule keepalive` pings an
account with a trivial low-cost prompt on a timer, so the window you care
about starts when you want it to, not whenever you happen to first type
something.

## What it creates

`claude-session schedule keepalive` is a thin, idempotent wrapper around
`schedule add`: it creates one `--new`, `--mode=plan`, `--model=haiku`
schedule per account, with the prompt `"hi"`, repeating on `--every`
(default `5h`). Using the cheapest model and plan mode (no file edits) keeps
each ping as close to free as this can get while still counting as usage
that starts the window.

## Usage

```bash
claude-session schedule keepalive                       # default account, every 5h
claude-session schedule keepalive --account=work         # a specific account
claude-session schedule keepalive --all-accounts         # one keepalive per registered account
claude-session schedule keepalive --every=4h30m          # a different interval
claude-session schedule keepalive --at=09:00              # first fire anchored to a clock time
claude-session schedule keepalive --in=3h                  # first fire this far from now
```

`--at`/`--in` only make sense for a single account — each account's usage
window resets at its own time, so anchoring the first fire to one clock
time doesn't generalize across `--all-accounts`. If you pass either
alongside `--all-accounts`, `keepalive` prints a warning, ignores both, and
falls back to firing one minute after creation for every account.

## Idempotence

Running `keepalive` again for an account that already has one is a no-op —
it detects the existing schedule (by scanning schedule metadata for
`keepalive=1` plus a matching account) and reports "keepalive already set
... skipping" instead of creating a duplicate. This makes it safe to put in
a setup script or re-run after `install.sh` without worrying about ending up
with two competing keepalive timers.

## Why the reset time has to come from you

Nothing in Claude Code exposes an account's exact 5-hour reset time
programmatically — `claude-session` has no way to discover it on its own.
`--at`/`--in` exist because you're the one who knows (from watching usage
banners, or trial and error) roughly when a given account's window resets;
the tool can anchor the first fire to that moment, but it can't infer it.

## Cost

Each ping is one `haiku`-model, plan-mode, `--new` chat with a single-word
prompt — the cheapest unit of "this counts as usage" available. It costs
essentially nothing per fire, but it isn't literally zero, so `keepalive` is
opt-in per account rather than something `install.sh` sets up automatically.

## Managing a keepalive schedule

A keepalive schedule is a schedule like any other — it shows up in
`claude-session schedule ls`, can be inspected with `schedule log <id>`, and
removed with `schedule rm <id>` if you decide you no longer want it. See
[scheduler.md](scheduler.md) for the general scheduling subsystem.

## Platform support

Keepalive relies entirely on the scheduler backend. On Linux it works via
systemd user timers; on macOS the scheduler has no `launchd` backend yet
(see [scheduler.md](scheduler.md) and [platforms.md](platforms.md)), so
`schedule keepalive` is currently unavailable there too.
