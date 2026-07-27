# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- Linux/macOS portability layer so the tool runs unmodified on both
  platforms.
