# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `ls --json` and `doctor --json`, backed by new `chats`/`issues`/`processes`
  JSON sections (per-chat runtime, title, and provenance state; the five
  session-state checks; orphan/stuck-build processes). `doctor --json` keeps
  the existing exit-code contract (its exit status is the issue count).
- `doctor` gained an upstream session-state schema-drift check: an unrecognized
  field in a `sessions/*.json` file (Claude Code writing something this build
  doesn't know about yet) is now reported by name instead of silently ignored.
  **Note:** this means `doctor`'s issue count can go from 0 to 1 the first time
  Claude Code's session-state schema changes upstream, even with nothing
  otherwise wrong — the exit-code *contract* (0 = all clear) is unchanged, but
  a monitor alerting on `>0` will see this new check the same as any other.

## [0.1.0] - 2026-07-27

### Added

- Multi-account support: register and switch between several Claude Code
  accounts (`accounts add`, `accounts ls`, `accounts rm`).
- Transfer + ledger: move or copy a chat's on-disk state between accounts
  (`transfer`, `--move`, `--force`, `--limit`), with a full ledger
  (`transfer log`, `transfer undo`, `transfer redo`, `transfer prune`),
  divergence guards, and an at-a-glance transfer badge.
- Custom chat titles for friendlier session listings.
- Native `claude` pass-through, so `claude-session` transparently forwards
  unrecognized invocations (and `-- <args>`) to the real `claude` binary.
- `transfer --move --launch`: move a chat and immediately reopen it, resumed,
  under the destination account.
- Scheduler backed by systemd user timers, plus `keepalive` support for
  long-running scheduled prompts.
- `doctor` orphan and stuck-build detection, with an opt-in `--reap` to clean
  up orphaned dev processes.
- Linux/macOS portability layer: process, date, stat, readlink and timeout
  differences are handled in one compat shim rather than at each call site,
  and a bash 4 guard reports stock macOS bash 3.2 with a readable message.

### Known limitations

- The scheduler (`schedule`, `keepalive`) requires systemd user timers and so
  works on Linux only. There is no launchd backend yet; every other subcommand
  is platform-independent. See `docs/platforms.md`.
