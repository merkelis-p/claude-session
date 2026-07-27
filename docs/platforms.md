# Platform support

**Problem:** this tool leans on Linux-specific tools in a few places
(`/proc`, GNU `date`/`stat`, `etimes` from GNU `ps`, systemd) that don't
exist on macOS at all. Rather than silently degrading or crashing with a
cryptic error on the other platform, every genuine OS difference is
centralized in one compatibility layer (`compat.sh`), and this page states
plainly what is and isn't supported where.

## Support matrix

| Platform | Sessions / accounts / transfer / doctor | Scheduler (`schedule`/`keepalive`) |
|---|---|---|
| Linux (bash 5, glibc/procps/GNU coreutils) | Full support — primary target | Full support, via `systemd --user` timers |
| macOS (with `brew install bash`) | Full support | **Not implemented** — no `launchd` backend exists yet |

## macOS prerequisites

**`brew install bash` is required, not optional.** Stock macOS ships bash
3.2.57 as `/bin/bash`, and this tool will not start at all under it —
associative arrays (`declare -A`) require bash 4+, and several are declared
at the top level of the sourced helpers, so the crash
(`declare: -A: invalid option`) happens before a single line of dispatch
logic runs, on every subcommand. Install a current bash first:

```bash
brew install bash
```

Make sure the Homebrew bash is what actually runs — either put
`/opt/homebrew/bin` (Apple Silicon) or `/usr/local/bin` (Intel) ahead of
`/bin` on your `PATH`, or invoke the script with that bash explicitly.

**`brew install coreutils` is optional**, for `gtimeout`. The scheduler's
run-time cap (`--timeout`) and the compat layer's `_timeout` wrapper prefer
GNU `timeout`; on macOS that's `gtimeout` from `coreutils`. Without either,
timeouts aren't silently ignored — a warning is printed and the command
runs uncapped instead.

## The scheduler gap, stated plainly

`claude-session schedule` and `claude-session schedule keepalive` are
implemented against `systemd --user` timers only. There is no `launchd`
equivalent yet. On macOS, every `schedule` subcommand will fail (loudly,
not silently) because `systemctl`/`journalctl` don't exist there. This is a
real, currently-open gap — not a "should work, untested" situation — see
[scheduler.md](scheduler.md) for what a `launchd` backend would need to
look like, and [troubleshooting.md](troubleshooting.md) for the symptom you'll
see if you try it anyway.

Everything else — sessions, accounts, transfer, doctor/orphan detection —
is fully supported on macOS once bash 4+ is in place.

## The compat-wrapper table

`compat.sh` is sourced first, before `ui.sh`, and defines the portable
functions every other file calls instead of touching `/proc`, GNU `date`,
or GNU `stat` directly. Most wrappers need **no OS branch at all** — the
same command works identically on both platforms; a few are genuine
per-OS branches.

| Wrapper | Purpose | Linux | macOS |
|---|---|---|---|
| `_proc_alive` | Is a pid alive? | `kill -0 "$pid"` | same — no branch |
| `_proc_comm` | Process command name | `ps -o comm= -p "$pid"` | same — no branch |
| `_proc_args` | Full process argv | `ps -o args= -p "$pid"` | same — no branch |
| `_proc_owner_uid` | Owning uid of a pid | `ps -o uid= -p "$pid"` | same — no branch |
| `_proc_elapsed_s` / `_etime_to_s` | Seconds since process start | `ps -o etime=` parsed | same field, same parser — no branch (`etime` exists on both; the Linux-only field is `etimes`, which this deliberately avoids) |
| `_proc_table` | Whole process table as TSV (pid, ppid, elapsed, %cpu, comm, args) | Two bulk calls — `ps -eo pid=,comm=` and `ps -eo pid=,ppid=,etime=,pcpu=,args=` — joined by pid in one `awk` (etime → seconds is computed there too); deliberately **not** `_proc_comm` per pid, since a per-pid `ps` fork once made `ls`/`doctor` take minutes on a large process table | same — no branch |
| `_reverse_lines` | Reverse line order (replaces `tac`) | `awk` one-liner | same — no branch |
| `_file_mtime` | File modification time as epoch seconds | `stat -c '%Y'` | `stat -f '%m'` |
| `_epoch_to_human` | epoch → formatted date string | `date -d "@$e" "$fmt"` | `date -r "$e" "$fmt"` |
| `_parse_datetime` | `"YYYY-MM-DD HH:MM[:SS]"` → epoch | `date -d "$s" +%s` | `date -j -f '%Y-%m-%d %H:%M[:%S]' "$s" +%s` |
| `_next_clock_epoch` | Next occurrence of `HH:MM` (today or tomorrow) | built on `_parse_datetime` | built on `_parse_datetime` |
| `_readlink_f` | Canonical absolute path | `readlink -f "$p"` | `perl -MCwd=abs_path -e 'print abs_path(shift)'` (BSD `readlink` has no `-f`; perl ships with macOS) |
| `_timeout` | Run a command with a time cap | `timeout "$dur" "$@"` | `gtimeout "$dur" "$@"` if `coreutils` is installed, else runs uncapped with a printed warning |

`_compat_os` detects `linux`/`darwin` via `uname -s`, overridable with
`CLAUDE_COMPAT_OS` (used by the test suite to exercise both branches from
one host without needing an actual Mac).

## What's fundamentally Linux-only

The `schedule.sh` backend (systemd user timers) is not a shim-able
difference — `launchd` is conceptually different enough (property lists
instead of INI-style units, no `journalctl` equivalent) that supporting it
would mean a second backend module, not a wrapper function. See
[scheduler.md](scheduler.md) for the current state.
