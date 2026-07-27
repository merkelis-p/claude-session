# Scheduler

**Problem:** some prompts don't need a human sitting there — a nightly
summary, a periodic check-in, a one-off reminder to run tomorrow morning.
`claude-session schedule` turns a prompt plus a timing rule into a
background job that fires Claude Code on its own, without an interactive
session or a person watching.

## Backends

| Platform | Backend | Status |
|---|---|---|
| Linux | `systemd --user` timers | Implemented |
| macOS | `launchd` agents | **Not implemented yet** |

On Linux, `schedule add` writes a `.service` + `.timer` unit pair under
`~/.config/systemd/user/` and enables them with `systemctl --user`. On
macOS, `schedule`/`keepalive` are currently unavailable — there is no
`launchd`-backed fallback in this release. If `systemctl` isn't found,
every schedule subcommand fails plainly (not silently) rather than pretend
to have scheduled anything. See [platforms.md](platforms.md) for the
platform matrix.

## Targets

A scheduled prompt runs against one of two targets:

- `--chat=<sessionId>` — resumes an existing chat and appends the prompt to it.
- `--new` — starts a brand-new chat each time the schedule fires (a fresh
  `--session-id`).

Exactly one of the two is required.

## Schedule kinds

- `--every=<duration>` — repeats forever on an interval (systemd span
  syntax: `30min`, `5h`, `1d`, ...).
- `--daily-at=<HH:MM>` — repeats once a day at a fixed 24h clock time.
- `--once="<YYYY-MM-DD HH:MM>"` — fires exactly once, then the timer is
  disabled automatically after it runs.

## Adding a schedule

```bash
claude-session schedule add "Summarize yesterday's commits" --new --daily-at=09:00
claude-session schedule add "Check for flaky test failures" --chat=<sid> --every=2h
claude-session schedule add "Remind me to deploy" --new --once="2026-08-01 08:00"
```

Optional flags:

| Flag | Purpose |
|---|---|
| `--account=NAME` | Run under a registered account (default: the default account) |
| `--mode=plan\|autopilot` | Permission mode for the run (maps to `--permission-mode`; default `autopilot`) |
| `--cwd=DIR` | Working directory for the run (default: the directory you added it from) |
| `--timeout=DURATION` | Hard cap on the run (default `30m`; passed through `timeout`/`gtimeout`) |

Each schedule gets a short id (e.g. `7c78ba`) and lives in its own directory
under `~/.config/claude-helpers/schedules/<id>/` (`meta` + `prompt.txt`).

## Managing schedules

```bash
claude-session schedule ls              # list every schedule, plus systemd's own timer summary
claude-session schedule log <id>        # tail the last run's output (journalctl)
claude-session schedule rm <id>         # disable and remove a schedule entirely
claude-session schedule run <id>        # fire a schedule immediately, out of band
```

`schedule ls` prints claude-session's own boxed summary (id, cadence,
target, mode, prompt preview) followed by `systemctl --user list-timers`'s
native output, so you can see both the friendly view and the underlying
timer state (next fire, last result) in one command.

## Permission modes

`--mode=plan` runs the prompt in plan mode (Claude proposes but does not
execute changes); `--mode=autopilot` (the default for scheduled runs) maps
to `--permission-mode acceptEdits`, since there is no one present to approve
prompts interactively. Choose `plan` for anything you want to review before
it touches files.

## Timeouts

Every scheduled run is wrapped in `timeout` (or `gtimeout` on macOS via
`brew install coreutils`) using `--timeout` (default `30m`). If neither
`timeout` nor `gtimeout` is available, the run proceeds uncapped — loudly,
with a warning printed first, never silently.

## Logs

Each schedule's unit logs to the systemd user journal under its own service
name (`claude-schedule-<id>.service`); `claude-session schedule log <id>`
is a thin wrapper around `journalctl --user -u claude-schedule-<id>.service`.

See also [keepalive.md](keepalive.md) for `schedule keepalive`, a specific,
idempotent use of this same subsystem.
